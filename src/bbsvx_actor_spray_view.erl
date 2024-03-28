%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray_view).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_common_types.hrl").
-include_lib("ejabberd/include/mqtt.hrl").
%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(EXCHANGE_TIMEOUT, 10000).

%% External API
-export([start_link/1, start_link/2, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3]).

-record(state,
        {in_view = [] :: [node_entry()],
         out_view = [] :: [node_entry()],
         namespace :: binary(),
         my_node :: node_entry(),
         cached_exchange = [] :: list(),
         pid_exchanger = undefined :: {pid(), reference()} | undefined,
         pid_exchange_timeout = undefined}).

%%%=============================================================================
%%% API
%%%=============================================================================
-spec start_link(Namespace :: binary()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace) ->
    start_link(Namespace, []).

-spec start_link(Namespace :: binary(), Options :: list()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, Options) ->
    gen_statem:start({via, gproc, {n, l, {?MODULE, Namespace}}},
                     ?MODULE,
                     [Namespace, Options],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    process_flag(trap_exit, true),

    init_metrics(Namespace),
    logger:info("spray Agent ~p : Starting state with Options ~p", [Namespace, Options]),
    %% Get our node id
    MyNodeId = bbsvx_crypto_service:my_id(),
    %% Get our host and port
    {ok, {Host, Port}} = bbsvx_connections_service:my_host_port(),
    MyNode =
        #node_entry{node_id = MyNodeId,
                    host = Host,
                    port = Port},
    %% Check options for contact_nodes to connect to
    case proplists:get_value(contact_nodes, Options) of
        undefined ->
            ok;
        [] ->
            ok;    
        [_ | _] = ContactNodes ->
            %% Choose a random node from the contact nodes
            ContactNode =
                lists:nth(
                    rand:uniform(length(ContactNodes)), ContactNodes),
            %% Start a join to the contact node
            bbsvx_actor_spray_join:start_link(contact, Namespace, MyNode, ContactNode)
    end,

    %% Register to events for this ontolgy namespace
    gproc:reg({p, l, {ontology, Namespace}}),

    {ok,
     running,
     #state{namespace = Namespace,
            my_node =
                #node_entry{node_id = MyNodeId,
                            host = Host,
                            port = Port}}}.

terminate(_Reason, #state{namespace = Namespace}, State) ->
    %% Notify outview we are leaving the node
    OutView = State#state.out_view,
    InViewNameSpace =
        iolist_to_binary([<<"ontologies/in/">>,
                          Namespace,
                          "/",
                          State#state.my_node#node_entry.node_id]),
    lists:foreach(fun(Node) ->
                     gen_statem:call({via, gproc, {n, l, Node#node_entry.node_id}},
                                     {publish,
                                      InViewNameSpace,
                                      {disconnecting, State#state.namespace, State#state.my_node}})
                  end,
                  OutView),
    %% Unsubscribe the nodes from the outview
    lists:foreach(fun(Node) ->
                     gen_statem:call({via, gproc, {n, l, {bbsvx_mqtt_connection, Node#node_entry.node_id}}},
                                     {unsubscribe, InViewNameSpace})
                  end,
                  OutView),
    %% Send disconnecting message to the inview
    InView = State#state.in_view,
    lists:foreach(fun(Node) ->
                    Topic =
                        iolist_to_binary([<<"ontologies/in/">>,
                                          State#state.namespace,
                                          "/",
                                          Node#node_entry.node_id]),
                     mod_mqtt:publish({State#state.my_node#node_entry.node_id,
                                       <<"localhost">>,
                                       <<"bob3">>},
                                      #publish{topic = Topic,
                                               payload = term_to_binary({disconnecting,
                                                                         State#state.namespace,
                                                                         State#state.my_node}),
                                               retain = false},
                                      ?MAX_UINT32)
                  end,
                  InView),

    %% Unsubscribe the nodes from the inview
    lists:foreach(fun(Node) ->
                    Topic = iolist_to_binary([<<"ontologies/in/">>, Namespace, "/", Node#node_entry.node_id]),
                     mod_mqtt:unsubscribe({Node#node_entry.node_id,
                                           <<"localhost">>,
                                           <<"bob3">>},
                                          Topic)
                  end,
                  InView),
    %% Maybe terminate epto service
    supervisor:terminate_child(bbsvx_sup_epto_agents,
                               {via, gproc, {n, l, {bbsvx_epto_service, Namespace}}}),

    %% Terminate leader manager
    supervisor:terminate_child(bbsvx_sup_leader_agents,
                               {via, gproc, {n, l, {bbsvx_actor_leader_manager, Namespace}}}),
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
running(enter, _OldState, State) ->
    case State#state.pid_exchange_timeout of
        undefined ->
            logger:info("spray Agent ~p : Running state, Starting exchange timer",
                        [State#state.namespace]),
            {ok, Pid} = timer:send_interval(?EXCHANGE_TIMEOUT, spray_loop),
            {keep_state, State#state{pid_exchange_timeout = Pid}};
        _ ->
            keep_state_and_data
    end;
%% Receive contact request
running(info, {contact_request, TargetNode}, State) ->
    %% Start a contact manager
    bbsvx_actor_spray_contact_manager:start_link(State#state.namespace,
                                                 State#state.my_node,
                                                 TargetNode),
    keep_state_and_data;
%% Remove nodes from outview
running(info,
        {remove_from_view, outview, #node_entry{node_id = NodeId} = Node},
        #state{out_view = [#node_entry{node_id = NodeId}]} = State) ->
    %% We don't remove the last node from the outview
    logger:info("spray Agent ~p : Running state, Prenventing empty out view ~p",
                [{State#state.namespace, Node}, State#state.out_view]),
    prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_outview_depleted_">>,
                                                            binary:replace(State#state.namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))),
    keep_state_and_data;
running(info,
        {remove_from_view, outview, #node_entry{} = Node},
        #state{namespace = Namespace} = State) ->
    logger:info("spray Agent ~p : Running state, Removing node ~p from outview",
                [State#state.namespace, Node]),

    NewOutView =
        lists:keydelete(Node#node_entry.node_id, #node_entry.node_id, State#state.out_view),

    Topic =
        iolist_to_binary([<<"ontologies/in/">>,
                          State#state.namespace,
                          "/",
                          State#state.my_node#node_entry.node_id]),

    ConPid = gproc:where({n, l, {bbsvx_mqtt_connection, Node#node_entry.node_id}}),
    gen_statem:call(ConPid, {publish, Topic, {left_inview, Namespace, State#state.my_node}}),
    gproc:send({n, l, {bbsvx_mqtt_connection, Node#node_entry.node_id}},
               {unsubscribe, Topic}),
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_outview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewOutView)),
    {keep_state, State#state{out_view = NewOutView}};
%% Remove nodes from inview
running(info,
        {remove_from_view, inview, #node_entry{node_id = NodeId} = Node},
        #state{namespace = Namespace, in_view = [#node_entry{node_id = NodeId}]} = State) ->
    %% We are removing our last inview node, we should request a new join to us
    %% to the oldest node in our outview
    logger:info("spray Agent ~p : Running state, Preventing empty in view ~p",
                [{State#state.namespace, Node}, State#state.in_view]),
    prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_inview_depleted_">>,
                                                            binary:replace(Namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))),

    OldestOutviewNode = get_oldest_node(State#state.out_view),
    logger:info("spray Agent ~p : Running state, refuel inview request to ~p",
                [State#state.namespace, OldestOutviewNode]),
    %% send join request to oldest node in outview
    ConnPid =
        gproc:where({n, l, {bbsvx_mqtt_connection, OldestOutviewNode#node_entry.node_id}}),

    gen_server:call(ConnPid,
                    {publish,
                     iolist_to_binary([<<"ontologies/in/">>,
                                       State#state.namespace,
                                       "/",
                                       State#state.my_node#node_entry.node_id]),
                     {empty_inview, State#state.my_node}}),
    {keep_state, State#state{in_view = []}};
running(info,
        {remove_from_view, inview, #node_entry{} = Node},
        #state{namespace = Namespace} = State) ->
    logger:info("spray Agent ~p : Running state, Removing node ~p from inview",
                [State#state.namespace, Node]),

    NewInView =
        lists:keydelete(Node#node_entry.node_id, #node_entry.node_id, State#state.in_view),
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_inview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewInView)),
    {keep_state, State#state{in_view = NewInView}};
%%Manage empty inview message reception
running(info, {empty_inview, RequesterNode}, State) ->
    logger:info("spray Agent ~p : Running state, Got empty inview message from ~p",
                [State#state.namespace, RequesterNode]),
    prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_empty_inview_answered_">>,
                                                            binary:replace(State#state.namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))),
    %% Add the node to our outview
    bbsvx_actor_spray_join:start_link(join_inview,
                                      State#state.namespace,
                                      State#state.my_node,
                                      RequesterNode),
    keep_state_and_data;
%% Manage requests to join a view
running(info,
        {add_to_view, inview, #node_entry{} = RequesterNode},
        #state{namespace = Namespace} = State) ->
    logger:info("spray Agent ~p : Running state, Adding to inview : ~p",
                [State#state.namespace, RequesterNode]),

    NewinView = [RequesterNode#node_entry{age = 0} | State#state.in_view],
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_inview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewinView)),
    {keep_state, State#state{in_view = NewinView}};
running(info, {add_to_view, outview, #node_entry{} = RequesterNode}, State) ->
    logger:info("spray Agent ~p : Running state, Adding to out view ~p",
                [State#state.namespace, RequesterNode]),
    NewOutView = [RequesterNode#node_entry{age = 0} | State#state.out_view],
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_outview_size_">>,
                                                          binary:replace(State#state.namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewOutView)),
    {keep_state, State#state{out_view = NewOutView}};
%% Manage forwarded subcription requests
running(info,
        {forwarded_subscription, Namespace, #node_entry{} = RequesterNode},
        State) ->
    logger:info("spray Agent ~p : Running state, Got forwarded subscription request from ~p",
                [State#state.namespace, RequesterNode]),
    %% Spawn spray join agent to join the inview of forwarded subscription
    bbsvx_actor_spray_join:start_link(join_inview,
                                      Namespace,
                                      State#state.my_node,
                                      RequesterNode),
    {keep_state, State};
%%Exchange management
%% Exchange with an empty out view
running(info, spray_loop, #state{out_view = OutView} = State) when length(OutView) =< 1 ->
    logger:info("spray Agent ~p : Running state, Empty out view, ignoring",
                [State#state.namespace]),
    keep_state_and_data;
running(info,
        spray_loop,
        #state{pid_exchanger = undefined,
               my_node = MyNode,
               namespace = Namespace,
               out_view = OutView} =
            State) ->
    %% Increase age of nodes in outview
    %% Increment age of nodes in out view
    AgedPartialView =
        lists:map(fun(Node) -> Node#node_entry{age = Node#node_entry.age + 1} end, OutView),
    %% Start a partial view exchange
    {ok, PidExchanger} =
        bbsvx_actor_spray_view_exchanger:start_link(initiator, Namespace, MyNode),
    RefExchanger = erlang:monitor(process, PidExchanger),

    {keep_state,
     State#state{pid_exchanger = {PidExchanger, RefExchanger}, out_view = AgedPartialView}};
running(info, spray_loop, #state{} = State) ->
    logger:info("spray Agent ~p : Running state, Concurent spray loop, ignoring",
                [State#state.namespace]),
    keep_state_and_data;
%% Received partial view exchange in and no exchanger running
running(info,
        {partial_view_exchange_in,
         Namespace,
         #node_entry{} = OriginNode,
         IncomingSamplePartialView},
        #state{pid_exchanger = undefined, my_node = MyNode} = State) ->
    logger:info("spray Agent ~p : Running state, Got partial view exchange in from ~p proposing : ~p",
                [State#state.namespace, OriginNode, IncomingSamplePartialView]),
    %% Add the incoming partial view to our inview
    {ok, PidExchanger} =
        bbsvx_actor_spray_view_exchanger:start_link(responder,
                                                    Namespace,
                                                    MyNode,
                                                    OriginNode,
                                                    IncomingSamplePartialView),
    RefExchanger = erlang:monitor(process, PidExchanger),
    {keep_state, State#state{pid_exchanger = {PidExchanger, RefExchanger}}};
running(info,
        {partial_view_exchange_in, Namespace, OriginNode, IncomingSamplePartialView},
        State) ->
    logger:info("spray Agent ~p : Running state, Caching  partial view exchange in from ~p proposing : ~p",
                [State#state.namespace, OriginNode, IncomingSamplePartialView]),
    {keep_state,
     State#state{cached_exchange =
                     State#state.cached_exchange
                     ++ [{partial_view_exchange_in,
                          Namespace,
                          OriginNode,
                          IncomingSamplePartialView}]}};
%% Manage reception of disconnection messages
running(info,
        {disconnection, #node_entry{node_id = DisconnectedNodeId} = Node},
        #state{out_view = OutView} = State) ->
    logger:info("spray Agent ~p : Running state, Got disconnection message from ~p",
                [State#state.namespace, Node]),

    %% Count and remove all occurences of disparting node_id from our outview
    {Count, NewOutView} =
        lists:foldl(fun(#node_entry{node_id = NodeId} = N, {Count, Acc}) ->
                       case NodeId of
                           DisconnectedNodeId ->
                               {Count + 1, Acc};
                           _ ->
                               {Count, [N | Acc]}
                       end
                    end,
                    {0, []},
                    OutView),
    lists:foldl(fun(C) ->
                   case rand:uniform() of
                       N when N > 1 / (length(NewOutView) + C) ->
                           DuplicatedNode = lists:nth(round(N * length(NewOutView)), NewOutView),
                           NewOutView ++ [DuplicatedNode#node_entry{age = 0}];
                       _ ->
                           NewOutView
                   end
                end,
                NewOutView,
                lists:seq(1, Count)),
    %% Remove the node from our inview
    {keep_state, State#state{out_view = NewOutView}};
running(info,
        {'DOWN', MonitorRef, process, PidTerminating, _Info},
        #state{my_node = MyNode,
               pid_exchanger = {PidTerminating, MonitorRef},
               cached_exchange =
                   [{partial_view_exchange_in, Namespace, OriginNode, IncomingSamplePartialView} =
                        CachedExchange
                    | OtherCachedExchanges]} =
            State) ->
    logger:info("spray Agent ~p : Running state, Partial view exchange done procesing cached events ~p",
                [State#state.namespace, CachedExchange]),
    {ok, PidExchanger} =
        bbsvx_actor_spray_view_exchanger:start_link(responder,
                                                    Namespace,
                                                    MyNode,
                                                    OriginNode,
                                                    IncomingSamplePartialView),
    RefExchanger = erlang:monitor(process, PidExchanger),

    {keep_state,
     State#state{pid_exchanger = {PidExchanger, RefExchanger},
                 cached_exchange = OtherCachedExchanges}};
running(info,
        {'DOWN', MonitorRef, process, PidTerminating, _Info},
        #state{pid_exchanger = {PidTerminating, MonitorRef}} = State) ->
    logger:info("spray Agent ~p : Running state, Partial view exchange done",
                [State#state.namespace]),
    {keep_state, State#state{pid_exchanger = undefined}};
%% Answer get inview request
running({call, From}, get_outview, #state{out_view = OutView} = State) ->
    gen_statem:reply(From, {ok, OutView}),
    {keep_state, State};
%% Answer get inview request
running({call, From}, get_inview, #state{in_view = InView} = State) ->
    gen_statem:reply(From, {ok, InView}),
    {keep_state, State};
%% Return both views
running({call, From}, get_views, #state{in_view = InView, out_view = OutView} = State) ->
    gen_statem:reply(From, {ok, {InView, OutView}}),
    {keep_state, State};
running(Type, Event, State) ->
    logger:info("spray Agent ~p : Running state, Unhandled event ~p",
                [State#state.namespace, {Type, Event}]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% @doc
%% get_oldest_node/1
%% Get the oldest node in a view
%% @end
%% ----------------------------------------------------------------------------
get_oldest_node([Node]) ->
    Node;
get_oldest_node(Nodes) ->
    Sorted = lists:keysort(#node_entry.age, Nodes),
    lists:last(Sorted).

init_metrics(Namespace) ->
    %% Create some metrics
    prometheus_gauge:new([{name,
                           binary_to_atom(iolist_to_binary([<<"spray_networksize_">>,
                                                            binary:replace(Namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))},
                          {help, "Number of nodes patricipating in this ontology network"}]),
    prometheus_gauge:new([{name,
                           binary_to_atom(iolist_to_binary([<<"spray_inview_size_">>,
                                                            binary:replace(Namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))},
                          {help, "Number of nodes in ontology inview"}]),
    prometheus_gauge:new([{name,
                           binary_to_atom(iolist_to_binary([<<"spray_outview_size_">>,
                                                            binary:replace(Namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))},
                          {help, "Number of nodes in ontology partial view"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_initiator_echange_timeout_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number of nodes in ontology inview"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_inview_depleted_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number of nodes in ontology inview"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_outview_depleted_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number of nodes in ontology inview"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_empty_inview_answered_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number of nodes in ontology inview"}]).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

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
-include("bbsvx_tcp_messages.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(EXCHANGE_TIMEOUT, 10000).

%% External API
-export([start_link/1, start_link/2, stop/0, reinit_age/2]).
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

reinit_age(Namespace, NodeId) ->
    gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}},
                    {reinit_age, NodeId}).

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
    {ok, {Host, Port}} = bbsvx_client_service:my_host_port(),
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
            logger:info("spray Agent ~p : Starting state, Connecting to contact node ~p",
                        [Namespace, ContactNode]),
            %% Start a join to the contact node
            supervisor:start_child(bbsvx_sup_client_connections,
                                   [register,
                                    Namespace,
                                    MyNode,
                                    ContactNode#node_entry{host =
                                                               binary_to_list(ContactNode#node_entry.host)}])
    end,

    %% Register to events for this ontolgy namespace
    gproc:reg({p, l, {ontology, Namespace}}),

    %%Register to events from client connections on this namespace
    gproc:reg({p, l, {bbsvx_client_connection, Namespace}}),

    {ok,
     running,
     #state{namespace = Namespace,
            my_node =
                #node_entry{node_id = MyNodeId,
                            host = Host,
                            port = Port}}}.

terminate(_Reason, _PreviousState, #state{namespace = Namespace} = State) ->
    logger:info("spray Agent ~p : Terminating state", [Namespace]),
    %% Notify outview we are leaving the node
    %% Maybe terminate epto service
    supervisor:terminate_child(bbsvx_sup_epto_agents,
                               {via, gproc, {n, l, {bbsvx_epto_service, Namespace}}}),

    %% Terminate leader manager
    supervisor:terminate_child(bbsvx_sup_leader_managers,
                               {via, gproc, {n, l, {bbsvx_actor_leader_manager, Namespace}}}).

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Add/Join View %%%%%%%%%%%%%%%%%%%%%%%%%%%%
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
running(info,
        {connected, _Namespace, RequesterNode, {outview, _}},
        #state{namespace = Namespace, out_view = OutView} = State) ->
    logger:info(" --> spray Agent ~p : Running state, Connected to ~p, adding "
                "to outview",
                [State#state.namespace, RequesterNode]),
    NewOutView = [RequesterNode#node_entry{age = 0} | OutView],
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_outview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewOutView)),
    {keep_state, State#state{out_view = NewOutView}};
running(info,
        {connected, _Namespace, RequesterNode, {inview, register}},
        #state{namespace = Namespace,
               my_node = MyNode,
               out_view = OutView,
               in_view = InView} =
            State) ->
    NewInView = [RequesterNode#node_entry{age = 0} | InView],
    logger:info("--> spray Agent ~p : Running state, Connected to ~p, adding "
                "to inview",
                [State#state.namespace, RequesterNode]),
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_inview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewInView)),

    %% If our outview is empty, we should request a join to the new node
    case OutView of
        [] ->
            logger:info("spray Agent ~p : Running state, Outview empty, requesting join "
                        "to ~p",
                        [State#state.namespace, RequesterNode]),
            supervisor:start_child(bbsvx_sup_client_connections,
                                   [join, Namespace, MyNode, RequesterNode]);
        _ ->
            logger:info("spray Agent ~p : Running state, Outview not empty, forwarding "
                        "join request",
                        [State#state.namespace]),
            %% Broad forward subscription to all nodes in the outview
            broadcast_unique(#forward_subscription{namespace = Namespace,
                                                   subscriber_node = RequesterNode},
                             OutView)
    end,
    {keep_state, State#state{in_view = NewInView}};
running(info,
        {connected, _Namespace, RequesterNode, {inview, _}},
        #state{namespace = Namespace, in_view = InView} = State) ->
    logger:info("spray Agent ~p : Running state, Connected to ~p, adding to "
                "inview",
                [State#state.namespace, RequesterNode]),
    NewInView = [RequesterNode#node_entry{age = 0} | InView],
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_inview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewInView)),
    {keep_state, State#state{in_view = NewInView}};
%% Manage forwarded subcription requests
running(info,
        {forwarded_subscription, Namespace, #node_entry{} = RequesterNode},
        #state{my_node = MyNode} = State) ->
    logger:info("spray Agent ~p : Running state, Received forwarded subscription "
                "request from ~p",
                [State#state.namespace, RequesterNode]),
    %% Spawn spray join agent to join the inview of forwarded subscription
    supervisor:start_child(bbsvx_sup_client_connections,
                           [join, Namespace, MyNode, RequesterNode]),
    {keep_state, State};
%% Diconnection management
running(info, {connection_terminated, {out, Reason}, Namespace, TargetNode}, State) ->
    logger:info("spray Agent ~p : Running state, Connection out terminated to "
                "~p   reason ~p",
                [Namespace, TargetNode, Reason]),
    logger:info("Current out view ~p", [State#state.out_view]),
    NewOutView =
        lists:keydelete(TargetNode#node_entry.pid, #node_entry.pid, State#state.out_view),
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_outview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewOutView)),
    logger:info("New out view ~p", [NewOutView]),
    case NewOutView of
        [] ->
            logger:info("spray Agent ~p : Running state, Outview depleted",
                        [State#state.namespace]),
            prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_outview_depleted_">>,
                                                                    binary:replace(Namespace,
                                                                                   <<":">>,
                                                                                   <<"_">>)])));
        _ ->
            ok
    end,
    {keep_state, State#state{out_view = NewOutView}};
running(info, {connection_terminated, {in, Reason}, Namespace, TargetNode}, State) ->
    logger:info("spray Agent ~p : Running state, Connection in terminated to "
                "~p   Reason ~p",
                [Namespace, TargetNode, Reason]),
    NewInView =
        lists:keydelete(TargetNode#node_entry.pid, #node_entry.pid, State#state.in_view),
    prometheus_gauge:set(binary_to_atom(iolist_to_binary([<<"spray_inview_size_">>,
                                                          binary:replace(Namespace,
                                                                         <<":">>,
                                                                         <<"_">>)])),
                         length(NewInView)),
    case NewInView of
        [] ->
            logger:info("spray Agent ~p : Running state, Inview depleted",
                        [State#state.namespace]),
            prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_inview_depleted_">>,
                                                                    binary:replace(Namespace,
                                                                                   <<":">>,
                                                                                   <<"_">>)])));
        _ ->
            ok
    end,
    {keep_state, State#state{in_view = NewInView}};
running(info,
        {connection_error, Reason, Namespace, TargetNode},
        #state{namespace = Namespace} = State) ->
    logger:info("spray Agent ~p : Running state, Connection error to ~p  Reason ~p",
                [State#state.namespace, TargetNode, Reason]),
    {keep_state, State#state{}};
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Old API
%% Remove nodes from outview
%%Exchange management
%% Exchange with an empty out view
running(info, spray_loop, #state{out_view = OutView}) when length(OutView) < 1 ->
    %% Increase age of outview
    AgedOutView =
        lists:map(fun(Node) -> Node#node_entry{age = Node#node_entry.age + 1} end, OutView),
    {keep_state, #state{out_view = AgedOutView}};
running(info,
        spray_loop,
        #state{pid_exchanger = undefined,
               my_node = MyNode,
               namespace = Namespace,
               out_view = OutView} =
            State) ->
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
    logger:warning("spray Agent ~p : Running state, Concurent spray loop, ignoring",
                   [State#state.namespace]),
    keep_state_and_data;
%% Exchange with an empty in view
running(info,
        {partial_view_exchange_in, _Namespace, #node_entry{node_id = OriginNodeId}, _},
        #state{in_view = [#node_entry{node_id = OriginNodeId, pid = OriginNodePid}]} = State) ->
    logger:info("spray Agent ~p : Running state, cancelling exchange : empty "
                "inview",
                [State#state.namespace]),
            bbsvx_server_connection:reject_exchange(OriginNodePid, empty_inview),
    keep_state_and_data;
%% Received partial view exchange in and no exchanger running
running(info,
        {partial_view_exchange_in,
         Namespace,
         #node_entry{} = OriginNode,
         IncomingSamplePartialView},
        #state{pid_exchanger = undefined, my_node = MyNode} = State) ->
    logger:info("spray Agent ~p : Running state, Got partial view exchange in "
                "from ~p proposing : ~p",
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
    logger:info("spray Agent ~p : Running state, Caching  partial view exchange "
                "in from ~p proposing : ~p",
                [State#state.namespace, OriginNode, IncomingSamplePartialView]),
    {keep_state,
     State#state{cached_exchange =
                     State#state.cached_exchange
                     ++ [{partial_view_exchange_in,
                          Namespace,
                          OriginNode,
                          IncomingSamplePartialView}]}};
running(info,
        {'DOWN', MonitorRef, process, PidTerminating, _Info},
        #state{my_node = MyNode,
               pid_exchanger = {PidTerminating, MonitorRef},
               cached_exchange =
                   [{partial_view_exchange_in, Namespace, OriginNode, IncomingSamplePartialView}
                    | OtherCachedExchanges]} =
            State) ->
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
running({call, From}, {reinit_age, TargetNodePid}, #state{out_view = OutView} = State) ->
    logger:info("spray Agent ~p : Running state, Reinit age for ~p",
                [State#state.namespace, TargetNodePid]),
    %% Update the age of the outview node designed by NodeId to 0
    {_, Node, TempOutview} = lists:keytake(TargetNodePid, #node_entry.pid, OutView),
    NewOutView = [Node#node_entry{age = 0} | TempOutview],

    gen_statem:reply(From, ok),
    {keep_state, State#state{out_view = NewOutView}};
running(info, {'EXIT', Pid, shutdown}, State) ->
    logger:info("spray Agent ~p : Running state, Exchanger ~p shutdown",
                [State#state.namespace, Pid]),
    {stop, normal, State};
running(Type, Event, State) ->
    logger:info("spray Agent ~p : Running state, Unhandled event ~p",
                [State#state.namespace, {Type, Event}]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

broadcast(Payload, View) ->
    lists:foreach(fun(#node_entry{pid = Pid}) -> gen_statem:call(Pid, {send, Payload}) end,
                  View).

broadcast_unique(Payload, View) ->
    lists:foreach(fun(#node_entry{pid = Pid}) ->
                     logger:info("spray Agent: Running state, Forwarding message to ~p", [Pid]),
                     gen_statem:call(Pid, {send, Payload})
                  end,
                  lists:usort(View)).

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
                            {help, "Number of timeout occuring during exchange"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_inview_depleted_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number of times invirew reach 0"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_outview_depleted_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number of times outview reach 0"}]),
    prometheus_counter:new([{name,
                             binary_to_atom(iolist_to_binary([<<"spray_empty_inview_answered_">>,
                                                              binary:replace(Namespace,
                                                                             <<":">>,
                                                                             <<"_">>)]))},
                            {help, "Number times this node answered a refuel inview request"}]).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

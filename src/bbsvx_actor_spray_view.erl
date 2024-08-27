%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray_view).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(EXCHANGE_TIMEOUT, 10000).

%% External API
-export([start_link/1, start_link/2, stop/0, reinit_age/2, broadcast/2,
         broadcast_unique/2, get_n_unique_random/2, broadcast_unique_random_subset/3]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3]).

-record(state,
        {in_view = [] :: [node_entry()],
         out_view = [] :: [node_entry()],
         namespace :: binary(),
         my_node :: node_entry(),
         pid_exchanger = undefined :: {pid(), reference()} | undefined,
         pid_exchange_timeout = undefined}).

-type state() :: #state{}.

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
    gen_statem:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, Options],
                          []).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Set the age of connection Pid to 0
%%% @returns ok
%%% @end
%%%
-spec reinit_age(Namespace :: binary(), NodePid :: pid()) -> ok.
reinit_age(Namespace, NodePid) ->
    gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}},
                    {reinit_age, NodePid}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to all connections in the outview
%%% @returns ok
%%% @end
%%%

-spec broadcast(Namespace :: binary(), Payload :: term()) -> ok.
broadcast(Namespace, Payload) ->
    gen_statem:cast({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}},
                    {broadcast, Payload}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to all unique connections in the outview
%%% @returns ok
%%% @end
%%%
-spec broadcast_unique(Namespace :: binary(), Payload :: term()) -> ok.
broadcast_unique(Namespace, Payload) ->
    gen_statem:cast({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}},
                    {broadcast_unique, Payload}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to a random subset of the view
%%% @returns Number of nodes the payload was sent to
%%% @end

-spec broadcast_unique_random_subset(Namespace :: binary(),
                                     Payload :: term(),
                                     N :: integer()) ->
                                        {ok, integer()}.
broadcast_unique_random_subset(Namespace, Payload, N) ->
    gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}},
                    {broadcast_unique_random_subset, Payload, N}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get n unique random nodes from the outview
%%% @returns [node_entry()]
%%% @end
-spec get_n_unique_random(Namespace :: binary(), N :: integer()) -> [node_entry()].
get_n_unique_random(Namespace, N) ->
    gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}},
                    {get_n_unique_random, N}).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    process_flag(trap_exit, true),

    _ = init_metrics(Namespace),
    ?'log-info'("spray Agent ~p : Starting state with Options ~p", [Namespace, Options]),
    %% Get our node id
    MyNodeId = bbsvx_crypto_service:my_id(),
    %% Get our host and port
    {ok, {Host, Port}} = bbsvx_network_service:my_host_port(),
    MyNode =
        #node_entry{node_id = MyNodeId,
                    host = Host,
                    port = Port},
    %% Check options for contact_nodes to connect to
    case maps:get(boot, Options, root) of
        root ->
            ok;
        {join, []} ->
            ?'log-notice'("spray Agent ~p : Starting state, No contact nodes, starting "
                          "as root",
                          [Namespace]),
            ok;
        {join, ContactNodes} ->
            %% Choose a random node from the contact nodes
            ContactNode =
                lists:nth(
                    rand:uniform(length(ContactNodes)), ContactNodes),
            ?'log-info'("spray Agent ~p : Starting state, Connecting to contact node ~p",
                        [Namespace, ContactNode]),
            %% Start a join to the contact node
            supervisor:start_child(bbsvx_sup_client_connections,
                                   [register,
                                    Namespace,
                                    MyNode,
                                    ContactNode#node_entry{host = ContactNode#node_entry.host}])
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

terminate(_Reason, _PreviousState, #state{namespace = Namespace}) ->
    ?'log-info'("spray Agent ~p : Terminating state", [Namespace]),
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
-spec running(Type :: atom(), Event :: term(), State :: state()) ->
                 {keep_state, state()} |
                 {keep_state_and_data, state()} |
                 {stop, Reason :: term(), state()}.
running(enter, _OldState, State) ->
    case State#state.pid_exchange_timeout of
        undefined ->
            ?'log-info'("spray Agent ~p : Running state, Starting exchange timer",
                        [State#state.namespace]),
            Me = self(),
            Timeref = erlang:start_timer(?EXCHANGE_TIMEOUT, Me, spray_loop),
            {keep_state, State#state{pid_exchange_timeout = Timeref}};
        _ ->
            keep_state_and_data
    end;
running(info,
        {connected, _Namespace, RequesterNode, {outview, register, CurrentIndex, CurrentLeader}},
        #state{namespace = Namespace, out_view = OutView} = State) ->
    ?'log-info'(" --> spray Agent ~p : Running state, Connected to ~p, adding "
                "to outview. Current index ~p, Current leader ~p",
                [State#state.namespace, RequesterNode, CurrentIndex, CurrentLeader]),
    NewOutView = [RequesterNode#node_entry{age = 0} | OutView],
    gproc:send({n, l, {bbsvx_actor_ontology, Namespace}}, {registered, CurrentIndex}),
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_outview_size_">>),
                         length(NewOutView)),
    {keep_state, State#state{out_view = NewOutView}};
running(info,
        {connected, _Namespace, RequesterNode, {outview, join, _, _}},
        #state{namespace = Namespace, out_view = OutView} = State) ->
    ?'log-info'(" --> spray Agent ~p : Running state, Connected to ~p, adding "
                "to outview.",
                [State#state.namespace, RequesterNode]),
    NewOutView = [RequesterNode#node_entry{age = 0} | OutView],
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_outview_size_">>),
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
    ?'log-info'("--> spray Agent ~p : Running state, Connected to ~p, adding "
                "to inview",
                [State#state.namespace, RequesterNode]),
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_inview_size_">>),
                         length(NewInView)),

    {ok, CurrentIndex} = bbsvx_actor_ontology:get_current_index(Namespace),
    ?'log-info'("spray Agent ~p : current index : ~p", [Namespace, CurrentIndex]),
    {ok, CurrentLeader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    bbsvx_server_connection:accept_register(RequesterNode#node_entry.pid,
                                            #header_register_ack{result = ok,
                                                                 leader = CurrentLeader,
                                                                 current_index = CurrentIndex}),
    %% If our outview is empty, we should request a join to the new node
    case length(OutView) of
        A when A < 1 ->
            ?'log-info'("spray Agent ~p : Running state, Outview empty, requesting join "
                        "to ~p",
                        [State#state.namespace, RequesterNode]),
            bbsvx_client_connection:new(join, Namespace, MyNode, RequesterNode);
        _ ->
            ?'log-info'("spray Agent ~p : Running state, Outview not empty, forwarding "
                        "join request",
                        [State#state.namespace]),
            %% Broadcast forward subscription to all nodes in the outview
            lists:foreach(fun(#node_entry{pid = Pid}) ->
                             bbsvx_client_connection:send(Pid,
                                                          #forward_subscription{namespace =
                                                                                    Namespace,
                                                                                subscriber_node =
                                                                                    RequesterNode})
                          end,
                          lists:usort(fun(N1, N2) -> N1#node_entry.node_id =< N2#node_entry.node_id
                                      end,
                                      OutView))
    end,
    {keep_state, State#state{in_view = NewInView}};
running(info,
        {connected, _Namespace, #node_entry{pid = RequesterPid} = RequesterNode, {inview, join}},
        #state{namespace = Namespace, in_view = InView} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Connected to ~p, adding to "
                "inview",
                [State#state.namespace, RequesterNode]),
    NewInView = [RequesterNode#node_entry{age = 0} | InView],
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_inview_size_">>),
                         length(NewInView)),

    {ok, CurrentIndex} = bbsvx_actor_ontology:get_current_index(Namespace),

    {ok, CurrentLeader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    bbsvx_server_connection:accept_join(RequesterPid,
                                        #header_join_ack{result = ok,
                                                         leader = CurrentLeader,
                                                         current_index = CurrentIndex}),
    {keep_state, State#state{in_view = NewInView}};
%% Manage forwarded subcription requests
running(info,
        {forwarded_subscription, Namespace, #node_entry{} = RequesterNode},
        #state{my_node = MyNode} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Received forwarded subscription "
                "request from ~p",
                [State#state.namespace, RequesterNode]),
    %% Spawn spray join agent to join the inview of forwarded subscription
    bbsvx_client_connection:new(join, Namespace, MyNode, RequesterNode),
    {keep_state, State};
%% Diconnection management
running(info, {connection_terminated, {out, Reason}, Namespace, TargetNode}, State) ->
    ?'log-info'("spray Agent ~p : Running state, Connection out terminated to "
                "~p   reason ~p",
                [Namespace, TargetNode, Reason]),
    ?'log-info'("Current out view ~p", [State#state.out_view]),
    NewOutView =
        lists:keydelete(TargetNode#node_entry.pid, #node_entry.pid, State#state.out_view),
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_outview_size_">>),
                         length(NewOutView)),
    ?'log-info'("New out view ~p", [NewOutView]),
    case NewOutView of
        [] ->
            ?'log-info'("spray Agent ~p : Running state, Outview depleted",
                        [State#state.namespace]),
            prometheus_counter:inc(build_metric_view_name(Namespace,
                                                          <<"spray_outview_depleted_">>));
        _ ->
            ok
    end,
    {keep_state, State#state{out_view = NewOutView}};
running(info, {connection_terminated, {in, Reason}, Namespace, TargetNode}, State) ->
    ?'log-info'("spray Agent ~p : Running state, Connection in terminated to "
                "~p   Reason ~p",
                [Namespace, TargetNode, Reason]),
    NewInView =
        lists:keydelete(TargetNode#node_entry.pid, #node_entry.pid, State#state.in_view),
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_inview_size_">>),
                         length(NewInView)),
    case NewInView of
        [] ->
            ?'log-warning'("spray Agent ~p : Running state, Inview depleted",
                           [State#state.namespace]),
            prometheus_counter:inc(build_metric_view_name(Namespace, <<"spray_inview_depleted_">>));
        _ ->
            ok
    end,
    {keep_state, State#state{in_view = NewInView}};
running(info,
        {connection_error, connection_to_self, Namespace, TargetNode},
        #state{namespace = Namespace} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Connection to self to ~p",
                [State#state.namespace, TargetNode]),
    {keep_state, State};
running(info,
        {connection_error, Reason, Namespace, TargetNode},
        #state{namespace = Namespace} = State) ->
    ?'log-error'("spray Agent ~p : Running state, Connection error to ~p  Reason ~p",
                 [State#state.namespace, TargetNode, Reason]),
    {keep_state, State};
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Old API
%% Remove nodes from outview
%%Exchange management
%% Exchange with an empty out view
running(info, {timeout, _, spray_loop}, #state{out_view = OutView} = State)
    when length(OutView) < 1 ->
    {keep_state, State};
running(info,
        {timeout, _, spray_loop},
        #state{pid_exchanger = undefined,
               my_node = MyNode,
               namespace = Namespace,
               out_view = OutView} =
            State) ->
    ?'log-info'("spray Agent ~p : starting spray loop", [Namespace]),
    %% Increment age of nodes in out view
    AgedPartialView =
        lists:map(fun(Node) -> Node#node_entry{age = Node#node_entry.age + 1} end, OutView),
    %% Start a partial view exchange
    {ok, PidExchanger} =
        bbsvx_actor_spray_view_exchanger:start_link(initiator, Namespace, MyNode),
    RefExchanger = erlang:monitor(process, PidExchanger),

    {keep_state,
     State#state{pid_exchanger = {PidExchanger, RefExchanger}, out_view = AgedPartialView}};
running(info, {timeout, _, spray_loop}, #state{} = State) ->
    logger:warning("spray Agent ~p : Running state, Concurent spray loop, ignoring",
                   [State#state.namespace]),
    keep_state_and_data;
%% Exchange with an empty in view
running(info,
        {partial_view_exchange_in, _Namespace, #node_entry{node_id = OriginNodeId}, _},
        #state{in_view = [#node_entry{node_id = OriginNodeId, pid = OriginNodePid}]} = State) ->
    ?'log-notice'("spray Agent ~p : Running state, cancelling exchange : empty "
                  "inview",
                  [State#state.namespace]),
    bbsvx_server_connection:reject_exchange(OriginNodePid, responding_empty_inview),
    keep_state_and_data;
%% Received partial view exchange in and no exchanger running
running(info,
        {partial_view_exchange_in,
         Namespace,
         #node_entry{} = OriginNode,
         IncomingSamplePartialView},
        #state{pid_exchanger = undefined, my_node = MyNode} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Got partial view exchange in "
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
        {partial_view_exchange_in, _Namespace, #node_entry{pid = OriginNodePid} = OriginNode, _},
        State) ->
    ?'log-notice'("spray Agent ~p : Running state, busy rejecting  partial view "
                  "exchange in from ~p",
                  [State#state.namespace, OriginNode]),

    bbsvx_server_connection:reject_exchange(OriginNodePid, busy),

    {keep_state, State};
running(cast, {broadcast, Payload}, #state{out_view = OutView} = State) ->
    lists:foreach(fun(#node_entry{pid = Pid}) -> bbsvx_client_connection:send(Pid, Payload)
                  end,
                  OutView),
    {keep_state, State};
running(cast, {broadcast_unique, Payload}, #state{out_view = OutView} = State) ->
    lists:foreach(fun(#node_entry{pid = Pid}) -> bbsvx_client_connection:send(Pid, Payload)
                  end,
                  lists:usort(fun(N1, N2) -> N1#node_entry.node_id =< N2#node_entry.node_id end,
                              OutView)),
    {keep_state, State};
running({call, From},
        {broadcast_unique_random_subset, Payload, N},
        #state{out_view = OutView} = State) ->
    %% Get n unique random nodes from the outview
    RandomSubset =
        lists:sublist(
            lists:usort(fun(_N1, _N2) -> rand:uniform(2) =< 1 end, OutView), N),

    lists:foreach(fun(#node_entry{pid = Pid}) -> bbsvx_client_connection:send(Pid, Payload)
                  end,
                  RandomSubset),
    gen_statem:reply(From, {ok, length(RandomSubset)}),
    {keep_state, State};
running(info,
        {'DOWN', MonitorRef, process, PidTerminating, _Info},
        #state{pid_exchanger = {PidTerminating, MonitorRef}} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Partial view exchange done",
                [State#state.namespace]),

    {keep_state, State#state{pid_exchanger = undefined}};
running(info,
        {'EXIT', PidTerminating, Info},
        #state{pid_exchanger = {PidTerminating, _MonitorRef}} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Partial view exchange exited, "
                "reason ~p",
                [State#state.namespace, Info]),
    Me = self(),
    Timeref = erlang:start_timer(?EXCHANGE_TIMEOUT, Me, spray_loop),
    {keep_state, State#state{pid_exchange_timeout = Timeref, pid_exchanger = undefined}};
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
    ?'log-info'("spray Agent ~p : Running state, Reinit age for ~p",
                [State#state.namespace, TargetNodePid]),
    %% Update the age of the outview node designed by NodeId to 0
    {_, Node, TempOutview} = lists:keytake(TargetNodePid, #node_entry.pid, OutView),
    NewOutView = [Node#node_entry{age = 0} | TempOutview],

    gen_statem:reply(From, ok),
    {keep_state, State#state{out_view = NewOutView}};
running({call, From}, {get_n_unique_random, N}, #state{out_view = OutView} = State) ->
    %% Get n unique random nodes from the outview
    gen_statem:reply(From,
                     {ok,
                      lists:sublist(
                          lists:usort(fun(_N1, _N2) -> rand:uniform(2) =< 1 end, OutView), N)}),
    {keep_state, State};
running(info, {'EXIT', Pid, shutdown}, State) ->
    ?'log-info'("spray Agent ~p : Running state, Exchanger ~p shutdown",
                [State#state.namespace, Pid]),
    {stop, normal, State};
running(Type, Event, State) ->
    ?'log-warning'("spray Agent ~p : Running state, Unhandled event ~p",
                   [State#state.namespace, {Type, Event}]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

get_random([]) ->
    [];
get_random(List) ->
    lists:nth(
        rand:uniform(length(List)), List).

-spec build_metric_view_name(Namespace :: binary(), MetricName :: binary()) -> atom().
build_metric_view_name(Namespace, MetricName) ->
    binary_to_atom(iolist_to_binary([MetricName,
                                     binary:replace(Namespace, <<":">>, <<"_">>)])).

-spec init_metrics(Namespace :: binary()) -> ok.
init_metrics(Namespace) ->
    %% Create some metrics
    prometheus_gauge:new([{name, build_metric_view_name(Namespace, <<"spray_networksize_">>)},
                          {help, "Number of nodes patricipating in this ontology network"}]),
    prometheus_gauge:new([{name, build_metric_view_name(Namespace, <<"spray_inview_size_">>)},
                          {help, "Number of nodes in ontology inview"}]),
    prometheus_gauge:new([{name,
                           build_metric_view_name(Namespace, <<"spray_outview_size_">>)},
                          {help, "Number of nodes in ontology partial view"}]),
    prometheus_counter:new([{name,
                             build_metric_view_name(Namespace,
                                                    <<"spray_initiator_echange_timeout_">>)},
                            {help, "Number of timeout occuring during exchange"}]),
    prometheus_counter:new([{name,
                             build_metric_view_name(Namespace, <<"spray_inview_depleted_">>)},
                            {help, "Number of times invirew reach 0"}]),
    prometheus_counter:new([{name,
                             build_metric_view_name(Namespace, <<"spray_outview_depleted_">>)},
                            {help, "Number of times outview reach 0"}]),
    prometheus_counter:new([{name,
                             build_metric_view_name(Namespace, <<"spray_empty_inview_answered_">>)},
                            {help, "Number times this node answered a refuel inview request"}]).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

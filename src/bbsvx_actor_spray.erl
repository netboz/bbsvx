%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray).

-behaviour(gen_statem).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(EXCHANGE_INTERVAL, 10000).
-define(EXCHANGE_OUT_TIMEOUT, 3000).

%% External API
-export([start_link/1, start_link/2, stop/0, broadcast/2, broadcast_unique/2,
         get_n_unique_random/2, broadcast_unique_random_subset/3, get_inview/1, get_outview/1,
         get_views/1]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([iddle/3]).

-record(state,
        {%%in_view = [] :: [arc()],
         %%out_view = [] :: [arc()],
         spray_timer :: reference(),
         current_exchange_peer :: {in | out, arc()} | undefined,
         proposed_sample :: [exchange_entry()],
         incoming_sample :: [exchange_entry()],
         contact_nodes = [] :: [node_entry()],
         namespace :: binary(),
         my_node :: node_entry(),
         arcs_to_leave = [] :: [exchange_entry()]}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================
-spec start_link(NameSpace :: binary()) -> gen_statem:start_ret().
start_link(NameSpace) ->
    start_link(NameSpace, []).

-spec start_link(NameSpace :: binary(), Options :: list()) -> gen_statem:start_ret().
start_link(NameSpace, Options) ->
    gen_statem:start_link({via, gproc, {n, l, {?MODULE, NameSpace}}},
                          ?MODULE,
                          [NameSpace, Options],
                          []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([NameSpace, Options]) ->
    %%process_flag(trap_exit, true),
    ?'log-info'("spray Agent ~p : Starting state with Options ~p", [NameSpace, Options]),
    %% Get our node id
    MyNodeId = bbsvx_crypto_service:my_id(),
    %% Get our host and port
    {ok, {Host, Port}} = bbsvx_network_service:my_host_port(),
    MyNode =
        #node_entry{node_id = MyNodeId,
                    host = Host,
                    port = Port},

    %% Register to events for this ontolgy namespace
    gproc:reg({p, l, {spray_exchange, NameSpace}}),
    %%  Try to register to the ontology node mesh
    ContactNodes = maps:get(contact_nodes, Options, []),
    register_namespace(NameSpace, MyNode, ContactNodes),

    %% TODO: Reove next
    Data =
        #{action => <<"add">>,
          node_id => MyNodeId,
          metadata =>
              #{host => format_host(Host),
                port => Port,
                namespace => NameSpace,
                node_id => MyNodeId}},
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    %% TODO: move next to another place
    httpc:request(post,
                  {"http://graph-visualizer:3400/nodes", [], "application/json", Json},
                  [],
                  []),

    Me = self(),
    SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
    {ok,
     iddle,
     #state{namespace = NameSpace,
            spray_timer = SprayTimer,
            proposed_sample = [],
            incoming_sample = [],
            contact_nodes = ContactNodes,
            my_node =
                #node_entry{node_id = MyNodeId,
                            host = Host,
                            port = Port}}}.

terminate(Reason,
          _CurrentState,
          #state{namespace = NameSpace, my_node = #node_entry{node_id = MyNodeId}}) ->
    ?'log-info'("spray Agent ~p : Terminating. Reason :~p", [MyNodeId, Reason]),
    % Normal termination
    % We need to terminate our in and out connections
    % First we get the outview, and keep a single arc per target node
    OutView = get_outview(NameSpace),
    OutArcs =
        lists:usort(fun(#arc{target = #node_entry{node_id = NodeId1}},
                        #arc{target = #node_entry{node_id = NodeId2}}) ->
                       NodeId1 < NodeId2
                    end,
                    OutView),
    ?'log-info'("1", []),

    lists:foreach(fun(#arc{ulid = Ulid}) -> terminate_connection(Ulid, out, Reason) end,
                  OutArcs),
    ?'log-info'("2", []),
    Inview = get_inview(NameSpace),
    InArcs =
        lists:usort(fun(#arc{source = #node_entry{node_id = NodeId1}},
                        #arc{source = #node_entry{node_id = NodeId2}}) ->
                       NodeId1 < NodeId2
                    end,
                    Inview),
    ?'log-info'("3", []),
    lists:foreach(fun(#arc{ulid = Ulid}) -> terminate_connection(Ulid, in, Reason) end,
                  InArcs),
    ?'log-info'("4", []),
    Data = #{action => <<"remove">>, node_id => MyNodeId},
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    httpc:request(post,
                  {"http://graph-visualizer:3400/nodes", [], "application/json", Json},
                  [],
                  []),
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    state_functions.

%%%=============================================================================
%%% State transitions
%%%=============================================================================

-spec iddle(gen_statem:event_type() | enter, any(), state()) ->
               gen_statem:state_function_result().
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event =
                          #evt_arc_connected_in{source = Source,
                                                lock = Lock,
                                                spread = Spread}},
      #state{namespace = NameSpace, my_node = MyNode} = State) ->
    ?'log-info'("New incoming arc, but empty outview, requesting joing"),
    case get_outview(NameSpace) of
        [] ->
            %% send a fowrard join request to the new node. If we would have an outview
            %% we would have sent a forward join request to all nodes in the outview.
            case Spread of
                {true, Lock} ->
                    open_connection(NameSpace, MyNode, Source, []),
                    {keep_state, State};
                _ ->
                    {keep_state, State}
            end;
        OutView ->
            %% Check if we need to spread ( send forward join ) to neighbors
            case Spread of
                {true, Lock} ->
                    ?'log-info'("spray Agent ~p : Running state, New arc in, spreading to neighbors",
                                [NameSpace]),
                    %% Broadcast forward subscription to all nodes in the outview
                    lists:foreach(fun(#arc{ulid = DestUlid}) ->
                                     send(DestUlid,
                                          out,
                                          #open_forward_join{lock = Lock, subscriber_node = Source})
                                  end,
                                  OutView);
                _ ->
                    ?'log-info'("spray Agent ~p : Running state, New arc in, no spread",
                                [NameSpace])
            end,
            {keep_state, State}
    end;
%% Register new arc out
iddle(info,
      #incoming_event{event =
                          #evt_arc_connected_out{target = TargetNode,
                                                 lock = Lock,
                                                 ulid = IncomingUlid}},
      #state{namespace = NameSpace, my_node = MyNode} = State) ->
    ?'log-info'("spray Agent ~p : Arc connected out, adding to outview : ~p",
                [NameSpace,
                 #arc{source = MyNode,
                      target = TargetNode,
                      lock = Lock,
                      ulid = IncomingUlid}]),

    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event = #open_forward_join{subscriber_node = SubscriberNode}},
      #state{namespace = NameSpace, my_node = MyNode} = State) ->
    %% Openning forwarded joinrequestfrom registration of SubscriberNode
    open_connection(NameSpace, MyNode, SubscriberNode, []),
    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event = #evt_arc_disconnected{ulid = Ulid, direction = in}},
      #state{namespace = NameSpace} = State) ->
    case get_inview(NameSpace) of
        [] ->
            prometheus_counter:inc(<<"bbsvx_spray_inview_depleted">>, [NameSpace]);
        _ ->
            ok
    end,

    ?'log-info'("spray Agent ~p : Running state, arc disconnected in ~p",
                [State#state.namespace, Ulid]),
    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event = #evt_arc_disconnected{ulid = Ulid, direction = out}},
      #state{namespace = NameSpace, arcs_to_leave = ArcsToLeave} = State) ->
    case get_outview(NameSpace) of
        [] ->
            prometheus_counter:inc(<<"bbsvx_spray_outview_depleted">>, [NameSpace]),
            NewArcToLeave = lists:keydelete(Ulid, #exchange_entry.ulid, ArcsToLeave),

            {keep_state, State#state{arcs_to_leave = NewArcToLeave}};
        _OutView ->
            ?'log-info'("spray Agent ~p : Running state, arc disconnected out ~p",
                        [State#state.namespace, Ulid]),
            %% Remove arc from node to leave
            NewArcToLeave = lists:keydelete(Ulid, #exchange_entry.ulid, ArcsToLeave),

            {keep_state, State#state{arcs_to_leave = NewArcToLeave}}
    end;
%% Reception of 'spray_time' event signaling it is time to start exchange
iddle(info,
      spray_time,
      #state{namespace = NameSpace, current_exchange_peer = {_, Peer}} = State) ->
    ?'log-info'("spray Agent ~p : Running state, spray time, but busy with peer ~p",
                [State#state.namespace, Peer]),
    Me = self(),
    ?'log-info'("spray Agent ~p : Busy state, QUEUE ~p",
                [NameSpace, erlang:process_info(Me, messages)]),
    {keep_state, State};
iddle(info,
      {timeout, _, spray_time},
      #state{namespace = NameSpace,
             arcs_to_leave = ArcsToLeave,
             my_node = MyNode = #node_entry{node_id = MyNodeId}} =
          State) ->
    case get_outview(NameSpace) of
        [] ->
            ?'log-info'("spray Agent ~p : Running state, Outview empty, no exchange",
                        [State#state.namespace]),
            Me = self(),
            SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),

            {keep_state, State#state{spray_timer = SprayTimer}};
        OutView ->
            OutViewPids = get_outview_pids(NameSpace),
            ?'log-info'("spray Agent ~p : Starting exchange, outview ~p", [NameSpace, OutView]),
            %% increase age of outview
            lists:foreach(fun(Pid) -> Pid ! inc_age end, OutViewPids),
            case filter_arcs_to_leave(OutView, ArcsToLeave) of
                [] ->
                    ?'log-info'("spray Agent ~p : Running state, no exchange, no nodes left "
                                "to connect",
                                [State#state.namespace]),
                    Me = self(),
                    SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
                    {keep_state, State#state{spray_timer = SprayTimer}};
                FilteredPartialView ->
                    ?'log-info'("spray Agent ~p : Node ~p starting spray loop",
                                [NameSpace, MyNodeId]),
                    ?'log-info'("spray Agent ~p : Outview :~p    Arcs to leave : ~p",
                                [NameSpace, FilteredPartialView, ArcsToLeave]),

                    %% Increment age of nodes in out view
                    AgedPartialView =
                        lists:map(fun(#arc{age = Age} = Arc) -> Arc#arc{age = Age + 1} end,
                                  FilteredPartialView),

                    %% Get oldest arc
                    #arc{ulid = Ulid} = OldestArc = get_oldest_arc(AgedPartialView),

                    ?'log-info'("Actor exchanger ~p : Doing exchange with node ~p  on arc ~p",
                                [NameSpace, OldestArc#arc.target, OldestArc#arc.ulid]),

                    %% Partialview without oldest Arc
                    {_, _, PartialViewWithoutOldest} =
                        lists:keytake(Ulid, #arc.ulid, FilteredPartialView),

                    %% Get sample from out view without oldest
                    {Sample, _KeptArcs} = get_random_sample(PartialViewWithoutOldest),

                    %% reAdd oldest node
                    SamplePlusOldest = [OldestArc | Sample],
                    %% Replace all occurences of oldest node in samplePlusOldest
                    %% by our node, to avoid target doing loops
                    FinalSample =
                        lists:map(fun (#arc{target = #node_entry{node_id = TargetNodeId}} = Arc)
                                          when TargetNodeId
                                               == OldestArc#arc.target#node_entry.node_id ->
                                          Arc#arc{target = MyNode};
                                      (Arc) ->
                                          Arc
                                  end,
                                  SamplePlusOldest),
                    ?'log-info'("Actor exchanger : unmodified sample sent ~p", [FinalSample]),

                    %% Prepare Proposed sample as list of exchange_entry
                    ProposedSample =
                        [#exchange_entry{ulid = Arc#arc.ulid,
                                         lock = Arc#arc.lock,
                                         target = Arc#arc.target}
                         || Arc <- FinalSample],

                    %% Send exchange in proposition to oldest node
                    send(OldestArc#arc.ulid, out, #exchange_in{proposed_sample = ProposedSample}),

                    ?'log-info'("Actor exchanger ~p : Running state, Sent partial view exchange "
                                "in to ~p   sample : ~p",
                                [State#state.namespace, OldestArc#arc.target, ProposedSample]),
                    %% program execution of next exchange
                    Me = self(),
                    SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
                    {keep_state,
                     State#state{current_exchange_peer = {out, OldestArc},
                                 proposed_sample = ProposedSample,
                                 spray_timer = SprayTimer}}
            end
    end;
%% Manage reception of exchange out from oldest node
iddle(info,
      #incoming_event{event = #exchange_out{proposed_sample = IncomingSample},
                      origin_arc = ArcUlid},
      #state{namespace = NameSpace,
             my_node = #node_entry{node_id = MyNodeId} = MyNode,
             arcs_to_leave = ArcsToLeave,
             proposed_sample = ProposedSample,
             current_exchange_peer = {_, CurrentExchangePeer}} =
          State) ->
    %% Change every occurence of MyNode in the incoming sample by the target node
    %% to avoid loops.
    %% Other side is supposed to have done it, but who knows
    IncomingSampleWithoutMyNode =
        lists:map(fun (#exchange_entry{target = #node_entry{node_id = TargetNodeId}} = Entry)
                          when TargetNodeId == MyNodeId ->
                          Entry#exchange_entry{target = CurrentExchangePeer#arc.target};
                      (Entry) ->
                          Entry
                  end,
                  IncomingSample),
    %% We can accept the exchange and start joining the proposed sample
    ?'log-info'("Actor exchanger ~p : Got partial view exchange out from ~p~nProposed "
                "sample ~p",
                [NameSpace, CurrentExchangePeer, IncomingSample]),

    case get_outview(NameSpace) of
        [_] when IncomingSampleWithoutMyNode == [] ->
            ?'log-info'("spray Agent ~p : Running state, empty outview, cancelling exchange",
                        [NameSpace]),
            send(ArcUlid,
                 out,
                 #exchange_cancelled{reason = exchange_out_cause_empty_outview,
                                     namespace = NameSpace}),
            {keep_state,
             State#state{current_exchange_peer = undefined,
                         proposed_sample = [],
                         incoming_sample = []}};
        _ ->
            Me = self(),
            %% Program removal of arcs from nodes to leave after timeout
            erlang:send_after(?CONNECTION_TIMEOUT,
                              Me,
                              #evt_end_exchange{exchanged_ulids =
                                                    lists:map(fun(#exchange_entry{ulid = Ulid}) ->
                                                                 Ulid
                                                              end,
                                                              ProposedSample)}),
            %% Send exchange accept to oldest node
            send(ArcUlid, out, #exchange_accept{}),
            ?'log-info'("Connecting to incoming sample ~p", [IncomingSample]),

            %% start conneting to the proposed sample
            swap_connections(NameSpace,
                             MyNode,
                             CurrentExchangePeer#arc.target,
                             IncomingSampleWithoutMyNode),
            {keep_state,
             State#state{current_exchange_peer = undefined,
                         arcs_to_leave = ArcsToLeave ++ ProposedSample,
                         proposed_sample = [],
                         incoming_sample = []}}
    end;
%% Manage reception of exchange in ( exchange initiated from other peer )
iddle(info,
      #incoming_event{origin_arc = ArcUlid, event = #exchange_in{}},
      #state{current_exchange_peer = {_, Peer}} = State) ->
    ?'log-info'("spray Agent ~p : Running state, exchange in received but busy "
                "with ~p",
                [State#state.namespace, Peer]),
    %% Notify other side cancel the exchange
    gproc:send({n, l, {arc, in, ArcUlid}}, {reject, exchange_busy}),

    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = OriginUlid,
                      event = #exchange_in{proposed_sample = IncomingSample}},
      #state{namespace = NameSpace,
             arcs_to_leave = ArcsToLeave,
             my_node = MyNode} =
          State) ->
    ?'log-info'("spray Agent ~p : Running state, exchange in received from ~p",
                [State#state.namespace, OriginUlid]),
    case get_inview(NameSpace) of
        [#arc{ulid = SourceArcUlid}] ->
            %% Origin node is in our inview
            %% Asked to do exchange but our only input is this node, going forward would
            %% make us empty inview, so we cancel this exchange
            ?'log-notice'("spray Agent ~p : Running state, cancelling exchange : would "
                          "cause empty inview",
                          [State#state.namespace]),
            gproc:send({n, l, {arc, in, SourceArcUlid}}, {reject, exchange_in_empty_inview}),

            {keep_state, State};
        InView ->
            ?'log-info'("Actor exchanger ~p : starting exchange proposed by arc ~p ~n "
                        "Incoming sample : ~p",
                        [NameSpace, OriginUlid, IncomingSample]),
            case lists:keyfind(OriginUlid, #arc.ulid, InView) of
                #arc{source = SourceNode} = ExchangeArc ->
                    ?'log-info'("spray Agent ~p : Arc ~p    Matching node ~p",
                                [NameSpace, OriginUlid, SourceNode]),
                    OutView = get_outview(NameSpace),
                    %% Remove arcs to leave from outview
                    FilteredOutView = filter_arcs_to_leave(OutView, ArcsToLeave),

                    {MySample, _KeptArcs} = get_big_random_sample(FilteredOutView),

                    %% Change every occurence of target node in the sample by our node
                    %% to avoid loops
                    MySampleWithoutTarget =
                        lists:map(fun (#arc{target = #node_entry{node_id = TargetNodeId}} = Arc)
                                          when TargetNodeId == SourceNode#node_entry.node_id ->
                                          Arc#arc{target = MyNode};
                                      (Arc) ->
                                          Arc
                                  end,
                                  MySample),

                    %% Turn sample into exchange_entry
                    MySampleEntry =
                        [#exchange_entry{ulid = Arc#arc.ulid,
                                         lock = Arc#arc.lock,
                                         target = Arc#arc.target}
                         || Arc <- MySampleWithoutTarget],

                    %% Send our sample to the origin node
                    ?'log-info'("Actor exchanger ~p : responding state, Sent partial view exchange "
                                "out to ~p   sample : ~p",
                                [NameSpace, OriginUlid, MySampleEntry]),

                    %% Send exchange out to origin node
                    send(OriginUlid, in, #exchange_out{proposed_sample = MySampleEntry}),

                    {keep_state,
                     State#state{proposed_sample = MySampleEntry,
                                 incoming_sample = IncomingSample,
                                 current_exchange_peer = {in, ExchangeArc}},
                     ?EXCHANGE_OUT_TIMEOUT};
                _ ->
                    ?'log-warning'("spray Agent ~p : Running state, exchange in from unk node ~p",
                                   [State#state.namespace, OriginUlid]),
                    %% Cancel exchange
                    gproc:send({n, l, {arc, in, OriginUlid}}, {reject, exchange_in_unknown_node}),
                    {keep_state, State}
            end
    end;
iddle(info,
      #incoming_event{event = #exchange_cancelled{reason = Reason}},
      #state{current_exchange_peer = {out, #arc{ulid = PeerUlid}}} = State) ->
    ?'log-info'("spray Agent ~p : Running state, exchange cancelled out : ~p",
                [State#state.namespace, Reason]),
    %% Reset age of the node in outview
    reset_age(PeerUlid),
    {keep_state,
     State#state{current_exchange_peer = undefined,
                 proposed_sample = [],
                 incoming_sample = []}};
iddle(info, #incoming_event{event = #exchange_cancelled{reason = Reason}}, State) ->
    ?'log-info'("spray Agent ~p : Running state, exchange cancelledin exchange "
                ": ~p",
                [State#state.namespace, Reason]),
    {keep_state,
     State#state{current_exchange_peer = undefined,
                 proposed_sample = [],
                 incoming_sample = []}};
%% Session accept is received by responder, to indicate him that he can proceed to the exchange
%% TODO: Check if the expeditor is the current exchange peer
iddle(info,
      #incoming_event{event = #exchange_accept{}},
      #state{namespace = NameSpace,
             my_node = MyNode,
             current_exchange_peer = {_, CurrentExchangePeer},
             incoming_sample = IncomingSample,
             proposed_sample = ProposedSample,
             arcs_to_leave = ArcsToLeave} =
          State) ->
    ?'log-info'("spray Agent ~p : Exchange accepted, nodes to leave : ~p    "
                "~nNodes to join : ~p    exchange peer : ~p",
                [NameSpace, ProposedSample, IncomingSample, CurrentExchangePeer]),

    swap_connections(NameSpace, MyNode, CurrentExchangePeer#arc.source, IncomingSample),
    Me = self(),
    %% Program removal of arcs from nodes to leave after timeout
    erlang:send_after(?CONNECTION_TIMEOUT,
                      Me,
                      #evt_end_exchange{exchanged_ulids =
                                            lists:map(fun(#exchange_entry{ulid = Ulid}) -> Ulid end,
                                                      ProposedSample)}),

    {keep_state,
     State#state{current_exchange_peer = undefined,
                 proposed_sample = [],
                 incoming_sample = [],
                 arcs_to_leave = ArcsToLeave ++ ProposedSample}};
iddle(info,
      #evt_end_exchange{exchanged_ulids = EndedExchangeUlids},
      #state{arcs_to_leave = ArcsToLeave} = State) ->
    ?'log-info'("spray Agent ~p : Running state, end exchange, veryting arcs ~p",
                [State#state.namespace, EndedExchangeUlids]),
    ?'log-info'("Arcs to leave ~p", [ArcsToLeave]),

    %% For each node in EndedExchangeUlids, check if an exchange entry with same Ulid is present
    %% in ArcsToLeave, if so remove it from arcs to leave
    %% and send a message on the ulid to request changing the lock.
    %% If the node is not in ArcsToLeave, it means the exchange for it was done normally
    NewAccArcToLeave =
        lists:filter(fun(#exchange_entry{ulid = Ulid, lock = Lock}) ->
                        case lists:member(Ulid, EndedExchangeUlids) of
                            true ->
                                %% Other side haven't connected to our arc, we remove it
                                %% from arc to leave so it participate again in exchanges
                                %% %% We change our lock and update the lock of client connection
                                NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),

                                send(Ulid,
                                     out,
                                     #change_lock{current_lock = Lock, new_lock = NewLock}),

                                false;
                            false -> true
                        end
                     end,
                     ArcsToLeave),

    {keep_state, State#state{arcs_to_leave = NewAccArcToLeave}};
%% API
%% Return the requested view
iddle({call, From}, get_inview, #state{} = State) ->
    InView = get_inview(State#state.namespace),
    gen_statem:reply(From, {ok, InView}),
    {keep_state, State};
iddle({call, From}, get_outview, #state{} = State) ->
    OutView = get_outview(State#state.namespace),
    gen_statem:reply(From, {ok, OutView}),
    {keep_state, State};
%% Error Management
iddle(info,
      #incoming_event{event = {connection_error, Reason, #arc{ulid = Ulid} = Arc},
                      origin_arc = Ulid},
      #state{} = State) ->
    ?'log-warning'("spray Agent ~p : Running state, connection error ~p to ~p",
                   [State#state.namespace, Reason, Arc]),
    {keep_state, State};
iddle(info,
      #incoming_event{event =
                          #evt_node_quitted{reason = Reason,
                                            direction = Direction,
                                            node_id = NodeId} =
                              Evt},
      #state{arcs_to_leave = ArcsToLeave} = State) ->
    ?'log-warning'("spray Agent ~p : Running state, node quitted ~p with reason "
                   "~p  direction ~p",
                   [State#state.namespace, NodeId, Reason, Direction]),

    OutView = get_outview(State#state.namespace),
    InView = get_inview(State#state.namespace),

    OutViewWithoutLeavingNode = filter_arcs_to_leave(OutView, ArcsToLeave),
    ?'log-info'("Start manage quitted node ~p", [OutViewWithoutLeavingNode]),
    manage_quitted_node(OutViewWithoutLeavingNode, InView, Evt, State);
%% catch all
iddle(Type, Msg, State) ->
    ?'log-warning'("spray Agent ~p : Running state, unhandled message ~p ~p~n State "
                   ": ~p",
                   [State#state.namespace, Type, Msg, State]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% @doc
%% swap_connections/4
%% Used to initiate proposed connections received from an exchange.
%% @end
%% ----------------------------------------------------------------------------

-spec swap_connections(binary(), node_entry(), node_entry(), [exchange_entry()]) -> ok.
swap_connections(NameSpace,
                 MyNode,
                 #node_entry{node_id = ExchangePeerNodeId},
                 IncomingSample) ->
    ?'log-info'("spray Agent ~p : Swapping connections with ~p",
                [NameSpace, ExchangePeerNodeId]),
    lists:foreach(fun (#exchange_entry{target = #node_entry{node_id = TargetNodeId}} =
                           ExchangeEntry)
                          when TargetNodeId == ExchangePeerNodeId ->
                          ?'log-info'("spray Agent ~p : mirror Swapping arc ~p to ~p",
                                      [NameSpace, ExchangeEntry#exchange_entry.ulid, TargetNodeId]),
                          swap_connection(NameSpace, MyNode, mirror, ExchangeEntry);
                      (ExchangeEntry) ->
                          ?'log-info'("spray Agent ~p : normal Swapping arc ~p to ~p",
                                      [NameSpace,
                                       ExchangeEntry#exchange_entry.ulid,
                                       ExchangeEntry#exchange_entry.target#node_entry.node_id]),
                          swap_connection(NameSpace, MyNode, normal, ExchangeEntry)
                  end,
                  IncomingSample).

%%-----------------------------------------------------------------------------
%% @doc
%% swap_connection/4
%% Initiate a connection proposed during and exchange.
%% The target node we are connecting to, when connected, will disconnected
%% the connection with same ulid
%% @end
%% ----------------------------------------------------------------------------

-spec swap_connection(NameSpace :: binary(),
                      MyNode :: node_entry(),
                      Type :: mirror | normal,
                      ExchangeEntry :: exchange_entry()) ->
                         supervisor:startchild_ret().
swap_connection(NameSpace,
                MyNode,
                Type,
                #exchange_entry{target = TargetNode,
                                ulid = Ulid,
                                lock = Lock}) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [join, NameSpace, MyNode, TargetNode, Ulid, Lock, Type, []]).

%%-----------------------------------------------------------------------------
%% @doc
%% open_connection/4
%% Open a connection in case of a forard join request
%% TODO: This function is badly named, it should be renamed to reflect the fact
%% this is a forward join request
%% @end
%% ----------------------------------------------------------------------------

-spec open_connection(NameSpace :: binary(),
                      MyNode :: node_entry(),
                      TargetNode :: node_entry(),
                      Options :: list()) ->
                         supervisor:startchild_ret().
open_connection(NameSpace, MyNode, TargetNode, Options) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [forward_join, NameSpace, MyNode, TargetNode, Options]).

%%-----------------------------------------------------------------------------
%% @doc
%% terminate_connection/3
%% Terminate a connection identified by Ulid, using direction Direction and
%% reason Reason.
%% @end
%% ----------------------------------------------------------------------------
-spec terminate_connection(Ulid :: binary(), Direction :: in | out, Reason :: atom()) ->
                              ok.
terminate_connection(Ulid, Direction, Reason) ->
    %% Signal we are closing the connection
    %% to the other side
    send(Ulid, Direction, #node_quitting{reason = Reason}),
    gproc:send({n, l, {arc, Direction, Ulid}}, {terminate, Reason}).

%%-----------------------------------------------------------------------------
%% @doc
%% send/3
%% Send a message over and arc
%% @end

-spec send(Ulid :: binary(), Direction :: in | out, Payload :: term()) -> ok.
send(Ulid, Direction, Payload) ->
    gproc:send({n, l, {arc, Direction, Ulid}}, {send, Payload}).

%%-----------------------------------------------------------------------------
%% @doc
%% register_to_node/3
%% Register to a node. This is to be called when contacting a node to request
%% to join the namespace.
%% @end
%% ----------------------------------------------------------------------------

-spec register_to_node(binary(), node_entry(), node_entry()) ->
                          supervisor:startchild_ret().
register_to_node(NameSpace, MyNode, ContactNode) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [register,
                            NameSpace,
                            MyNode,
                            ContactNode#node_entry{host = ContactNode#node_entry.host},
                            []]).

%%-----------------------------------------------------------------------------
%% @doc
%% register_namespace/3
%% Join namespace by sending register requests to the lists of nodes
%% Return list of nodes that failed to start registering, empty list if all
%% nodes succeeded to connection bootup
%% @end
%% ----------------------------------------------------------------------------

-spec register_namespace(binary(), node_entry(), [node_entry()]) ->
                            [{node_entry(), any()}].
register_namespace(NameSpace, MyNode, ContactNodes) ->
    ?'log-info'("spray Agent ~p : Registering to nodes ~p", [NameSpace, ContactNodes]),
    lists:foldl(fun(Node, FailedNodes) ->
                   ?'log-debug'("Registering to node ~p", [Node]),
                   case register_to_node(NameSpace, MyNode, Node) of
                       {ok, _} -> FailedNodes;
                       {error, Reason} -> [{Node, Reason} | FailedNodes];
                       ignore -> FailedNodes
                   end
                end,
                [],
                ContactNodes).

-spec manage_quitted_node([arc()], [arc()], term(), state()) ->
                             gen_statem:state_function_result().
manage_quitted_node(FilteredOutview,
                    Inview,
                    #evt_node_quitted{reason = Reason, node_id = TargetNodeId} = Evt,
                    #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : Running state, quitted node ~p with reason ~p",
                [NameSpace, TargetNodeId, Reason]),
    %% Remove target_nde from outview and count number of time it appears
    {FutureOutView, CountRemovedOut} =
        lists:foldr(fun(#arc{target = #node_entry{node_id = NodeId}} = Arc,
                        {NewOutView, Count}) ->
                       case NodeId of
                           TargetNodeId -> {NewOutView, Count + 1};
                           _ -> {[Arc | NewOutView], Count}
                       end
                    end,
                    {[], 0},
                    FilteredOutview),
    ?'log-info'("11", []),
    %% Remove target_node from inview
    {FutureInView, CountRemovedIn} =
        lists:foldr(fun(#arc{source = #node_entry{node_id = NodeId}} = Arc, {NewInView, Count}) ->
                       case NodeId of
                           TargetNodeId -> {NewInView, Count + 1};
                           _ -> {[Arc | NewInView], Count}
                       end
                    end,
                    {[], 0},
                    Inview),
    ?'log-info'("12  FutureOutView:~p", [FutureOutView]),
    ?'log-info'("12  CountRemovedOut:~p", [CountRemovedOut]),
    ?'log-info'("12  FutureInView:~p", [FutureInView]),
    ?'log-info'("12  CountRemovedIn:~p", [CountRemovedIn]),

    react_quitted_node(FutureOutView,
                       CountRemovedOut,
                       FutureInView,
                       CountRemovedIn,
                       Evt,
                       State);
%% catch all
manage_quitted_node(FilteredOutview, Inview, Evt, State) ->
    ?'log-warning'("spray Agent ~p : Running state, quitted node, unhandled case "
                   "Outview ~p  Inview ~p  Event ~p ~n State ~p",
                   [State#state.namespace, FilteredOutview, Inview, Evt, State]),
    {keep_state, State}.

%% Will leave us without connectection, we neeed to reregister
-spec react_quitted_node([arc()], integer(), [arc()], integer(), term(), state()) ->
                            gen_statem:state_function_result().
react_quitted_node([],
                   _,
                   [],
                   _,
                   #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
                   #state{namespace = NameSpace,
                          my_node = MyNode,
                          contact_nodes = ContactNodes} =
                       State) ->
    ?'log-info'("Node ~p quitted with reason ~p, Reacting to isolation by re-registering",
                [QuittedNodeId, Reason]),
    %% Select random node from contact nodes and re-register
    %% TODO: What if node that quitted is the only node in contact nodes
    RandomNode =
        lists:nth(
            rand:uniform(length(ContactNodes)), ContactNodes),

    supervisor:start_child(bbsvx_sup_client_connections,
                           [register, NameSpace, MyNode, RandomNode, []]),
    ?'log-info'("13", []),
    {keep_state, State};
%% Manage empty outview
react_quitted_node([],
                   _,
                   FilteredInView,
                   _,
                   #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
                   #state{namespace = NameSpace, my_node = MyNode} = State) ->
    ?'log-info'("Node ~p quitted with reason ~p, empty outview, joining node "
                "in inview",
                [QuittedNodeId, Reason]),
    %% get random node from Inview
    #arc{source = TargetNode} =
        lists:nth(
            rand:uniform(length(FilteredInView)), FilteredInView),

    supervisor:start_child(bbsvx_sup_client_connections,
                           [forward_join, NameSpace, MyNode, TargetNode, []]),
    {keep_state, State};
%% Manage empty inview
react_quitted_node(FilteredOutView,
                   CountRemovedOut,
                   [],
                   _,
                   #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
                   #state{namespace = NameSpace, my_node = MyNode} = State) ->
    ?'log-info'("Node ~p quitted with reason ~p, ack node in outview to foin me",
                [QuittedNodeId, Reason]),
    %% get random node from Outview and ask it to connect to us
    %% TODO
    {keep_state, State};
%% Manage normal case
react_quitted_node(FilteredOutView,
                   CountRemovedOut,
                   _FilteredInView,
                   _CountRemovedIn,
                   #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
                   #state{namespace = NameSpace, my_node = MyNode} = State) ->
    ?'log-info'("Node ~p quitted with reason ~p, Recreating connections. FilteredOutV"
                "iew ~p  count ~p",
                [QuittedNodeId, Reason, FilteredOutView, CountRemovedOut]),
    lists:foreach(fun(IndexL) ->
                     Rand = rand:uniform(1),
                     ?'log-info'("spray Agent : Rand is ~p   gap is ~p",
                                 [Rand, 1 / (CountRemovedOut + IndexL)]),

                     case Rand of
                         X when X > 1 / (CountRemovedOut + IndexL) ->
                             %% Select a random arc
                             RandomArc =
                                 lists:nth(
                                     rand:uniform(length(FilteredOutView)), FilteredOutView),
                             supervisor:start_child(bbsvx_sup_client_connections,
                                                    [forward_join,
                                                     NameSpace,
                                                     MyNode,
                                                     RandomArc#arc.target,
                                                     []]);
                         _ -> ok
                     end
                  end,
                  lists:seq(0, CountRemovedOut)),
    ?'log-info'("spray Agent ~p : Recreating connections done", [NameSpace]),
    {keep_state, State};
%% catch all
react_quitted_node(FilteredOutView,
                   CountRemovedOut,
                   FilteredInView,
                   CountRemovedIn,
                   Evt,
                   State) ->
    ?'log-info'("spray Agent ~p : Running state, quitted node, unhandled case "
                "Outview ~p  RemovedOutCount : ~p Inview ~p RemovedInCount ~p "
                "~n Event ~p ~n State ~p",
                [State#state.namespace,
                 FilteredOutView,
                 CountRemovedOut,
                 FilteredInView,
                 CountRemovedIn,
                 Evt,
                 State]),
    {keep_state, State}.

%%-----------------------------------------------------------------------------
%% @doc
%% reset_age/1
%% Reset the age of a node
%% @end
%% ----------------------------------------------------------------------------

-spec reset_age(Ulid :: binary()) -> ok.
reset_age(Ulid) ->
    gproc:send({n, l, {arc, out, Ulid}}, reset_age).

%%-----------------------------------------------------------------------------
%% @doc
%% get_oldest_arc/1
%% Get the oldest arc in a view
%% @end
%% ----------------------------------------------------------------------------

-spec get_oldest_arc([arc()]) -> arc().
get_oldest_arc([Arc]) ->
    Arc;
get_oldest_arc(Arcs) ->
    Sorted = lists:keysort(#arc.age, Arcs),
    lists:last(Sorted).

%%-----------------------------------------------------------------------------
%% @doc
%% filter_arcs_to_leave/2
%% Removes nodes to leave from the outview
%% @end
%% ----------------------------------------------------------------------------
-spec filter_arcs_to_leave([arc()], [exchange_entry()]) -> [arc()].
filter_arcs_to_leave(OutView, ArcsToLeave) ->
    lists:filter(fun(Arc) ->
                    case lists:keyfind(Arc#arc.ulid, #exchange_entry.ulid, ArcsToLeave) of
                        false -> true;
                        _ -> false
                    end
                 end,
                 OutView).

%%-----------------------------------------------------------------------------
%% @doc
%% get_big_random_sample/1
%% Like get_random_sample/1 but doesn't substract 1 when halving view size.
%% Used to select nodes to exchange when acting as exchange target
%% @end
%% ----------------------------------------------------------------------------

-spec get_big_random_sample([arc()]) -> {[arc()], [arc()]}.
get_big_random_sample([]) ->
    {[], []};
get_big_random_sample([_] = View) ->
    {[], View};
get_big_random_sample(View) ->
    %% Shuffle the view
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- View])],
    %% split the view in two
    {_Sample, _Rest} = lists:split(length(View) div 2, Shuffled).

%%-----------------------------------------------------------------------------
%% @doc
%% get_randm_sample/2
%% Get a random sample of nodes from a list of nodes.
%% returns the sample and the rest of the list.
%% Used to select nodes to exchange when acting as exchange initiator.
%% @end
%% ----------------------------------------------------------------------------
-spec get_random_sample([arc()]) -> {[arc()], [arc()]}.
get_random_sample([]) ->
    {[], []};
get_random_sample([_] = View) ->
    {[], View};
get_random_sample(View) ->
    %% Shuffle the view
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- View])],
    %% split the view in two
    {_Sample, _Rest} = lists:split(length(View) div 2 - 1, Shuffled).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to all connections in the outview
%%% @returns ok
%%% @end
%%%

-spec broadcast(NameSpace :: binary(), Payload :: term()) -> ok.
broadcast(NameSpace, Payload) ->
    lists:foreach(fun(Pid) -> Pid ! {send, Payload} end, get_outview_pids(NameSpace)).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to all unique connections in the outview
%%% @returns ok
%%% @end
%%%
-spec broadcast_unique(NameSpace :: binary(), Payload :: term()) -> ok.
broadcast_unique(NameSpace, Payload) ->
    Pids = get_outview_pids(NameSpace),
    UniquePids = lists:usort(Pids),

    lists:foreach(fun(Pid) -> Pid ! {send, Payload} end, UniquePids).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to a random subset of the view
%%% @returns Number of nodes the payload was sent to
%%% @end

-spec broadcast_unique_random_subset(NameSpace :: binary(),
                                     Payload :: term(),
                                     N :: integer()) ->
                                        {ok, integer()}.
broadcast_unique_random_subset(NameSpace, Payload, N) ->
    RandomSubset = get_n_unique_random(NameSpace, N),
    lists:foreach(fun(#arc{ulid = Ulid}) -> send(Ulid, out, Payload) end, RandomSubset),
    {ok, length(RandomSubset)}.

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get n unique random arcs from the outview
%%% @returns [arc()]
%%% @end
-spec get_n_unique_random(binary() | list(), N :: integer()) -> [arc()].
get_n_unique_random(NameSpace, N) when is_binary(NameSpace) ->
    OutView = get_outview(NameSpace),
    get_n_unique_random(OutView, N);
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get n unique random elements from the input list
%%% @returns [term()]
%%% @end
get_n_unique_random(List, N) ->
    lists:sublist(
        lists:usort(fun(_N1, _N2) -> rand:uniform(2) =< 1 end, List), N).

%%-----------------------------------------------------------------------------
%% @doc
%% get_outview/1
%% Get the outview of a namespace
%% @end
%% ----------------------------------------------------------------------------

-spec get_outview(binary()) -> [arc()].
get_outview(NameSpace) ->
    Key = {outview, NameSpace},
    GProcKey = {p, l, Key},
    MatchHead = {GProcKey, '_', '$1'},
    Guard = [],
    Result = ['$1'],
    gproc:select([{MatchHead, Guard, Result}]).

%%-----------------------------------------------------------------------------
%% @doc
%% get_inview/1
%% Get the inview of a namespace
%% @end
%% ----------------------------------------------------------------------------

-spec get_inview(binary()) -> [arc()].
get_inview(NameSpace) ->
    Key = {inview, NameSpace},
    GProcKey = {p, l, Key},
    MatchHead = {GProcKey, '_', '$1'},
    Guard = [],
    Result = ['$1'],
    gproc:select([{MatchHead, Guard, Result}]).

%%-----------------------------------------------------------------------------
%% @doc
%% get_views/1
%% Get the views of a namespace ( inview and outview )
%% @end
%% ----------------------------------------------------------------------------

get_views(NameSpace) ->
    Key = {'_', NameSpace},
    GProcKey = {p, l, Key},
    MatchHead = {GProcKey, '_', '$1'},
    Guard = [],
    Result = ['$1'],
    lists:sort(
        gproc:select([{MatchHead, Guard, Result}])).

get_outview_pids(NameSpace) ->
    Key = {outview, NameSpace},
    GProcKey = {p, l, Key},
    MatchHead = {GProcKey, '$1', '_'},
    Guard = [],
    Result = ['$1'],
    gproc:select([{MatchHead, Guard, Result}]).

get_inview_pids(NameSpace) ->
    Key = {inview, NameSpace},
    GProcKey = {p, l, Key},
    MatchHead = {GProcKey, '$1', '_'},
    Guard = [],
    Result = ['$1'],
    gproc:select([{MatchHead, Guard, Result}]).

format_host(Host) when is_binary(Host) ->
    Host;
format_host(Host) when is_list(Host) ->
    list_to_binary(Host);
format_host({A, B, C, D}) ->
    list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])).

-spec build_metric_view_name(NameSpace :: binary(), MetricName :: binary()) -> binary().
build_metric_view_name(NameSpace, MetricName) ->
    iolist_to_binary([MetricName, binary:replace(NameSpace, <<":">>, <<"_">>)]).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

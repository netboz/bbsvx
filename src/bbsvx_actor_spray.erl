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
-define(EXCHANGE_INTERVAL, 30000).
-define(EXCHANGE_OUT_TIMEOUT, 3000).

%% External API
-export([start_link/1, start_link/2, stop/0, broadcast/2, broadcast_unique/2,
         get_n_unique_random/2, broadcast_unique_random_subset/3, get_view/2]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([iddle/3]).

-record(state,
        {in_view = [] :: [arc()],
         out_view = [] :: [arc()],
         spray_timer :: reference(),
         current_exchange_peer :: {in | out, arc()} | undefined,
         proposed_sample :: [exchange_entry()],
         incoming_sample :: [exchange_entry()],
         namespace :: binary(),
         my_node :: node_entry(),
         arcs_to_leave = [] :: [exchange_entry()]}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================
-spec start_link(Namespace :: binary()) -> gen_statem:start_ret().
start_link(Namespace) ->
    start_link(Namespace, []).

-spec start_link(Namespace :: binary(), Options :: list()) -> gen_statem:start_ret().
start_link(Namespace, Options) ->
    gen_statem:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, Options],
                          []).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to all connections in the outview
%%% @returns ok
%%% @end
%%%

-spec broadcast(Namespace :: binary(), Payload :: term()) -> ok.
broadcast(Namespace, Payload) ->
    gen_statem:cast({via, gproc, {n, l, {?MODULE, Namespace}}}, {broadcast, Payload}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send payload to all unique connections in the outview
%%% @returns ok
%%% @end
%%%
-spec broadcast_unique(Namespace :: binary(), Payload :: term()) -> ok.
broadcast_unique(Namespace, Payload) ->
    gen_statem:cast({via, gproc, {n, l, {?MODULE, Namespace}}}, {broadcast_unique, Payload}).

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
    gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}},
                    {broadcast_unique_random_subset, Payload, N}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get n unique random arcs from the outview
%%% @returns [arc()]
%%% @end
-spec get_n_unique_random(Namespace :: binary(), N :: integer()) -> [arc()].
get_n_unique_random(Namespace, N) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, {get_n_unique_random, N}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get the outview of the spray agent
%%% @returns {ok, [arc()]} | {error, binary()}
%%% @end

-spec get_view(atom(), binary()) -> {ok, [arc()]} | {error, binary()}.
get_view(Type, Namespace) when Type == get_inview orelse Type == get_outview ->
    %% Look for spray agent
    case gproc:where({n, l, {?MODULE, Namespace}}) of
        undefined ->
            ?'log-error'("No view actor on namespace ~p:", [Namespace]),
            {error, <<"no_actor_on_namespace_", Namespace/binary>>};
        Pid ->
            gen_statem:call(Pid, Type)
    end.

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
    %%  Try to register to the ontology node mesh
    register_namespace(Namespace, MyNode, maps:get(contact_nodes, Options, [])),
    %% Notify this node + namespace is ready
    gproc:send({p, l, {spray_exchange, Namespace}}, {node_started, Namespace, MyNode}),

    %% Register to events for this ontolgy namespace
    gproc:reg({p, l, {spray_exchange, Namespace}}),

    Me = self(),
    SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
    {ok,
     iddle,
     #state{namespace = Namespace,
            spray_timer = SprayTimer,
            proposed_sample = [],
            incoming_sample = [],
            my_node =
                #node_entry{node_id = MyNodeId,
                            host = Host,
                            port = Port}}}.

terminate(_Reason, _State, _Data) ->
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
      #incoming_event{origin_arc = Ulid,
                      event = #evt_arc_connected_in{source = Source, lock = Lock}},
      #state{namespace = Namespace,
             out_view = [],
             in_view = InView,
             my_node = MyNode} =
          State) ->
    ?'log-info'("New incoming arc, but empty outview, requesting joing"),
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_inview_size_">>),
                         length(InView) + 1),
    %% send a fowrard join request to the new node. If we would have an outview
    %% we would have sent a forward join request to all nodes in the outview.
    open_connection(Namespace, MyNode, Source, []),
    {keep_state,
     State#state{in_view =
                     [#arc{source = Source,
                           lock = Lock,
                           target = MyNode,
                           ulid = Ulid}
                      | InView]}};
iddle(info,
      #incoming_event{event =
                          #evt_arc_connected_in{ulid = Ulid,
                                                lock = Lock,
                                                source = SourceNode,
                                                spread = Spread}},
      #state{namespace = Namespace,
             my_node = MyNode,
             out_view = OutView,
             in_view = InView} =
          State) ->
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_inview_size_">>),
                         length(InView) + 1),
    %% Check if we need to spread ( send forward join ) to neighbors
    case Spread of
        {true, Lock} ->
            ?'log-info'("spray Agent ~p : Running state, New arc in, spreading to neighbors",
                        [State#state.namespace]),
            %% Broadcast forward subscription to all nodes in the outview
            lists:foreach(fun(#arc{ulid = DestUlid}) ->
                             send(DestUlid,
                                  out,
                                  #open_forward_join{lock = Lock, subscriber_node = SourceNode})
                          end,
                          OutView);
        _ ->
            ?'log-info'("spray Agent ~p : Running state, New arc in, no spread",
                        [State#state.namespace])
    end,
    {keep_state,
     State#state{in_view =
                     [#arc{ulid = Ulid,
                           lock = Lock,
                           target = MyNode,
                           source = SourceNode}
                      | InView]}};
%% Register new arc out
iddle(info,
      #incoming_event{event =
                          #evt_arc_connected_out{target = TargetNode,
                                                 lock = Lock,
                                                 ulid = IncomingUlid}},
      #state{namespace = Namespace,
             out_view = OutView,
             my_node = MyNode} =
          State) ->
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_outview_size_">>),
                         length(OutView) + 1),

    ?'log-info'("spray Agent ~p : Arc connected out, adding to outview",
                [#arc{source = MyNode,
                      target = TargetNode,
                      lock = Lock,
                      ulid = IncomingUlid}]),

    {keep_state,
     State#state{out_view =
                     [#arc{source = MyNode,
                           target = TargetNode,
                           lock = Lock,
                           ulid = IncomingUlid}
                      | OutView]}};
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event = #open_forward_join{subscriber_node = SubscriberNode}},
      #state{namespace = Namespace, my_node = MyNode} = State) ->
    %% Openning forwarded joinrequestfrom registration of SubscriberNode
    open_connection(Namespace, MyNode, SubscriberNode, []),
    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event = #evt_arc_disconnected{ulid = Ulid, direction = in}},
      #state{namespace = Namespace, in_view = InView} = State) ->
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_inview_size_">>),
                         length(InView) - 1),
    %% If size of inview is 0, log prometheus event
    case length(InView) - 1 of
        0 ->
            prometheus_counter:inc(build_metric_view_name(Namespace, <<"spray_inview_depleted_">>));
        _ ->
            ok
    end,
    ?'log-info'("spray Agent ~p : Running state, arc disconnected in ~p",
                [State#state.namespace, Ulid]),
    NewView = lists:keydelete(Ulid, #arc.ulid, InView),
    {keep_state, State#state{in_view = NewView}};
iddle(info,
      #incoming_event{origin_arc = _Ulid,
                      event = #evt_arc_disconnected{ulid = Ulid, direction = out}},
      #state{namespace = Namespace,
             out_view = OutView,
             arcs_to_leave = ArcsToLeave} =
          State) ->
    prometheus_gauge:set(build_metric_view_name(Namespace, <<"spray_outview_size_">>),
                         length(OutView) - 1),
    case length(OutView) - 1 of
        0 ->
            prometheus_counter:inc(build_metric_view_name(Namespace,
                                                          <<"spray_outview_depleted_">>));
        _ ->
            ok
    end,

    ?'log-info'("spray Agent ~p : Running state, arc disconnected out ~p",
                [State#state.namespace, Ulid]),
    %% Remove arc from node to leave
    NewArcToLeave = lists:keydelete(Ulid, #exchange_entry.ulid, ArcsToLeave),
    %% Remove also from outview
    NewView = lists:keydelete(Ulid, #arc.ulid, OutView),
    {keep_state, State#state{out_view = NewView, arcs_to_leave = NewArcToLeave}};
%% Reception of 'spray_time' event signaling it is time to start exchange
iddle(info,
      spray_time,
      #state{namespace = Namespace, current_exchange_peer = {_, Peer}} = State) ->
    ?'log-info'("spray Agent ~p : Running state, spray time, but busy with peer ~p",
                [State#state.namespace, Peer]),
    Me = self(),
    ?'log-info'("spray Agent ~p : Busy state, QUEUE ~p",
                [Namespace, erlang:process_info(Me, messages)]),
    {keep_state, State};
iddle(info, {timeout, _, spray_time}, #state{out_view = []} = State) ->
    ?'log-info'("spray Agent ~p : Running state, Outview empty, no exchange",
                [State#state.namespace]),
    Me = self(),
    SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),

    {keep_state, State#state{spray_timer = SprayTimer}};
iddle(info,
      {timeout, _, spray_time},
      #state{namespace = Namespace,
             my_node = #node_entry{node_id = MyNodeId} = MyNode,
             arcs_to_leave = ArcsToLeave,
             out_view = OutView} =
          State) ->
    %% Filter out the arcs that are among the arcs to leave
    FilteredPartialView = filter_arcs_to_leave(OutView, ArcsToLeave),

    case FilteredPartialView of
        [] ->
            ?'log-info'("spray Agent ~p : Running state, no exchange, no nodes to connect",
                        [State#state.namespace]),
            Me = self(),
            SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
            {keep_state, State#state{spray_timer = SprayTimer}};
        _ ->
            ?'log-info'("spray Agent ~p : Node ~p starting spray loop", [Namespace, MyNodeId]),
            ?'log-info'("spray Agent ~p : Outview :~p    Arcs to leave : ~p",
                        [Namespace, FilteredPartialView, ArcsToLeave]),

            %% Increment age of nodes in out view
            AgedPartialView =
                lists:map(fun(#arc{age = Age} = Arc) -> Arc#arc{age = Age + 1} end,
                          FilteredPartialView),

            %% Get oldest arc
            #arc{ulid = Ulid} = OldestArc = get_oldest_arc(FilteredPartialView),

            ?'log-info'("Actor exchanger ~p : Doing exchange with node ~p  on arc ~p",
                        [Namespace, OldestArc#arc.target, OldestArc#arc.ulid]),

            %% Partialview without oldest Arc
            {_, _, PartialViewWithoutOldest} = lists:keytake(Ulid, #arc.ulid, FilteredPartialView),

            %% Get sample from out view without oldest
            {Sample, _KeptArcs} = get_random_sample(PartialViewWithoutOldest),

            %% reAdd oldest node
            SamplePlusOldest = [OldestArc | Sample],
            %% Replace all occurences of oldest node in samplePlusOldest
            %% by our node, to avoid target doing loops
            FinalSample =
                lists:map(fun (#arc{target = #node_entry{node_id = TargetNodeId}} = Arc)
                                  when TargetNodeId == OldestArc#arc.target#node_entry.node_id ->
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
            send(OldestArc#arc.ulid, out, {send, #exchange_in{proposed_sample = ProposedSample}}),

            ?'log-info'("Actor exchanger ~p : Running state, Sent partial view exchange "
                        "in to ~p   sample : ~p",
                        [State#state.namespace, OldestArc#arc.target, ProposedSample]),
            %% program execution of next exchange
            Me = self(),
            SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
            {keep_state,
             State#state{current_exchange_peer = {out, OldestArc},
                         proposed_sample = ProposedSample,
                         out_view = AgedPartialView,
                         spray_timer = SprayTimer},
             1500}
    end;
%% Manage reception of exchange out from oldest node
iddle(info,
      #incoming_event{event = #exchange_out{proposed_sample = IncomingSample},
                      origin_arc = ArcUlid},
      #state{namespace = Namespace,
             my_node = #node_entry{node_id = MyNodeId} = MyNode,
             arcs_to_leave = ArcsToLeave,
             out_view = OutView,
             proposed_sample = ProposedSample,
             current_exchange_peer = {_, CurrentExchangePeer}} =
          State) ->
    %% We can accept the exchange and start joining the proposed sample
    ?'log-info'("Actor exchanger ~p : Got partial view exchange out from ~p~nProposed "
                "sample ~p~nOutview ~p",
                [Namespace, CurrentExchangePeer, IncomingSample, State#state.out_view]),
    %% Filter out the arcs in the IncomingSample to remove arcs coming to us.
    %% If this returns an empty list, and we only have one node in outview
    %% we cancel the exchange
    case lists:filter(fun(#exchange_entry{target = #node_entry{node_id = LoopNodeId}}) ->
                         LoopNodeId =/= MyNodeId
                      end,
                      IncomingSample)
    of
        [] when length(OutView) == 1 ->
            ?'log-info'("Actor exchanger ~p : wait_exchange_out, empty proposal single "
                        "outview ~p",
                        [Namespace, ArcUlid]),
            send(ArcUlid,
                 out,
                 {send,
                  #exchange_cancelled{reason = exchange_out_cause_empty_outview,
                                      namespace = Namespace}}),

            %% Trigger next exchange
            SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, self(), spray_time),
            {keep_state,
             State#state{current_exchange_peer = undefined,
                         proposed_sample = [],
                         incoming_sample = [],
                         spray_timer = SprayTimer}};
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
            send(ArcUlid, out, {send, #exchange_accept{}}),
            ?'log-info'("Connecting to incoming sample ~p", [IncomingSample]),

            %% start conneting to the proposed sample
            swap_connections(Namespace, MyNode, CurrentExchangePeer#arc.target, IncomingSample),
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
    send(ArcUlid, in, {reject, exchange_busy}),
    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = SourceArcUlid, event = #exchange_in{}},
      #state{in_view = [#arc{ulid = SourceArcUlid}]} = State) ->
    %% Origin node is in our inview
    %% Asked to do exchange but our only input is this node, going forward would
    %% make us empty inview, so we cancel this exchange
    ?'log-notice'("spray Agent ~p : Running state, cancelling exchange : empty "
                  "inview",
                  [State#state.namespace]),
    send(SourceArcUlid, in, {reject, exchange_in_empty_inview}),
    {keep_state, State};
iddle(info,
      #incoming_event{origin_arc = OriginUlid,
                      event = #exchange_in{proposed_sample = IncomingSample}},
      #state{namespace = Namespace,
             arcs_to_leave = ArcsToLeave,
             my_node = MyNode,
             current_exchange_peer = undefined,
             in_view = InView,
             out_view = OutView} =
          State) ->
    ?'log-info'("Actor exchanger ~p : starting exchange proposed by arc ~p ~n "
                "Incoming sample : ~p",
                [Namespace, OriginUlid, IncomingSample]),
    case lists:keyfind(OriginUlid, #arc.ulid, InView) of
        #arc{source = SourceNode} = ExchangeArc ->
            ?'log-info'("spray Agent ~p : Arc ~p    Matching node ~p",
                        [State#state.namespace, OriginUlid, SourceNode]),
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
                        [Namespace, OriginUlid, MySample]),

            %% Send exchange out to origin node
            send(OriginUlid, in, #exchange_out{proposed_sample = MySampleEntry}),

            {keep_state,
             State#state{proposed_sample = MySampleEntry,
                         incoming_sample = IncomingSample,
                         current_exchange_peer = {in, ExchangeArc}},
             ?EXCHANGE_OUT_TIMEOUT};
        _ ->
            ?'log-warning'("spray Agent ~p : Running state, exchange in from unknown node ~p",
                           [State#state.namespace, OriginUlid]),
            %% Cancel exchange
            send(OriginUlid, in, {reject, exchange_in_unknown_node}),
            {keep_state, State}
    end;
iddle(info,
      #incoming_event{event = #exchange_cancelled{reason = Reason}},
      #state{current_exchange_peer = {out, #arc{ulid = PeerUlid}}, out_view = OutView} =
          State) ->
    ?'log-info'("spray Agent ~p : Running state, exchange cancelled out : ~p",
                [State#state.namespace, Reason]),
    %% Reset age of the node in outview
    NewOutView = reset_age(PeerUlid, OutView),
    {keep_state,
     State#state{current_exchange_peer = undefined,
                 out_view = NewOutView,
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
      #state{namespace = Namespace,
             my_node = MyNode,
             current_exchange_peer = {_, CurrentExchangePeer},
             incoming_sample = IncomingSample,
             proposed_sample = ProposedSample,
             arcs_to_leave = ArcsToLeave} =
          State) ->
    ?'log-info'("spray Agent ~p : Exchange accepted, nodes to leave : ~p    "
                "~nNodes to join : ~p    exchange peer : ~p",
                [Namespace, ProposedSample, IncomingSample, CurrentExchangePeer]),

    swap_connections(Namespace, MyNode, CurrentExchangePeer#arc.source, IncomingSample),
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
      #incoming_event{event =
                          #evt_arc_swapped_in{ulid = Ulid,
                                              newlock = NewLock,
                                              new_source = NewSource}},
      #state{in_view = InView, my_node = MyNode} = State) ->
    ?'log-info'("spray Agent ~p : Running state, arc swapped in ~p",
                [State#state.namespace, Ulid]),
    case lists:keytake(Ulid, #arc.ulid, InView) of
        {value, #arc{source = OldSource} = Arc, NewInView} ->
            ?'log-info'("spray Agent ~p : Running state, arc swapped in ~p  old source "
                        ": ~p    new source : ~p",
                        [State#state.namespace, Ulid, OldSource, NewSource]),
            {keep_state,
             State#state{in_view =
                             [Arc#arc{lock = NewLock,
                                      source = NewSource,
                                      target = MyNode}
                              | NewInView]}};
        false ->
            ?'log-warning'("spray Agent ~p : Running state, arc swapped in ~p not found "
                           "in ~p",
                           [State#state.namespace, Ulid, InView]),
            {keep_state, State}
    end,
    {keep_state, State};
iddle(info,
      #evt_end_exchange{exchanged_ulids = EndedExchangeUlids},
      #state{arcs_to_leave = ArcsToLeave,
             out_view = OutView,
             my_node = #node_entry{node_id = MyNodeId}} =
          State) ->
    ?'log-info'("spray Agent ~p : Running state, end exchange, veryting arcs ~p",
                [State#state.namespace, EndedExchangeUlids]),
    ?'log-info'("Arcs to leave ~p", [ArcsToLeave]),

    %% For each node in EndedExchangeUlids, check if an exchange entry with same Ulid is present
    %% in ArcsToLeave, if so remove it from arcs to leave
    %% and send a message on the ulid to request changing the lock.
    %% If the node is not in ArcsToLeave, it means the exchange for it was done normally
    {NewArcsToLeave, NewOutView} =
        lists:foldl(fun(Ulid, {AccArcToLeave, AccOutView}) ->
                       case lists:keytake(Ulid, #exchange_entry.ulid, AccArcToLeave) of
                           {value,
                            #exchange_entry{lock = Lock, target = #node_entry{node_id = MyNodeId}} =
                                E,
                            NewAccArcToLeave} ->
                               ?'log-notice'("spray Agent ~p : Mirror Exchange ended, not connected : ~p "
                                             "exhange entry : ~p",
                                             [State#state.namespace, Ulid, E]),
                               %% Exchange peer haven't reconnected to us
                               %% We change our lock and update the lock of client connection
                               NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),
                               case update_lock(Ulid, NewLock, AccOutView) of
                                   {ok, NewAccOutView} ->
                                       %%Lock was updated locally, send message to the node
                                       send(Ulid,
                                            out,
                                            {send,
                                             #change_lock{current_lock = Lock,
                                                          new_lock = NewLock}}),
                                       {NewAccArcToLeave, NewAccOutView};
                                   {error, Reason} ->
                                       ?'log-warning'("spray Agent ~p : Error updating mirror lock ~p",
                                                      [State#state.namespace, Reason]),
                                       {AccArcToLeave, AccOutView}
                               end;
                           {value, #exchange_entry{lock = Lock} = E, NewAccArcToLeave} ->
                               ?'log-notice'("spray Agent ~p : normal Exchange ended, not connected : ~p "
                                             " Exchange entry : ~p",
                                             [State#state.namespace, Ulid, E]),
                               NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),
                               case update_lock(Ulid, NewLock, AccOutView) of
                                   {ok, NewAccOutView} ->
                                       %%Lock was updated locally, send message to the node
                                       send(Ulid,
                                            out,
                                            {send,
                                             #change_lock{current_lock = Lock,
                                                          new_lock = NewLock}}),
                                       {NewAccArcToLeave, NewAccOutView};
                                   {error, Reason} ->
                                       ?'log-warning'("spray Agent ~p : Error updating lock ~p   ulid: ~p",
                                                      [State#state.namespace, Reason, ulid]),
                                       {AccArcToLeave, AccOutView}
                               end;
                           false ->
                               ?'log-info'("spray Agent ~p : verified exchange entry ~p disconectedin ~p",
                                           [State#state.namespace, Ulid, AccArcToLeave]),
                               {AccArcToLeave, AccOutView}
                       end
                    end,
                    {ArcsToLeave, OutView},
                    EndedExchangeUlids),
    {keep_state, State#state{arcs_to_leave = NewArcsToLeave, out_view = NewOutView}};
iddle(info,
      #incoming_event{event = #change_lock{current_lock = CurrentLock, new_lock = NewLock}},
      #state{in_view = InView} = State) ->
    ?'log-info'("spray Agent ~p : Running state, change lock, current ~p new ~p",
                [State#state.namespace, CurrentLock, NewLock]),
    case update_lock(CurrentLock, NewLock, InView) of
        {ok, NewInView} ->
            {keep_state, State#state{in_view = NewInView}};
        {error, Reason} ->
            ?'log-warning'("spray Agent ~p : Running state, error updating inview lock ~p",
                           [State#state.namespace, Reason]),
            {keep_state, State}
    end;
%% API
iddle(cast,
      {broadcast, Payload},
      #state{out_view = OutView, arcs_to_leave = ArcsToLeave} = State) ->
    lists:foreach(fun(#arc{ulid = Ulid}) -> send(Ulid, out, {send, Payload}) end,
                  filter_arcs_to_leave(OutView, ArcsToLeave)),
    {keep_state, State};
iddle(cast,
      {broadcast_unique, Payload},
      #state{out_view = OutView, arcs_to_leave = ArcsToLeave} = State) ->
    lists:foreach(fun(#arc{ulid = Ulid}) -> send(Ulid, out, {send, Payload}) end,
                  lists:usort(fun(N1, N2) -> N1#arc.ulid =< N2#arc.ulid end,
                              filter_arcs_to_leave(OutView, ArcsToLeave))),
    {keep_state, State};
iddle({call, From},
      {broadcast_unique_random_subset, Payload, N},
      #state{out_view = OutView, arcs_to_leave = ArcsToLeave} = State)
    when is_number(N) ->
    %% Get n unique random nodes from the outview
    RandomSubset =
        lists:sublist(
            lists:usort(fun(_N1, _N2) -> rand:uniform(2) =< 1 end,
                        filter_arcs_to_leave(OutView, ArcsToLeave)),
            N),

    lists:foreach(fun(#arc{ulid = Ulid}) -> send(Ulid, out, Payload) end, RandomSubset),
    gen_statem:reply(From, {ok, length(RandomSubset)}),
    {keep_state, State};
%% Return the requested view
iddle({call, From}, get_inview, #state{in_view = InView} = State) ->
    gen_statem:reply(From, {ok, InView}),
    {keep_state, State};
iddle({call, From}, get_outview, #state{out_view = OutView} = State) ->
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
%% catch all
iddle(Type, Msg, State) ->
    ?'log-warning'("spray Agent ~p : Running state, unhandled message ~p ~p~n State "
                   ": ~p",
                   [State#state.namespace, Type, Msg, State]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% Join a node. This is to be called when joining a node as an exchange
-spec swap_connections(binary(), node_entry(), node_entry(), [exchange_entry()]) -> ok.
swap_connections(Namespace,
                 MyNode,
                 #node_entry{node_id = ExchangePeerNodeId},
                 IncomingSample) ->
    ?'log-info'("spray Agent ~p : Swapping connections with ~p",
                [Namespace, ExchangePeerNodeId]),
    lists:foreach(fun (#exchange_entry{target = #node_entry{node_id = TargetNodeId}} =
                           ExchangeEntry)
                          when TargetNodeId == ExchangePeerNodeId ->
                          ?'log-info'("spray Agent ~p : mirror Swapping connection with ~p",
                                      [Namespace, TargetNodeId]),
                          swap_connection(Namespace, MyNode, mirror, ExchangeEntry);
                      (ExchangeEntry) ->
                          ?'log-info'("spray Agent ~p : normal Swapping connection with ~p",
                                      [Namespace,
                                       ExchangeEntry#exchange_entry.target#node_entry.node_id]),
                          swap_connection(Namespace, MyNode, normal, ExchangeEntry)
                  end,
                  IncomingSample).

-spec swap_connection(Namespace :: binary(),
                      MyNode :: node_entry(),
                      Type :: mirror | normal,
                      ExchangeEntry :: exchange_entry()) ->
                         supervisor:startchild_ret().
swap_connection(Namespace,
                MyNode,
                Type,
                #exchange_entry{target = TargetNode,
                                ulid = Ulid,
                                lock = Lock}) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [join, Namespace, MyNode, TargetNode, Ulid, Lock, Type, []]).

-spec open_connection(Namespace :: binary(),
                      MyNode :: node_entry(),
                      TargetNode :: node_entry(),
                      Options :: list()) ->
                         supervisor:startchild_ret().
open_connection(Namespace, MyNode, TargetNode, Options) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [forward_join, Namespace, MyNode, TargetNode, Options]).

-spec send(Ulid :: binary(), Direction :: in | out, Payload :: term()) -> ok.
send(Ulid, Direction, Payload) ->
    gproc:send({n, l, {arc, Direction, Ulid}},
               #incoming_event{origin_arc = Ulid, event = Payload}).

%% set to 0 the age of the nodes in the outview
-spec reset_age(Ulid :: binary(), View :: [arc()]) -> [arc()].
reset_age(Ulid, View) ->
    case lists:keytake(Ulid, #arc.ulid, View) of
        {value, #arc{age = _} = Arc, NewView} ->
            [Arc#arc{age = 0} | NewView];
        false ->
            View
    end.

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
%% get_randm_sample/2
%% Get a random sample of nodes from a list of nodes.
%% returns the sample and the rest of the list
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

%%-----------------------------------------------------------------------------
%% @doc
%% get_big_random_sample/1
%% Like get_random_sample/1 but doesn't substract 1 when halving view size
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

%% Register to a node. This is to be called when contacting a node to request
%% to join the namespace
-spec register_to_node(binary(), node_entry(), node_entry()) ->
                          supervisor:startchild_ret().
register_to_node(Namespace, MyNode, ContactNode) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [register,
                            Namespace,
                            MyNode,
                            ContactNode#node_entry{host = ContactNode#node_entry.host},
                            []]).

%% Join namespace by sending register requests to the lists of nodes
%% Return list of nodes that failed to start registering, empty list if all
%% nodes succeeded to connection bootup
-spec register_namespace(binary(), node_entry(), [node_entry()]) ->
                            [{node_entry(), any()}].
register_namespace(Namespace, MyNode, ContactNodes) ->
    ?'log-info'("spray Agent ~p : Registering to nodes ~p", [Namespace, ContactNodes]),
    lists:foldl(fun(Node, FailedNodes) ->
                   ?'log-debug'("Registering to node ~p", [Node]),
                   case register_to_node(Namespace, MyNode, Node) of
                       {ok, _} -> FailedNodes;
                       {error, Reason} -> [{Node, Reason} | FailedNodes];
                       ignore -> FailedNodes
                   end
                end,
                [],
                ContactNodes).

-spec update_lock(Ulid :: binary(), NewLock :: binary(), View :: [arc()]) ->
                     {ok, [arc()]} | {error, atom()}.
update_lock(Ulid, NewLock, View) ->
    case lists:keytake(Ulid, #arc.ulid, View) of
        {value, #arc{} = Arc, NewView} ->
            NewArc = Arc#arc{lock = NewLock},
            {ok, [NewArc | NewView]};
        false ->
            {error, arc_not_found}
    end.

-spec init_metrics(Namespace :: binary()) -> ok.
init_metrics(Namespace) ->
    %% Create some metrics
    prometheus_gauge:declare([{name,
                               build_metric_view_name(Namespace, <<"spray_networksize_">>)},
                              {help, "Number of nodes patricipating in this ontology network"}]),
    prometheus_gauge:declare([{name,
                               build_metric_view_name(Namespace, <<"spray_inview_size_">>)},
                              {help, "Number of nodes in ontology inview"}]),
    prometheus_gauge:declare([{name,
                               build_metric_view_name(Namespace, <<"spray_outview_size_">>)},
                              {help, "Number of nodes in ontology partial view"}]),
    prometheus_counter:declare([{name,
                                 build_metric_view_name(Namespace,
                                                        <<"spray_initiator_echange_timeout_">>)},
                                {help, "Number of timeout occuring during exchange"}]),
    prometheus_counter:declare([{name,
                                 build_metric_view_name(Namespace, <<"spray_inview_depleted_">>)},
                                {help, "Number of times invirew reach 0"}]),
    prometheus_counter:declare([{name,
                                 build_metric_view_name(Namespace, <<"spray_outview_depleted_">>)},
                                {help, "Number of times outview reach 0"}]),
    prometheus_counter:declare([{name,
                                 build_metric_view_name(Namespace,
                                                        <<"spray_empty_inview_answered_">>)},
                                {help, "Number times this node answered a refuel inview request"}]).

-spec build_metric_view_name(Namespace :: binary(), MetricName :: binary()) -> atom().
build_metric_view_name(Namespace, MetricName) ->
    binary_to_atom(iolist_to_binary([MetricName,
                                     binary:replace(Namespace, <<":">>, <<"_">>)])).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

%%%-----------------------------------------------------------------------------
%%% BBSvx EPTO Disorder Component
%%%-----------------------------------------------------------------------------

-module(bbsvx_epto_disord_component).

-moduledoc "BBSvx EPTO Disorder Component\n\n"
"Gen State Machine for EPTO dissemination protocol disorder handling.\n\n"
"Manages event ordering, broadcasting, and state transitions for the EPTO consensus algorithm.".

-author("yan").

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-behaviour(gen_statem).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(DEFAULT_ROUND_TIME, 20).
%% Minimum TTL - ensures delivery even in small networks
-define(MIN_TTL, 4).
%% Maximum TTL - prevents excessive latency in large networks
-define(MAX_TTL, 20).
%% TTL update interval in rounds (update every N rounds to avoid thrashing)
-define(TTL_UPDATE_INTERVAL, 50).

%% External API
-export([start_link/2, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3, syncing/3, handle_event/3]).

-record(state, {
    namespace :: binary(),
    round_timer :: timer:tref(),
    current_index :: integer() | undefined,
    fanout :: integer(),
    ttl :: integer(),
    next_ball :: map(),
    logical_clock_pid :: pid(),
    received = #{} :: map(),
    delivered :: ordsets:ordset(term()),
    last_delivered_ts = 0 :: integer(),
    %% Round counter for periodic TTL updates
    round_count = 0 :: integer()
}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), Options :: list()) ->
    {ok, pid()} | gen_statem:start_ret().
start_link(Namespace, Options) ->
    gen_statem:start(
        {via, gproc, {n, l, {?SERVER, Namespace}}},
        ?MODULE,
        [Namespace, Options],
        []
    ).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    quickrand:seed(),
    Fanout = maps:get(fanout, Options, 4),
    Ttl = maps:get(ttl, Options, 6),
    {ok, LogicalClock} = bbsvx_epto_logical_clock:start_link(Namespace, Ttl),
    %% Register to epto messages received at inview (ejabberd mod )
    ?'log-info'(
        "Epto dissemination component starting ~p with options ~p (initial TTL=~p)",
        [Namespace, Options, Ttl]
    ),
    gproc:reg({p, l, {epto_event, Namespace}}),
    %% Initialize Prometheus TTL metric
    prometheus_gauge:set(<<"bbsvx_epto_ttl">>, [Namespace], Ttl),

    {ok, RoundTimer} =
        timer:apply_interval(?DEFAULT_ROUND_TIME, gen_server, cast, [self(), next_round]),

    case maps:get(boot, Options, false) of
        create ->
            %% Start with current_index = 1 because genesis transaction (index 0)
            %% is submitted directly to ontology actor, bypassing EPTO.
            %% First user transaction will be delivered with index 1.
            ?'log-info'("~p starting discord as root (create mode, starting at index 1)", [?MODULE]),
            {ok, running, #state{
                round_timer = RoundTimer,
                namespace = Namespace,
                logical_clock_pid = LogicalClock,
                fanout = Fanout,
                current_index = 1,
                delivered = ordsets:new(),
                ttl = Ttl,
                next_ball = #{}
            }};
        _ ->
            ?'log-info'("~p starting discord as non-root (connect/reconnect mode)", [?MODULE]),
            {ok, syncing, #state{
                round_timer = RoundTimer,
                namespace = Namespace,
                logical_clock_pid = LogicalClock,
                fanout = Fanout,
                delivered = ordsets:new(),
                ttl = Ttl,
                next_ball = #{}
            }}
    end.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
syncing(enter, _, State) ->
    ?'log-info'("Entering syncing state ~p", [State]),
    {keep_state, State};
syncing({call, From}, empty_inview, _State) ->
    gen_statem:reply(From, ok),
    keep_state_and_data;
syncing({call, From}, {epto_broadcast, Payload}, #state{next_ball = NextBall} = State) ->
    ?'log-info'("Epto dissemination component : Broadcast ~p", [Payload]),

    EvtId = ulid:generate(),
    Event =
        #epto_event{
            id = EvtId,
            ts = gen_server:call(State#state.logical_clock_pid, get_clock),
            ttl = 0,
            namespace = State#state.namespace,
            source_id = atom_to_binary(node()),
            payload = Payload
        },
    gen_statem:reply(From, ok),
    {keep_state, State#state{next_ball = maps:put(EvtId, Event, NextBall)}};
syncing(
    info,
    {incoming_event, {receive_ball, Ball, CurrentIndex}},
    #state{
        namespace = Namespace,
        delivered = Delivered,
        received = Received,
        last_delivered_ts = LastDeliveredTs,
        logical_clock_pid = LogicalClockPid
    } = State
) ->
    gproc:send({n, l, {bbsvx_actor_ontology, Namespace}}, {registered, CurrentIndex}),
    %% This means we are getting connected to the network
    %% We process the ball and update the index accordingliy
    UpdatedNextBall =
        maps:fold(
            fun
                (EvtId, #epto_event{ttl = EvtTtl, ts = EvtTs} = Evt, Acc) when
                    EvtTtl < State#state.ttl
                ->
                    NewAcc =
                        case maps:get(EvtId, Acc, undefined) of
                            undefined ->
                                maps:put(EvtId, Evt, Acc);
                            #epto_event{ttl = EvtBallTtl} = EvtBall when
                                EvtBallTtl < EvtTtl
                            ->
                                maps:put(EvtId, EvtBall#epto_event{ttl = EvtTtl}, Acc);
                            _ ->
                                Acc
                        end,
                    gen_server:call(State#state.logical_clock_pid, {update_clock, EvtTs}),
                    NewAcc;
                (_EvtId, #epto_event{ts = EvtTs}, Acc) ->
                    gen_server:call(State#state.logical_clock_pid, {update_clock, EvtTs}),
                    Acc
            end,
            State#state.next_ball,
            Ball
        ),

    %% Process events from the ball for delivery before transitioning to running
    {NewDelivered, NewReceived, NewLastDeliveredTs, NewIndex} =
        order_events(
            UpdatedNextBall,
            Delivered,
            Received,
            LastDeliveredTs,
            LogicalClockPid,
            CurrentIndex
        ),

    {next_state, running, State#state{
        next_ball = #{},
        delivered = NewDelivered,
        current_index = NewIndex,
        received = NewReceived,
        last_delivered_ts = NewLastDeliveredTs
    }};
syncing(
    cast,
    next_round,
    #state{
        namespace = Namespace,
        delivered = Delivered,
        received = Received,
        current_index = CurrentIndex,
        last_delivered_ts = LastDeliveredTs,
        logical_clock_pid = LogicalClockPid
    } =
        State
) when
    CurrentIndex =/= undefined
->
    NewBall =
        maps:map(
            fun(_EvtId, #epto_event{ttl = EvtTtl} = Evt) -> Evt#epto_event{ttl = EvtTtl + 1} end,
            State#state.next_ball
        ),

    %% Broadcast next ball to sample peers
    bbsvx_actor_spray:broadcast_unique(
        Namespace,
        #epto_message{
            payload =
                {receive_ball, NewBall, CurrentIndex}
        }
    ),
    {NewDelivered, NewReceived, NewLastDeliveredTs, NewIndex} =
        order_events(
            NewBall,
            Delivered,
            Received,
            LastDeliveredTs,
            LogicalClockPid,
            CurrentIndex
        ),
    {keep_state, State#state{
        next_ball = #{},
        delivered = NewDelivered,
        current_index = NewIndex,
        received = NewReceived,
        last_delivered_ts = NewLastDeliveredTs
    }};
syncing(cast, next_round, _State) ->
    %% The agent is booting and so have no ball or index to transmit
    keep_state_and_data.

running(enter, _, State) ->
    ?'log-info'("Entering running state ~p", [State]),
    {keep_state, State};
running({call, From}, empty_inview, _State) ->
    %% TODO: Review SPRAY-EPTO interaction design
    %% For now, stay in running state - EPTO is resilient to temporary disconnections
    gen_statem:reply(From, ok),
    keep_state_and_data;
running({call, From}, {epto_broadcast, Payload}, #state{next_ball = NextBall} = State) ->
    ?'log-info'("Epto dissemination component : Broadcast ~p", [Payload]),

    EvtId = ulid:generate(),
    Event =
        #epto_event{
            id = EvtId,
            ts = gen_server:call(State#state.logical_clock_pid, get_clock),
            ttl = 0,
            namespace = State#state.namespace,
            source_id = atom_to_binary(node()),
            payload = Payload
        },
    gen_statem:reply(From, ok),
    {keep_state, State#state{next_ball = maps:put(EvtId, Event, NextBall)}};
running(
    cast,
    next_round,
    #state{
        namespace = Namespace,
        delivered = Delivered,
        received = Received,
        current_index = CurrentIndex,
        last_delivered_ts = LastDeliveredTs,
        logical_clock_pid = LogicalClockPid,
        round_count = RoundCount
    } =
        State
) ->
    %% Increment round counter and maybe update TTL adaptively
    NewRoundCount = RoundCount + 1,
    StateWithTTL = maybe_update_ttl(State#state{round_count = NewRoundCount}),

    NewBall =
        maps:map(
            fun(_EvtId, #epto_event{ttl = EvtTtl} = Evt) -> Evt#epto_event{ttl = EvtTtl + 1} end,
            StateWithTTL#state.next_ball
        ),

    %% Broadcast next ball to sample peers
    bbsvx_actor_spray:broadcast_unique(
        Namespace,
        #epto_message{
            payload =
                {receive_ball, NewBall, CurrentIndex}
        }
    ),
    {NewDelivered, NewReceived, NewLastDeliveredTs, NewIndex} =
        order_events(
            NewBall,
            Delivered,
            Received,
            LastDeliveredTs,
            LogicalClockPid,
            CurrentIndex
        ),
    {keep_state, StateWithTTL#state{
        next_ball = #{},
        delivered = NewDelivered,
        received = NewReceived,
        current_index = NewIndex,
        last_delivered_ts = NewLastDeliveredTs
    }};
running(
    info,
    {incoming_event, {receive_ball, Ball, _CurrentIndex}},
    #state{namespace = _Namespace} = State
) ->
    %% TODO: next event could considerably slow down the ball processing, should be made async ?
    % gproc:send({p, l, {epto_event, State#state.ontology}}, {received_ball, Ball}),
    UpdatedNextBall =
        maps:fold(
            fun
                (EvtId, #epto_event{ttl = EvtTtl, ts = EvtTs} = Evt, Acc) when
                    EvtTtl < State#state.ttl
                ->
                    NewAcc =
                        case maps:get(EvtId, Acc, undefined) of
                            undefined ->
                                maps:put(EvtId, Evt, Acc);
                            #epto_event{ttl = EvtBallTtl} = EvtBall when
                                EvtBallTtl < EvtTtl
                            ->
                                maps:put(EvtId, EvtBall#epto_event{ttl = EvtTtl}, Acc);
                            _ ->
                                Acc
                        end,
                    gen_server:call(State#state.logical_clock_pid, {update_clock, EvtTs}),
                    NewAcc;
                (_EvtId, #epto_event{ts = EvtTs}, Acc) ->
                    gen_server:call(State#state.logical_clock_pid, {update_clock, EvtTs}),
                    Acc
            end,
            State#state.next_ball,
            Ball
        ),
    {keep_state, State#state{next_ball = UpdatedNextBall}}.

%% Handle events common to all states.
handle_event({call, From}, get_count, Data) ->
    %% Reply with the current count
    {keep_state, Data, [{reply, From, Data}]};
handle_event(_, _, Data) ->
    %% Ignore all other events
    {keep_state, Data}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
-spec order_events(
    Ball :: map(),
    Delivered :: ordsets:ordset(term()),
    Received :: map(),
    LasteDeliveredTs :: integer(),
    LogicalClock :: pid(),
    CurrentIndex :: integer()
) ->
    {ordsets:ordset(term()), map(), integer(), integer()}.
order_events(Ball, Delivered, Received, LastDeliveredTs, LogicalClock, CurrentIndex) ->
    %% update TTL of received events
    TtlReceived =
        maps:map(
            fun(_EvtId, #epto_event{ttl = EvtTtl} = Evt) -> Evt#epto_event{ttl = EvtTtl + 1} end,
            Received
        ),

    %% update set of received events with events in the ball
    ReceivedPlusBallEvents =
        maps:fold(
            fun(
                BallEvtId,
                #epto_event{
                    id = BallEvtId,
                    ttl = BallEvtTtl,
                    ts = Ts
                } =
                    BallEvt,
                ReceivedEvts
            ) ->
                case ordsets:is_element(BallEvtId, Delivered) of
                    false when Ts >= LastDeliveredTs ->
                        case maps:get(BallEvtId, ReceivedEvts, undefined) of
                            undefined ->
                                maps:put(BallEvtId, BallEvt, ReceivedEvts);
                            #epto_event{ttl = ReceivedEvtTtl} = ReceivedEvt when
                                ReceivedEvtTtl < BallEvtTtl
                            ->
                                ReceivedEvts#{
                                    BallEvtId =>
                                        ReceivedEvt#epto_event{ttl = BallEvtTtl}
                                };
                            _ ->
                                ReceivedEvts
                        end;
                    _ ->
                        ReceivedEvts
                end
            end,
            TtlReceived,
            Ball
        ),

    %% collect deliverable events and determine smallest timestamp of non deliverable events
    InitialDeliverableEvents = [],
    MinQueueTs = infinity,

    {DeliverableEvents, UpdatedMinQueueTs} =
        maps:fold(
            fun(_EvtId, #epto_event{ts = EvtTs} = Evt, {DeliverableEvents, MQTs}) ->
                case gen_server:call(LogicalClock, {is_deliverable, Evt}) of
                    true ->
                        {[Evt | DeliverableEvents], MinQueueTs};
                    _ ->
                        case is_above(MQTs, EvtTs) of
                            true -> {DeliverableEvents, EvtTs};
                            _ -> {DeliverableEvents, MinQueueTs}
                        end
                end
            end,
            {InitialDeliverableEvents, MinQueueTs},
            ReceivedPlusBallEvents
        ),
    FilteredDeliverableEvent =
        lists:filter(
            fun
                (#epto_event{ts = Ts}) when Ts > UpdatedMinQueueTs ->
                    false;
                (_) ->
                    true
            end,
            DeliverableEvents
        ),
    FilteredReceivedEvents =
        lists:foldl(
            fun(#epto_event{id = DelivEvtId}, AccReceived) ->
                maps:remove(DelivEvtId, AccReceived)
            end,
            ReceivedPlusBallEvents,
            FilteredDeliverableEvent
        ),
    SortedDeliverableEvents = lists:keysort(3, FilteredDeliverableEvent),
    {NewDeliveredEvents, NewLastDeliveredTs, NewIndex} =
        lists:foldl(
            fun
                (
                    #epto_event{ts = EvtTs, id = EvtId} = Evt,
                    {AccDelivered, _AccLastDeliveredTs, TempIndex}
                ) ->
                    NewDelivered = ordsets:add_element(EvtId, AccDelivered),
                    NewLastDeliveredTs = EvtTs,
                    NewIndex = deliver(TempIndex, Evt),
                    {NewDelivered, NewLastDeliveredTs, NewIndex};
                (B, C) ->
                    logger:error("Unexpected Params :~p     ~p", [B, C])
            end,
            {Delivered, LastDeliveredTs, CurrentIndex},
            SortedDeliverableEvents
        ),
    {NewDeliveredEvents, FilteredReceivedEvents, NewLastDeliveredTs, NewIndex}.

is_above(infiny, _EvtTs) ->
    true;
is_above(MinQueueTs, EvtTs) when MinQueueTs > EvtTs ->
    true;
is_above(_MinQueueTs, _EvtTs) ->
    false.

deliver(Index, #epto_event{payload = #transaction{} = Transaction}) ->
    ?'log-info'("~p delivering transaction ~p ~nindex ~p", [?MODULE, Transaction, Index]),
    Timestamp = erlang:system_time(microsecond),
    prometheus_gauge:set(
        <<"bbsvx_transasction_delivering_time">>,
        [Transaction#transaction.namespace],
        Timestamp - Transaction#transaction.ts_created
    ),
    bbsvx_actor_ontology:receive_transaction(Transaction#transaction{
        index = Index,
        ts_delivered =
            Timestamp
    }),
    Index + 1;
deliver(Index, #epto_event{payload = #goal_result{} = GoalResult}) ->
    ?'log-info'("Received goal result ~p", [GoalResult]),
    bbsvx_actor_ontology:accept_transaction_result(GoalResult),
    Index;
deliver(Index, #epto_event{payload = <<"leader">>}) ->
    %% Get leader from leader manager
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(<<"bbsvx:root">>),
    {ok, F} = file:open("/logs/leader-" ++ atom_to_list(node()) ++ ".log", [append]),
    file:write(F, iolist_to_binary([Leader, <<"\n">>])),
    file:close(F),
    Index;
deliver(Index, Evt) when is_binary(Evt#epto_event.payload) ->
    {ok, F} = file:open("/logs/" ++ atom_to_list(node()) ++ ".log", [append]),
    file:write(F, iolist_to_binary(Evt#epto_event.payload)),
    file:close(F),
    Index.

%% Calculate adaptive TTL based on current outview size.
%% SPRAY maintains |outview| ≈ ln(N) connections, so we estimate N ≈ e^|outview|
%% EPTO formula: TTL >= 2 * ceil((c+1) * log2(N)) + 1
%% With c=1 (covers single failure scenarios)
-spec calculate_adaptive_ttl(Namespace :: binary()) -> integer().
calculate_adaptive_ttl(Namespace) ->
    OutViewSize = length(bbsvx_arc_registry:get_available_arcs(Namespace, out)),
    case OutViewSize of
        0 ->
            %% No connections yet, use minimum TTL
            ?MIN_TTL;
        Size ->
            %% Estimate N from view size: N ≈ e^|view|
            %% But SPRAY view size is actually closer to ln(N), so this is reasonable
            %% For safety, we add 1 to the view size before exponentiating
            EstimatedN = math:exp(Size),
            %% EPTO formula with c=1: TTL >= 2 * ceil(2 * log2(N)) + 1
            C = 1,
            RawTTL = 2 * ceil((C + 1) * math:log2(max(EstimatedN, 2))) + 1,
            %% Clamp to valid range
            TTL = max(?MIN_TTL, min(?MAX_TTL, round(RawTTL))),
            ?'log-debug'(
                "Adaptive TTL: outview_size=~p, estimated_n=~p, raw_ttl=~p, clamped_ttl=~p",
                [Size, round(EstimatedN), RawTTL, TTL]
            ),
            TTL
    end.

%% Update TTL in state and sync with logical clock if changed
-spec maybe_update_ttl(State :: #state{}) -> #state{}.
maybe_update_ttl(#state{round_count = RoundCount} = State)
  when RoundCount rem ?TTL_UPDATE_INTERVAL =/= 0 ->
    %% Not time to update yet
    State;
maybe_update_ttl(#state{namespace = Namespace, ttl = CurrentTTL, logical_clock_pid = LogicalClockPid} = State) ->
    NewTTL = calculate_adaptive_ttl(Namespace),
    case NewTTL of
        CurrentTTL ->
            %% No change needed
            State;
        _ ->
            ?'log-info'(
                "EPTO adaptive TTL update: ~p -> ~p (namespace=~p)",
                [CurrentTTL, NewTTL, Namespace]
            ),
            %% Update the logical clock's TTL threshold
            gen_server:call(LogicalClockPid, {set_ttl, NewTTL}),
            %% Update Prometheus metric for monitoring
            prometheus_gauge:set(<<"bbsvx_epto_ttl">>, [Namespace], NewTTL),
            State#state{ttl = NewTTL}
    end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

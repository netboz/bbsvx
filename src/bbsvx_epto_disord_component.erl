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
    last_delivered_ts = 0 :: integer()
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
        "Epto dissemination component starting ~p with options ~p",
        [Namespace, Options]
    ),
    gproc:reg({p, l, {epto_event, Namespace}}),

    {ok, RoundTimer} =
        timer:apply_interval(?DEFAULT_ROUND_TIME, gen_server, cast, [self(), next_round]),

    case maps:get(boot, Options, false) of
        root ->
            ?'log-info'("~p starting discord as root", [?MODULE]),
            {ok, running, #state{
                round_timer = RoundTimer,
                namespace = Namespace,
                logical_clock_pid = LogicalClock,
                fanout = Fanout,
                current_index = 0,
                delivered = ordsets:new(),
                ttl = Ttl,
                next_ball = #{}
            }};
        _ ->
            ?'log-info'("~p starting discord as non-root", [?MODULE]),
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
    {incoming_event, {epto_message, {receive_ball, Ball, CurrentIndex}}},
    #state{namespace = Namespace} = State
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
    {next_state, running, State#state{next_ball = UpdatedNextBall, current_index = CurrentIndex}};
syncing(
    info,
    {incoming_event, {receive_ball, Ball, CurrentIndex}},
    #state{namespace = Namespace} = State
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
    {next_state, running, State#state{next_ball = UpdatedNextBall, current_index = CurrentIndex}};
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
running({call, From}, empty_inview, State) ->
    gen_statem:reply(From, ok),
    {next_state, syncing, State};
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
        logical_clock_pid = LogicalClockPid
    } =
        State
) ->
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
        received = NewReceived,
        current_index = NewIndex,
        last_delivered_ts = NewLastDeliveredTs
    }};
running(
    info,
    {incoming_event, {epto_message, {receive_ball, Ball, _CurrentIndex}}},
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
    {keep_state, State#state{next_ball = UpdatedNextBall}};
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
    bbsvx_transaction_pipeline:receive_transaction(Transaction#transaction{
        index = Index,
        ts_delivered =
            Timestamp
    }),
    Index + 1;
deliver(Index, #epto_event{payload = #goal_result{} = GoalResult}) ->
    ?'log-info'("Received goal result ~p", [GoalResult]),
    bbsvx_transaction_pipeline:accept_transaction_result(GoalResult),
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

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_epto_ordering_component).

-author("yan").

-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/2]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-include("bbsvx_epto.hrl").

-define(SERVER, ?MODULE).

%% Loop state
-record(state,
        {namespace :: binary(),
         received = #{} :: map(),
         delivered = undefined :: term(),
         last_delivered_ts = 0 :: integer(),
         logical_clock :: pid()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), LogicalClockPid :: pid()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, LogicalClockPid) ->
    gen_server:start_link({via, gproc, {n, l, {?SERVER, Namespace}}},
                          ?MODULE,
                          [Namespace, LogicalClockPid],
                          []).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Namespace, LogicalClockPid]) ->
    State =
        #state{namespace = Namespace,
               delivered = ordsets:new(),
               logical_clock = LogicalClockPid},
    {ok, State}.

handle_call({order_events, Ball},
            _From,
            #state{delivered = Delivered,
                   received = Received,
                   last_delivered_ts = LastDeliveredTs} =
                State) ->
    %% update TTL of received events
    TtlReceived =
        maps:map(fun(_EvtId, #event{ttl = EvtTtl} = Evt) -> Evt#event{ttl = EvtTtl + 1} end,
                 Received),

    %% update set of received events with events in the ball
    ReceivedPlusBallEvents =
        maps:fold(fun(BallEvtId,
                      #event{id = BallEvtId,
                             ttl = BallEvtTtl,
                             ts = Ts} =
                          BallEvt,
                      ReceivedEvts) ->
                     case ordsets:is_element(BallEvtId, Delivered) of
                         false when Ts >= LastDeliveredTs ->
                             case maps:get(BallEvtId, ReceivedEvts, undefined) of
                                 #event{ttl = ReceivedEvtTtl} = ReceivedEvt
                                     when ReceivedEvtTtl < BallEvtTtl ->
                                     maps:put(BallEvtId,
                                              ReceivedEvt#event{ttl = BallEvtTtl},
                                              ReceivedEvts);
                                 undefined ->
                                     maps:put(BallEvtId, BallEvt, ReceivedEvts);
                                 _ ->
                                     ReceivedEvts
                             end;
                         _ ->
                             ReceivedEvts
                     end
                  end,
                  TtlReceived,
                  Ball),

    %% collect deliverable events and determine smallest timestamp of non deliverable events
    InitialDeliverableEvents = [],
    MinQueueTs = infinity,

    {DeliverableEvents, UpdatedMinQueueTs} =
        maps:fold(fun(_EvtId, #event{ts = EvtTs} = Evt, {DeliverableEvents, MQTs}) ->
                     case gen_server:call(State#state.logical_clock, {is_deliverable, Evt}) of
                         true ->
                             {[Evt | DeliverableEvents], MinQueueTs};
                         _ ->
                             case is_above(MQTs, EvtTs) of
                                 true ->
                                     {DeliverableEvents, EvtTs};
                                 _ ->
                                     {DeliverableEvents, MinQueueTs}
                             end
                     end
                  end,
                  {InitialDeliverableEvents, MinQueueTs},
                  ReceivedPlusBallEvents),

    FilteredDeliverableEvent =
        lists:filter(fun (#event{ts = Ts}) when Ts > UpdatedMinQueueTs ->
                             false;
                         (_) ->
                             true
                     end,
                     DeliverableEvents),

    FilteredReceivedEvents =
        lists:foldl(fun(#event{id = DelivEvtId}, AccReceived) ->
                       maps:remove(DelivEvtId, AccReceived)
                    end,
                    ReceivedPlusBallEvents,
                    FilteredDeliverableEvent),

    SortedDeliverableEvents = lists:keysort(3, FilteredDeliverableEvent),

    %logger:info("Sorted deilverable : ~p", [SortedDeliverableEvents]),
    {NewDeliveredEvents, NewLastDeliveredTs} =
        lists:foldl(fun (#event{ts = EvtTs, id = EvtId} = Evt,
                         {AccDelivered, _AccLastDeliveredTs}) ->
                            NewDelivered = ordsets:add_element(EvtId, AccDelivered),
                            NewLastDeliveredTs = EvtTs,
                            deliver(Evt),
                            {NewDelivered, NewLastDeliveredTs};
                        (B, C) ->
                            logger:error("Unexpected Params :~p     ~p", [B, C])
                    end,
                    {Delivered, LastDeliveredTs},
                    SortedDeliverableEvents),
    {reply,
     ok,
     State#state{last_delivered_ts = NewLastDeliveredTs,
                 delivered = NewDeliveredEvents,
                 received = FilteredReceivedEvents}};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

is_above(infiny, _EvtTs) ->
    true;
is_above(MinQueueTs, EvtTs) when MinQueueTs > EvtTs ->
    true;
is_above(_MinQueueTs, _EvtTs) ->
    false.

deliver(Evt) ->
    logger:info("Delivering ~p", [Evt]),
    {ok, F} = file:open("/logs/" ++ atom_to_list(node()) ++ ".log", [append]),
    file:write(F, iolist_to_binary(Evt#event.payload)),
    file:close(F),
    ok.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

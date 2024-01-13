%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_epto_dissemination_comp).

-author("yan").

-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/4, test/0, test_func/0]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_ROUND_TIME, 20).

-include("bbsvx_epto.hrl").

%% Loop state
-record(state,
        {round_timer :: term(),
         fanout :: integer(),
         ttl :: integer(),
         ontology :: binary(),
         next_ball :: map(),
         orderer :: pid(),
         logical_clock_pid :: pid()}).


%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Fanout :: integer(),
                 Ttl :: integer(),
                 Orderer :: pid(),
                 LogicalClock :: pid()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Fanout, Ttl, Orderer, LogicalClock) ->
    gen_server:start_link({via, gproc, {n, l, ?SERVER}},
                                   ?MODULE,
                                   [Fanout, Ttl, Orderer, LogicalClock],
                                   []).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Fanout, Ttl, Orderer, LogicalClock]) ->
    quickrand:seed(),
    State =
        #state{orderer = Orderer,
               logical_clock_pid = LogicalClock,
               fanout = Fanout,
               ttl = Ttl,
               next_ball = #{}},
    {ok, RoundTimer} =
        timer:apply_interval(?DEFAULT_ROUND_TIME,
                             gen_server,
                             call,
                             [self(), next_round]),
    logger:info("RoundTimer ~p", [RoundTimer]),

    {ok, State#state{round_timer = RoundTimer}}.

handle_call({epto_broadcast, Payload}, _From, #state{next_ball = NextBall} = State) ->
    logger:info("Broadcast ~p", [Payload]),
    EvtId = uuid:get_v4(),
    Event =
        #event{id = EvtId,
               ts = gen_server:call(State#state.logical_clock_pid, get_clock),
               ttl = 0,
               source_id = node(),
               payload = Payload},
    {reply, ok, State#state{next_ball = maps:put(EvtId, Event, NextBall)}};
handle_call(next_round, _From, #state{next_ball = NextBall} = State)
    when NextBall == #{} ->
    {reply, ok, State};
handle_call(next_round, _From, State) ->
    logger:info("Next round. Ball is ~p", [State#state.next_ball]),
    NewBall =
        maps:map(fun(_EvtId, #event{ttl = EvtTtl} = Evt) -> Evt#event{ttl = EvtTtl + 1} end,
                 State#state.next_ball),

    {ok, Peers} = partisan_peer_service:members(),
    SamplePeers = get_random_sample(State#state.fanout, Peers),
    logger:info("Sample peers ~p", [SamplePeers]),
    TargetProcesName = atom_to_binary(?MODULE),
    TargetProcess = <<"#Name", TargetProcesName/binary>>,
    logger:info("TagetProcess ~p", [TargetProcess]),
    [partisan:forward_message([Peer | TargetProcess], {receive_ball, NewBall})
     || Peer <- SamplePeers],
    gen_server:call(State#state.orderer, {order_events, NewBall}),
    {reply, ok, State#state{next_ball = #{}}};

handle_call({set_fanout_ttl, Fanout, Ttl}, _From, State) ->
    gen_server:call(State#state.logical_clock_pid, {set_ttl, Ttl}), 
    {reply, ok, State#state{fanout = Fanout, ttl = Ttl}};


handle_call(_Request, _From, State) ->
    logger:info("Unmanaged message ~p", [_Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    logger:info("Unmanaged cast message ~p", [_Msg]),
    {noreply, State}.

handle_info({receive_ball, Ball}, State) ->
    logger:info("Processs ~p Received ball", [partisan:self()]),

    %% QUESTION: next event could considerably slow down the ball processing, should be made async ?
    %% gproc:send({p, l, {epto_event, State#state.ontology}}, {received_ball, Ball}),

    UpdatedNextBall =
        maps:fold(fun (EvtId, #event{ttl = EvtTtl, ts = EvtTs} = Evt, Acc)
                          when EvtTtl < State#state.ttl ->
                          NewAcc =
                              case maps:get(EvtId, Acc, undefined) of
                                  undefined ->
                                      maps:put(EvtId, Evt, Acc);
                                  #event{ttl = EvtBallTtl} = EvtBall when EvtBallTtl < EvtTtl ->
                                      maps:put(EvtId, EvtBall#event{ttl = EvtTtl}, Acc);
                                  _ ->
                                      Acc
                              end,
                          gen_server:call(State#state.logical_clock_pid,
                                                   {update_clock, EvtTs}),
                          NewAcc;
                      (_EvtId, #event{ts = EvtTs}, Acc) ->
                          gen_server:call(State#state.logical_clock_pid,
                                                   {update_clock, EvtTs}),
                          Acc
                  end,
                  State#state.next_ball,
                  Ball),
    logger:info("New Ball ~p", [UpdatedNextBall]),
    {noreply, State#state{next_ball = UpdatedNextBall}};
handle_info(_Info, State) ->
    logger:info("Unmanaged info message ~p", [_Info]),

    {noreply, State}.

terminate(_Reason, State) ->
    timer:cancel(State#state.round_timer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
get_random_sample(Num, Peers) ->
    get_random_sample(Num, Peers, []).

get_random_sample(0, _Peers, Acc) ->
    Acc;
get_random_sample(_N, [], Acc) ->
    %% No more peers in list
    Acc;
get_random_sample(N, Peers, Acc) ->
    L = length(Peers),
    Index = quickrand:strong_uniform(L) - 1,
    {A, [Selected | B]} = lists:split(Index, Peers),
    get_random_sample(N - 1, A ++ B, Acc ++ [Selected]).

test() ->
    timer:apply_interval(4000,
                         ?MODULE,
                         test_func,
                         []).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================
test_func() ->
    case rand:uniform(3) of 
        1 ->
            Node = lists:flatten(io_lib:format("~p",[node()])),
            Index = lists:flatten(io_lib:format("~p",[time()])),
            gen_server:call(?MODULE, {epto_broadcast,  iolist_to_binary([Index, <<"-MSG-">>, Node, <<"\n">>])});
        _ ->
            ok
    end.
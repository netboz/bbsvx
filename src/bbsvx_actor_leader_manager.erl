%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% Leader election over overlayed network
%%% cf : https://pure.tudelft.nl/ws/portalfiles/portal/69222795/main.pdf
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_leader_manager).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/2, stop/0, get_leader/1]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3]).

-record(state,
        {namespace :: binary(),
         diameter :: integer(),
         delta_c :: integer(),
         delta_e :: integer(),
         delta_d :: integer(),
         my_id :: binary(),
         leader :: binary(),
         neighbors :: neighbors()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), Options :: map()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, Options) ->
    gen_statem:start_link({via, gproc, {n, l, {leader_manager, Namespace}}},
                     ?MODULE,
                     [Namespace, Options],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

-spec get_leader(binary()) -> {ok, binary()}.
get_leader(Namespace) ->
    gen_statem:call({via, gproc, {n, l, {leader_manager, Namespace}}}, get_leader).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    Diameter = maps:get(diameter, Options, 8),
    DeltaC = maps:get(delta_c, Options, 50),
    DeltaE = maps:get(delta_e, Options, 100),
    DeltaD = maps:get(delta_d, Options, 200),

    T = erlang:system_time(millisecond),
    MyId = bbsvx_crypto_service:my_id(),
    Leader = MyId,
    PublicKey = bbsvx_crypto_service:get_public_key(),
    Ts = T,
    SignedTs = bbsvx_crypto_service:sign(term_to_binary(Ts)),
    State =
        #state{namespace = Namespace,
               diameter = Diameter,
               delta_c = DeltaC,
               delta_e = DeltaE,
               delta_d = DeltaD,
               my_id = MyId,
               neighbors = [],
               leader = Leader},

    Payload =
        #neighbor{node_id = MyId,
                  public_key = PublicKey,
                  signed_ts = SignedTs,
                  ts = Ts},

    %% Resgister to receive leader election info
    gproc:reg({p, l, {leader_election, Namespace}}),

    %% Send election info to neighborhood
    bbsvx_actor_spray_view:broadcast_unique(Namespace,
                                            #leader_election_info{payload = Payload}),

    DeltaR = DeltaE + DeltaD,
    Passed = T div DeltaR,
    Delta = DeltaC + (Passed + 1) * DeltaR - T,

    erlang:send_after(Delta, self(), next_round),
    {ok, running, State}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    state_functions.

%%%=============================================================================
%%% State transitions
%%%=============================================================================
-spec running(gen_statem:event_type(), atom(), state()) -> {next_state, atom(), state()}.
running(info,
        next_round,
        #state{namespace = Namespace,
               my_id = MyId,
               neighbors = Neighbors,
               delta_c = DeltaC,
               delta_d = DeltaD,
               diameter = D,
               delta_e = DeltaE} =
            State) ->
    M = 2 * D, % M = 2D + k − 1 with k = 1
    DeltaR = DeltaE + DeltaD,
    T = erlang:system_time(millisecond),
    ValidNeighbors = get_valid_entries(Neighbors, T, DeltaC, DeltaR, M),
    {Vote, Ts, SignedTs} =
        case ValidNeighbors of
            [] ->
                %% No valid neighbors
                {MyId, T, bbsvx_crypto_service:sign(term_to_binary(T))};
            _ ->
                %% We have valid neighbors
                %% Pick 3 random, neighbors from valid neighbors
                RandomNeighbors = pick_three_random(Neighbors),
                %% chosen Leader is the most referenced leader among the 3 random neighbors
                FollowedNeigbor = get_most_referenced_leader(RandomNeighbors),
        
                %% Get neighbour entry with the highest Ts
                Tsf = lists:foldl(fun (#neighbor{ts = Tsi}, Acc) when Tsi > Acc ->
                                          Tsi;
                                      (#neighbor{ts = _Tsi}, Acc) ->
                                          Acc
                                  end,
                                  0,
                                  ValidNeighbors),
                {FollowedNeigbor#neighbor.chosen_leader,
                 Tsf,
                 bbsvx_crypto_service:sign(term_to_binary(Tsf))}
        end,
    {FinalTs, SignedFinalTs} =
        case Vote of
            MyId ->
                {T, bbsvx_crypto_service:sign(term_to_binary(T))};
            _ ->
                {Ts, SignedTs}
        end,
    PublicKey = bbsvx_crypto_service:get_public_key(),
    Payload =
        #neighbor{node_id = MyId,
                  public_key = PublicKey,
                  signed_ts = SignedFinalTs,
                  ts = FinalTs,
                  chosen_leader = Vote},
    %% Publish payload to Outview
    bbsvx_actor_spray_view:broadcast_unique(Namespace,
                                            #leader_election_info{payload = Payload}),
    Me = self(),
    %% Set timer to DeltaR for next round
    erlang:send_after(DeltaR, Me, next_round),
    {next_state, running, State#state{leader = Vote}};
running(info,
        {incoming_event, #leader_election_info{payload = Payload}},
        #state{neighbors = Neighbors} = State) ->
  
    {keep_state,
     State#state{neighbors =
                     lists:keystore(Payload#neighbor.node_id,
                                    #neighbor.node_id,
                                    Neighbors,
                                    Payload)}};
running({call, From}, get_leader, #state{leader = Leader}) ->
    {keep_state_and_data, [{reply, From, {ok, Leader}}]};
running(EventType, EventContent, Data) ->
    ?'log-warning'("Leader manager received an unmanaged event ~p ~p ~p",
                [EventType, EventContent, Data]),
    keep_state_and_data.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% @doc
%% Get the valid entries from the neighbors list.
%% meaning only entries for witch the Ts does not differ by more than
%% DeltaC + M*DeltaR time units from T.
%% @end

-spec get_valid_entries(neighbors(), integer(), integer(), integer(), integer()) ->
                           neighbors().
get_valid_entries(Neigh, T, DeltaC, DeltaR, M) ->
    lists:filter(fun(#neighbor{ts = Ts}) -> abs(T - Ts) < DeltaC + M * DeltaR end, Neigh).

%%-----------------------------------------------------------------------------
%% @doc
%% Pick 3 random entries from the given list, duplicate some entries if the list
%% is too short.
%% @end

-spec pick_three_random(neighbors()) -> neighbors().
pick_three_random([]) ->
    [];
pick_three_random(Neighbors) when length(Neighbors) < 3 ->
    pick_three_random(Neighbors
                      ++ [lists:nth(
                              rand:uniform(length(Neighbors)), Neighbors)]);
pick_three_random(Neigh) ->
    %% Randomize list of neigbours
    Randomized = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- Neigh])],
    lists:sublist(Randomized, 3).

%%-----------------------------------------------------------------------------
%% @doc
%% Get the most referenced leader from the given list.
%% @end

-spec get_most_referenced_leader(neighbors()) -> neighbor() | none.
get_most_referenced_leader([#neighbor{chosen_leader = A} = NA,
                            #neighbor{chosen_leader = B},
                            #neighbor{chosen_leader = _C}])
    when A == B ->
    NA;
get_most_referenced_leader([#neighbor{chosen_leader = A} = NA,
                            #neighbor{chosen_leader = _B},
                            #neighbor{chosen_leader = C}])
    when A == C ->
    NA;
get_most_referenced_leader([#neighbor{chosen_leader = _A},
                            #neighbor{chosen_leader = B} = NB,
                            #neighbor{chosen_leader = C}])
    when B == C ->
    NB;
get_most_referenced_leader([#neighbor{} = A, #neighbor{} = B, #neighbor{} = C]) ->
    ?'log-warning'("Leader manager : get_most_referenced_leader failed A:~p ~n "
                   " B:~p ~n C:~p",
                   [A#neighbor.node_id, B#neighbor.node_id, C#neighbor.node_id]),
    none.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

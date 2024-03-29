%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_ontoloy).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_common_types.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/0, stop/0, example_action/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([ready/3]).

-record(state, {namespace :: binary, ont_state :: #est{}}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link() ->
    gen_statem:start({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

-spec example_action() -> term().
example_action() ->
    gen_statem:call(?SERVER, example_action).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([]) ->
    State = example_state,
    Data = data,
    {ok, State, Data}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    state_functions.

%%%=============================================================================
%%% State transitions
%%%=============================================================================

%% Agent is in ready state and receive call to prove a goal
ready({call, From}, {prove_goal, #goal{} = Goal}, State) ->
    logger:info("Ontology Agent for namespace : ~p received goal to prove :~p",
                [State#state.namespace, Goal]),
    {Result, NewState} = prove_goal(Goal, State),
    {keep_state, State#state{ont_state = NewState}, [{reply, From, Result}]};
%% Catch all for ready state
ready(Type, Event, _state) ->
    logger:info("Ontology Agent received unmanaged call :~p", [{Type, Event}]),
    keep_state_and_data.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
prove_goal(#goal{payload = Payload}, _State) when is_binary(Payload)->
    %% Parse the payload
    ok;

prove_goal(#goal{payload = Payload}, State) ->
    erlog:prove(Payload, {erlog, [], State#state.ont_state}).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

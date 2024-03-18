%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_goal_processor).
-author("yan").
-behaviour(gen_statem).
-include("bbsvx_common_types.hrl").
%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([
    start_link/1,
    stop/0
]).

%% Gen State Machine Callbacks
-export([
    init/1,
    code_change/4,
    callback_mode/0,
    terminate/3
]).

%% State transitions
-export([
    example_state/3,
    next_example_state/3,
    handle_event/3
]).

-record(state, {   }).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Goal :: goal()) -> {ok, pid()} | {error, {already_started, pid()}} | {error, Reason::any()}.
start_link(Goal) ->
    gen_statem:start({local, ?SERVER}, ?MODULE, [Goal], []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).	

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([#goal{} = Goal]) ->
    Data = data, 
    {ok, parsing, Data}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok,State,Data}.
    
callback_mode() -> 
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

example_state({call,From}, example_action, Data) ->
    {next_state, next_example_state, Data, [{reply,From,next_example_state}]};
example_state(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

next_example_state({call,From}, example_action, Data) ->
    {next_state, example_state, Data, [{reply,From,example_state}]};
next_example_state(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%-----------------------------------------------------------------------------
%% @doc
%% Handle events common to all states.
%% @end
%%-----------------------------------------------------------------------------
handle_event({call,From}, get_count, Data) ->
    %% Reply with the current count
    {keep_state,Data,[{reply,From,Data}]};
handle_event(_, _, Data) ->
    %% Ignore all other events
    {keep_state,Data}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.
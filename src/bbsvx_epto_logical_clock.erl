%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_epto_logical_clock).

-author("yan").

-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/2]).
%% Callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%% Loop state
-record(state, {namespace :: binary(), logical_clock = 0 :: integer(), ttl :: integer()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), Ttl :: integer()) -> gen_server:start_ret().
start_link(Namespace, Ttl) ->
    gen_server:start_link(
        {via, gproc, {n, l, {?MODULE, Namespace}}},
        ?MODULE,
        [Namespace, Ttl],
        []
    ).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Namespace, Ttl]) ->
    State = #state{namespace = Namespace, ttl = Ttl},
    {ok, State}.

-spec handle_call(Request :: term(), From :: gen_server:from(), State :: state()) ->
    {reply, Reply :: term(), State :: state()}
    | {noreply, State :: state()}
    | {stop, Reason :: term(), Reply :: term(), State :: state()}.
handle_call({set_ttl, Ttl}, _From, State) when is_number(Ttl) ->
    {reply, ok, State#state{ttl = Ttl}};
handle_call({is_deliverable, #epto_event{ttl = Ttl}}, _From, State) ->
    Reply = Ttl > State#state.ttl,
    ?'log-info'(
        "Logical clock: Is deliverable Event TTs : ~p State TTl :~p",
        [Ttl, State#state.ttl]
    ),
    {reply, Reply, State};
handle_call(get_clock, _From, State) ->
    NewClock = State#state.logical_clock + 1,
    {reply, NewClock, State};
handle_call({update_clock, Ts}, _From, State) when is_number(Ts) ->
    case Ts > State#state.logical_clock of
        true ->
            {reply, ok, State#state{logical_clock = Ts}};
        _ ->
            {reply, ok, State}
    end;
handle_call(Request, _From, State) ->
    ?'log-warning'("Logical clock: Unknown request ~p", [Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(Msg, State) ->
    ?'log-warning'("Logical clock: Unknown cast ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?'log-warning'("Logical clock: Unknown info ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

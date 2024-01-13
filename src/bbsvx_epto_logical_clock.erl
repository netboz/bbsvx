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
-export([start_link/1]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-include("bbsvx_epto.hrl").

%% Loop state
-record(state, {logical_clock = 0 :: integer(), ttl :: integer()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Ttl :: integer()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Ttl) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Ttl], []).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Ttl]) ->

    State = #state{ttl = Ttl},
    {ok, State}.

handle_call({set_ttl, Ttl}, _From, State) ->
    {reply, ok, State#state{ttl = Ttl}};

handle_call({is_deliverable, Event}, _From, State) ->
    Reply = Event#event.ttl > State#state.ttl,
    {reply, Reply, State};
handle_call(get_clock, _From, State) ->
    NewClock = State#state.logical_clock + 1,
    {reply, NewClock, State};
handle_call({update_clock, Ts}, _From, State) ->
    case Ts > State#state.logical_clock of
        true ->
            {reply, ok, State#state{logical_clock = Ts}};
        _ ->
            {reply, ok, State}
    end;
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

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

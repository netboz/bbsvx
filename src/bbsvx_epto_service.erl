%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_epto_service).

-author("yan").

-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/2, broadcast/2]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% Loop state
-record(state, {namespace :: binary()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), Options :: map()) -> gen_server:start_ret().
start_link(Namespace, Options) ->
    gen_server:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, Options],
                          []).

-spec broadcast(binary(), term()) -> ok.
broadcast(Namespace, Msg) ->
    gen_server:call({via, gproc, {n, l, {bbsvx_epto_disord_component, Namespace}}},
                    {epto_broadcast, Msg}).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Namespace, _Options]) ->
    {ok,
     #state{namespace = Namespace}}.

handle_call(Msg, From, State) ->
    logger:warning("Node : ~p  Dissemination component got unmanaged call : ~p", [From, Msg]),
    {reply, ok, State}.

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

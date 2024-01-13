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
-export([start_link/2]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

%% Loop state
-record(state, {
    broadcaster :: pid(),
    orderer :: pid(),
    logical_clock :: pid(),
    fanout :: integer(),
    ttl :: integer()
}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Fanout :: integer(), Ttl :: integer()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Fanout, Ttl) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Fanout, Ttl], []).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Fanout, Ttl]) ->
    State = #state{fanout = Fanout, ttl = Ttl},
    {ok, LogicalClock} = bbsvx_epto_logical_clock:start_link(Ttl),
    {ok, Orderer} = bbsvx_epto_ordering_component:start_link(LogicalClock),

    {ok, Broadcaster} = bbsvx_epto_dissemination_comp:start_link(Fanout, Ttl, Orderer, LogicalClock),
    {ok, State#state{broadcaster = Broadcaster, logical_clock = LogicalClock, orderer = Orderer}}.

handle_call({set_fanout_tll, Fanout, Ttl}, _From, State) ->
    Reply = gen_server:call(State#state.broadcaster, {set_fanout_ttl, Fanout, Ttl}),
    {reply, Reply, State#state{fanout = Fanout, ttl = Ttl}};

handle_call({get_fanout_tll, Fanout, Ttl}, _From, State) ->
        Reply = {ok, State#state.fanout, State#state.ttl},
        {reply, Reply, State#state{fanout = Fanout, ttl = Ttl}};

handle_call(Msg, From, State) ->
    logger:warning("Node : ~p  Dissemination component got unmanaged call : ~p",[From, Msg]),
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

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_crypto_service).
-author("yan").
-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/0, my_id/0]).

%% Callbacks
-export([
    init/1, 
    handle_call/3, 
    handle_cast/2, 
    handle_info/2,
    terminate/2, 
    code_change/3
]).

-define(SERVER, ?MODULE).

%% Loop state
-record(state, {
    privkey :: binary(),
    pubkey :: binary(),
    id :: binary()
}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> {ok, pid()} | {error, {already_started, pid()}} | {error, Reason::any()}.
start_link() ->
    gen_server:start_link({via, gproc, {n, l, ?MODULE}}, ?MODULE, [], []).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% my_id() -> binary().
%%% Returns the id of this node.
%%% At this moent, it is the public key stored into the state of the gen_server
%%% @end
%%%-----------------------------------------------------------------------------

-spec my_id() -> binary().
my_id() ->
    case gproc:where({n, l, ?MODULE}) of
        undefined -> 
            logger:error("Crypto service not started"),
            undefined;
        P ->
            gen_server:call(P, my_id)
    end.

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([]) ->
    logger:info("Starting crypto service"),
    %% Create a private ets table to store the data loaded from DETS
    {PubKey, PrivKey} = crypto:generate_key(eddsa, ed25519),
    logger:info("Generated keys ~p ~p", [PubKey, PrivKey]),
    {ok, #state{privkey = PrivKey, pubkey = PubKey, id = base64:encode(PubKey, #{padding => false, mode => urlsafe})}}.

handle_call(my_id, _From, State) ->
    {reply, State#state.id, State};

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

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.
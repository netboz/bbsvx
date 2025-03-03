%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_crypto_service).

-author("yan").

-behaviour(gen_server).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").


%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/0, my_id/0, sign/1, get_public_key/0, calculate_hash_address/2]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {privkey :: binary(), pubkey :: binary(), node_id :: binary()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> gen_server:start_ret().
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
    gen_server:call({via, gproc, {n, l, ?MODULE}}, my_id).

-spec sign(binary()) -> binary().
sign(Data) ->
    gen_server:call({via, gproc, {n, l, ?MODULE}}, {sign, Data}).

-spec get_public_key() -> binary().
get_public_key() ->
    gen_server:call({via, gproc, {n, l, ?MODULE}}, get_public_key).

calculate_hash_address(Index,
                       #transaction{ts_created = TsCreated,
                                    source_ontology_id = SourceOntologyId,
                                    prev_address = PrevAddress,
                                    prev_hash = PrevHash,
                                    namespace = Namespace,
                                    leader = Leader,
                                    payload = Payload}) ->
    crypto:hash(blake2b,
                term_to_binary({Index,
                                TsCreated,
                                SourceOntologyId,
                                PrevAddress,
                                PrevHash,
                                Namespace,
                                Leader,
                                Payload})).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([]) ->
    ?'log-info'("Starting crypto service"),
    %% Create a private ets table to store the data loaded from DETS
    {PubKey, PrivKey} = crypto:generate_key(eddsa, ed25519),
    {ok,
     #state{privkey = PrivKey,
            pubkey = PubKey,
            node_id = base64:encode(PubKey, #{padding => false, mode => urlsafe})}}.

handle_call(my_id, _From, State) ->
    {reply, State#state.node_id, State};
handle_call({sign, Data}, _From, #state{pubkey = PubKey, privkey = PrivKey} = State) ->
    Signature = public_key:sign(Data, none, {ed_pri, ed25519, PubKey, PrivKey}, []),
    {reply, Signature, State};
handle_call(get_public_key, _From, State) ->
    {reply, State#state.pubkey, State};
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

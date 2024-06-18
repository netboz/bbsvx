%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_ontology).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/1, start_link/2, stop/0, prove/2]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([ready/3, initialize_ontology/3, syncing/3]).

-record(state,
        {namespace :: binary(),
         ont_state :: ont_state(),
         repos_table :: atom(),
         current_address :: binary() | undefined,
         next_address :: binary() | undefined,
         db_mod :: atom(),
         db_ref :: term(),
         my_id :: binary() | undefined,
         current_goal :: tuple() | undefined}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace) ->
    gen_statem:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, #{}],
                          []).

-spec start_link(Namespace :: binary(), Options :: map()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, Options) ->
    gen_statem:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, Options],
                          []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

prove(Goal, Namespace) ->
    case gproc:where({n, l, {?MODULE, Namespace}}) of
        undefined ->
            {error, not_started};
        Pid ->
            gen_statem:call(Pid, {prove_goal, Goal})
    end.

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    case bbsvx_ont_service:table_exists(Namespace) of
        false ->
            {error, {no_table, Namespace}};
        true ->
            MyId = bbsvx_crypto_service:my_id(),
            DbRepos = bbsvx_ont_service:binary_to_table_name(Namespace),
            {DbMod, DbRef} =
                maps:get(db_mod,
                         Options,
                         {bbsvx_erlog_db_ets, bbsvx_ont_service:binary_to_table_name(Namespace)}),
            {ok, #est{} = PrologState} = erlog_int:new(bbsvx_erlog_db_differ, {DbRef, DbMod}),

            OntState =
                #ont_state{namespace = Namespace,
                           current_address = <<"0">>,
                           next_address = <<"0">>,
                           prolog_state = PrologState},

            gproc:send({p, l, {?MODULE, Namespace}}, {initialisation, Namespace}),
            {ok,
             initialize_ontology,
             #state{namespace = Namespace,
                    repos_table = DbRepos,
                    db_mod = DbMod,
                    db_ref = DbRef,
                    ont_state = OntState,
                    my_id = MyId}}
    end.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

initialize_ontology(enter,
                    _,
                    #state{namespace = Namespace,
                           ont_state = #ont_state{prolog_state = PrologState} = OntState} =
                        State) ->
    gproc:reg({p, l, {?MODULE, Namespace}}),

    {NewCurrentAddress, NewDb} =
        load_history(OntState#ont_state.prolog_state#est.db, State#state.repos_table),
    {ok, _Pid} =
        supervisor:start_child({via, gproc, {n, l, {bbsvx_sup_shared_ontology, Namespace}}},
                               #{id => {bbsvx_transaction_pipeline, Namespace},
                                 start =>
                                     {bbsvx_transaction_pipeline,
                                      start_link,
                                      [Namespace, OntState, #{}]},
                                 restart => transient,
                                 shutdown => 1000,
                                 type => worker,
                                 modules => [bbsvx_transaction_pipeline]}),
    gproc:send({p, l, {?MODULE, Namespace}}, {syncing, Namespace}),

    {keep_state,
     State#state{ont_state = OntState#ont_state{prolog_state = PrologState#est{db = NewDb}},
                 current_address = NewCurrentAddress}};
initialize_ontology(info, {syncing, _}, State) ->
    {next_state, syncing, State}.

%% @TODO : crypto: diff needs to be signed
syncing(enter, _, #state{namespace = _Namespace} = State) ->
    {keep_state, State};
syncing(info, #ontology_history{list_tx = ListTransactions}, #state{} = State) ->
    lists:foreach(fun(#transaction{} = Transaction) ->
                     bbsvx_transaction_pipeline:accept_transaction(Transaction)
                  end,
                  ListTransactions),
    {next_state, syncing, State}.

%% Catch all for ready state
ready(Type, Event, _State) ->
    logger:info("Ontology Agent received unmanaged call :~p", [{Type, Event}]),
    keep_state_and_data.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-spec request_segment(binary(), binary(), binary()) -> {ok, integer()}.
request_segment(Namespace, OldestTx, YoungerTx) ->
    bbsvx_actor_spray_view:broadcast_unique_random_subset(Namespace,
                                                          #ontology_history_request{namespace =
                                                                                        Namespace,
                                                                                    oldest_tx =
                                                                                        OldestTx,
                                                                                    younger_tx =
                                                                                        YoungerTx},
                                                          1).

-spec load_history(db(), atom()) -> {binary(), db()}.
load_history(OntState, ReposTable) ->
    FrstTransationKey = mnesia:dirty_first(ReposTable),
    do_load_history(FrstTransationKey, OntState, <<"0">>, ReposTable).

-spec do_load_history(term(), db(), binary(), atom()) -> {binary(), db()}.
do_load_history('$end_of_table', #db{} = OntDb, CurrentAddress, _ReposTable) ->
    {CurrentAddress, OntDb};
do_load_history(Key, #db{} = OntDb, _CurrentAddress, ReposTable) ->
    %% @TODO : Current Adrress should match the transaction previous address field
    TransacEntry = bbsvx_transaction:read_transaction(ReposTable, Key),
    {ok, NewOntDb} = bbsvx_erlog_db_differ:apply_diff(TransacEntry#transaction.diff, OntDb),
    NextKey = mnesia:next(ReposTable, Key),
    do_load_history(NextKey, NewOntDb, TransacEntry#transaction.current_address, ReposTable).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

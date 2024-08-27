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

-include_lib("logjam/include/logjam.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/1, start_link/2, stop/0, request_segment/3, get_current_index/1]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([ready/3, initialize_ontology/3, wait_for_registration/3, syncing/3]).

-record(state,
        {namespace :: binary(),
         ont_state :: ont_state(),
         repos_table :: atom(),
         boot :: term(),
         db_mod :: atom(),
         db_ref :: term(),
         my_id :: binary() | undefined}).

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

-spec get_current_index(Namespace :: binary()) -> {ok, integer()}.
get_current_index(Namespace) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, get_current_index).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

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
            Boot = maps:get(boot, Options, root),
            OntState =
                #ont_state{namespace = Namespace,
                           current_address = <<"0">>,
                           next_address = <<"0">>,
                           prolog_state = PrologState},
            ?'log-info'("Ontology Agent ~p starting with boot ~p", [Namespace, Boot]),
            gproc:send({p, l, {?MODULE, Namespace}}, {initialisation, Namespace}),
            {ok,
             initialize_ontology,
             #state{namespace = Namespace,
                    repos_table = DbRepos,
                    boot = Boot,
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
                           ont_state = OntState,
                           boot = Boot} =
                        State)
    when Boot == root orelse Boot == {join, []} ->
    gproc:reg({p, l, {?MODULE, Namespace}}),
    ?'log-info'("Ontology Agent ~p booting  ontology as root", [Namespace]),
    %% For now we consider booting allowed to have history
    NewOntState = load_history(OntState, State#state.repos_table),
    ?'log-info'("Ontology Agent ~p loaded history ~p",
                [Namespace, NewOntState#ont_state.current_index]),

    %% Register to events from pipeline
    gproc:reg({p, l, {bbsvx_transaction_pipeline, Namespace}}),

    gproc:send({p, l, {?MODULE, Namespace}}, {syncing, Namespace}),
    {keep_state, State#state{ont_state = NewOntState, boot = root}};
initialize_ontology(enter,
                    _,
                    #state{namespace = Namespace,
                           boot = {join, _ContactNodes},
                           ont_state = #ont_state{} = OntState} =
                        State) ->
    gproc:reg({p, l, {?MODULE, Namespace}}),
    ?'log-info'("Ontology Agent ~p booting joined ontology", [Namespace]),
    NewOntState = load_history(OntState, State#state.repos_table),
    ?'log-info'("Ontology Agent ~p loaded history ~p",
                [Namespace, NewOntState#ont_state.current_index]),

    %% Register to events from pipeline
    gproc:reg({p, l, {bbsvx_transaction_pipeline, Namespace}}),

    gproc:send({p, l, {?MODULE, Namespace}}, {wait_current_index, Namespace}),

    {keep_state, State#state{ont_state = NewOntState}};
initialize_ontology(info, {registered, _CurrentIndex}, State) ->
    %% Postpone the event
    {keep_state, State, [{pospone, true}]};
initialize_ontology(info,
                    {syncing, _},
                    #state{boot = root,
                           ont_state = OntState,
                           namespace = Namespace} =
                        State) ->
    ?'log-info'("Setting current index to local index: ~p", [OntState#ont_state.local_index]),
    {ok, _Pid} =
        supervisor:start_child({via, gproc, {n, l, {bbsvx_sup_shared_ontology, Namespace}}},
                               #{id => {bbsvx_transaction_pipeline, Namespace},
                                 start =>
                                     {bbsvx_transaction_pipeline,
                                      start_link,
                                      [Namespace,
                                       OntState#ont_state{current_index =
                                                              OntState#ont_state.local_index},
                                       #{}]},
                                 restart => transient,
                                 shutdown => 1000,
                                 type => worker,
                                 modules => [bbsvx_transaction_pipeline]}),
    {next_state, syncing, State};
initialize_ontology(info, {wait_current_index, _}, #state{boot = {join, _}} = State) ->
    {next_state, wait_for_registration, State}.

wait_for_registration(enter, _, State) ->
    {keep_state, State};
wait_for_registration(info,
                      {registered, CurrentIndex},
                      #state{namespace = Namespace,
                             ont_state = #ont_state{local_index = LocalIndex} = OntState} =
                          State) ->
    ?'log-info'("Actor ~p received registration ~p", [Namespace, CurrentIndex]),
    {ok, _Pid} =
        supervisor:start_child({via, gproc, {n, l, {bbsvx_sup_shared_ontology, Namespace}}},
                               #{id => {bbsvx_transaction_pipeline, Namespace},
                                 start =>
                                     {bbsvx_transaction_pipeline,
                                      start_link,
                                      [Namespace,
                                       OntState#ont_state{current_index = CurrentIndex},
                                       #{}]},
                                 restart => transient,
                                 shutdown => 1000,
                                 type => worker,
                                 modules => [bbsvx_transaction_pipeline]}),
    bbsvx_actor_ontology:request_segment(Namespace, LocalIndex + 1, CurrentIndex),

    {next_state,
     syncing,
     State#state{ont_state = OntState#ont_state{current_index = CurrentIndex}}}.

%% @TODO : crypto: diff needs to be signed
syncing(enter, _, #state{namespace = _Namespace} = State) ->
    {keep_state, State};
syncing({call, From},
        get_current_index,
        #state{ont_state = #ont_state{current_index = Index}} = State) ->
    gen_statem:reply(From, {ok, Index}),
    {keep_state, State};
syncing(info,
        #ontology_history_request{namespace = Namespace,
                                  requester = #node_entry{pid = RequesterPid},
                                  oldest_index = OldestIndex,
                                  younger_index = YoungerIndex},
        #state{} = State) ->
    %% @TODO : May some checks should be done to see if we indeed
    %% have segment and forward request if needed
    History = retrieve_transaction_history(Namespace, OldestIndex, YoungerIndex),
    YoungerIndexRetrieved =
        case History of
            [] ->
                OldestIndex;
            _ ->
                Y = lists:last(History),
                Y#transaction.index
        end,
    OldestIndexRetrieved =
        case History of
            [] ->
                YoungerIndex;
            [O | _] ->
                O#transaction.index
        end,

    bbsvx_server_connection:send_history(RequesterPid,
                                         #ontology_history{list_tx = History,
                                                           oldest_index = OldestIndexRetrieved,
                                                           younger_index = YoungerIndexRetrieved}),
    {next_state, syncing, State};
syncing(info, {transaction_validated, Index}, #state{ont_state = OntState} = State) ->
    {keep_state, State#state{ont_state = OntState#ont_state{current_index = Index}}};
syncing(info, #ontology_history{list_tx = ListTransactions}, #state{} = State) ->
    logger:info("Received transactions history : ~p", [ListTransactions]),
    lists:foreach(fun(#transaction{} = Transaction) ->
                     bbsvx_transaction_pipeline:receive_transaction(Transaction)
                  end,
                  ListTransactions),
    {next_state, syncing, State}.

%% Catch all for ready state
ready(Type, Event, _State) ->
    ?'log-warning'("Ontology Agent received invalid call :~p", [{Type, Event}]),
    keep_state_and_data.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-spec request_segment(binary(), binary(), binary()) -> {ok, integer()}.
request_segment(Namespace, OldestIndex, YoungerIndex) ->
    ?'log-info'("Requesting segment ~p ~p ~p", [Namespace, OldestIndex, YoungerIndex]),
    MyId = bbsvx_crypto_service:my_id(),
    {ok, {Host, Port}} = bbsvx_network_service:my_host_port(),
    bbsvx_actor_spray_view:broadcast_unique_random_subset(Namespace,
                                                          #ontology_history_request{namespace =
                                                                                        Namespace,
                                                                                    requester =
                                                                                        #node_entry{host
                                                                                                        =
                                                                                                        Host,
                                                                                                    port
                                                                                                        =
                                                                                                        Port,
                                                                                                    node_id
                                                                                                        =
                                                                                                        MyId},
                                                                                    oldest_index =
                                                                                        OldestIndex,
                                                                                    younger_index =
                                                                                        YoungerIndex},
                                                          1).

-spec load_history(ont_state(), atom()) -> {binary(), db()}.
load_history(OntState, ReposTable) ->
    FrstTransationKey = mnesia:dirty_first(ReposTable),
    do_load_history(FrstTransationKey, OntState, ReposTable).

-spec do_load_history(term(), ont_state(), atom()) -> {binary(), db()}.
do_load_history('$end_of_table', #ont_state{} = OntState, _ReposTable) ->
    OntState;
do_load_history(Key, #ont_state{prolog_state = PrologState} = OntState, ReposTable) ->
    OntDb = PrologState#est.db,
    %% @TODO : Current Adrress should match the transaction previous address field
    TransacEntry = bbsvx_transaction:read_transaction(ReposTable, Key),
    {ok, #db{ref = Ref} = NewOntDb} =
        bbsvx_erlog_db_differ:apply_diff(TransacEntry#transaction.diff, OntDb),
    NextKey = mnesia:dirty_next(ReposTable, Key),
    %% @TODO : The way op_fifo is resetted is not good and coud be done by using
    %% standard erlog state instead of differ
    do_load_history(NextKey,
                    OntState#ont_state{prolog_state =
                                           PrologState#est{db =
                                                               NewOntDb#db{ref =
                                                                               Ref#db_differ{op_fifo
                                                                                                 =
                                                                                                 []}}},
                                       current_address = TransacEntry#transaction.current_address,
                                       local_index = TransacEntry#transaction.index},
                    ReposTable).

retrieve_transaction_history(Namespace, OldestIndex, YoungerIndex) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    SelectFun =
        ets:fun2ms(fun(#transaction{index = Index} = Transaction)
                      when Index >= OldestIndex, Index =< YoungerIndex ->
                      Transaction
                   end),
    ?'log-info'("Selecting history ~p ~p ~p", [Namespace, OldestIndex, YoungerIndex]),
    HistResult = mnesia:dirty_select(TableName, SelectFun),
    ?'log-info'("History ~p", [HistResult]),
    lists:sort(fun(#transaction{index = A}, #transaction{index = B}) -> A =< B end,
               HistResult).

    %%%=============================================================================

%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

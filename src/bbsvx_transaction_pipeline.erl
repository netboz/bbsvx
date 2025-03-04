%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_transaction_pipeline).

-author("yan").

-behaviour(gen_server).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/3, accept_transaction/1, accept_transaction_result/1,
         receive_transaction/1]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% Loop state
-record(state, {namespace :: binary()}).
-record(transaction_validate_stage_state,
        {namespace :: binary(),
         previous_ts :: number() | undefined,
         current_ts :: number(),
         current_index :: integer(),
         local_index :: integer(),
         current_address :: binary(),
         pending = #{} :: map()}).

-type transaction_validate_stage_state() :: #transaction_validate_stage_state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), OntState :: ont_state(), Options :: map()) ->
                    gen_server:start_ret().
start_link(Namespace, OntState, Options) ->
    gen_server:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, OntState, Options],
                          []).

%%%=============================================================================
%%% @doc This function is the entry point to start processing a transaction.
%%%
%%% @end
%%%=============================================================================

-spec accept_transaction(transaction()) -> ok.
accept_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:enqueue({stage_transaction_accept, Namespace}, Transaction).

-spec receive_transaction(transaction()) -> ok.
receive_transaction(#transaction{namespace = Namespace} = Transaction) ->
    ?'log-info'("Received Transaction entry point, validating ~p", [Transaction]),
    jobs:enqueue({stage_transaction_validate, Namespace}, Transaction).

-spec accept_history_transaction(transaction()) -> ok.
accept_history_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:enqueue({stage_transaction_history, Namespace}, Transaction).

-spec accept_transaction_result(goal_result()) -> ok.
accept_transaction_result(#goal_result{namespace = Namespace} = GoalResult) ->
    jobs:enqueue({stage_transaction_results, Namespace}, GoalResult).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Namespace,
      #ont_state{current_address = CurrentAddress,
                 local_index = LocalIndex,
                 current_index = CurrentIndex,
                 current_ts = CurrentTs} =
          OntState,
      _Options]) ->
    ?'log-info'("Starting transaction pipeline for ~p current index:~p  local_index:~p",
                [Namespace, CurrentIndex, LocalIndex]),
    %% @TOOD: jobs offers many options, we may use them to simplify
    ok = jobs:add_queue({stage_transaction_validate, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_process, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_postprocess, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_results, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_accept, Namespace}, [passive]),

    spawn_link(fun() ->
                  transaction_validate_stage(Namespace,
                                             #transaction_validate_stage_state{current_address =
                                                                                   CurrentAddress,
                                                                               namespace =
                                                                                   Namespace,
                                                                               current_index =
                                                                                   CurrentIndex,
                                                                               local_index =
                                                                                   LocalIndex,
                                                                               current_ts =
                                                                                   CurrentTs})
               end),
    spawn_link(fun() -> transaction_process_stage(Namespace, OntState) end),
    spawn_link(fun() -> transaction_postprocess_stage(Namespace, OntState) end),
    spawn_link(fun() -> transaction_accept_process(Namespace) end),
    {ok, #state{namespace = Namespace}}.

handle_call(_, _From, LoopState) ->
    {reply, ok, LoopState}.

handle_cast(_Msg, LoopState) ->
    {noreply, LoopState}.

handle_info(_Info, LoopState) ->
    {noreply, LoopState}.

terminate(_Reason, _LoopState) ->
    ok.

code_change(_OldVsn, LoopState, _Extra) ->
    {ok, LoopState}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
-spec transaction_accept_process(Namespace :: binary()) -> no_return().
transaction_accept_process(Namespace) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_accept, Namespace}, 1),
    ?'log-info'("Received Transaction, accepting ~p", [Transaction]),
    bbsvx_epto_service:broadcast(Namespace,
                                 Transaction#transaction{status = accepted,
                                                         ts_created = erlang:system_time()}),
    transaction_accept_process(Namespace).

-spec transaction_validate_stage(binary(), transaction_validate_stage_state()) ->
                                    no_return().
transaction_validate_stage(Namespace, ValidationState) ->
    ?'log-info'("Waiting for transaction ~p", [self()]),
    [{_, Transaction}] = jobs:dequeue({stage_transaction_validate, Namespace}, 1),
    ?'log-info'("Received Transaction, validating ~p", [Transaction]),
    case transaction_validate(Transaction, ValidationState) of
        {stop, #transaction_validate_stage_state{} = NewValidationState} ->
            transaction_validate_stage(Namespace, NewValidationState);
        {ValidatedTransaction, #transaction_validate_stage_state{} = NewOntState} ->
            jobs:enqueue({stage_transaction_process, Namespace}, ValidatedTransaction),
            case maps:get(NewOntState#transaction_validate_stage_state.current_index,
                          NewOntState#transaction_validate_stage_state.pending,
                          not_found)
            of
                {PendingTransaction, NewPending} ->
                    jobs:enqueue(stage_transaction_validate, PendingTransaction),
                    transaction_validate_stage(Namespace,
                                               NewOntState#transaction_validate_stage_state{pending
                                                                                                =
                                                                                                NewPending});
                _ ->
                    transaction_validate_stage(Namespace, NewOntState)
            end
    end.

-spec transaction_process_stage(binary(), ont_state()) -> no_return().
transaction_process_stage(Namespace, OntState) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_process, Namespace}, 1),
    ?'log-info'("Received Transaction, processing ~p", [Transaction]),
    {ProcessedTransaction, NewOntState} = process_transaction(Transaction, OntState),
    jobs:enqueue({stage_transaction_postprocess, Namespace}, ProcessedTransaction),
    transaction_process_stage(Namespace, NewOntState).

-spec transaction_postprocess_stage(binary(), ont_state()) -> no_return().
transaction_postprocess_stage(Namespace, OntState) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_postprocess, Namespace}, 1),
    ?'log-info'("Received Transaction, postprocessing ~p", [Transaction]),
    bbsvx_transaction:record_transaction(Transaction#transaction{status = processed}),
    Time = erlang:system_time(microsecond),
    prometheus_gauge:set(<<"bbsvx_transction_processing_time">>,
                         [Transaction#transaction.namespace],
                         Time - Transaction#transaction.ts_delivered),
    prometheus_gauge:set(<<"bbsvx_transction_total_validation_time">>,
                         [Transaction#transaction.namespace],
                         Time - Transaction#transaction.ts_created),
    transaction_postprocess_stage(Namespace, OntState).

%% Procesing functions
-spec transaction_validate(transaction(), transaction_validate_stage_state()) ->
                              {transaction(), transaction_validate_stage_state()} |
                              {stop, transaction_validate_stage_state()}.
transaction_validate(#transaction{index = TxIndex,
                                  current_address = CurrentTxAddress,
                                  status = processed} =
                         Transaction,
                     #transaction_validate_stage_state{local_index = LocalIndex} = ValidationSt)
    when TxIndex == LocalIndex + 1 ->
    %% This transaction comes from history and have been processed already by the leader
    %% we check it is valid and store it
    ?'log-info'("Accepting history transaction ~p, storing it", [Transaction]),
    %% @TODO: veriy validation of transaction
    bbsvx_transaction:record_transaction(Transaction),
    {stop,
     ValidationSt#transaction_validate_stage_state{local_index = TxIndex,
                                                   current_address = CurrentTxAddress}};
%% History Transaction is not ready to be processed, we store it for later
transaction_validate(#transaction{status = processed} = Transaction,
                     #transaction_validate_stage_state{local_index = LocalIndex,
                                                       current_index = CurrentIndex,
                                                       pending = Pending} =
                         ValidationState) ->
    ?'log-info'("Storing history transaction for later ~p   Current Index : "
                "~p    Local index ~p",
                [Transaction, CurrentIndex, LocalIndex]),
    NewPending = maps:put(Transaction#transaction.index, Transaction, Pending),
    {stop, ValidationState#transaction_validate_stage_state{pending = NewPending}};
transaction_validate(#transaction{ts_created = TsCreated, status = created} = Transaction,
                     #transaction_validate_stage_state{namespace = Namespace,
                                                       current_address = CurrentAddress,
                                                       current_index = CurrentIndex,
                                                       current_ts = CurrentTs} =
                         ValidationState) ->
    NewIndex = CurrentIndex + 1,
    NewTransaction =
        Transaction#transaction{status = created,
                                index = NewIndex,
                                prev_address = CurrentAddress},
    bbsvx_transaction:record_transaction(NewTransaction),
    gproc:send({n, l, {bbsvx_actor_ontology, Namespace}}, {transaction_validated, NewIndex}),
    NewCurrentAddress = bbsvx_crypto_service:calculate_hash_address(NewIndex, Transaction),
    ?'log-info'("new address ~p", [NewCurrentAddress]),
    {NewTransaction,
     ValidationState#transaction_validate_stage_state{current_address = NewCurrentAddress,
                                                      current_index = NewIndex,
                                                      local_index = NewIndex,
                                                      previous_ts = CurrentTs,
                                                      current_ts = TsCreated}};
%% Not index ready to process current transaction, we store it for later
transaction_validate(#transaction{} = Transaction,
                     #transaction_validate_stage_state{namespace = Namespace,
                                                       pending = Pending,
                                                       local_index = LocalIndex,
                                                       current_index = CurrentIndex} =
                         ValidationState) ->
    ?'log-info'("Storing transaction for later ~p   Current Index : ~p    Local "
                "index ~p",
                [Transaction, CurrentIndex, LocalIndex]),
    %% @TODO: Check if transaction is already in pending
    NewPending = maps:put(Transaction#transaction.index, Transaction, Pending),
    bbsvx_actor_ontology:request_segment(Namespace, LocalIndex + 1, CurrentIndex),
    {stop, ValidationState#transaction_validate_stage_state{pending = NewPending}}.

-spec process_transaction(transaction(), ont_state()) -> {transaction(), ont_state()}.
    %% Compute transcaton address

process_transaction(#transaction{type = creation,
                                 payload =
                                     #transaction_payload_init_ontology{namespace = Namespace,
                                                                        contact_nodes =
                                                                            _ContactNodes},
                                 namespace = Namespace} =
                        Transaction,
                    OntState) ->
    {Transaction, OntState};
process_transaction(#transaction{type = goal,
                                 payload = #goal{} = Goal,
                                 namespace = Namespace} =
                        Transaction,
                    OntState) ->
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    MyId = bbsvx_crypto_service:my_id(),
    ?'log-info'("Is leader ~p", [Leader == MyId]),
    case do_prove_goal(Goal, OntState, MyId == Leader) of
        {_FailOrSucceed, #ont_state{} = NewOntState} ->
            ?'log-info'("Recording transaction ~p", [Transaction]),
            #est{db = #db{ref = #db_differ{op_fifo = OpFifo} = DbDiffer} = Db} =
                PrologState = NewOntState#ont_state.prolog_state,
            NewTransaction =
                Transaction#transaction{status = processed,
                                        ts_processed = erlang:system_time(),
                                        diff = OpFifo},
            bbsvx_transaction:record_transaction(NewTransaction),
            {NewTransaction,
             NewOntState#ont_state{prolog_state =
                                       PrologState#est{db =
                                                           Db#db{ref =
                                                                     DbDiffer#db_differ{op_fifo =
                                                                                            []}}}}};
        {error, Reason} ->
            %% @TODO: Manage errors
            logger:error("Error processing goal ~p: ~p", [Goal, Reason]),
            {Transaction, OntState}
    end.

-spec do_prove_goal(goal(), ont_state(), boolean()) ->
                       {succeed, ont_state()} | {fail, ont_state()} | {error, any()}.
do_prove_goal(#goal{namespace = Namespace, payload = ReceivedPred} = Goal,
              #ont_state{namespace = Namespace, prolog_state = PrologState} = OntState,
              true) ->
    ?'log-info'("Proving goal ~p as Leader", [ReceivedPred]),
    %% @TODO : Predicate validating should done in validation stage in a more robust way
    case erlog_int:prove_goal(ReceivedPred, PrologState) of
        {succeed, #est{db = #db{ref = #db_differ{op_fifo = OpFifo}}} = NewPrologState} ->
            GoalResult =
                %% @TODO : Add signature
                #goal_result{namespace = Namespace,
                             result = succeed,
                             signature = <<>>,
                             address = Goal#goal.id,
                             diff = OpFifo},
            bbsvx_epto_service:broadcast(Namespace, GoalResult),
            {succeed, OntState#ont_state{prolog_state = NewPrologState}};
        {fail, NewPrologState} ->
            %% @TODO : Add signature
            GoalResult =
                #goal_result{namespace = Namespace,
                             result = fail,
                             signature = <<>>,
                             address = Goal#goal.id,
                             diff = []},
            bbsvx_epto_service:broadcast(Namespace, GoalResult),
            {fail, OntState#ont_state{prolog_state = NewPrologState}};
        Other ->
            logger:error("Unknown result from erlog_int:prove_goal ~p", [Other]),
            %% @TODO : Add signature
            GoalResult =
                #goal_result{namespace = Namespace,
                             result = error,
                             signature = <<>>,
                             address = Goal#goal.id,
                             diff = []},
            bbsvx_actor_spray:broadcast_unique(Namespace, GoalResult),
            {error, Other}
    end;
do_prove_goal(Goal, #ont_state{prolog_state = PrologState} = OntState, false) ->
    ?'log-info'("Proving goal ~p as Follower", [Goal]),
    [{_, GoalResult}] =
        jobs:dequeue({stage_transaction_results, OntState#ont_state.namespace}, 1),
    ?'log-info'("Received goal result ~p", [GoalResult]),
    %% Get current leader
    case GoalResult of
        #goal_result{diff = GoalDiff, result = Result} ->
            {ok, NewDb} =
                bbsvx_erlog_db_differ:apply_diff(GoalDiff, OntState#ont_state.prolog_state#est.db),
            {Result, OntState#ont_state{prolog_state = PrologState#est{db = NewDb}}};
        Else ->
            logger:error("Unknown message ~p", [Else]),
            {fail, OntState}
    end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

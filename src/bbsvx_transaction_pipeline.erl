%%%-----------------------------------------------------------------------------
%%% BBSvx Transaction Pipeline
%%%-----------------------------------------------------------------------------

-module(bbsvx_transaction_pipeline).

-moduledoc """
# BBSvx Transaction Pipeline

A gen_server that orchestrates the complete transaction processing pipeline for the BBSvx blockchain-powered BBS system.

## Overview

The transaction pipeline implements a multi-stage processing system that handles:

1. **Transaction Acceptance** - Initial reception and broadcasting of transactions
2. **Transaction Validation** - Ordering, indexing, and validation against blockchain state  
3. **Transaction Processing** - Execution of goals through the Prolog knowledge base
4. **Post-processing** - Recording final results and metrics collection

## Architecture

The pipeline uses the `jobs` application to create separate queues for each processing stage:

- `stage_transaction_accept` - Accepts and broadcasts new transactions
- `stage_transaction_validate` - Validates transaction order and readiness
- `stage_transaction_process` - Executes transaction goals via Prolog
- `stage_transaction_postprocess` - Records results and updates metrics
- `stage_transaction_results` - Handles goal execution results from leaders

Each stage runs in a separate spawned process linked to the main gen_server for fault tolerance.

## Transaction Flow

```
accept_transaction/1 → Accept Queue → EPTO Broadcast
                                           ↓
receive_transaction/1 → Validate Queue → Process Queue → Postprocess Queue
                                                              ↓
                                                    Record & Metrics
```

## Leader vs Follower Behavior

- **Leaders**: Execute goals directly through the Prolog engine and broadcast results
- **Followers**: Wait for goal results from leaders and apply diffs to their state

## State Management

The pipeline maintains blockchain state including:
- Current transaction index and address
- Local index for processed transactions  
- Pending transactions awaiting proper ordering
- Integration with the ontology service for knowledge base updates
""".

-author("yan").

-behaviour(gen_server).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([
    start_link/3,
    accept_transaction/1,
    accept_transaction_result/1,
    receive_transaction/1
]).

%% Callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%%%=============================================================================
%%% State Records and Types
%%%=============================================================================

-doc """
Main gen_server state record.

Simple state containing only the namespace this pipeline instance handles.
The actual transaction processing state is maintained separately in worker processes.
""".
-record(state, {namespace :: binary()}).
-record(transaction_validate_stage_state, {
    namespace :: binary(),
    previous_ts :: number() | undefined,
    current_ts :: number(),
    current_index :: integer(),
    local_index :: integer(),
    current_address :: binary(),
    pending = #{} :: map()
}).

-type transaction_validate_stage_state() :: #transaction_validate_stage_state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-doc """
Starts the transaction pipeline gen_server for a specific namespace.

The server is registered with gproc using the pattern `{bbsvx_transaction_pipeline, Namespace}`
to allow unique pipeline processes per namespace.

## Parameters

- `Namespace` - Binary namespace identifier for the ontology
- `OntState` - Current ontology state containing blockchain indices and addresses
- `Options` - Configuration map (currently unused)

## Returns

Standard gen_server start result (`{ok, Pid}` | `{error, Reason}`)

## Side Effects

- Creates job queues for all transaction processing stages
- Spawns linked worker processes for each stage
- Registers the process with gproc for namespace-based lookup
""".
-spec start_link(Namespace :: binary(), OntState :: ont_state(), Options :: map()) ->
    gen_server:start_ret().
start_link(Namespace, OntState, Options) ->
    gen_server:start_link(
        {via, gproc, {n, l, {?MODULE, Namespace}}},
        ?MODULE,
        [Namespace, OntState, Options],
        []
    ).

%%%=============================================================================
%%% Transaction Entry Points
%%%=============================================================================

-doc """
Entry point for locally created transactions that need to be broadcast to the network.

This is the starting point for new transactions originating from this node. The transaction
is queued for acceptance processing where it will be broadcast via EPTO to all network peers.

## Parameters

- `Transaction` - A transaction record with status `created`

## Flow

1. Extracts namespace from transaction
2. Enqueues transaction in the accept stage queue
3. Accept stage worker broadcasts transaction via EPTO
4. Returns immediately without waiting for processing
""".
-spec accept_transaction(transaction()) -> ok.
accept_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:enqueue({stage_transaction_accept, Namespace}, Transaction).

-doc """
Entry point for transactions received from the network via EPTO broadcast.

This handles transactions that have been broadcast by other nodes and delivered through
the EPTO consensus protocol. These transactions enter the validation stage to be ordered
and processed according to the blockchain's sequential requirements.

## Parameters  

- `Transaction` - A transaction record received from network peers

## Flow

1. Logs the received transaction for debugging
2. Enqueues transaction in the validation stage queue  
3. Validation stage orders transactions by index before processing
4. Returns immediately without waiting for validation
""".
-spec receive_transaction(transaction()) -> ok.
receive_transaction(#transaction{namespace = Namespace} = Transaction) ->
    ?'log-info'("Received Transaction entry point, validating ~p", [Transaction]),
    jobs:enqueue({stage_transaction_validate, Namespace}, Transaction).

-doc """
Entry point for historical transactions during blockchain synchronization.

Used when catching up with the blockchain state by processing previously committed
transactions. These transactions have already been processed by the network and
have a status of `processed`.

## Parameters

- `Transaction` - A pre-processed transaction from blockchain history

## Note

This function is currently not exported and may be used for future synchronization features.
""".
-spec accept_history_transaction(transaction()) -> ok.
accept_history_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:enqueue({stage_transaction_history, Namespace}, Transaction).

-doc """  
Entry point for goal execution results broadcast by leader nodes.

When a leader node executes a goal (Prolog query), it broadcasts the result to all followers.
This function receives those results and queues them for follower nodes to apply the
resulting state changes.

## Parameters

- `GoalResult` - Result of goal execution including success/failure and state diffs

## Flow

1. Extracts namespace from goal result
2. Enqueues result in the transaction results queue
3. Follower processing applies the result diff to local state
4. Returns immediately without waiting for application
""".
-spec accept_transaction_result(goal_result()) -> ok.
accept_transaction_result(#goal_result{namespace = Namespace} = GoalResult) ->
    jobs:enqueue({stage_transaction_results, Namespace}, GoalResult).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([
    Namespace,
    #ont_state{
        local_index = LocalIndex,
        current_index = CurrentIndex,
        current_ts = CurrentTs,
        current_address = CurrentAddress
    } =
        OntState,
    _Options
]) ->
    ?'log-info'(
        "Starting transaction pipeline for ~p current index:~p  local_index:~p",
        [Namespace, CurrentIndex, LocalIndex]
    ),
    %% @TODO: jobs offers many options, we may use them to simplify
    ok = jobs:add_queue({stage_transaction_validate, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_process, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_postprocess, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_results, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_accept, Namespace}, [passive]),

    spawn_link(fun() ->
        transaction_validate_stage(
            Namespace,
            #transaction_validate_stage_state{
                current_address = CurrentAddress,
                namespace =
                    Namespace,
                current_index =
                    CurrentIndex,
                local_index =
                    LocalIndex,
                current_ts =
                    CurrentTs
            }
        )
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

terminate(_Reason, #state{namespace = Namespace}) ->
    jobs:delete_queue({stage_transaction_validate, Namespace}),
    jobs:delete_queue({stage_transaction_process, Namespace}),
    jobs:delete_queue({stage_transaction_postprocess, Namespace}),
    jobs:delete_queue({stage_transaction_results, Namespace}),
    jobs:delete_queue({stage_transaction_accept, Namespace}),
    ok.

code_change(_OldVsn, LoopState, _Extra) ->
    {ok, LoopState}.

%%%=============================================================================
%%% Internal Processing Functions
%%%=============================================================================

-doc """
Worker process that handles transaction acceptance and broadcasting.

This is a linked worker process that runs in an infinite loop, dequeuing transactions
from the accept stage and broadcasting them to the network via EPTO. Each transaction
gets a timestamp and status update before broadcast.

## Parameters

- `Namespace` - The namespace this worker processes transactions for

## Behavior

1. Blocks waiting for transactions in the accept queue
2. Updates transaction status to `accepted` and adds creation timestamp  
3. Broadcasts transaction via EPTO to all network peers
4. Loops indefinitely until the parent process terminates

## Notes

- This function never returns (`no_return()`)
- Process crashes will be caught by the supervisor and restarted
- EPTO ensures reliable delivery to all connected network peers
""".
-spec transaction_accept_process(Namespace :: binary()) -> no_return().
transaction_accept_process(Namespace) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_accept, Namespace}, 1),
    ?'log-info'("Received Transaction, accepting ~p", [Transaction]),
    bbsvx_epto_service:broadcast(
        Namespace,
        Transaction#transaction{
            status = accepted,
            ts_created = erlang:system_time()
        }
    ),
    transaction_accept_process(Namespace).

-doc """
Worker process that handles transaction validation and ordering.

This worker ensures transactions are processed in the correct blockchain order by validating
indices and managing pending transactions. It handles both new transactions and historical
transactions during synchronization.

## Parameters

- `Namespace` - The namespace this worker processes transactions for
- `ValidationState` - Current blockchain state including indices and pending transactions

## Behavior

1. Dequeues transaction from validation stage
2. Validates transaction readiness based on blockchain index
3. Either processes immediately or stores in pending map
4. Handles pending transaction queue when gaps are filled
5. Forwards validated transactions to processing stage

## Transaction States Handled

- **Ready transactions**: Index matches expected sequence, process immediately  
- **Future transactions**: Index too high, store in pending map
- **History transactions**: Pre-processed transactions from blockchain sync

## Notes

- This function never returns (`no_return()`)
- Maintains strict ordering to preserve blockchain integrity
- Requests missing transaction segments when gaps detected
""".
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
            case
                maps:get(
                    NewOntState#transaction_validate_stage_state.current_index,
                    NewOntState#transaction_validate_stage_state.pending,
                    not_found
                )
            of
                {PendingTransaction, NewPending} ->
                    jobs:enqueue(stage_transaction_validate, PendingTransaction),
                    transaction_validate_stage(
                        Namespace,
                        NewOntState#transaction_validate_stage_state{
                            pending =
                                NewPending
                        }
                    );
                _ ->
                    transaction_validate_stage(Namespace, NewOntState)
            end
    end.

-doc """
Worker process that executes validated transactions.

This worker handles the actual execution of transactions, primarily goal-based transactions
that query or modify the Prolog knowledge base. It coordinates leader/follower behavior
for distributed consensus.

## Parameters

- `Namespace` - The namespace this worker processes transactions for  
- `OntState` - Current ontology state with Prolog database

## Behavior

1. Dequeues validated transaction from process stage
2. Executes transaction based on type (creation, goal, etc.)
3. Updates ontology state with execution results
4. Forwards processed transaction to postprocess stage
5. Continues with updated state

## Transaction Types

- **Creation transactions**: Initialize new ontologies
- **Goal transactions**: Execute Prolog queries with leader/follower coordination

## Notes

- Leaders execute goals directly and broadcast results
- Followers wait for results from leaders via the results queue
- State changes are applied through database diffs for consistency
""".
-spec transaction_process_stage(binary(), ont_state()) -> no_return().
transaction_process_stage(Namespace, OntState) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_process, Namespace}, 1),
    ?'log-info'("Received Transaction, processing ~p", [Transaction]),
    {ProcessedTransaction, NewOntState} = process_transaction(Transaction, OntState),
    jobs:enqueue({stage_transaction_postprocess, Namespace}, ProcessedTransaction),
    transaction_process_stage(Namespace, NewOntState).

-doc """
Worker process that handles final transaction recording and metrics collection.

This is the final stage of transaction processing that records the completed transaction
to storage, notifies interested parties, and updates performance metrics.

## Parameters

- `Namespace` - The namespace this worker processes transactions for
- `OntState` - Current ontology state (passed through unchanged)

## Behavior

1. Dequeues processed transaction from postprocess stage  
2. Records final transaction state to persistent storage
3. Sends notification to processes listening for transaction completion
4. Updates Prometheus metrics for processing times
5. Continues processing next transaction

## Metrics Updated

- `bbsvx_transction_processing_time` - Time from delivery to completion
- `bbsvx_transction_total_validation_time` - Total time from creation to completion

## Notifications

Sends `{transaction_processed, Transaction}` message to processes subscribed to
`{diff, Namespace}` via gproc for real-time transaction monitoring.
""".
-spec transaction_postprocess_stage(binary(), ont_state()) -> no_return().
transaction_postprocess_stage(Namespace, OntState) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_postprocess, Namespace}, 1),
    ?'log-info'("Received Transaction, postprocessing ~p", [Transaction]),
    bbsvx_transaction:record_transaction(Transaction#transaction{status = processed}),
    gproc:send({p, l, {diff, Namespace}}, {transaction_processed, Transaction}),
    Time = erlang:system_time(microsecond),
    prometheus_gauge:set(
        <<"bbsvx_transction_processing_time">>,
        [Transaction#transaction.namespace],
        Time - Transaction#transaction.ts_delivered
    ),
    prometheus_gauge:set(
        <<"bbsvx_transction_total_validation_time">>,
        [Transaction#transaction.namespace],
        Time - Transaction#transaction.ts_created
    ),
    transaction_postprocess_stage(Namespace, OntState).

%%%=============================================================================
%%% Core Processing Functions  
%%%=============================================================================

-doc """
Validates a transaction against the current blockchain state and ordering requirements.

This function implements the core transaction validation logic that ensures blockchain
integrity by maintaining proper transaction ordering and handling various transaction
states during network synchronization.

## Parameters

- `Transaction` - The transaction to validate
- `ValidationState` - Current validation state with indices and pending transactions

## Returns

- `{Transaction, NewValidationState}` - Transaction ready for processing
- `{stop, NewValidationState}` - Transaction stored for later, validation continues

## Validation Logic

1. **History transactions** (`status = processed`): 
   - Ready when `index = local_index + 1`
   - Stored in pending map if not ready
   
2. **New transactions** (`status = created`):
   - Assigned next available index
   - Previous address and blockchain hash calculated
   
3. **Out-of-order transactions**:
   - Stored in pending map keyed by index
   - Triggers segment request for missing transactions

## State Updates

- Updates `local_index` when transactions are processed in order
- Maintains `pending` map for future transactions
- Calculates new blockchain addresses using cryptographic hashing
""".
-spec transaction_validate(transaction(), transaction_validate_stage_state()) ->
    {transaction(), transaction_validate_stage_state()}
    | {stop, transaction_validate_stage_state()}.
transaction_validate(
    #transaction{
        index = TxIndex,
        current_address = CurrentTxAddress,
        status = processed
    } =
        Transaction,
    #transaction_validate_stage_state{local_index = LocalIndex} = ValidationSt
) when
    TxIndex == LocalIndex + 1
->
    %% This transaction comes from history and have been processed already by the leader
    %% we check it is valid and store it
    ?'log-info'("Accepting history transaction ~p, storing it", [Transaction]),
    %% TODO: veriy validation of transaction
    bbsvx_transaction:record_transaction(Transaction),
    {stop, ValidationSt#transaction_validate_stage_state{
        local_index = TxIndex,
        current_address = CurrentTxAddress
    }};
%% History Transaction is not ready to be processed, we store it for later
transaction_validate(
    #transaction{status = processed} = Transaction,
    #transaction_validate_stage_state{
        local_index = LocalIndex,
        current_index = CurrentIndex,
        pending = Pending
    } =
        ValidationState
) ->
    ?'log-info'(
        "Storing history transaction for later ~p   Current Index : "
        "~p    Local index ~p",
        [Transaction, CurrentIndex, LocalIndex]
    ),
    NewPending = maps:put(Transaction#transaction.index, Transaction, Pending),
    {stop, ValidationState#transaction_validate_stage_state{pending = NewPending}};
transaction_validate(
    #transaction{ts_created = TsCreated, status = created} = Transaction,
    #transaction_validate_stage_state{
        namespace = Namespace,
        current_address = CurrentAddress,
        current_index = CurrentIndex,
        current_ts = CurrentTs
    } =
        ValidationState
) ->
    NewIndex = CurrentIndex + 1,
    NewTransaction =
        Transaction#transaction{
            status = created,
            index = NewIndex,
            prev_address = CurrentAddress
        },
    bbsvx_transaction:record_transaction(NewTransaction),
    gproc:send({n, l, {bbsvx_actor_ontology, Namespace}}, {transaction_validated, NewIndex}),
    NewCurrentAddress = bbsvx_crypto_service:calculate_hash_address(NewIndex, Transaction),
    ?'log-info'("new address ~p", [NewCurrentAddress]),
    {NewTransaction, ValidationState#transaction_validate_stage_state{
        current_address = NewCurrentAddress,
        current_index = NewIndex,
        local_index = NewIndex,
        previous_ts = CurrentTs,
        current_ts = TsCreated
    }};
%% Not index ready to process current transaction, we store it for later
transaction_validate(
    #transaction{} = Transaction,
    #transaction_validate_stage_state{
        namespace = Namespace,
        pending = Pending,
        local_index = LocalIndex,
        current_index = CurrentIndex
    } =
        ValidationState
) ->
    ?'log-info'(
        "Storing transaction for later ~p   Current Index : ~p    Local "
        "index ~p",
        [Transaction, CurrentIndex, LocalIndex]
    ),
    %% TODO: Check if transaction is already in pending
    NewPending = maps:put(Transaction#transaction.index, Transaction, Pending),
    bbsvx_actor_ontology:request_segment(Namespace, LocalIndex + 1, CurrentIndex),
    {stop, ValidationState#transaction_validate_stage_state{pending = NewPending}}.

-doc """
Processes a validated transaction by executing its payload against the ontology state.

This function handles the core transaction execution, dispatching to appropriate handlers
based on transaction type and coordinating leader/follower consensus for goal execution.

## Parameters

- `Transaction` - Validated transaction ready for execution
- `OntState` - Current ontology state with Prolog database

## Returns

`{ProcessedTransaction, NewOntState}` - Updated transaction and state

## Transaction Types

1. **Creation transactions**: Initialize new ontologies with contact nodes
2. **Goal transactions**: Execute Prolog queries with distributed consensus

## Goal Processing

- **Leaders**: Execute goals directly via `erlog_int:prove_goal/2`  
- **Followers**: Wait for results from leaders and apply diffs
- **Results**: Broadcast via EPTO for network-wide consistency

## State Management

- Updates Prolog database state with execution results
- Clears operation FIFO after recording diffs
- Maintains blockchain integrity through hash-linked addresses
""".
-spec process_transaction(transaction(), ont_state()) -> {transaction(), ont_state()}.

process_transaction(
    #transaction{
        type = creation,
        payload =
            #transaction_payload_init_ontology{
                namespace = Namespace,
                contact_nodes =
                    _ContactNodes
            },
        namespace = Namespace
    } =
        Transaction,
    OntState
) ->
    {Transaction, OntState};
process_transaction(
    #transaction{
        type = goal,
        payload = #goal{} = Goal,
        namespace = Namespace
    } =
        Transaction,
    OntState
) ->
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    MyId = bbsvx_crypto_service:my_id(),
    ?'log-info'("Is leader ~p", [Leader == MyId]),
    case do_prove_goal(Goal, OntState, MyId == Leader) of
        {_FailOrSucceed, #ont_state{} = NewOntState} ->
            ?'log-info'("Recording transaction ~p", [Transaction]),
            #est{db = #db{ref = #db_differ{op_fifo = OpFifo} = DbDiffer} = Db} =
                PrologState = NewOntState#ont_state.prolog_state,
            NewTransaction =
                Transaction#transaction{
                    status = processed,
                    ts_processed = erlang:system_time(),
                    diff = OpFifo
                },
            bbsvx_transaction:record_transaction(NewTransaction),
            {NewTransaction, NewOntState#ont_state{
                prolog_state =
                    PrologState#est{
                        db =
                            Db#db{
                                ref =
                                    DbDiffer#db_differ{
                                        op_fifo =
                                            []
                                    }
                            }
                    }
            }};
        {error, Reason} ->
            %% TODO: Manage errors
            logger:error("Error processing goal ~p: ~p", [Goal, Reason]),
            {Transaction, OntState}
    end.

-doc """
Executes a Prolog goal with leader/follower coordination for distributed consensus.

This function implements the core logic for executing goals in the distributed knowledge
base, with different behavior for leader and follower nodes to maintain consistency
across the network.

## Parameters

- `Goal` - The Prolog goal to execute
- `OntState` - Current ontology state with Prolog database  
- `IsLeader` - Boolean indicating if this node is the current leader

## Returns

- `{succeed, NewOntState}` - Goal succeeded with updated state
- `{fail, NewOntState}` - Goal failed, state may be unchanged
- `{error, Reason}` - Execution error occurred

## Leader Behavior (`IsLeader = true`)

1. Executes goal directly via `erlog_int:prove_goal/2`
2. Creates `goal_result` record with execution outcome and diffs
3. Broadcasts result to all followers via EPTO
4. Updates local state with execution results

## Follower Behavior (`IsLeader = false`) 

1. Waits for goal result from leader via results queue
2. Applies received database diffs to local state
3. Returns execution result without independent computation

## Distributed Consistency

- Leaders broadcast results to ensure all nodes reach same state
- Followers apply diffs rather than re-executing goals
- EPTO ensures reliable delivery of results across network
- Database diffs capture all state changes for exact replication

## Error Handling

- Execution errors are broadcast as error results
- Unknown results logged and treated as failures
- Network failures handled by EPTO's reliability guarantees
""".
-spec do_prove_goal(goal(), ont_state(), boolean()) ->
    {succeed, ont_state()} | {fail, ont_state()} | {error, any()}.
do_prove_goal(
    #goal{namespace = Namespace, payload = ReceivedPred} = Goal,
    #ont_state{namespace = Namespace, prolog_state = PrologState} = OntState,
    true
) ->
    ?'log-info'("Proving goal ~p as Leader", [ReceivedPred]),
    %% TODO : Predicate validating should done in validation stage in a more robust way
    case erlog_int:prove_goal(ReceivedPred, PrologState) of
        {succeed, #est{db = #db{ref = #db_differ{op_fifo = OpFifo}}} = NewPrologState} ->
            GoalResult =
                %% TODO : Add signature
                #goal_result{
                    namespace = Namespace,
                    result = succeed,
                    signature = <<>>,
                    address = Goal#goal.id,
                    diff = OpFifo
                },
            bbsvx_epto_service:broadcast(Namespace, GoalResult),
            {succeed, OntState#ont_state{prolog_state = NewPrologState}};
        {fail, NewPrologState} ->
            %% TODO : Add signature
            GoalResult =
                #goal_result{
                    namespace = Namespace,
                    result = fail,
                    signature = <<>>,
                    address = Goal#goal.id,
                    diff = []
                },
            bbsvx_epto_service:broadcast(Namespace, GoalResult),
            {fail, OntState#ont_state{prolog_state = NewPrologState}};
        Other ->
            logger:error("Unknown result from erlog_int:prove_goal ~p", [Other]),
            %% TODO : Add signature
            GoalResult =
                #goal_result{
                    namespace = Namespace,
                    result = error,
                    signature = <<>>,
                    address = Goal#goal.id,
                    diff = []
                },
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

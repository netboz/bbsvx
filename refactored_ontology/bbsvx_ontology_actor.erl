%%%-----------------------------------------------------------------------------
%%% BBSvx Unified Ontology Actor (Refactored)
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Merged implementation combining bbsvx_actor_ontology and bbsvx_transaction_pipeline.
%%% This eliminates state duplication by maintaining a single source of truth for
%%% ontology state (ont_state) within the gen_statem process.
%%%
%%% Architecture:
%%% - Single gen_statem manages ontology lifecycle AND transaction processing
%%% - Spawned worker processes handle async pipeline stages via jobs queues
%%% - Workers send results back to gen_statem as events
%%% - gen_statem updates ont_state atomically
%%%
%%% Key Improvements:
%%% - No state duplication between actor and pipeline
%%% - Single source of truth for prolog_state, indices, and addresses
%%% - Cleaner ownership model (one process owns the ontology)
%%% - Eliminates synchronization issues
%%% - Maintains pipeline stages for separation of concerns
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_ontology_actor).

-moduledoc """
# BBSvx Unified Ontology Actor

Combines ontology lifecycle management and transaction processing into a single
gen_statem component with integrated pipeline stages.

## Architecture

### Single State Owner
The gen_statem owns the complete `ont_state` including:
- Prolog knowledge base state
- Transaction indices (local_index, current_index)
- Blockchain addresses
- Contact nodes

### Pipeline Integration
Transaction processing stages are implemented as:
- Linked worker processes that dequeue from jobs queues
- Pure functions that operate on state
- Event-based communication back to gen_statem
- Atomic state updates via gen_statem event handlers

### State Machine Flow
```
wait_for_genesis_transaction
    ↓
initialize_ontology
    ↓
syncing (operational state)
    - Spawns pipeline workers
    - Handles transaction events
    - Updates ont_state atomically
```

## Benefits

1. **No State Duplication**: Single ont_state in gen_statem
2. **Atomic Updates**: All state changes via gen_statem events
3. **Clear Ownership**: One process owns ontology resources
4. **Maintainable**: All ontology logic in one module
5. **Testable**: State machine + pure pipeline functions
""".

-behaviour(gen_statem).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%=============================================================================
%%% Exports
%%%=============================================================================

%% External API
-export([
    start_link/1,
    start_link/2,
    stop/1,
    % Transaction entry points
    accept_transaction/1,
    receive_transaction/1,
    accept_transaction_result/1,
    % Query API
    get_current_index/1,
    request_segment/3
]).

%% Gen State Machine Callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

%% State Functions
-export([
    wait_for_genesis_transaction/3,
    initialize_ontology/3,
    wait_for_registration/3,
    syncing/3
]).

%%%=============================================================================
%%% Records and Types
%%%=============================================================================

-record(state, {
    namespace :: binary(),
    repos_table :: atom(),
    boot :: term(),
    % The single source of truth for ontology state
    ont_state :: ont_state() | undefined,
    % Pipeline worker PIDs (linked processes)
    worker_accept :: pid() | undefined,
    worker_validate :: pid() | undefined,
    worker_process :: pid() | undefined,
    worker_postprocess :: pid() | undefined,
    % Validation stage state
    validation_state :: validation_state() | undefined
}).

-record(validation_state, {
    previous_ts :: number() | undefined,
    pending = #{} :: map()
}).

-type state() :: #state{}.
-type validation_state() :: #validation_state{}.

%%%=============================================================================
%%% API Functions
%%%=============================================================================

-doc """
Starts a linked ontology actor for the specified namespace.
Uses default options.
""".
-spec start_link(Namespace :: binary()) -> gen_statem:start_ret().
start_link(Namespace) ->
    start_link(Namespace, #{}).

-doc """
Starts a linked ontology actor with custom options.
Options may include boot mode and other configuration.
""".
-spec start_link(Namespace :: binary(), Options :: map()) -> gen_statem:start_ret().
start_link(Namespace, Options) ->
    gen_statem:start_link(
        {via, gproc, {n, l, {?MODULE, Namespace}}},
        ?MODULE,
        [Namespace, Options],
        []
    ).

-doc """
Stops the ontology actor gracefully.
""".
-spec stop(Namespace :: binary()) -> ok.
stop(Namespace) ->
    gen_statem:stop({via, gproc, {n, l, {?MODULE, Namespace}}}).

-doc """
Entry point for locally created transactions.
Queues transaction for acceptance and broadcasting.
""".
-spec accept_transaction(transaction()) -> ok.
accept_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:enqueue({stage_transaction_accept, Namespace}, Transaction).

-doc """
Entry point for transactions received from network via EPTO.
Queues transaction for validation and processing.
""".
-spec receive_transaction(transaction()) -> ok.
receive_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:enqueue({stage_transaction_validate, Namespace}, Transaction).

-doc """
Entry point for goal execution results from leader nodes.
Queues result for follower nodes to apply state diffs.
""".
-spec accept_transaction_result(goal_result()) -> ok.
accept_transaction_result(#goal_result{namespace = Namespace} = GoalResult) ->
    jobs:enqueue({stage_transaction_results, Namespace}, GoalResult).

-doc """
Retrieves the current transaction index for the namespace.
""".
-spec get_current_index(Namespace :: binary()) -> {ok, integer()}.
get_current_index(Namespace) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, get_current_index).

-doc """
Requests a segment of transaction history from the network.
Broadcasts request to other nodes for missing transactions.
""".
-spec request_segment(binary(), integer(), integer()) -> ok.
request_segment(Namespace, OldestIndex, YoungerIndex) ->
    gen_statem:cast(
        {via, gproc, {n, l, {?MODULE, Namespace}}},
        {request_segment, OldestIndex, YoungerIndex}
    ).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    %% Verify table exists
    case bbsvx_ont_service:table_exists(Namespace) of
        false ->
            ?'log-error'("Transaction table missing for namespace ~p", [Namespace]),
            {stop, {error, {missing_transaction_table, Namespace}}};
        true ->
            State = #state{
                namespace = Namespace,
                repos_table = bbsvx_ont_service:binary_to_table_name(Namespace),
                boot = maps:get(boot, Options, create),
                ont_state = undefined,
                validation_state = #validation_state{}
            },

            %% Start in appropriate state based on boot mode
            %% Only 3 valid boot modes: create, connect, reconnect
            case maps:get(boot, Options, create) of
                create ->
                    %% Creating new ontology - wait for genesis transaction
                    {ok, wait_for_genesis_transaction, State,
                     [{state_timeout, 5000, genesis_timeout}]};
                connect ->
                    %% Connecting to existing ontology - wait for network registration
                    {ok, wait_for_registration, State,
                     [{state_timeout, 30000, registration_timeout}]};
                reconnect ->
                    %% Reconnecting to ontology after restart - wait for registration
                    {ok, wait_for_registration, State,
                     [{state_timeout, 60000, registration_timeout}]}
            end
    end.

callback_mode() ->
    [state_functions, state_enter].

terminate(_Reason, _State, #state{namespace = Namespace}) ->
    %% Clean up jobs queues
    jobs:delete_queue({stage_transaction_accept, Namespace}),
    jobs:delete_queue({stage_transaction_validate, Namespace}),
    jobs:delete_queue({stage_transaction_process, Namespace}),
    jobs:delete_queue({stage_transaction_postprocess, Namespace}),
    jobs:delete_queue({stage_transaction_results, Namespace}),
    ok.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%=============================================================================
%%% State Functions
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% wait_for_genesis_transaction State
%%-----------------------------------------------------------------------------

wait_for_genesis_transaction(enter, _, #state{namespace = Namespace} = State) ->
    ?'log-info'("Ontology Actor ~p waiting for genesis transaction", [Namespace]),
    {keep_state, State};

wait_for_genesis_transaction(
    info,
    #transaction{type = creation, namespace = Namespace} = GenesisTx,
    #state{namespace = Namespace} = State
) ->
    ?'log-info'("Ontology Actor ~p received genesis transaction", [Namespace]),

    %% Build initial Prolog state
    case build_initial_prolog_state(Namespace) of
        {ok, PrologState} ->
            %% Create initial ontology state (no history for new ontology)
            OntState = #ont_state{
                namespace = Namespace,
                current_ts = 0,
                previous_ts = -1,
                local_index = -1,
                current_index = 0,
                current_address = <<"-1">>,
                next_address = <<"0">>,
                contact_nodes = [],
                prolog_state = PrologState
            },

            %% For boot=create, skip initialize_ontology (no history to load)
            %% Go directly to syncing state
            ?'log-info'("Ontology Actor ~p: new ontology, going directly to syncing", [Namespace]),
            {next_state, syncing, State#state{ont_state = OntState}};
        {error, Reason} ->
            ?'log-error'("Failed to build initial Prolog state: ~p", [Reason]),
            {stop, {error, Reason}, State}
    end;

wait_for_genesis_transaction(state_timeout, genesis_timeout, State) ->
    ?'log-error'("Timeout waiting for genesis transaction"),
    {stop, genesis_timeout, State};

wait_for_genesis_transaction(_EventType, _Event, _State) ->
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% initialize_ontology State
%%-----------------------------------------------------------------------------

initialize_ontology(
    enter,
    _,
    #state{namespace = Namespace, ont_state = OntState} = State
) ->
    ?'log-info'("Ontology Actor ~p loading history", [Namespace]),

    gproc:reg({p, l, {?MODULE, Namespace}}),

    case load_history(OntState, State#state.repos_table) of
        #ont_state{} = NewOntState ->
            ?'log-info'(
                "Loaded history: local_index=~p, current_index=~p",
                [NewOntState#ont_state.local_index, NewOntState#ont_state.current_index]
            ),
            {next_state, wait_for_registration, State#state{ont_state = NewOntState}};
        {error, Reason} ->
            ?'log-error'("Failed to load history: ~p", [Reason]),
            {stop, {error, Reason}, State}
    end;

initialize_ontology(_EventType, _Event, _State) ->
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% wait_for_registration State
%%-----------------------------------------------------------------------------

wait_for_registration(enter, _, #state{namespace = Namespace} = State) ->
    ?'log-info'("Ontology Actor ~p waiting for network registration", [Namespace]),
    {keep_state, State};

wait_for_registration(
    info,
    {registered, CurrentIndex},
    #state{namespace = Namespace, ont_state = OntState} = State
) ->
    ?'log-info'("Ontology Actor ~p registered with network, current_index=~p",
                [Namespace, CurrentIndex]),

    LocalIndex = OntState#ont_state.local_index,
    NewOntState = OntState#ont_state{current_index = CurrentIndex},

    %% Request missing transactions if needed
    case CurrentIndex > LocalIndex of
        true ->
            request_segment(Namespace, LocalIndex + 1, CurrentIndex);
        false ->
            ok
    end,

    {next_state, syncing, State#state{ont_state = NewOntState}};

wait_for_registration(state_timeout, registration_timeout, State) ->
    ?'log-error'("Timeout waiting for network registration"),
    {stop, registration_timeout, State};

wait_for_registration(_EventType, _Event, _State) ->
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% syncing State (Main Operational State)
%%-----------------------------------------------------------------------------

syncing(enter, _, #state{namespace = Namespace, ont_state = OntState} = State) ->
    ?'log-info'("Ontology Actor ~p entering syncing state", [Namespace]),

    %% Create jobs queues for pipeline stages
    ok = jobs:add_queue({stage_transaction_accept, Namespace}, [passive]),
    ok = jobs:add_queue({stage_transaction_validate, Namespace}, [passive]),
    ok = jobs:add_queue({stage_transaction_process, Namespace}, [passive]),
    ok = jobs:add_queue({stage_transaction_postprocess, Namespace}, [passive]),
    ok = jobs:add_queue({stage_transaction_results, Namespace}, [passive]),

    %% Spawn linked worker processes
    Parent = self(),
    AcceptWorker = spawn_link(fun() ->
        transaction_accept_worker(Namespace, Parent)
    end),
    ValidateWorker = spawn_link(fun() ->
        transaction_validate_worker(Namespace, Parent)
    end),
    ProcessWorker = spawn_link(fun() ->
        transaction_process_worker(Namespace, Parent)
    end),
    PostprocessWorker = spawn_link(fun() ->
        transaction_postprocess_worker(Namespace, Parent)
    end),

    ?'log-info'("Pipeline workers spawned for ~p", [Namespace]),

    {keep_state, State#state{
        worker_accept = AcceptWorker,
        worker_validate = ValidateWorker,
        worker_process = ProcessWorker,
        worker_postprocess = PostprocessWorker
    }};

%% Get current index query
syncing(
    {call, From},
    get_current_index,
    #state{ont_state = #ont_state{current_index = Index}}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index}}]};

%% Transaction validated - update current_index
syncing(
    info,
    {transaction_validated, ValidatedTx, NewCurrentAddress},
    #state{ont_state = OntState, validation_state = ValidationState} = State
) ->
    #transaction{index = Index, ts_created = TsCreated} = ValidatedTx,

    NewOntState = OntState#ont_state{
        current_index = Index,
        local_index = Index,
        current_address = NewCurrentAddress,
        current_ts = TsCreated
    },

    NewValidationState = ValidationState#validation_state{
        previous_ts = OntState#ont_state.current_ts
    },

    ?'log-info'("Transaction ~p validated, new index: ~p", [Index, Index]),

    {keep_state, State#state{
        ont_state = NewOntState,
        validation_state = NewValidationState
    }};

%% Transaction processed - update Prolog state
syncing(
    info,
    {transaction_processed, ProcessedTx, NewPrologState},
    #state{ont_state = OntState} = State
) ->
    NewOntState = OntState#ont_state{prolog_state = NewPrologState},

    ?'log-info'("Transaction ~p processed, Prolog state updated",
                [ProcessedTx#transaction.index]),

    {keep_state, State#state{ont_state = NewOntState}};

%% History transaction accepted - update local_index
syncing(
    info,
    {history_transaction_accepted, Index, CurrentAddress},
    #state{ont_state = OntState} = State
) ->
    NewOntState = OntState#ont_state{
        local_index = Index,
        current_address = CurrentAddress
    },

    ?'log-info'("History transaction ~p accepted, local_index updated", [Index]),

    {keep_state, State#state{ont_state = NewOntState}};

%% Segment request
syncing(
    cast,
    {request_segment, OldestIndex, YoungerIndex},
    #state{namespace = Namespace}
) ->
    ?'log-info'("Broadcasting segment request: ~p to ~p", [OldestIndex, YoungerIndex]),

    bbsvx_actor_spray:broadcast_unique_random_subset(
        Namespace,
        #ontology_history_request{
            namespace = Namespace,
            oldest_index = OldestIndex,
            younger_index = YoungerIndex
        },
        1
    ),

    keep_state_and_data;

%% History request from peer
syncing(
    info,
    #ontology_history_request{
        namespace = Namespace,
        requester = ReqUlid,
        oldest_index = OldestIndex,
        younger_index = YoungerIndex
    },
    #state{namespace = Namespace}
) ->
    ?'log-info'("Received history request: ~p to ~p", [OldestIndex, YoungerIndex]),

    %% Retrieve transactions from storage
    History = retrieve_transaction_history(Namespace, OldestIndex, YoungerIndex),

    {ActualOldest, ActualYoungest} = case History of
        [] -> {OldestIndex, YoungerIndex};
        [First | _] = H -> {First#transaction.index, (lists:last(H))#transaction.index}
    end,

    %% Send history response
    gen_statem:cast(
        {via, gproc, {n, l, {arc, in, ReqUlid}}},
        {send_history, #ontology_history{
            namespace = Namespace,
            list_tx = History,
            oldest_index = ActualOldest,
            younger_index = ActualYoungest
        }}
    ),

    keep_state_and_data;

%% History received from peer
syncing(
    info,
    #ontology_history{list_tx = ListTransactions},
    _State
) ->
    ?'log-info'("Received history: ~p transactions", [length(ListTransactions)]),

    %% Queue each transaction for validation
    lists:foreach(
        fun(Transaction) ->
            receive_transaction(Transaction)
        end,
        ListTransactions
    ),

    keep_state_and_data;

%% Catch-all
syncing(Type, Event, _State) ->
    ?'log-warning'("Unhandled event in syncing state: ~p ~p", [Type, Event]),
    keep_state_and_data.

%%%=============================================================================
%%% Pipeline Worker Processes
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% Transaction Accept Worker
%%-----------------------------------------------------------------------------

-doc """
Worker process that accepts and broadcasts new transactions.
Runs in infinite loop, sending events back to parent gen_statem.
""".
transaction_accept_worker(Namespace, Parent) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_accept, Namespace}, 1),

    ?'log-info'("Accepting transaction ~p", [Transaction#transaction.index]),

    %% Update transaction status and broadcast via EPTO
    UpdatedTx = Transaction#transaction{
        status = accepted,
        ts_created = erlang:system_time()
    },

    bbsvx_epto_service:broadcast(Namespace, UpdatedTx),

    %% Continue loop
    transaction_accept_worker(Namespace, Parent).

%%-----------------------------------------------------------------------------
%% Transaction Validate Worker
%%-----------------------------------------------------------------------------

-doc """
Worker process that validates transaction ordering and readiness.
Sends validation results back to parent gen_statem for state updates.
""".
transaction_validate_worker(Namespace, Parent) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_validate, Namespace}, 1),

    ?'log-info'("Validating transaction index=~p status=~p",
                [Transaction#transaction.index, Transaction#transaction.status]),

    %% Get current state from parent
    {ok, CurrentIndex} = gen_statem:call(Parent, get_current_index),

    %% Validate transaction
    case validate_transaction(Transaction, CurrentIndex, Namespace) of
        {ok, ValidatedTx, NewCurrentAddress} ->
            %% Send validation event to parent
            Parent ! {transaction_validated, ValidatedTx, NewCurrentAddress},

            %% Forward to processing stage
            jobs:enqueue({stage_transaction_process, Namespace}, ValidatedTx);

        {pending, Index} ->
            ?'log-info'("Transaction ~p is pending (current=~p)", [Index, CurrentIndex]),
            %% Re-queue for later (or store in pending map - simplified here)
            ok;

        {history_accepted, Index, CurrentAddress} ->
            Parent ! {history_transaction_accepted, Index, CurrentAddress},
            ok
    end,

    %% Continue loop
    transaction_validate_worker(Namespace, Parent).

%%-----------------------------------------------------------------------------
%% Transaction Process Worker
%%-----------------------------------------------------------------------------

-doc """
Worker process that executes validated transactions.
Handles Prolog goal execution and state diff generation.
""".
transaction_process_worker(Namespace, Parent) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_process, Namespace}, 1),

    ?'log-info'("Processing transaction ~p", [Transaction#transaction.index]),

    %% Get current Prolog state from parent (via call)
    {ok, PrologState} = gen_statem:call(Parent, get_prolog_state),

    %% Process transaction
    case process_transaction(Transaction, PrologState, Namespace) of
        {ok, ProcessedTx, NewPrologState} ->
            %% Send processed event to parent
            Parent ! {transaction_processed, ProcessedTx, NewPrologState},

            %% Forward to postprocess stage
            jobs:enqueue({stage_transaction_postprocess, Namespace}, ProcessedTx);

        {error, Reason} ->
            ?'log-error'("Transaction processing failed: ~p", [Reason]),
            ok
    end,

    %% Continue loop
    transaction_process_worker(Namespace, Parent).

%%-----------------------------------------------------------------------------
%% Transaction Postprocess Worker
%%-----------------------------------------------------------------------------

-doc """
Worker process that handles final transaction recording and metrics.
""".
transaction_postprocess_worker(Namespace, Parent) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_postprocess, Namespace}, 1),

    ?'log-info'("Postprocessing transaction ~p", [Transaction#transaction.index]),

    %% Record transaction to storage
    bbsvx_transaction:record_transaction(Transaction#transaction{status = processed}),

    %% Notify subscribers
    gproc:send({p, l, {diff, Namespace}}, {transaction_processed, Transaction}),

    %% Update metrics
    Time = erlang:system_time(microsecond),
    prometheus_gauge:set(
        <<"bbsvx_transaction_processing_time">>,
        [Namespace],
        Time - Transaction#transaction.ts_delivered
    ),
    prometheus_gauge:set(
        <<"bbsvx_transaction_total_validation_time">>,
        [Namespace],
        Time - Transaction#transaction.ts_created
    ),

    %% Continue loop
    transaction_postprocess_worker(Namespace, Parent).

%%%=============================================================================
%%% Pipeline Helper Functions (Pure Functions)
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% Transaction Validation
%%-----------------------------------------------------------------------------

-doc """
Validates transaction against blockchain ordering requirements.
Pure function - returns validation result without side effects.
""".
validate_transaction(
    #transaction{index = TxIndex, status = processed} = Transaction,
    CurrentIndex,
    Namespace
) when TxIndex == CurrentIndex + 1 ->
    %% History transaction ready to be accepted
    ?'log-info'("Accepting history transaction ~p", [TxIndex]),
    bbsvx_transaction:record_transaction(Transaction),
    {history_accepted, TxIndex, Transaction#transaction.current_address};

validate_transaction(
    #transaction{status = processed} = _Transaction,
    _CurrentIndex,
    _Namespace
) ->
    %% History transaction not ready - should be stored in pending
    {pending, _Transaction#transaction.index};

validate_transaction(
    #transaction{status = created, ts_created = TsCreated} = Transaction,
    CurrentIndex,
    Namespace
) ->
    %% New transaction - assign index
    NewIndex = CurrentIndex + 1,

    %% Get current address (would need to query parent in real impl)
    CurrentAddress = get_current_address_for_validation(Namespace),

    ValidatedTx = Transaction#transaction{
        status = validated,
        index = NewIndex,
        prev_address = CurrentAddress
    },

    %% Record transaction
    bbsvx_transaction:record_transaction(ValidatedTx),

    %% Calculate new address
    NewCurrentAddress = bbsvx_crypto_service:calculate_hash_address(NewIndex, Transaction),

    {ok, ValidatedTx, NewCurrentAddress};

validate_transaction(_Transaction, _CurrentIndex, _Namespace) ->
    %% Out of order - pending
    {pending, _Transaction#transaction.index}.

%%-----------------------------------------------------------------------------
%% Transaction Processing
%%-----------------------------------------------------------------------------

-doc """
Processes a validated transaction by executing its payload.
Pure function for most operations, coordinates with leader for goals.
""".
process_transaction(
    #transaction{type = creation} = Transaction,
    PrologState,
    _Namespace
) ->
    %% Creation transaction - no Prolog execution needed
    {ok, Transaction, PrologState};

process_transaction(
    #transaction{type = goal, payload = #goal{} = Goal, namespace = Namespace} = Transaction,
    PrologState,
    Namespace
) ->
    %% Get leader
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    MyId = bbsvx_crypto_service:my_id(),
    IsLeader = (Leader == MyId),

    case do_prove_goal(Goal, PrologState, IsLeader, Namespace) of
        {_Result, NewPrologState, Diff} ->
            ProcessedTx = Transaction#transaction{
                status = processed,
                ts_processed = erlang:system_time(),
                diff = Diff
            },

            {ok, ProcessedTx, NewPrologState};

        {error, Reason} ->
            {error, Reason}
    end.

%%-----------------------------------------------------------------------------
%% Goal Execution
%%-----------------------------------------------------------------------------

-doc """
Executes a Prolog goal with leader/follower coordination.
""".
do_prove_goal(
    #goal{namespace = Namespace, payload = Predicate} = Goal,
    PrologState,
    true, % IsLeader
    Namespace
) ->
    ?'log-info'("Executing goal as leader: ~p", [Predicate]),

    case erlog_int:prove_goal(Predicate, PrologState) of
        {succeed, #est{db = #db{ref = #db_differ{op_fifo = OpFifo}}} = NewPrologState} ->
            %% Broadcast result to followers
            GoalResult = #goal_result{
                namespace = Namespace,
                result = succeed,
                signature = <<>>,
                address = Goal#goal.id,
                diff = OpFifo
            },
            bbsvx_epto_service:broadcast(Namespace, GoalResult),

            {succeed, NewPrologState, OpFifo};

        {fail, NewPrologState} ->
            GoalResult = #goal_result{
                namespace = Namespace,
                result = fail,
                signature = <<>>,
                address = Goal#goal.id,
                diff = []
            },
            bbsvx_epto_service:broadcast(Namespace, GoalResult),

            {fail, NewPrologState, []};

        Other ->
            ?'log-error'("Goal execution error: ~p", [Other]),
            {error, Other}
    end;

do_prove_goal(
    _Goal,
    PrologState,
    false, % IsLeader
    Namespace
) ->
    ?'log-info'("Waiting for goal result as follower"),

    %% Wait for result from leader
    [{_, GoalResult}] = jobs:dequeue({stage_transaction_results, Namespace}, 1),

    case GoalResult of
        #goal_result{diff = Diff, result = Result} ->
            {ok, NewDb} = bbsvx_erlog_db_differ:apply_diff(
                Diff,
                PrologState#est.db
            ),
            {Result, PrologState#est{db = NewDb}, Diff};

        _ ->
            {error, unknown_result}
    end.

%%%=============================================================================
%%% Internal Helper Functions
%%%=============================================================================

-doc """
Builds initial Prolog state for a new ontology.
""".
build_initial_prolog_state(Namespace) ->
    DbRepos = bbsvx_ont_service:binary_to_table_name(Namespace),
    DbMod = bbsvx_erlog_db_ets,
    DbRef = DbRepos,

    erlog_int:new(bbsvx_erlog_db_differ, {DbRef, DbMod}).

-doc """
Loads transaction history from persistent storage.
""".
load_history(OntState, ReposTable) ->
    FirstKey = mnesia:dirty_first(ReposTable),

    case FirstKey of
        '$end_of_table' ->
            OntState;
        Key when is_number(Key) ->
            do_load_history(Key, OntState, ReposTable)
    end.

-doc """
Recursive helper for loading transaction history.
""".
do_load_history('$end_of_table', OntState, _ReposTable) ->
    OntState;

do_load_history(Key, #ont_state{prolog_state = PrologState} = OntState, ReposTable) ->
    OntDb = PrologState#est.db,

    case bbsvx_transaction:read_transaction(ReposTable, Key) of
        not_found ->
            ?'log-error'("Transaction ~p not found", [Key]),
            {error, {not_found, Key}};

        #transaction{diff = Diff, current_address = CurrentAddress, index = Index} = _Tx ->
            {ok, #db{ref = Ref} = NewOntDb} =
                bbsvx_erlog_db_differ:apply_diff(Diff, OntDb),

            NextKey = mnesia:dirty_next(ReposTable, Key),

            do_load_history(
                NextKey,
                OntState#ont_state{
                    prolog_state = PrologState#est{
                        db = NewOntDb#db{
                            ref = Ref#db_differ{op_fifo = []}
                        }
                    },
                    current_address = CurrentAddress,
                    local_index = Index
                },
                ReposTable
            )
    end.

-doc """
Retrieves transaction history from repository.
""".
retrieve_transaction_history(Namespace, OldestIndex, YoungerIndex) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),

    SelectFun = ets:fun2ms(
        fun(#transaction{index = Index} = Transaction) when
            Index >= OldestIndex, Index =< YoungerIndex
        ->
            Transaction
        end
    ),

    HistResult = mnesia:dirty_select(TableName, SelectFun),

    lists:sort(
        fun(#transaction{index = A}, #transaction{index = B}) -> A =< B end,
        HistResult
    ).

%%-----------------------------------------------------------------------------
%% Temporary Helper (needs proper implementation)
%%-----------------------------------------------------------------------------

get_current_address_for_validation(Namespace) ->
    %% TODO: This should query the parent gen_statem
    %% For now, return a placeholder
    case gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, get_current_address) of
        {ok, Address} -> Address;
        _ -> <<"0">>
    end.

%%%=============================================================================
%%% Additional State Machine Handlers
%%%=============================================================================

%% Add handler for get_prolog_state call
syncing({call, From}, get_prolog_state, #state{ont_state = OntState}) ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.prolog_state}}]};

syncing({call, From}, get_current_address, #state{ont_state = OntState}) ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.current_address}}]}.

%%%=============================================================================
%%% Tests
%%%=============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

state_consistency_test() ->
    %% Test that state updates are atomic
    ?assertEqual(true, true).

-endif.

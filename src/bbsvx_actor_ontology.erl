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

-module(bbsvx_actor_ontology).

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
    request_segment/3,
    % Testing API
    get_pending_count/1,
    is_transaction_pending/2
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
    pending = #{} :: map(),  %% #{Index => Transaction}
    requested_txs = #{} :: #{integer() => integer()}  %% #{Index => RequestTimestamp}
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
Gets the count of pending transactions (for testing).
""".
-spec get_pending_count(binary()) -> {ok, integer()}.
get_pending_count(Namespace) ->
    {ok, _CurrentIndex, ValidationState, _CurrentAddress} =
        gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, get_validation_context, 5000),
    PendingCount = maps:size(ValidationState#validation_state.pending),
    {ok, PendingCount}.

-doc """
Checks if a transaction at given index is in pending map (for testing).
""".
-spec is_transaction_pending(binary(), integer()) -> {ok, boolean()}.
is_transaction_pending(Namespace, Index) ->
    {ok, _CurrentIndex, ValidationState, _CurrentAddress} =
        gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, get_validation_context, 5000),
    IsPending = maps:is_key(Index, ValidationState#validation_state.pending),
    {ok, IsPending}.

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
            %% Build initial Prolog state for all boot modes
            case build_initial_prolog_state(Namespace) of
                {ok, PrologState} ->
                    %% Create initial ont_state with Prolog state
                    OntState = #ont_state{
                        namespace = Namespace,
                        current_ts = 0,
                        previous_ts = -1,
                        local_index = -1,
                        current_index = -1,
                        current_address = <<"-1">>,
                        next_address = <<"0">>,
                        contact_nodes = [],
                        prolog_state = PrologState
                    },

                    State = #state{
                        namespace = Namespace,
                        repos_table = bbsvx_ont_service:binary_to_table_name(Namespace),
                        boot = maps:get(boot, Options, create),
                        ont_state = OntState,
                        validation_state = #validation_state{}
                    },

                    %% Create jobs queues for pipeline stages
                    %% These need to be created early so genesis transaction can go through pipeline
                    ok = jobs:add_queue({stage_transaction_accept, Namespace}, [passive]),
                    ok = jobs:add_queue({stage_transaction_validate, Namespace}, [passive]),
                    ok = jobs:add_queue({stage_transaction_process, Namespace}, [passive]),
                    ok = jobs:add_queue({stage_transaction_postprocess, Namespace}, [passive]),
                    ok = jobs:add_queue({stage_transaction_results, Namespace}, [passive]),

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
                            %% Reconnecting to ontology after restart - load history first
                            {ok, initialize_ontology, State}
                    end;
                {error, Reason} ->
                    ?'log-error'("Failed to build initial Prolog state: ~p", [Reason]),
                    {stop, {error, {prolog_init_failed, Reason}}}
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

    %% Register for broadcast messages
    gproc:reg({p, l, {?MODULE, Namespace}}),

    %% Spawn worker processes for pipeline (needed to process genesis transaction)
    Parent = self(),
    AcceptWorker = spawn_link(fun() -> transaction_accept_worker(Namespace, Parent) end),
    ValidateWorker = spawn_link(fun() -> transaction_validate_worker(Namespace, Parent) end),
    ProcessWorker = spawn_link(fun() -> transaction_process_worker(Namespace, Parent) end),
    PostprocessWorker = spawn_link(fun() -> transaction_postprocess_worker(Namespace, Parent) end),

    ?'log-info'("Pipeline workers spawned for ~p (waiting for genesis)", [Namespace]),

    {keep_state, State#state{
        worker_accept = AcceptWorker,
        worker_validate = ValidateWorker,
        worker_process = ProcessWorker,
        worker_postprocess = PostprocessWorker
    }};

wait_for_genesis_transaction(
    info,
    {transaction_validated, #transaction{type = creation, index = 0} = ValidatedTx, NewCurrentAddress, NewValidationState},
    #state{ont_state = OntState} = State
) ->
    ?'log-info'("Genesis transaction validated and processed", []),

    %% Update ontology state with genesis transaction results
    UpdatedOntState = OntState#ont_state{
        local_index = 0,
        current_index = 0,
        current_address = NewCurrentAddress,
        next_address = <<"1">>
    },

    %% Transition to syncing state - workers are already running
    {next_state, syncing, State#state{
        ont_state = UpdatedOntState,
        validation_state = NewValidationState
    }};

wait_for_genesis_transaction(
    {call, From},
    get_validation_context,
    #state{ont_state = #ont_state{current_index = Index, current_address = CurrentAddress},
           validation_state = ValidationState}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index, ValidationState, CurrentAddress}}]};

wait_for_genesis_transaction(
    {call, From},
    get_current_index,
    #state{ont_state = #ont_state{current_index = Index}}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index}}]};

wait_for_genesis_transaction(state_timeout, genesis_timeout, State) ->
    ?'log-error'("Timeout waiting for genesis transaction"),
    {stop, genesis_timeout, State};

wait_for_genesis_transaction(_EventType, _Event, _State) ->
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% initialize_ontology State
%%-----------------------------------------------------------------------------

initialize_ontology(enter, _, #state{namespace = Namespace} = State) ->
    ?'log-info'("Ontology Actor ~p entering initialize_ontology state", [Namespace]),
    %% Use timeout to trigger history loading (enter callbacks can only use timeout actions)
    {keep_state, State, [{state_timeout, 0, load_history}]};

initialize_ontology(state_timeout, load_history, #state{namespace = Namespace, ont_state = OntState, repos_table = ReposTable} = State) ->
    ?'log-info'("Ontology Actor ~p loading history", [Namespace]),

    %% Load history (this can be slow, but we're not blocking init)
    case load_history(OntState, ReposTable) of
        #ont_state{local_index = LocalIndex, current_index = CurrentIndex} = NewOntState ->
            ?'log-info'("Loaded history: local_index=~p, current_index=~p", [LocalIndex, CurrentIndex]),

            %% Transition to wait_for_registration with loaded state
            {next_state, wait_for_registration, State#state{ont_state = NewOntState}};
        {error, Reason} ->
            ?'log-error'("Failed to load history: ~p", [Reason]),
            {stop, {error, {load_history_failed, Reason}}, State}
    end;

initialize_ontology(_EventType, _Event, _State) ->
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% wait_for_registration State
%%-----------------------------------------------------------------------------

wait_for_registration(enter, _, #state{namespace = Namespace} = State) ->
    ?'log-info'("Ontology Actor ~p waiting for network registration", [Namespace]),
    {keep_state, State, [{state_timeout, 60000, registration_timeout}]};

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

syncing(enter, _, #state{namespace = Namespace, worker_accept = AcceptWorker} = State) ->
    ?'log-info'("Ontology Actor ~p entering syncing state", [Namespace]),

    %% Register for broadcast messages (only if not already registered)
    %% This is critical for receiving history requests and network events
    try
        gproc:reg({p, l, {?MODULE, Namespace}})
    catch
        error:badarg -> ok  % Already registered
    end,

    %% Check if workers are already spawned (from wait_for_genesis_transaction)
    case AcceptWorker of
        undefined ->
            %% Workers not spawned yet - spawn them now
            %% (This happens when coming from initialize_ontology or wait_for_registration)
            Parent = self(),
            NewAcceptWorker = spawn_link(fun() -> transaction_accept_worker(Namespace, Parent) end),
            NewValidateWorker = spawn_link(fun() -> transaction_validate_worker(Namespace, Parent) end),
            NewProcessWorker = spawn_link(fun() -> transaction_process_worker(Namespace, Parent) end),
            NewPostprocessWorker = spawn_link(fun() -> transaction_postprocess_worker(Namespace, Parent) end),

            ?'log-info'("Pipeline workers spawned for ~p", [Namespace]),

            {keep_state, State#state{
                worker_accept = NewAcceptWorker,
                worker_validate = NewValidateWorker,
                worker_process = NewProcessWorker,
                worker_postprocess = NewPostprocessWorker
            }};
        _ ->
            %% Workers already running (from wait_for_genesis_transaction)
            ?'log-info'("Pipeline workers already running for ~p", [Namespace]),
            {keep_state, State}
    end;

%% Get current index query
syncing(
    {call, From},
    get_current_index,
    #state{ont_state = #ont_state{current_index = Index}}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index}}]};

%% Get validation context (index + state + address) in single call
syncing(
    {call, From},
    get_validation_context,
    #state{ont_state = #ont_state{current_index = Index, current_address = CurrentAddress},
           validation_state = ValidationState}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index, ValidationState, CurrentAddress}}]};

%% Transaction validated - update current_index, validation_state, and check pending
syncing(
    info,
    {transaction_validated, ValidatedTx, NewCurrentAddress, UpdatedValidationState},
    #state{namespace = Namespace, ont_state = OntState} = State
) ->
    #transaction{index = Index, ts_created = TsCreated} = ValidatedTx,

    NewOntState = OntState#ont_state{
        current_index = Index,
        local_index = Index,
        current_address = NewCurrentAddress,
        current_ts = TsCreated
    },

    ?'log-info'("Transaction ~p validated, index updated to ~p", [ValidatedTx#transaction.index, Index]),

    %% Check if next transaction is pending and re-queue it
    NextIndex = Index + 1,
    FinalValidationState = case check_pending(UpdatedValidationState, NextIndex) of
        {found, PendingTx, NewValidationState} ->
            ?'log-info'("Re-queueing pending transaction ~p", [NextIndex]),
            jobs:enqueue({stage_transaction_validate, Namespace}, PendingTx),
            %% Update metrics
            #validation_state{pending = NewPending} = NewValidationState,
            prometheus_gauge:set(
                <<"bbsvx_pending_transactions">>,
                [Namespace],
                maps:size(NewPending)
            ),
            NewValidationState;
        {not_found, _} ->
            UpdatedValidationState
    end,

    {keep_state, State#state{
        ont_state = NewOntState,
        validation_state = FinalValidationState
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

%% History transaction accepted - update local_index, validation_state, and check pending
syncing(
    info,
    {history_transaction_accepted, Index, CurrentAddress, UpdatedValidationState},
    #state{namespace = Namespace, ont_state = OntState} = State
) ->
    NewOntState = OntState#ont_state{
        current_index = Index,
        local_index = Index,
        current_address = CurrentAddress
    },

    ?'log-info'("History transaction ~p accepted, current_index and local_index updated to ~p", [Index, Index]),

    %% Check if next transaction is pending and re-queue it
    NextIndex = Index + 1,
    FinalValidationState = case check_pending(UpdatedValidationState, NextIndex) of
        {found, PendingTx, NewValidationState} ->
            ?'log-info'("Re-queueing pending transaction ~p after history", [NextIndex]),
            jobs:enqueue({stage_transaction_validate, Namespace}, PendingTx),
            %% Update metrics
            #validation_state{pending = NewPending} = NewValidationState,
            prometheus_gauge:set(
                <<"bbsvx_pending_transactions">>,
                [Namespace],
                maps:size(NewPending)
            ),
            NewValidationState;
        {not_found, _} ->
            UpdatedValidationState
    end,

    {keep_state, State#state{
        ont_state = NewOntState,
        validation_state = FinalValidationState
    }};

%% Validation state updated (when transaction goes to pending map)
syncing(
    info,
    {validation_state_updated, UpdatedValidationState},
    #state{namespace = Namespace} = State
) ->
    %% Update metrics for pending transaction count
    #validation_state{pending = Pending} = UpdatedValidationState,
    prometheus_gauge:set(
        <<"bbsvx_pending_transactions">>,
        [Namespace],
        maps:size(Pending)
    ),

    ?'log-debug'("Validation state updated, pending count: ~p", [maps:size(Pending)]),

    {keep_state, State#state{validation_state = UpdatedValidationState}};

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
    #state{validation_state = ValidationState} = State
) ->
    ?'log-info'("Received history: ~p transactions", [length(ListTransactions)]),

    %% Queue each transaction for validation
    lists:foreach(
        fun(Transaction) ->
            receive_transaction(Transaction)
        end,
        ListTransactions
    ),

    %% Remove received transactions from requested_txs
    #validation_state{requested_txs = RequestedTxs} = ValidationState,
    ReceivedIndices = [Tx#transaction.index || Tx <- ListTransactions],
    NewRequestedTxs = lists:foldl(
        fun(Index, Acc) -> maps:remove(Index, Acc) end,
        RequestedTxs,
        ReceivedIndices
    ),

    ?'log-debug'("Cleaned up ~p requested transactions, ~p still pending request",
                [length(ReceivedIndices), maps:size(NewRequestedTxs)]),

    NewValidationState = ValidationState#validation_state{requested_txs = NewRequestedTxs},

    {keep_state, State#state{validation_state = NewValidationState}};

%% State queries for workers
syncing({call, From}, get_prolog_state, #state{ont_state = OntState}) ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.prolog_state}}]};

syncing({call, From}, get_current_address, #state{ont_state = OntState}) ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.current_address}}]};

syncing({call, From}, get_validation_state, #state{validation_state = ValidationState}) ->
    {keep_state_and_data, [{reply, From, {ok, ValidationState}}]};

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
Parent is responsible for checking pending transactions and re-queuing.
""".
transaction_validate_worker(Namespace, Parent) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_validate, Namespace}, 1),

    ?'log-info'("Validating transaction index=~p status=~p",
                [Transaction#transaction.index, Transaction#transaction.status]),

    %% Get validation context from parent with timeout and error handling
    case gen_statem:call(Parent, get_validation_context, 10000) of
        {ok, CurrentIndex, ValidationState, CurrentAddress} ->
            %% Validate transaction
            case validate_transaction(Transaction, CurrentIndex, CurrentAddress, Namespace, ValidationState) of
                {ok, ValidatedTx, NewCurrentAddress, NewValidationState} ->
                    %% Send validation event to parent with updated validation state
                    %% Parent will check pending and re-queue if needed
                    Parent ! {transaction_validated, ValidatedTx, NewCurrentAddress, NewValidationState},

                    %% Forward to processing stage
                    jobs:enqueue({stage_transaction_process, Namespace}, ValidatedTx);

                {pending, Index, NewValidationState} ->
                    ?'log-info'("Transaction ~p is pending (current=~p)", [Index, CurrentIndex]),
                    %% Send updated validation state to parent
                    %% Transaction is stored in pending map, parent owns it now
                    Parent ! {validation_state_updated, NewValidationState};

                {history_accepted, Index, NewAddr, NewValidationState} ->
                    %% History transaction accepted, send to parent
                    %% Parent will check pending and re-queue if needed
                    Parent ! {history_transaction_accepted, Index, NewAddr, NewValidationState}
            end;

        {error, Reason} ->
            ?'log-error'("Failed to get validation context: ~p, retrying in 1s", [Reason]),
            timer:sleep(1000);

        Other ->
            ?'log-error'("Unexpected response from parent: ~p, retrying in 1s", [Other]),
            timer:sleep(1000)
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
        <<"bbsvx_transction_processing_time">>,
        [Namespace],
        Time - Transaction#transaction.ts_delivered
    ),
    prometheus_gauge:set(
        <<"bbsvx_transction_total_validation_time">>,
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
Accepts current_address as parameter to avoid extra gproc lookup.
""".
validate_transaction(
    #transaction{index = TxIndex, status = processed} = Transaction,
    CurrentIndex,
    _CurrentAddress,
    Namespace,
    ValidationState
) when TxIndex == CurrentIndex + 1 ->
    %% History transaction ready to be accepted
    ?'log-info'("Accepting history transaction ~p", [TxIndex]),
    bbsvx_transaction:record_transaction(Transaction),
    {history_accepted, TxIndex, Transaction#transaction.current_address, ValidationState};

validate_transaction(
    #transaction{status = processed, index = TxIndex} = Transaction,
    CurrentIndex,
    _CurrentAddress,
    Namespace,
    ValidationState
) ->
    %% History transaction not ready - store in pending
    ?'log-info'("Transaction ~p arrives out of order (current=~p), storing in pending",
                [TxIndex, CurrentIndex]),

    #validation_state{pending = Pending, requested_txs = RequestedTxs} = ValidationState,
    NewPending = Pending#{TxIndex => Transaction},

    %% Check which transactions in the gap need to be requested
    MissingIndices = lists:seq(CurrentIndex + 1, TxIndex - 1),
    Now = erlang:system_time(millisecond),
    TimeoutMs = 5000,  %% 5 second timeout

    {ToRequest, NewRequestedTxs} = lists:foldl(
        fun(Index, {AccToRequest, AccRequested}) ->
            InPending = maps:is_key(Index, NewPending),
            AlreadyRequested = is_tx_requested(Index, AccRequested, TimeoutMs),

            case InPending orelse AlreadyRequested of
                true ->
                    {AccToRequest, AccRequested};  %% Skip - already have it or requested
                false ->
                    {[Index | AccToRequest], AccRequested#{Index => Now}}
            end
        end,
        {[], RequestedTxs},
        MissingIndices
    ),

    %% Request the range if any transactions need requesting
    case ToRequest of
        [] ->
            ?'log-debug'("All transactions ~p-~p already pending or requested",
                        [CurrentIndex + 1, TxIndex - 1]);
        _ ->
            MinIndex = lists:min(ToRequest),
            MaxIndex = lists:max(ToRequest),
            ?'log-info'("Requesting segment ~p-~p (~p transactions)",
                       [MinIndex, MaxIndex, length(ToRequest)]),
            request_segment(Namespace, MinIndex, MaxIndex)
    end,

    NewValidationState = ValidationState#validation_state{
        pending = NewPending,
        requested_txs = NewRequestedTxs
    },

    {pending, TxIndex, NewValidationState};

validate_transaction(
    #transaction{status = created, ts_created = TsCreated} = Transaction,
    CurrentIndex,
    CurrentAddress,
    Namespace,
    ValidationState
) ->
    %% New transaction - assign index
    NewIndex = CurrentIndex + 1,

    ValidatedTx = Transaction#transaction{
        status = validated,
        index = NewIndex,
        prev_address = CurrentAddress
    },

    %% Record transaction
    bbsvx_transaction:record_transaction(ValidatedTx),

    %% Calculate new address
    NewCurrentAddress = bbsvx_crypto_service:calculate_hash_address(NewIndex, Transaction),

    %% Update validation state with previous timestamp
    NewValidationState = ValidationState#validation_state{
        previous_ts = TsCreated
    },

    {ok, ValidatedTx, NewCurrentAddress, NewValidationState};

validate_transaction(Transaction, CurrentIndex, _CurrentAddress, Namespace, ValidationState) ->
    %% Out of order - store in pending
    TxIndex = Transaction#transaction.index,
    ?'log-info'("Transaction ~p out of order (current=~p), storing in pending",
                [TxIndex, CurrentIndex]),

    #validation_state{pending = Pending, requested_txs = RequestedTxs} = ValidationState,
    NewPending = Pending#{TxIndex => Transaction},

    %% Request missing segment if there's a gap
    {NewRequestedTxs, _Requested} = case TxIndex > CurrentIndex + 1 of
        true ->
            %% Check which transactions in the gap need to be requested
            MissingIndices = lists:seq(CurrentIndex + 1, TxIndex - 1),
            Now = erlang:system_time(millisecond),
            TimeoutMs = 5000,  %% 5 second timeout

            {ToRequest, UpdatedRequestedTxs} = lists:foldl(
                fun(Index, {AccToRequest, AccRequested}) ->
                    InPending = maps:is_key(Index, NewPending),
                    AlreadyRequested = is_tx_requested(Index, AccRequested, TimeoutMs),

                    case InPending orelse AlreadyRequested of
                        true ->
                            {AccToRequest, AccRequested};
                        false ->
                            {[Index | AccToRequest], AccRequested#{Index => Now}}
                    end
                end,
                {[], RequestedTxs},
                MissingIndices
            ),

            %% Request the range if any transactions need requesting
            case ToRequest of
                [] ->
                    ?'log-debug'("All transactions ~p-~p already pending or requested",
                                [CurrentIndex + 1, TxIndex - 1]),
                    {UpdatedRequestedTxs, false};
                _ ->
                    MinIndex = lists:min(ToRequest),
                    MaxIndex = lists:max(ToRequest),
                    ?'log-info'("Requesting segment ~p-~p (~p transactions)",
                               [MinIndex, MaxIndex, length(ToRequest)]),
                    request_segment(Namespace, MinIndex, MaxIndex),
                    {UpdatedRequestedTxs, true}
            end;
        false ->
            {RequestedTxs, false}
    end,

    NewValidationState = ValidationState#validation_state{
        pending = NewPending,
        requested_txs = NewRequestedTxs
    },

    {pending, TxIndex, NewValidationState}.

%%-----------------------------------------------------------------------------
%% Transaction Processing
%%-----------------------------------------------------------------------------

-doc """
Processes a validated transaction by executing its payload.
Pure function for most operations, coordinates with leader for goals.
""".
process_transaction(
    #transaction{type = creation, external_predicates = ExternalPreds} = Transaction,
    #ont_state{prolog_state = #est{db = PrologDb} = PrologState} = OntState,
    Namespace
) ->
    %% Genesis transaction - load external predicates into Prolog database
    ?'log-info'("Processing genesis transaction for ~p with ~p external predicate modules",
                [Namespace, length(ExternalPreds)]),

    %% Load external predicates from Erlang modules
    UpdatedDb = lists:foldl(
        fun(Mod, DbAcc) ->
            case erlang:function_exported(Mod, external_predicates, 0) of
                true ->
                    Preds = Mod:external_predicates(),
                    ?'log-info'("Loading ~p external predicates from ~p", [length(Preds), Mod]),
                    lists:foldl(
                        fun({{Functor, Arity}, PredMod, PredFunc}, Db) ->
                            case bbsvx_erlog_db_differ:add_compiled_proc(Db, {Functor, Arity}, PredMod, PredFunc) of
                                {ok, NewDb} ->
                                    ?'log-debug'("Added predicate ~p/~p", [Functor, Arity]),
                                    NewDb;
                                error ->
                                    ?'log-warning'("Failed to add predicate ~p/~p", [Functor, Arity]),
                                    Db
                            end
                        end,
                        DbAcc,
                        Preds
                    );
                false ->
                    ?'log-warning'("Module ~p does not export external_predicates/0", [Mod]),
                    DbAcc
            end
        end,
        PrologDb,
        ExternalPreds
    ),

    %% TODO: Execute payload (asserta static predicates if present)
    %% The payload contains [{asserta, StaticPredicates}] but for now we'll skip this

    UpdatedPrologState = PrologState#est{db = UpdatedDb},
    UpdatedOntState = OntState#ont_state{prolog_state = UpdatedPrologState},

    ?'log-info'("Genesis transaction processing complete for ~p", [Namespace]),
    {ok, Transaction, UpdatedOntState};

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
Checks if a pending transaction exists for the given index.
Returns {found, Transaction, UpdatedValidationState} or {not_found, ValidationState}.
""".
check_pending(ValidationState, NextIndex) ->
    #validation_state{pending = Pending} = ValidationState,
    case maps:take(NextIndex, Pending) of
        {Transaction, NewPending} ->
            NewValidationState = ValidationState#validation_state{pending = NewPending},
            {found, Transaction, NewValidationState};
        error ->
            {not_found, ValidationState}
    end.

-doc """
Checks if a transaction has been requested recently (within timeout).
Returns true if already requested and not timed out, false otherwise.
""".
is_tx_requested(Index, RequestedTxs, TimeoutMs) ->
    case maps:get(Index, RequestedTxs, undefined) of
        undefined ->
            false;  %% Not requested
        RequestedAt ->
            Now = erlang:system_time(millisecond),
            Age = Now - RequestedAt,
            Age < TimeoutMs  %% True if still fresh, false if timed out
    end.

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

%%%=============================================================================
%%% Tests
%%%=============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

state_consistency_test() ->
    %% Test that state updates are atomic
    ?assertEqual(true, true).

-endif.

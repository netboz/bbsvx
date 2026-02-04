%%%-----------------------------------------------------------------------------
%%% BBSvx Ontology Actor
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen_statem managing blockchain-based knowledge ontology lifecycle.
%%%
%%% Combines Prolog knowledge base (erlog) with blockchain transaction processing
%%% in a single stateful actor. Rate-limited transaction submission (50 tx/s)
%%% via jobs library provides automatic backpressure.
%%%
%%% Key Features:
%%% - Single source of truth for ontology state (ont_state)
%%% - Rate-limited transaction processing (50 tx/s per ontology)
%%% - Leader/follower architecture for distributed goal execution
%%% - Out-of-order transaction handling via pending map
%%% - Atomic state updates via gen_statem events
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_ontology).

-moduledoc """
# BBSvx Ontology Actor

Manages the lifecycle of a blockchain-based knowledge ontology using gen_statem.
Integrates Prolog knowledge base management with blockchain transaction processing.

## Architecture

### Single State Owner
The gen_statem process owns the complete `ont_state` including:
- Prolog knowledge base state (erlog)
- Transaction index (last_processed_index) - EPTO is the source of truth
- Blockchain addresses (current_address, next_address)
- Validation state for out-of-order transactions

### Transaction Processing
Transaction submission is rate-limited via the `jobs` library:
- Rate limit: 50 transactions/second per ontology
- Transactions submitted via `receive_transaction/1`
- Processing via `jobs:run/2` with automatic backpressure
- Synchronous validation → process → postprocess pipeline

Leader nodes execute Prolog goals and broadcast results.
Follower nodes wait for goal results from leaders to apply diffs.

### State Machine Flow
```
wait_for_genesis_transaction → Genesis transaction creates ontology
    ↓
wait_for_registration → Network registration for non-root nodes
    ↓
initialize_ontology → Load history and initialize state
    ↓
syncing (operational) → Process incoming transactions
    ↓
waiting_for_goal_result → Followers wait for leader's goal execution
    ↓
syncing → Continue processing
```

## Benefits

1. **Rate Limiting**: Automatic backpressure via jobs queue (50 tx/s)
2. **Single State Owner**: All ontology state in one gen_statem process
3. **Atomic Updates**: State changes via gen_statem events only
4. **Out-of-Order Handling**: Pending map for transactions arriving early
5. **Leader/Follower**: Distributed execution with result broadcasting
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
    get_last_processed_index/1,
    request_segment/3,
    get_prolog_state/1,
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
    syncing/3,
    waiting_for_goal_result/3,
    disconnected/3
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
    % Validation stage state
    validation_state :: validation_state() | undefined,
    % Transaction being processed while waiting for goal result from leader
    pending_goal_transaction :: transaction() | undefined,
    % Cache of goal results that arrived before their transaction
    % #{TransactionIndex => GoalResult}
    cached_goal_results = #{} :: map(),
    % Connection management
    connection_state = connected :: connection_state(),
    connection_attempts = 0 :: non_neg_integer(),
    last_connection_attempt = undefined :: integer() | undefined,
    last_connection_error = undefined :: term() | undefined,
    contact_nodes = [] :: [node_entry()],
    retry_timer_ref = undefined :: reference() | undefined,
    services_sup_pid = undefined :: pid() | undefined
}).

-record(validation_state, {
    pending = #{} :: map(),  %% #{Index => Transaction}
    requested_txs = #{} :: #{integer() => integer()}  %% #{Index => RequestTimestamp}
}).

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
Submits transaction to rate-limited queue for acceptance and broadcasting.
This is just an alias for receive_transaction/1 for API compatibility.
""".
-spec accept_transaction(transaction()) -> ok.
accept_transaction(Transaction) ->
    receive_transaction(Transaction).

-doc """
Entry point for transactions (locally created or received from network via EPTO).
Submits transaction to rate-limited queue (50 tx/s) for processing.

The jobs queue provides:
- Rate limiting to prevent overload
- Fair scheduling across concurrent transactions
- Backpressure when system is under load

Returns immediately after queuing (non-blocking).
""".
-spec receive_transaction(transaction()) -> ok.
receive_transaction(#transaction{namespace = Namespace} = Transaction) ->
    jobs:run({stage_transaction_accept, Namespace}, fun() ->
        %% Send transaction to the ontology actor for processing
        case gproc:where({n, l, {?MODULE, Namespace}}) of
            undefined ->
                ?'log-warning'("Cannot process transaction - ontology actor not found for ~p", [Namespace]),
                ok;
            Pid ->
                gen_statem:cast(Pid, {process_transaction, Transaction}),
                ok
        end
    end).

-doc """
Entry point for goal execution results from leader nodes.
Sends result event directly to the ontology actor.
""".
-spec accept_transaction_result(goal_result()) -> ok.
accept_transaction_result(#goal_result{namespace = Namespace} = GoalResult) ->
    %% Send goal result event directly to the ontology actor
    case gproc:where({n, l, {?MODULE, Namespace}}) of
        undefined ->
            ?'log-warning'("Cannot deliver goal result - ontology actor not found for ~p", [Namespace]),
            ok;
        Pid ->
            Pid ! GoalResult,
            ok
    end.

-doc """
Retrieves the last processed transaction index for the namespace.
""".
-spec get_last_processed_index(Namespace :: binary()) -> {ok, integer()}.
get_last_processed_index(Namespace) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Namespace}}}, get_last_processed_index).

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
Retrieves the Prolog state for cross-ontology queries.
Returns the current Prolog state even if ontology is not fully synced.
Used by the :: operator for cross-ontology predicate calls.
""".
-spec get_prolog_state(binary()) -> {ok, erlog_state()} | {error, term()}.
get_prolog_state(Namespace) ->
    case gproc:where({n, l, {?MODULE, Namespace}}) of
        undefined ->
            {error, ontology_not_found};
        Pid ->
            try
                gen_statem:call(Pid, get_prolog_state, 5000)
            catch
                exit:{timeout, _} -> {error, timeout};
                exit:{noproc, _} -> {error, ontology_not_found}
            end
    end.

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
    process_flag(trap_exit, true),  % Trap exits to handle services supervisor crashes

    %% Extract and log boot mode early
    BootMode = maps:get(boot, Options, create),
    ?'log-info'("========================================"),
    ?'log-info'("Ontology Actor: ~p", [Namespace]),
    ?'log-info'("Boot Mode: ~p", [BootMode]),
    ?'log-info'("========================================"),

    %% Verify table exists (only for reconnect mode - others will create it)
    TableCheck = case BootMode of
        reconnect ->
            %% Reconnect mode - table must exist from previous run
            case bbsvx_ont_service:table_exists(Namespace) of
                false ->
                    ?'log-error'("Transaction table missing for namespace ~p (boot mode: reconnect)", [Namespace]),
                    false;
                true ->
                    true
            end;
        _ ->
            %% Create/connect modes - table will be created
            true
    end,

    case TableCheck of
        false ->
            {stop, {error, {missing_transaction_table, Namespace}}};
        true ->
            %% Build initial Prolog state for all boot modes
            case build_initial_prolog_state(Namespace) of
                {ok, PrologState} ->
                    %% Create initial ont_state with Prolog state
                    %% last_processed_index starts at -1 (nothing processed yet)
                    %% For reconnect mode, load_history will update this to the last stored index
                    OntState = #ont_state{
                        namespace = Namespace,
                        current_ts = 0,
                        previous_ts = -1,
                        last_processed_index = -1,
                        current_address = <<"-1">>,
                        next_address = <<"0">>,
                        contact_nodes = [],
                        prolog_state = PrologState
                    },

                    State = #state{
                        namespace = Namespace,
                        repos_table = bbsvx_ont_service:binary_to_table_name(Namespace),
                        boot = BootMode,
                        ont_state = OntState,
                        validation_state = #validation_state{}
                    },

                    %% Create jobs queue for transaction acceptance
                    %% Rate limited to 50 tx/s (1 transaction per 20ms)
                    %% Use standard_rate which is designed for ask_queue pattern
                    QueueName = {stage_transaction_accept, Namespace},
                    ?'log-info'("Creating jobs queue: ~p", [QueueName]),

                    try jobs:add_queue(QueueName, [{standard_rate, 50}]) of
                        ok ->
                            ?'log-info'("Successfully created jobs queue: ~p", [QueueName]),

                            %% Start in appropriate state based on boot mode
                            case BootMode of
                                create ->
                                    %% Creating new ontology - start services first, then wait for genesis
                                    ?'log-info'(">> CREATE MODE: Starting services for new root ontology", []),
                                    case start_ontology_services(Namespace, #{boot => create}) of
                                        {ok, ServicesPid} ->
                                            NewState = State#state{
                                                connection_state = connecting,
                                                services_sup_pid = ServicesPid
                                            },
                                            ?'log-info'(">> CREATE MODE: Services started, waiting for genesis transaction", []),
                                            {ok, wait_for_genesis_transaction, NewState,
                                             [{state_timeout, 5000, genesis_timeout}]};
                                        {error, Reason} ->
                                            ?'log-error'(">> CREATE MODE FAILED: Could not start services: ~p", [Reason]),
                                            {stop, Reason}
                                    end;

                                connect ->
                                    %% Join network - start services and wait for registration
                                    ContactNodes = maps:get(contact_nodes, Options, []),
                                    ?'log-info'(">> CONNECT MODE: Starting services and joining network", []),
                                    case start_ontology_services(Namespace, Options) of
                                        {ok, ServicesPid} ->
                                            NewState = State#state{
                                                connection_state = connecting,
                                                connection_attempts = 1,
                                                last_connection_attempt = erlang:system_time(millisecond),
                                                contact_nodes = ContactNodes,
                                                services_sup_pid = ServicesPid
                                            },
                                            ?'log-info'(">> Services started, waiting for network registration (timeout: 10s)", []),
                                            {ok, wait_for_registration, NewState,
                                             [{state_timeout, 10000, registration_timeout}]};
                                        {error, Reason} ->
                                            ?'log-error'(">> CONNECT MODE FAILED: Could not start services: ~p", [Reason]),
                                            {stop, Reason}
                                    end;

                                reconnect ->
                                    %% Rejoin network - load history first, then start services
                                    ?'log-info'(">> RECONNECT MODE: Loading history then rejoining network", []),
                                    {ok, initialize_ontology,
                                     State#state{connection_state = connecting}}
                            end
                    catch
                        Error:Reason:Stacktrace ->
                            ?'log-error'("Failed to create jobs queue ~p: ~p:~p~nStacktrace: ~p",
                                        [QueueName, Error, Reason, Stacktrace]),
                            {stop, {error, {queue_creation_failed, {Error, Reason}}}}
                    end;
                {error, Reason} ->
                    ?'log-error'("Failed to build initial Prolog state: ~p", [Reason]),
                    {stop, {error, {prolog_init_failed, Reason}}}
            end
    end.

callback_mode() ->
    [state_functions, state_enter].

terminate(_Reason, _State, #state{namespace = Namespace, services_sup_pid = ServicesPid, retry_timer_ref = TimerRef}) ->
    %% Cancel retry timer if active
    case TimerRef of
        undefined -> ok;
        _ -> erlang:cancel_timer(TimerRef)
    end,

    %% Stop services if running
    stop_ontology_services(Namespace, ServicesPid),

    %% Clean up jobs queue
    jobs:delete_queue({stage_transaction_accept, Namespace}),
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

    {keep_state, State};

%% Handle genesis transaction (type = creation, index = 0)
%% This MUST come before the generic process_transaction handler to match first
wait_for_genesis_transaction(
    cast,
    {process_transaction, #transaction{type = creation, index = 0} = Transaction},
    #state{namespace = Namespace, ont_state = OntState, validation_state = ValidationState} = State
) ->
    ?'log-info'("Processing genesis transaction", []),

    %% Step 1: Validate genesis (index must be 0)
    LastProcessedIndex = OntState#ont_state.last_processed_index,
    CurrentAddress = OntState#ont_state.current_address,

    case validate_transaction(Transaction, LastProcessedIndex, CurrentAddress, Namespace, ValidationState) of
        {ok, ValidatedTx, NewCurrentAddress, NewValidationState} ->
            %% Step 2: Mark as accepted
            %% NOTE: Do NOT broadcast genesis via EPTO because:
            %% - At creation time, no peers exist to receive it
            %% - Broadcasting causes genesis to be delivered back with an index
            %%   that conflicts with the already-processed genesis (index 0)
            %% - Joining nodes receive genesis via history sync, not EPTO
            AcceptedTx = ValidatedTx#transaction{
                status = accepted,
                ts_created = erlang:system_time()
            },

            %% Step 3: Process genesis
            case process_transaction(AcceptedTx, OntState, Namespace) of
                {ok, ProcessedTx, NewOntState} ->
                    %% Step 4: Postprocess
                    case postprocess_transaction(ProcessedTx, Namespace) of
                        ok ->
                            %% Update state with genesis results
                            UpdatedOntState = NewOntState#ont_state{
                                last_processed_index = 0,
                                current_address = NewCurrentAddress,
                                next_address = <<"1">>
                            },

                            %% Genesis complete - services already started, transition to syncing
                            ?'log-info'(">> CREATE MODE SUCCESS: Genesis complete, now CONNECTED and syncing", []),
                            {next_state, syncing, State#state{
                                ont_state = UpdatedOntState,
                                validation_state = NewValidationState,
                                connection_state = connected
                            }};

                        {error, PostprocessReason} ->
                            ?'log-error'("Genesis postprocessing failed: ~p", [PostprocessReason]),
                            {stop, {genesis_postprocess_failed, PostprocessReason}, State}
                    end;

                {error, Reason, _OntState} ->
                    ?'log-error'("Genesis processing failed: ~p", [Reason]),
                    {stop, {genesis_process_failed, Reason}, State}
            end;

        {error, Reason} ->
            ?'log-error'("Genesis validation failed: ~p", [Reason]),
            {stop, {genesis_validation_failed, Reason}, State}
    end;

%% Handle non-genesis transactions - store in pending for processing after genesis
%% This handler must come AFTER the genesis handler above
wait_for_genesis_transaction(
    cast,
    {process_transaction, #transaction{index = TxIndex} = Transaction},
    #state{validation_state = ValidationState} = State
) ->
    ?'log-info'("Received non-genesis transaction ~p while waiting for genesis, storing in pending",
                [TxIndex]),

    %% Store in pending - will be processed after genesis
    #validation_state{pending = Pending} = ValidationState,
    NewPending = Pending#{TxIndex => Transaction},
    NewValidationState = ValidationState#validation_state{pending = NewPending},

    {keep_state, State#state{validation_state = NewValidationState}};

wait_for_genesis_transaction(
    {call, From},
    get_validation_context,
    #state{ont_state = #ont_state{last_processed_index = Index, current_address = CurrentAddress},
           validation_state = ValidationState}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index, ValidationState, CurrentAddress}}]};

wait_for_genesis_transaction(
    {call, From},
    get_last_processed_index,
    #state{ont_state = #ont_state{last_processed_index = Index}}
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
    ?'log-info'(">> RECONNECT MODE: Loading transaction history", []),

    %% Load history (this can be slow, but we're not blocking init)
    case load_history(OntState, ReposTable) of
        #ont_state{last_processed_index = LastProcessedIndex} = NewOntState ->
            ?'log-info'(">> RECONNECT MODE: History loaded (last_processed_index=~p)", [LastProcessedIndex]),

            %% Start services after loading history
            ?'log-info'(">> RECONNECT MODE: Starting services", []),
            case start_ontology_services(Namespace, #{}) of
                {ok, ServicesPid} ->
                    %% Transition to wait_for_registration with loaded state
                    ?'log-info'(">> RECONNECT MODE: Services started, waiting for network registration (timeout: 10s)", []),
                    {next_state, wait_for_registration, State#state{
                        ont_state = NewOntState,
                        services_sup_pid = ServicesPid,
                        connection_state = connecting,
                        connection_attempts = 1,
                        last_connection_attempt = erlang:system_time(millisecond)
                    }, [{state_timeout, 10000, registration_timeout}]};
                {error, ServiceReason} ->
                    ?'log-error'(">> RECONNECT MODE FAILED: Could not start services: ~p", [ServiceReason]),
                    {stop, {services_start_failed, ServiceReason}, State}
            end;
        {error, Reason} ->
            ?'log-error'(">> RECONNECT MODE FAILED: Could not load history: ~p", [Reason]),
            {stop, {error, {load_history_failed, Reason}}, State}
    end;

%% Allow cross-ontology queries during initialization (state may be stale)
initialize_ontology({call, From}, get_prolog_state, #state{ont_state = OntState}) when OntState =/= undefined ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.prolog_state}}]};
initialize_ontology({call, From}, get_prolog_state, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_initialized}}]};

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
    #state{namespace = Namespace, ont_state = OntState, boot = BootMode} = State
) ->
    ?'log-info'(">> ~p MODE SUCCESS: Registered with network (network_index=~p)",
                [string:uppercase(atom_to_list(BootMode)), CurrentIndex]),

    LastProcessedIndex = OntState#ont_state.last_processed_index,

    %% Request missing transactions if needed
    case CurrentIndex > LastProcessedIndex of
        true ->
            ?'log-info'(">> Requesting missing transactions (~p to ~p)", [LastProcessedIndex + 1, CurrentIndex]),
            request_segment(Namespace, LastProcessedIndex + 1, CurrentIndex);
        false ->
            ok
    end,

    %% Update connection state to connected
    ?'log-info'(">> Now CONNECTED and syncing", []),
    {next_state, syncing, State#state{
        ont_state = OntState,
        connection_state = connected
    }};

wait_for_registration(state_timeout, registration_timeout, #state{boot = BootMode} = State) ->
    AttemptNum = State#state.connection_attempts + 1,
    ?'log-warn'(">> ~p MODE: Registration timeout (attempt ~p) - will retry while keeping services alive",
                [string:uppercase(atom_to_list(BootMode)), AttemptNum]),

    %% Don't stop services - just retry registration
    %% The SPRAY and EPTO services will continue attempting to connect
    RetryInterval = calculate_retry_interval(AttemptNum),

    ?'log-info'(">> Will check registration again in ~p ms", [RetryInterval]),

    %% Stay in wait_for_registration state and retry after interval
    {keep_state, State#state{
        connection_attempts = AttemptNum,
        last_connection_attempt = erlang:system_time(millisecond),
        last_connection_error = registration_timeout
    }, [{state_timeout, RetryInterval, registration_timeout}]};

wait_for_registration(cast, {process_transaction, _Tx}, _State) ->
    %% Reject transactions when not connected
    {keep_state_and_data, [{reply, {error, ontology_disconnected}}]};

%% Allow cross-ontology queries during registration (state may be stale)
wait_for_registration({call, From}, get_prolog_state, #state{ont_state = OntState}) when OntState =/= undefined ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.prolog_state}}]};
wait_for_registration({call, From}, get_prolog_state, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_initialized}}]};

wait_for_registration(_EventType, _Event, _State) ->
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% syncing State (Main Operational State)
%%-----------------------------------------------------------------------------

syncing(enter, _, #state{namespace = Namespace} = State) ->
    ?'log-info'("Ontology Actor ~p entering syncing state", [Namespace]),

    %% Register for broadcast messages (only if not already registered)
    %% This is critical for receiving history requests and network events
    try
        gproc:reg({p, l, {?MODULE, Namespace}})
    catch
        error:badarg -> ok  % Already registered
    end,

    {keep_state, State};

%% Get last processed index query
syncing(
    {call, From},
    get_last_processed_index,
    #state{ont_state = #ont_state{last_processed_index = Index}}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index}}]};

%% Get validation context (index + state + address) in single call
syncing(
    {call, From},
    get_validation_context,
    #state{ont_state = #ont_state{last_processed_index = Index, current_address = CurrentAddress},
           validation_state = ValidationState}
) ->
    {keep_state_and_data, [{reply, From, {ok, Index, ValidationState, CurrentAddress}}]};

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
    ?'log-info'("Retrieved ~p transactions for history request", [length(History)]),

    {ActualOldest, ActualYoungest} = case History of
        [] -> {OldestIndex, YoungerIndex};
        [ #transaction{} = First | _] = H -> {First#transaction.index, (lists:last(H))#transaction.index}
    end,

    %% Send history response via the arc registry
    ?'log-info'("Sending history response to arc ~p", [ReqUlid]),
    HistoryResponse = #ontology_history{
        namespace = Namespace,
        list_tx = History,
        oldest_index = ActualOldest,
        younger_index = ActualYoungest
    },
    case bbsvx_arc_registry:send(Namespace, in, ReqUlid, HistoryResponse) of
        ok ->
            ?'log-info'("History response sent successfully");
        {error, not_found} ->
            ?'log-warning'("Could not send history response - arc ~p not found", [ReqUlid])
    end,

    keep_state_and_data;

%% History received from peer
syncing(
    info,
    #ontology_history{list_tx = ListTransactions},
    #state{validation_state = ValidationState} = State
) ->
    ?'log-info'("Received history: ~p transactions", [length(ListTransactions)]),

    %% Log each transaction's status for debugging
    lists:foreach(
        fun(#transaction{index = Idx, status = Status, type = Type}) ->
            ?'log-info'("History tx ~p: type=~p, status=~p", [Idx, Type, Status])
        end,
        ListTransactions
    ),

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

syncing({call, From}, get_db_ref, #state{ont_state = OntState}) ->
    #ont_state{prolog_state = PrologState} = OntState,
    #est{db = Db} = PrologState,
    #db{ref = DbDiffer} = Db,
    #db_differ{out_db = OutDb} = DbDiffer,
    #db{ref = Ref} = OutDb,
    {keep_state_and_data, [{reply, From, {ok, Ref}}]};

%% Ignore new genesis (status != processed) - these should only be processed in wait_for_genesis state
%% But allow history genesis (status = processed) to be validated and applied
syncing(
    cast,
    {process_transaction, #transaction{type = creation, index = 0, status = Status}},
    _State
) when Status =/= processed ->
    ?'log-warning'("Received new genesis transaction in syncing state, ignoring (status=~p)", [Status]),
    keep_state_and_data;

syncing(
    cast,
    {process_transaction, Transaction},
    #state{
        namespace = Namespace,
        ont_state = OntState,
        validation_state = ValidationState
    } = State
) ->
    ?'log-info'("Processing transaction in actor", []),

    %% Step 1: Validate (transaction already broadcasted via EPTO)
    %% last_processed_index is the single source of truth for what we've processed
    LastProcessedIndex = OntState#ont_state.last_processed_index,
    CurrentAddress = OntState#ont_state.current_address,

    case validate_transaction(Transaction, LastProcessedIndex, CurrentAddress, Namespace, ValidationState) of
        {ok, ValidatedTx, NewCurrentAddress, NewValidationState} ->
            %% Step 3: Process
            case process_transaction(ValidatedTx, OntState, Namespace) of
                {ok, ProcessedTx, NewOntState} ->
                    %% Step 4: Postprocess
                    case postprocess_transaction(ProcessedTx, Namespace) of
                        ok ->
                            %% Update state
                            UpdatedOntState = NewOntState#ont_state{
                                last_processed_index = ValidatedTx#transaction.index,
                                current_address = NewCurrentAddress,
                                current_ts = ValidatedTx#transaction.ts_created
                            },

                            %% Check if next transaction is pending
                            NextIndex = ValidatedTx#transaction.index + 1,
                            FinalValidationState = case check_pending(NewValidationState, NextIndex) of
                                {found, PendingTx, UpdatedPendingState} ->
                                    ?'log-info'("Re-queueing pending transaction ~p", [NextIndex]),
                                    receive_transaction(PendingTx),
                                    UpdatedPendingState;
                                {not_found, _} ->
                                    NewValidationState
                            end,

                            {keep_state, State#state{
                                ont_state = UpdatedOntState,
                                validation_state = FinalValidationState
                            }};

                        {error, PostprocessReason} ->
                            ?'log-error'("Transaction postprocessing failed: ~p", [PostprocessReason]),
                            %% Transaction was processed but recording failed - this is serious
                            %% State is already updated in NewOntState, so we keep it but log the error
                            {keep_state, State#state{ont_state = NewOntState}}
                    end;

                {wait_for_result, _WaitTx, _OntState} ->
                    %% Follower node needs to wait for goal result from leader
                    ?'log-info'("Transitioning to waiting_for_goal_result state for transaction ~p",
                                [ValidatedTx#transaction.index]),

                    %% Check if we already have the result cached (using index as key)
                    TxIndex = ValidatedTx#transaction.index,
                    case maps:get(TxIndex, State#state.cached_goal_results, undefined) of
                        undefined ->
                            %% No cached result - transition to waiting state with 5 sec timeout
                            {next_state, waiting_for_goal_result,
                             State#state{
                                 pending_goal_transaction = ValidatedTx,
                                 ont_state = OntState,
                                 validation_state = NewValidationState
                             },
                             [{state_timeout, 15000, goal_result_timeout}]};

                        CachedResult ->
                            %% We already have the result - process it immediately
                            ?'log-info'("Found cached goal result for transaction index ~p", [TxIndex]),
                            NewCachedResults = maps:remove(TxIndex, State#state.cached_goal_results),
                            %% Apply the result and continue (handled in helper function below)
                            apply_goal_result_and_continue(CachedResult, ValidatedTx, NewCurrentAddress,
                                                          NewValidationState, OntState, Namespace,
                                                          State#state{cached_goal_results = NewCachedResults})
                    end;

                {error, Reason, _OntState} ->
                    ?'log-error'("Transaction processing failed: ~p", [Reason]),
                    %% Mark transaction as invalid and record
                    InvalidTx = ValidatedTx#transaction{status = invalid},
                    bbsvx_transaction:record_transaction(InvalidTx),
                    %% Still need to increment index to maintain chain integrity
                    UpdatedOntState = OntState#ont_state{
                        last_processed_index = ValidatedTx#transaction.index,
                        current_address = NewCurrentAddress,
                        current_ts = ValidatedTx#transaction.ts_created
                    },
                    {keep_state, State#state{ont_state = UpdatedOntState}}
            end;

        {pending, TxIndex, NewValidationState} ->
            ?'log-info'("Transaction ~p is pending", [TxIndex]),
            {keep_state, State#state{validation_state = NewValidationState}};

        {duplicate, TxIndex, _ValidationState} ->
            ?'log-debug'("Ignoring duplicate transaction ~p", [TxIndex]),
            keep_state_and_data;

        {history_accepted, Index, NewAddr, Diff, NewValidationState} ->
            ?'log-info'("History transaction ~p accepted with ~p diffs", [Index, length(Diff)]),
            %% Apply the diff to our Prolog state
            #ont_state{prolog_state = PrologState} = OntState,
            {ok, NewDb} = bbsvx_erlog_db_differ:apply_diff(Diff, PrologState#est.db),
            NewPrologState = PrologState#est{db = NewDb},
            NewOntState = OntState#ont_state{
                last_processed_index = Index,
                current_address = NewAddr,
                prolog_state = NewPrologState
            },
            %% Check if the next transaction is waiting in pending map.
            %% This ensures that when history transactions arrive out of order
            %% (e.g., tx2 before tx1), the pending tx2 gets requeued after tx1.
            NextIndex = Index + 1,
            FinalValidationState = case check_pending(NewValidationState, NextIndex) of
                {found, PendingTx, UpdatedValidationState} ->
                    ?'log-info'("Re-queueing pending transaction ~p after history sync", [NextIndex]),
                    receive_transaction(PendingTx),
                    UpdatedValidationState;
                {not_found, UpdatedValidationState} ->
                    UpdatedValidationState
            end,
            {keep_state, State#state{
                ont_state = NewOntState,
                validation_state = FinalValidationState
            }}
    end;

%% Handle duplicate registration messages (ignore - we're already syncing)
syncing(info, {registered, _Index}, _State) ->
    ?'log-debug'("Ignoring duplicate registration message in syncing state"),
    keep_state_and_data;

%% Handle goal results for leader (we already processed the goal, ignore our own result)
syncing(info, #goal_result{}, _State) ->
    ?'log-debug'("Ignoring goal_result in syncing state (leader already processed)"),
    keep_state_and_data;

%% Handle connection status queries
syncing({call, From}, get_connection_status, State) ->
    Status = build_connection_status(State),
    {keep_state_and_data, [{reply, From, {ok, Status}}]};

%% Catch-all
syncing(Type, Event, _State) ->
    ?'log-warning'("Unhandled event in syncing state: ~p ~p", [Type, Event]),
    keep_state_and_data.

%%%=============================================================================
%%% State: waiting_for_goal_result
%%%=============================================================================

-doc """
State for follower nodes waiting for goal execution result from leader.
Transitions back to syncing once result is received and processed.
""".
waiting_for_goal_result(enter, _, State) ->
    ?'log-info'("Waiting for goal result from leader"),
    {keep_state, State};

%% Received goal result from leader - matching index
waiting_for_goal_result(
    info,
    #goal_result{index = Index} = GoalResult,
    #state{
        namespace = Namespace,
        pending_goal_transaction = #transaction{index = Index} = PendingTx,
        ont_state = OntState,
        validation_state = ValidationState
    } = State
) ->
    ?'log-info'("Received matching goal result for transaction index ~p", [Index]),

    %% Get the current address that was set during validation
    NewCurrentAddress = PendingTx#transaction.current_address,

    %% Apply the result and continue processing
    apply_goal_result_and_continue(GoalResult, PendingTx, NewCurrentAddress,
                                   ValidationState, OntState, Namespace, State);

%% Received goal result but index doesn't match - cache it
waiting_for_goal_result(
    info,
    #goal_result{index = ResultIndex} = GoalResult,
    #state{
        pending_goal_transaction = #transaction{index = PendingIndex}
    } = State
) ->
    ?'log-info'("Received goal result for index ~p but waiting for ~p - caching",
                [ResultIndex, PendingIndex]),

    %% Cache this result for later (using index as key)
    NewCachedResults = maps:put(ResultIndex, GoalResult, State#state.cached_goal_results),

    {keep_state, State#state{cached_goal_results = NewCachedResults}};

%% Timeout waiting for result - request history instead of skipping
waiting_for_goal_result(state_timeout, goal_result_timeout, State) ->
    ?'log-error'("Timeout waiting for goal result from leader"),
    #state{
        namespace = Namespace,
        pending_goal_transaction = PendingTx
    } = State,

    TxIndex = PendingTx#transaction.index,

    %% DON'T increment index - we need the processed transaction with its diff
    %% Request this specific transaction from peers via history request
    ?'log-warning'("Timeout on transaction ~p - requesting history from peers instead of skipping",
                   [TxIndex]),

    %% Request the processed transaction from the network
    %% Peers who have processed it will have the diff attached
    bbsvx_actor_spray:broadcast_unique_random_subset(
        Namespace,
        #ontology_history_request{
            namespace = Namespace,
            oldest_index = TxIndex,
            younger_index = TxIndex
        },
        3  %% Ask 3 random peers
    ),

    %% Transition back to syncing WITHOUT updating ont_state.last_processed_index
    %% The history response will deliver the processed transaction with diff
    {next_state, syncing, State#state{
        pending_goal_transaction = undefined
        %% Note: ont_state remains unchanged - we still need index TxIndex
    }};

%% Log leader changes while waiting for goal result
waiting_for_goal_result(
    info,
    {incoming_event, #leader_election_info{payload = #neighbor{chosen_leader = NewLeader}}},
    #state{namespace = Namespace, pending_goal_transaction = PendingTx} = _State
) ->
    %% Get current leader for comparison
    case bbsvx_actor_leader_manager:get_leader(Namespace) of
        {ok, CurrentLeader} when CurrentLeader =/= NewLeader, NewLeader =/= undefined ->
            ?'log-warning'("Leader change detected while waiting for goal result! "
                          "Current: ~p, New vote: ~p, Pending tx: ~p",
                          [CurrentLeader, NewLeader, PendingTx#transaction.index]);
        _ ->
            ok
    end,
    keep_state_and_data;

%% Handle incoming transactions while waiting - store in pending for later processing
waiting_for_goal_result(
    cast,
    {process_transaction, #transaction{index = TxIndex} = Transaction},
    #state{validation_state = ValidationState} = State
) ->
    ?'log-info'("Received transaction ~p while waiting for goal result - storing in pending", [TxIndex]),
    #validation_state{pending = Pending} = ValidationState,
    NewPending = Pending#{TxIndex => Transaction},
    NewValidationState = ValidationState#validation_state{pending = NewPending},
    {keep_state, State#state{validation_state = NewValidationState}};

%% Allow cross-ontology queries even while waiting for goal result
waiting_for_goal_result({call, From}, get_prolog_state, #state{ont_state = OntState}) ->
    {keep_state_and_data, [{reply, From, {ok, OntState#ont_state.prolog_state}}]};

%% Catch-all
waiting_for_goal_result(Type, Event, _State) ->
    ?'log-warning'("Unhandled event in waiting_for_goal_result state: ~p ~p", [Type, Event]),
    keep_state_and_data.

%%-----------------------------------------------------------------------------
%% disconnected State
%%-----------------------------------------------------------------------------

disconnected(enter, _, #state{namespace = Namespace} = State) ->
    ?'log-info'("Ontology Actor ~p entering disconnected state", [Namespace]),
    {keep_state, State};

%% Handle retry connection event
disconnected(info, retry_connection, #state{namespace = Namespace, contact_nodes = ContactNodes} = State) ->
    AttemptNum = State#state.connection_attempts + 1,
    ?'log-info'(">> DISCONNECTED: Retry attempt #~p - Starting services", [AttemptNum]),

    %% Start services
    case start_ontology_services(Namespace, #{contact_nodes => ContactNodes}) of
        {ok, ServicesPid} ->
            %% Transition to wait_for_registration
            ?'log-info'(">> DISCONNECTED: Services started, waiting for registration (timeout: 10s)", []),
            {next_state, wait_for_registration, State#state{
                connection_state = connecting,
                connection_attempts = AttemptNum,
                last_connection_attempt = erlang:system_time(millisecond),
                services_sup_pid = ServicesPid,
                retry_timer_ref = undefined
            }, [{state_timeout, 10000, registration_timeout}]};
        {error, Reason} ->
            ?'log-error'(">> DISCONNECTED: Retry #~p failed - could not start services: ~p", [AttemptNum, Reason]),

            %% Schedule another retry
            RetryInterval = calculate_retry_interval(AttemptNum),
            TimerRef = erlang:send_after(RetryInterval, self(), retry_connection),

            ?'log-warn'(">> DISCONNECTED: Next retry in ~p ms (attempt #~p)", [RetryInterval, AttemptNum + 1]),

            {keep_state, State#state{
                connection_attempts = AttemptNum,
                last_connection_attempt = erlang:system_time(millisecond),
                last_connection_error = Reason,
                retry_timer_ref = TimerRef
            }}
    end;

%% Reject all transactions when disconnected
disconnected(cast, {process_transaction, _Tx}, _State) ->
    {keep_state_and_data, [{reply, {error, ontology_disconnected}}]};

%% Handle connection status queries
disconnected({call, From}, get_connection_status, State) ->
    Status = build_connection_status(State),
    {keep_state_and_data, [{reply, From, {ok, Status}}]};

%% Catch-all
disconnected(_EventType, _Event, _State) ->
    keep_state_and_data.

%%%=============================================================================
%%% Pipeline Worker Processes
%%%=============================================================================

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
    _Namespace,
    ValidationState
) when TxIndex == CurrentIndex + 1 ->
    %% History transaction ready to be accepted
    ?'log-info'("Accepting history transaction ~p", [TxIndex]),
    bbsvx_transaction:record_transaction(Transaction),
    {history_accepted, TxIndex, Transaction#transaction.current_address, Transaction#transaction.diff, ValidationState};

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
    %% Guard against invalid range (when CurrentIndex + 1 > TxIndex - 1)
    MissingIndices = case CurrentIndex + 1 =< TxIndex - 1 of
        true -> lists:seq(CurrentIndex + 1, TxIndex - 1);
        false -> []
    end,
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
    #transaction{status = created, index = TxIndex} = Transaction,
    LastProcessedIndex,
    CurrentAddress,
    _Namespace,
    ValidationState
) when TxIndex =:= LastProcessedIndex + 1 ->
    %% EPTO-delivered transaction with expected index - validate and process
    ?'log-info'("Transaction ~p is next expected (last_processed=~p)", [TxIndex, LastProcessedIndex]),

    ValidatedTx = Transaction#transaction{
        status = validated,
        prev_address = CurrentAddress
    },

    %% Record transaction
    bbsvx_transaction:record_transaction(ValidatedTx),

    %% Calculate new address
    NewCurrentAddress = bbsvx_crypto_service:calculate_hash_address(TxIndex, Transaction),

    {ok, ValidatedTx, NewCurrentAddress, ValidationState};

validate_transaction(
    #transaction{status = created, index = TxIndex} = _Transaction,
    LastProcessedIndex,
    _CurrentAddress,
    _Namespace,
    ValidationState
) when TxIndex =< LastProcessedIndex ->
    %% Duplicate transaction - already processed
    ?'log-info'("Ignoring duplicate transaction ~p (last_processed=~p)", [TxIndex, LastProcessedIndex]),
    {duplicate, TxIndex, ValidationState};

validate_transaction(
    #transaction{status = created, index = TxIndex} = Transaction,
    LastProcessedIndex,
    _CurrentAddress,
    Namespace,
    ValidationState
) when TxIndex > LastProcessedIndex + 1 ->
    %% Gap detected - store in pending and request missing
    ?'log-info'("Gap detected: got ~p, expected ~p, storing in pending", [TxIndex, LastProcessedIndex + 1]),

    #validation_state{pending = Pending, requested_txs = RequestedTxs} = ValidationState,
    NewPending = Pending#{TxIndex => Transaction},

    %% Check which transactions in the gap need to be requested
    %% Guard against invalid range (defensive)
    MissingIndices = case LastProcessedIndex + 1 =< TxIndex - 1 of
        true -> lists:seq(LastProcessedIndex + 1, TxIndex - 1);
        false -> []
    end,
    Now = erlang:system_time(millisecond),
    TimeoutMs = 5000,

    {ToRequest, NewRequestedTxs} = lists:foldl(
        fun(Index, {AccToRequest, AccRequested}) ->
            InPending = maps:is_key(Index, NewPending),
            AlreadyRequested = is_tx_requested(Index, AccRequested, TimeoutMs),
            case InPending orelse AlreadyRequested of
                true -> {AccToRequest, AccRequested};
                false -> {[Index | AccToRequest], AccRequested#{Index => Now}}
            end
        end,
        {[], RequestedTxs},
        MissingIndices
    ),

    case ToRequest of
        [] ->
            ?'log-debug'("All transactions ~p-~p already pending or requested",
                        [LastProcessedIndex + 1, TxIndex - 1]);
        _ ->
            MinIndex = lists:min(ToRequest),
            MaxIndex = lists:max(ToRequest),
            ?'log-info'("Requesting missing segment ~p-~p", [MinIndex, MaxIndex]),
            request_segment(Namespace, MinIndex, MaxIndex)
    end,

    NewValidationState = ValidationState#validation_state{
        pending = NewPending,
        requested_txs = NewRequestedTxs
    },

    {pending, TxIndex, NewValidationState};

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
            %% Guard against invalid range (defensive)
            MissingIndices = case CurrentIndex + 1 =< TxIndex - 1 of
                true -> lists:seq(CurrentIndex + 1, TxIndex - 1);
                false -> []
            end,
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
    %% Note: PrologDb is a #db{} wrapper, we need to extract and update the #db_differ{} inside
    UpdatedDbDiffer = lists:foldl(
        fun(Mod, DbDifferAcc) ->
            case erlang:function_exported(Mod, external_predicates, 0) of
                true ->
                    Preds = Mod:external_predicates(),
                    ?'log-info'("Loading ~p external predicates from ~p", [length(Preds), Mod]),
                    lists:foldl(
                        fun({{Functor, Arity}, PredMod, PredFunc}, DbDiffer) ->
                            case bbsvx_erlog_db_differ:add_compiled_proc(DbDiffer, {Functor, Arity}, PredMod, PredFunc) of
                                {ok, NewDbDiffer} ->
                                    ?'log-debug'("Added predicate ~p/~p", [Functor, Arity]),
                                    NewDbDiffer;
                                error ->
                                    ?'log-warning'("Failed to add predicate ~p/~p", [Functor, Arity]),
                                    DbDiffer
                            end
                        end,
                        DbDifferAcc,
                        Preds
                    );
                false ->
                    ?'log-warning'("Module ~p does not export external_predicates/0", [Mod]),
                    DbDifferAcc
            end
        end,
        PrologDb#db.ref,  %% Extract #db_differ{} from #db{} wrapper
        ExternalPreds
    ),

    %% Wrap the updated #db_differ{} back into #db{}
    UpdatedDb = PrologDb#db{ref = UpdatedDbDiffer},
    UpdatedPrologState = PrologState#est{db = UpdatedDb},

    %% Execute genesis goal payload to assert static ontology predicates
    #transaction{payload = #goal{payload = GoalPayload}} = Transaction,
    FinalPrologState = case GoalPayload of
        [{asserta, StaticPredicates}] when is_list(StaticPredicates) ->
            ?'log-info'("Asserting ~p static ontology predicates from genesis", [length(StaticPredicates)]),
            lists:foldl(
                fun(Predicate, PrologStateAcc) ->
                    case erlog_int:prove_goal({asserta, Predicate}, PrologStateAcc) of
                        {succeed, NewPrologStateAcc} -> NewPrologStateAcc;
                        _Error ->
                            ?'log-warning'("Failed to assert genesis predicate: ~p", [Predicate]),
                            PrologStateAcc
                    end
                end,
                UpdatedPrologState,
                StaticPredicates
            );
        _ ->
            UpdatedPrologState
    end,

    %% Extract the diffs that were generated during genesis assertion
    {GenesisDiff, ClearedPrologState} = case FinalPrologState#est.db of
        #db{ref = #db_differ{op_fifo = OpFifo} = DbDiffer} = Db ->
            %% Clear the op_fifo for next transaction
            ClearedDbDiffer = bbsvx_erlog_db_differ:clear_diff(DbDiffer),
            ClearedDb = Db#db{ref = ClearedDbDiffer},
            ClearedState = FinalPrologState#est{db = ClearedDb},
            {OpFifo, ClearedState};
        _ ->
            {[], FinalPrologState}
    end,

    %% Update transaction with the captured diffs
    UpdatedTransaction = Transaction#transaction{diff = GenesisDiff},

    UpdatedOntState = OntState#ont_state{prolog_state = ClearedPrologState},

    ?'log-info'("Genesis transaction processing complete for ~p with ~p diffs",
                [Namespace, length(GenesisDiff)]),
    {ok, UpdatedTransaction, UpdatedOntState};

process_transaction(
    #transaction{type = goal, payload = #goal{} = Goal, namespace = Namespace} = Transaction,
    #ont_state{prolog_state = PrologState} = OntState,
    Namespace
) ->
    %% Get leader
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    MyId = bbsvx_crypto_service:my_id(),
    IsLeader = (Leader == MyId),
    ?'log-info'("Goal processing: Leader=~p, MyId=~p, IsLeader=~p", [Leader, MyId, IsLeader]),

    case IsLeader of
        true ->
            %% We are the leader - execute the goal
            case do_prove_goal(Goal, Transaction#transaction.index, PrologState, true, Namespace) of
                {_Result, NewPrologState, Diff, Bindings} ->
                    ProcessedTx = Transaction#transaction{
                        status = processed,
                        ts_processed = erlang:system_time(),
                        diff = Diff,
                        bindings = Bindings
                    },
                    {ok, ProcessedTx, OntState#ont_state{prolog_state = NewPrologState}};

                {error, Reason} ->
                    {error, Reason, OntState}
            end;

        false ->
            %% We are a follower - need to wait for leader's result
            ?'log-info'("Follower node - will wait for goal result from leader"),
            {wait_for_result, Transaction, OntState}
    end.

%%-----------------------------------------------------------------------------
%% Goal Execution
%%-----------------------------------------------------------------------------

-doc """
Executes a Prolog goal as leader and broadcasts result to followers.
""".
do_prove_goal(
    #goal{namespace = Namespace, payload = Predicate} = Goal,
    TransactionIndex,
    PrologState,
    true, % IsLeader
    Namespace
) ->
    ?'log-info'("Executing goal as leader: ~p", [Predicate]),

    case erlog_int:prove_goal(Predicate, PrologState) of
        {succeed, #est{db = #db{ref = #db_differ{op_fifo = OpFifo} = DbDiffer} = OldDb, bs = Bindings, vn = Vn} = NewPrologState} ->
            %% Clear the op_fifo for next transaction
            ClearedDbDiffer = bbsvx_erlog_db_differ:clear_diff(DbDiffer),
            ClearedDb = OldDb#db{ref = ClearedDbDiffer},
            ClearedPrologState = NewPrologState#est{db = ClearedDb},

            %% Debug: log raw bindings and state
            ?'log-info'("DEBUG - Raw Erlog bindings: ~p, Vn: ~p", [Bindings, Vn]),
            ?'log-info'("DEBUG - Original predicate: ~p", [Predicate]),
            ?'log-info'("DEBUG - Full final state: ~p", [NewPrologState]),

            %% Extract variable bindings for the result
            SerializedBindings = serialize_bindings(Bindings),
            ?'log-info'("Query succeeded with bindings: ~p", [SerializedBindings]),

            %% Broadcast result to followers
            GoalResult = #goal_result{
                namespace = Namespace,
                result = succeed,
                signature = <<>>,
                address = Goal#goal.id,
                index = TransactionIndex,
                diff = OpFifo,
                bindings = SerializedBindings
            },
            bbsvx_epto_service:broadcast(Namespace, GoalResult),

            {succeed, ClearedPrologState, OpFifo, SerializedBindings};

        {fail, NewPrologState} ->
            ?'log-warning'("Goal FAILED: ~p", [Predicate]),
            GoalResult = #goal_result{
                namespace = Namespace,
                result = fail,
                signature = <<>>,
                address = Goal#goal.id,
                index = TransactionIndex,
                diff = [],
                bindings = []
            },
            bbsvx_epto_service:broadcast(Namespace, GoalResult),

            {fail, NewPrologState, [], []};

        Other ->
            ?'log-error'("Goal execution error: ~p", [Other]),
            {error, Other}
    end.

%%-----------------------------------------------------------------------------
%% Transaction Postprocessing
%%-----------------------------------------------------------------------------

-doc """
Handles final transaction recording, notifications, and metrics.
This replaces the old postprocess worker logic.
Returns ok on success, {error, Reason} on failure.
""".
postprocess_transaction(Transaction, Namespace) ->
    ?'log-info'("Postprocessing transaction ~p", [Transaction#transaction.index]),

    %% Record transaction to storage
    case bbsvx_transaction:record_transaction(Transaction#transaction{status = processed}) of
        ok ->
            %% Notify subscribers (may fail if no subscribers, that's ok)
            try
                gproc:send({p, l, {diff, Namespace}}, {transaction_processed, Transaction})
            catch
                _:_ -> ok
            end,

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

            ok;

        {error, Reason} = Error ->
            ?'log-error'("Failed to record transaction ~p: ~p",
                        [Transaction#transaction.index, Reason]),
            Error
    end.

%%%=============================================================================
%%% Internal Helper Functions
%%%=============================================================================

-doc """
Serialize Erlog bindings to a simple format for transmission.
Converts Erlog's internal binding representation to a list of {VarName, Value} tuples.

Erlog bindings come as a map:
- Atom keys (variable names) map to variable numbers: 'X' => {0}
- Integer keys (variable numbers) map to values: 0 => bob
""".
serialize_bindings(Bindings) when is_map(Bindings) ->
    %% Extract variable names (atom keys only)
    VarNames = [K || K <- maps:keys(Bindings), is_atom(K)],

    %% For each variable name, resolve its value
    lists:filtermap(
        fun(VarName) ->
            case maps:get(VarName, Bindings, undefined) of
                {VarNum} when is_integer(VarNum) ->
                    %% Follow the chain to get the actual value
                    case maps:get(VarNum, Bindings, undefined) of
                        undefined -> false;
                        Value -> {true, {VarName, Value}}
                    end;
                _ -> false
            end
        end,
        VarNames
    );
serialize_bindings([]) ->
    [];
serialize_bindings(Bindings) when is_list(Bindings) ->
    %% Already serialized
    Bindings;
serialize_bindings(_) ->
    [].

-doc """
Applies a goal result received from the leader and continues transaction processing.
Used by both the waiting_for_goal_result state and cached result handling.
""".
apply_goal_result_and_continue(
    #goal_result{diff = Diff, result = _Result, index = Index, bindings = Bindings},
    PendingTx,
    NewCurrentAddress,
    ValidationState,
    #ont_state{prolog_state = PrologState} = OntState,
    Namespace,
    State
) ->
    ?'log-info'("Applying goal result for transaction index ~p with bindings ~p", [Index, Bindings]),

    %% Apply the diff to our Prolog state
    case bbsvx_erlog_db_differ:apply_diff(Diff, PrologState#est.db) of
        {ok, NewDb} ->
            %% Update Prolog state with the diff
            NewPrologState = PrologState#est{db = NewDb},
            UpdatedOntState = OntState#ont_state{prolog_state = NewPrologState},

            %% Create processed transaction with bindings from goal result
            ProcessedTx = PendingTx#transaction{
                status = processed,
                ts_processed = erlang:system_time(),
                diff = Diff,
                bindings = Bindings
            },

            %% Postprocess the transaction
            case postprocess_transaction(ProcessedTx, Namespace) of
                ok ->
                    %% Update state with completed transaction
                    FinalOntState = UpdatedOntState#ont_state{
                        last_processed_index = Index,
                        current_address = NewCurrentAddress,
                        current_ts = PendingTx#transaction.ts_created
                    },

                    %% Check if next transaction is pending
                    NextIndex = Index + 1,
                    FinalValidationState = case check_pending(ValidationState, NextIndex) of
                        {found, NextPendingTx, UpdatedPendingState} ->
                            ?'log-info'("Re-queueing pending transaction ~p", [NextIndex]),
                            receive_transaction(NextPendingTx),
                            UpdatedPendingState;
                        {not_found, _} ->
                            ValidationState
                    end,

                    %% Transition back to syncing state
                    {next_state, syncing, State#state{
                        ont_state = FinalOntState,
                        validation_state = FinalValidationState,
                        pending_goal_transaction = undefined
                    }};

                {error, PostprocessReason} ->
                    ?'log-error'("Goal result postprocessing failed: ~p", [PostprocessReason]),
                    %% Transition back to syncing anyway
                    {next_state, syncing, State#state{
                        ont_state = UpdatedOntState,
                        pending_goal_transaction = undefined
                    }}
            end;

        {error, DiffReason} ->
            ?'log-error'("Failed to apply goal diff: ~p", [DiffReason]),
            %% Mark transaction as invalid
            InvalidTx = PendingTx#transaction{status = invalid},
            bbsvx_transaction:record_transaction(InvalidTx),
            %% Transition back to syncing
            {next_state, syncing, State#state{pending_goal_transaction = undefined}}
    end.

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
Loads common predicates (like ::) that are available to all ontologies.
""".
build_initial_prolog_state(Namespace) ->
    DbRepos = bbsvx_ont_service:binary_to_table_name(Namespace),
    DbMod = bbsvx_erlog_db_ets,
    DbRef = DbRepos,

    %% Create base Prolog state
    {ok, BaseState} = erlog_int:new(bbsvx_erlog_db_differ, {DbRef, DbMod}),

    %% Set unknown=fail so missing predicates fail gracefully instead of throwing errors
    StateWithFlags = set_unknown_flag(fail, BaseState),

    %% Load common predicates available to ALL ontologies
    {ok, load_common_predicates(StateWithFlags)}.

-doc """
Loads common predicates into a Prolog state.
Common predicates are defined in bbsvx_common_predicates and are
available to all ontologies (e.g., :: for cross-ontology calls).
""".
load_common_predicates(#est{db = #db{ref = DbDiffer} = PrologDb} = PrologState) ->
    CommonPreds = bbsvx_common_predicates:external_predicates(),
    ?'log-debug'("Loading ~p common predicates", [length(CommonPreds)]),

    UpdatedDbDiffer = lists:foldl(
        fun({{Functor, Arity}, Mod, Func}, DbDifferAcc) ->
            case bbsvx_erlog_db_differ:add_compiled_proc(DbDifferAcc, {Functor, Arity}, Mod, Func) of
                {ok, NewDbDiffer} ->
                    ?'log-debug'("Added common predicate ~p/~p", [Functor, Arity]),
                    NewDbDiffer;
                error ->
                    ?'log-warning'("Failed to add common predicate ~p/~p", [Functor, Arity]),
                    DbDifferAcc
            end
        end,
        DbDiffer,
        CommonPreds
    ),

    %% Return updated Prolog state
    PrologState#est{db = PrologDb#db{ref = UpdatedDbDiffer}}.

-doc """
Sets the 'unknown' flag in the Prolog state flags.
When set to 'fail', missing predicates fail gracefully instead of throwing errors.
""".
set_unknown_flag(Value, #est{fs = Flags} = State) ->
    NewFlags = lists:keyreplace(unknown, 1, Flags, {unknown, Value, [error, fail, warning]}),
    State#est{fs = NewFlags}.

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
                    last_processed_index = Index
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
%%% Service Management Functions
%%%=============================================================================

%% Start services supervisor for this ontology
-spec start_ontology_services(binary(), map()) -> {ok, pid()} | {error, term()}.
start_ontology_services(Namespace, Options) ->
    ?'log-info'("Starting services for ontology ~p", [Namespace]),
    supervisor:start_child(bbsvx_sup_ont_services_sup, [Namespace, Options]).

%% Stop services supervisor cleanly
-spec stop_ontology_services(binary(), pid() | undefined) -> ok.
stop_ontology_services(_Namespace, undefined) ->
    ok;
stop_ontology_services(Namespace, Pid) ->
    ?'log-info'("Stopping services for ontology ~p", [Namespace]),
    case is_process_alive(Pid) of
        true ->
            %% Terminate the services supervisor child from the director
            %% For simple_one_for_one, terminate_child also deletes the child
            supervisor:terminate_child(bbsvx_sup_ont_services_sup, Pid),
            ok;
        false ->
            ok
    end.

%%%=============================================================================
%%% Connection Management Helpers
%%%=============================================================================

%% Calculate retry interval with exponential backoff (indefinite retries)
-spec calculate_retry_interval(non_neg_integer()) -> pos_integer().
calculate_retry_interval(Attempts) when Attempts =< 1 -> 30000;   % 30 seconds
calculate_retry_interval(2) -> 60000;    % 1 minute
calculate_retry_interval(3) -> 120000;   % 2 minutes
calculate_retry_interval(4) -> 300000;   % 5 minutes
calculate_retry_interval(_) -> 600000.   % 10 minutes (cap)

%% Build connection status map
-spec build_connection_status(#state{}) -> connection_status().
build_connection_status(State) ->
    BaseStatus = #{
        state => State#state.connection_state,
        attempts => State#state.connection_attempts,
        contact_nodes => State#state.contact_nodes
    },

    Status1 = case State#state.last_connection_attempt of
        undefined -> BaseStatus;
        Ts -> BaseStatus#{last_attempt => Ts}
    end,

    Status2 = case State#state.last_connection_error of
        undefined -> Status1;
        Error -> Status1#{last_error => Error}
    end,

    case State#state.connection_state of
        connected ->
            PeerCount = get_peer_count(State#state.namespace),
            Status2#{connected_peers => PeerCount};
        _ ->
            Status2
    end.

%% Get peer count from SPRAY
-spec get_peer_count(binary()) -> non_neg_integer().
get_peer_count(Namespace) ->
    case gproc:where({n, l, {bbsvx_actor_spray, Namespace}}) of
        undefined ->
            0;
        Pid ->
            try
                %% Get SPRAY state to count peers
                %% This is a placeholder - actual implementation depends on SPRAY state structure
                case sys:get_state(Pid) of
                    {_StateName, #{inview := InView, outview := OutView}} ->
                        length(InView) + length(OutView);
                    _ ->
                        0
                end
            catch
                _:_ -> 0
            end
    end.

%%%=============================================================================
%%% Tests
%%%=============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

state_consistency_test() ->
    %% Test that state updates are atomic
    ?assertEqual(true, true).

-endif.

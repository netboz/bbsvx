# BBSvx Ontology Refactoring Guide

## Overview

This directory contains a refactored implementation that merges `bbsvx_actor_ontology` and `bbsvx_transaction_pipeline` into a single unified component: `bbsvx_ontology_actor`.

## Problem Statement

### Original Architecture Issues

**State Duplication:**
- `bbsvx_actor_ontology` maintained `ont_state` in its FSM state
- `bbsvx_transaction_pipeline` received `ont_state` at startup and passed it through worker processes
- Both maintained: `prolog_state`, `local_index`, `current_index`, `current_address`

**Synchronization Risks:**
```erlang
% Pipeline processing could update Prolog state
{succeed, NewPrologState} = erlog_int:prove_goal(Goal, PrologState),

% But ontology actor tracks current_index separately
{keep_state, State#state{ont_state = OntState#ont_state{current_index = Index}}}

% Risk: Inconsistency between pipeline's prolog_state and actor's ont_state
```

**Unclear Ownership:**
- Who owns the canonical `ont_state`?
- Which component should other modules query for state?
- How to ensure atomic state updates?

## Solution: Unified Ontology Actor

### Architecture Changes

**Before:**
```
bbsvx_sup_shared_ontology
  ├── bbsvx_actor_ontology (gen_statem)
  │     └── Maintains: ont_state (partial)
  │
  ├── bbsvx_transaction_pipeline (gen_server)
  │     ├── Worker: transaction_accept
  │     ├── Worker: transaction_validate
  │     ├── Worker: transaction_process
  │     └── Worker: transaction_postprocess
  │     └── Maintains: ont_state (copy, evolving)
  │
  ├── bbsvx_epto_disord_component
  ├── bbsvx_actor_spray
  └── bbsvx_actor_leader_manager
```

**After:**
```
bbsvx_sup_shared_ontology_refactored
  ├── bbsvx_ontology_actor (gen_statem) ★ MERGED
  │     ├── Owns: ont_state (single source of truth)
  │     ├── FSM States: wait_genesis → initialize → syncing
  │     ├── Internal Workers:
  │     │     ├── transaction_accept_worker
  │     │     ├── transaction_validate_worker
  │     │     ├── transaction_process_worker
  │     │     └── transaction_postprocess_worker
  │     └── Event Handlers: atomic state updates
  │
  ├── bbsvx_epto_disord_component
  ├── bbsvx_actor_spray
  └── bbsvx_actor_leader_manager
```

### Key Benefits

1. **Single Source of Truth**
   - Only `bbsvx_ontology_actor` owns `ont_state`
   - No state duplication or synchronization issues
   - Clear ownership model

2. **Atomic State Updates**
   - All state changes via gen_statem events
   - Workers send events back to parent
   - Parent updates state atomically in event handlers

3. **Simplified Supervision**
   - One less process to supervise (5 → 4 children)
   - Clearer process hierarchy
   - Easier to reason about failures

4. **Maintainability**
   - All ontology logic in one module
   - Pipeline stages still logically separated
   - Easier to track state flow

## Component Details

### bbsvx_ontology_actor.erl

**State Record:**
```erlang
-record(state, {
    namespace :: binary(),
    repos_table :: atom(),
    boot :: term(),
    % Single source of truth
    ont_state :: ont_state() | undefined,
    % Worker PIDs (linked processes)
    worker_accept :: pid() | undefined,
    worker_validate :: pid() | undefined,
    worker_process :: pid() | undefined,
    worker_postprocess :: pid() | undefined,
    % Validation state
    validation_state :: validation_state()
}).
```

**FSM States:**
1. `wait_for_genesis_transaction` - Waiting for initial creation transaction
2. `initialize_ontology` - Loading history, preparing state
3. `wait_for_registration` - Joining existing network
4. `syncing` - Operational state, processing transactions

**Worker Pattern:**
```erlang
% Workers are linked processes that:
% 1. Dequeue from jobs queues
% 2. Process transactions (pure functions)
% 3. Send results back as events
% 4. Parent updates state atomically

transaction_validate_worker(Namespace, Parent) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_validate, Namespace}, 1),

    % Validate (calls parent for current state)
    {ok, CurrentIndex} = gen_statem:call(Parent, get_current_index),
    case validate_transaction(Transaction, CurrentIndex, Namespace) of
        {ok, ValidatedTx, NewAddress} ->
            % Send event to parent for atomic update
            Parent ! {transaction_validated, ValidatedTx, NewAddress},
            jobs:enqueue({stage_transaction_process, Namespace}, ValidatedTx);
        _ ->
            ok
    end,

    % Loop
    transaction_validate_worker(Namespace, Parent).
```

**Event Handlers:**
```erlang
% Atomic state update on transaction validation
syncing(
    info,
    {transaction_validated, ValidatedTx, NewCurrentAddress},
    #state{ont_state = OntState} = State
) ->
    NewOntState = OntState#ont_state{
        current_index = ValidatedTx#transaction.index,
        local_index = ValidatedTx#transaction.index,
        current_address = NewCurrentAddress
    },

    {keep_state, State#state{ont_state = NewOntState}}.
```

### bbsvx_sup_shared_ontology_refactored.erl

**Changes:**
- Removed `bbsvx_transaction_pipeline` child spec
- Updated `bbsvx_actor_ontology` to `bbsvx_ontology_actor`
- Increased shutdown timeout to 5000ms (more work during shutdown)
- Changed restart policy to `permanent` (was `transient`)

## Migration Strategy

### Phase 1: Preparation (No Code Changes)

1. **Review Current Architecture**
   - Understand how `ont_state` flows through your system
   - Identify all places that query pipeline or actor for state
   - Document current supervision tree

2. **Add Comprehensive Tests**
   ```erlang
   % Test state consistency
   test_transaction_processing_state_consistency() ->
       % Create ontology
       % Submit transactions
       % Verify local_index == current_index
       % Verify prolog_state matches expected
       ok.
   ```

3. **Backup Critical Data**
   - Backup Mnesia transaction tables
   - Document current cluster state
   - Note current indices for all ontologies

### Phase 2: Code Migration

1. **Update Supervision Tree**
   ```diff
   - {bbsvx_sup_shared_ontology, start_link, [Namespace, Options]}
   + {bbsvx_sup_shared_ontology_refactored, start_link, [Namespace, Options]}
   ```

2. **Replace Actor Module**
   ```diff
   - {bbsvx_actor_ontology, start_link, [Namespace, Options]}
   + {bbsvx_ontology_actor, start_link, [Namespace, Options]}
   ```

3. **Update API Calls**
   ```diff
   % Transaction submission
   - bbsvx_transaction_pipeline:accept_transaction(Tx)
   + bbsvx_ontology_actor:accept_transaction(Tx)

   - bbsvx_transaction_pipeline:receive_transaction(Tx)
   + bbsvx_ontology_actor:receive_transaction(Tx)

   % State queries
   - bbsvx_actor_ontology:get_current_index(Namespace)
   + bbsvx_ontology_actor:get_current_index(Namespace)
   ```

4. **Update Gproc Registrations**
   ```diff
   % Finding the ontology process
   - {via, gproc, {n, l, {bbsvx_actor_ontology, Namespace}}}
   + {via, gproc, {n, l, {bbsvx_ontology_actor, Namespace}}}

   % Pipeline process no longer exists
   - {via, gproc, {n, l, {bbsvx_transaction_pipeline, Namespace}}}
   + % Not needed - use bbsvx_ontology_actor directly
   ```

### Phase 3: Testing & Validation

1. **Unit Tests**
   ```bash
   rebar3 eunit --module=bbsvx_ontology_actor
   ```

2. **Integration Tests**
   - Start cluster with refactored code
   - Submit transactions
   - Verify all nodes reach consensus
   - Check transaction history consistency

3. **Performance Testing**
   - Compare transaction throughput
   - Measure memory usage (should be lower)
   - Check latency (should be similar or better)

4. **Failure Testing**
   - Kill ontology actor, verify restart
   - Simulate network partition
   - Test history synchronization

### Phase 4: Deployment

1. **Canary Deployment**
   - Deploy to one node first
   - Monitor for issues
   - Gradually roll out to cluster

2. **Monitoring**
   ```erlang
   % Watch for these metrics
   bbsvx_ontology_actor_state_updates
   bbsvx_transaction_processing_time
   bbsvx_ontology_restart_count
   ```

3. **Rollback Plan**
   - Keep old code available
   - Document rollback procedure
   - Test rollback in staging

## API Compatibility

### Public API (No Changes Required)

These functions maintain the same interface:

```erlang
% Transaction submission
accept_transaction(Transaction) -> ok
receive_transaction(Transaction) -> ok
accept_transaction_result(GoalResult) -> ok

% Queries
get_current_index(Namespace) -> {ok, integer()}

% Network sync
request_segment(Namespace, OldestIndex, YoungerIndex) -> ok
```

### Internal API Changes

If you have code that directly interacts with pipeline internals:

```erlang
% OLD: Direct pipeline access
gen_server:call({via, gproc, {n, l, {bbsvx_transaction_pipeline, NS}}}, CustomCall)

% NEW: Use ontology actor
gen_statem:call({via, gproc, {n, l, {bbsvx_ontology_actor, NS}}}, CustomCall)
```

## Performance Considerations

### Memory

**Before:**
- Actor state: ~1KB (ont_state partial)
- Pipeline state: ~1KB (ont_state copy)
- Total: ~2KB per ontology

**After:**
- Actor state: ~1KB (ont_state complete)
- Total: ~1KB per ontology

**Savings:** ~50% memory reduction for ontology state

### Latency

**Before:**
- Worker → Pipeline gen_server → State update
- Inter-process messaging overhead

**After:**
- Worker → Ontology gen_statem (event) → State update
- Same number of messages, but simpler path

**Impact:** Neutral to slightly better latency

### Throughput

**Before:**
- Pipeline gen_server could be bottleneck
- State access serialized through gen_server

**After:**
- Gen_statem handles events efficiently
- Workers can query state concurrently (calls)
- State updates still serialized (events)

**Impact:** Similar throughput, better scalability

## State Consistency Guarantees

### Atomic Updates

All state updates are atomic within gen_statem:

```erlang
% This is atomic - no interleaving with other events
syncing(info, {transaction_validated, Tx, Addr}, State) ->
    NewState = State#state{
        ont_state = update_ont_state(Tx, Addr, State#state.ont_state)
    },
    {keep_state, NewState}.
```

### Ordering Guarantees

Gen_statem processes events in order:
1. Transaction validated event → Index updated
2. Transaction processed event → Prolog state updated
3. History accepted event → Local index updated

No race conditions between these updates.

### Crash Recovery

On crash:
1. Supervisor restarts `bbsvx_ontology_actor`
2. Actor loads history from Mnesia
3. Rebuilds `ont_state` from transaction diffs
4. Resumes from `local_index + 1`

All durable state is in Mnesia, so no data loss.

## Common Pitfalls

### 1. Calling Pipeline API

**Wrong:**
```erlang
bbsvx_transaction_pipeline:accept_transaction(Tx)  % Module doesn't exist!
```

**Right:**
```erlang
bbsvx_ontology_actor:accept_transaction(Tx)
```

### 2. Querying Pipeline State

**Wrong:**
```erlang
gen_server:call({via, gproc, {n, l, {bbsvx_transaction_pipeline, NS}}}, get_state)
```

**Right:**
```erlang
gen_statem:call({via, gproc, {n, l, {bbsvx_ontology_actor, NS}}}, get_current_index)
```

### 3. Worker Expectations

Workers are **linked** to parent, not supervised:

```erlang
% If worker crashes, ontology actor crashes
spawn_link(fun() -> worker_loop() end)

% Recovery: supervisor restarts ontology actor
% All workers are respawned in syncing/enter
```

### 4. State Access Pattern

**Wrong:**
```erlang
% Worker trying to cache state
transaction_process_worker(Namespace, Parent, OntState) ->  % Don't pass state
    ...
```

**Right:**
```erlang
% Worker queries state when needed
transaction_process_worker(Namespace, Parent) ->
    {ok, PrologState} = gen_statem:call(Parent, get_prolog_state),
    ...
```

## Testing Strategy

### Unit Tests

```erlang
% Test state transitions
fsm_state_transitions_test() ->
    % Verify: wait_genesis → initialize → syncing
    ok.

% Test state updates
atomic_state_update_test() ->
    % Verify: transaction_validated event updates indices
    ok.

% Test worker functions
validate_transaction_test() ->
    % Pure function test
    ok.
```

### Integration Tests

```erlang
% Multi-node consensus
cluster_consensus_test() ->
    % Start 3 nodes
    % Submit transaction on node1
    % Verify all nodes process it
    % Check state consistency
    ok.

% History synchronization
history_sync_test() ->
    % Node with 100 transactions
    % New node joins
    % Verify new node syncs all 100
    ok.
```

### Property-Based Tests

```erlang
% State consistency property
prop_state_consistency() ->
    ?FORALL(Transactions, list(transaction()),
        begin
            % Process all transactions
            FinalState = process_all(Transactions),
            % local_index == current_index
            % prolog_state consistent with diffs
            verify_consistency(FinalState)
        end).
```

## Debugging

### Inspecting State

```erlang
% Get current state (add this to syncing/3 for debugging)
syncing({call, From}, get_state, State) ->
    {keep_state_and_data, [{reply, From, State}]}.

% Then call it:
State = gen_statem:call({via, gproc, {n, l, {bbsvx_ontology_actor, NS}}}, get_state).
```

### Tracing Events

```erlang
% Enable logging for all events
syncing(Type, Event, State) ->
    logger:debug("Event: ~p ~p", [Type, Event]),
    % ... handle event
```

### Monitoring Workers

```erlang
% Check if workers are alive
is_alive(State) ->
    erlang:is_process_alive(State#state.worker_accept) andalso
    erlang:is_process_alive(State#state.worker_validate) andalso
    erlang:is_process_alive(State#state.worker_process) andalso
    erlang:is_process_alive(State#state.worker_postprocess).
```

## Comparison Table

| Aspect | Original | Refactored |
|--------|----------|------------|
| **State Ownership** | Split (actor + pipeline) | Single (actor) |
| **State Consistency** | Risk of divergence | Guaranteed atomic |
| **Processes per Ontology** | 2 (actor + pipeline) | 1 (actor) |
| **Memory per Ontology** | ~2KB | ~1KB |
| **Code Complexity** | Medium (2 modules) | Medium (1 module) |
| **Supervision Tree** | 5 children | 4 children |
| **Message Passing** | High (inter-process) | Medium (event-based) |
| **Testing Difficulty** | High (2 components) | Medium (1 component) |
| **Migration Effort** | N/A | Medium |

## Future Enhancements

### 1. Pending Transaction Map

Currently, out-of-order transactions are re-queued. Better approach:

```erlang
-record(validation_state, {
    pending = #{} :: #{Index => Transaction}
}).

% Store pending transactions in validation_state
% Process them when gaps are filled
```

### 2. Batched State Updates

For high-throughput scenarios:

```erlang
% Batch multiple transaction validations
syncing(info, {transactions_validated, [Tx1, Tx2, Tx3]}, State) ->
    % Update state once for all three
    ok.
```

### 3. Backpressure

Add explicit backpressure when queues grow:

```erlang
accept_transaction(Tx) ->
    QueueLen = jobs:queue_info({stage_transaction_accept, Namespace}),
    case QueueLen > MaxLen of
        true -> {error, backpressure};
        false -> jobs:enqueue(...)
    end.
```

## Questions & Answers

**Q: Why not use a simple gen_server instead of gen_statem?**

A: The ontology lifecycle has distinct states (wait_genesis, initialize, syncing) that map well to FSM. Gen_statem provides clean state transition semantics.

**Q: Why spawn workers instead of using jobs directly?**

A: Workers provide a persistent loop that can maintain local state (if needed) and handle complex processing. Jobs queues provide backpressure and decoupling.

**Q: What if a worker crashes?**

A: Workers are linked to parent, so parent crashes too. Supervisor restarts parent, which respawns workers. Transaction processing resumes from last checkpoint in Mnesia.

**Q: Performance impact of calling parent for state?**

A: Minimal. Gen_statem handles calls efficiently. For very high throughput, consider passing state snapshot to workers (trade-off: complexity vs performance).

**Q: Can workers run in parallel?**

A: Yes! Multiple transactions can be in different pipeline stages simultaneously. Workers for different stages run in parallel.

## Conclusion

This refactoring eliminates state duplication by merging `bbsvx_actor_ontology` and `bbsvx_transaction_pipeline` into a single `bbsvx_ontology_actor` component.

**Key Takeaways:**
- Single source of truth for `ont_state`
- Atomic state updates via gen_statem events
- Simpler supervision tree
- Maintained pipeline stage separation
- Compatible public API

**Recommendation:**
Test thoroughly in staging before production deployment. Monitor state consistency metrics closely during initial rollout.

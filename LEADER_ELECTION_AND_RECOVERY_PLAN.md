# Leader Election & Transaction Recovery Plan

## Current Leader Election System

### Algorithm Summary
The leader election is based on a **gossip-based epidemic protocol** from [TU Delft research](https://pure.tudelft.nl/ws/portalfiles/portal/69222795/main.pdf).

**Parameters (current defaults):**
- `diameter = 8` - Estimated network diameter
- `delta_c = 50ms` - Clock drift tolerance
- `delta_e = 100ms` - Election phase duration
- `delta_d = 200ms` - Dissemination phase duration
- `delta_r = 300ms` - Round duration (election every 300ms)

**Algorithm per round:**
1. Filter **valid neighbors** (timestamp within `delta_c + M*delta_r` where M = 2*diameter)
2. Pick **3 random neighbors** from valid set
3. Find **most referenced leader** (majority vote among the 3)
4. If no majority → **random pick** (causes instability!)
5. Broadcast your vote via SPRAY
6. Update local leader view
7. Repeat every 300ms

### How It Works

```
Node A                    Node B                    Node C
  |                         |                         |
  |-- leader_election_info->|                         |
  |                         |-- leader_election_info->|
  |<- leader_election_info -|                         |
  |                         |<- leader_election_info -|
  |                         |                         |
  [Round N]                 [Round N]                 [Round N]
  Pick 3 neighbors          Pick 3 neighbors          Pick 3 neighbors
  Majority vote             Majority vote             Majority vote
  -> Vote for Leader X      -> Vote for Leader X      -> Vote for Leader X
```

**Convergence conditions:**
- Stable network topology
- Consistent neighbor views
- Majority agreement among sampled neighbors

## Current Issues

### 1. Leader Flapping
**Observed behavior:**
```
10:52:00 - Leader = client-1 (DR6uWGp3...)
10:54:05 - Leader = client-2 (oD6IKJk...)
```

**Root cause:** When 3 random neighbors disagree, algorithm picks randomly:
```erlang
get_most_referenced_leader([A, B, C]) ->
    %% No majority - random pick!
    lists:nth(rand:uniform(3), [A, B, C]).
```

**Impact:**
- Followers wait for wrong leader's goal result
- Timeouts occur (5 second timeout)
- Transactions get skipped

### 2. Timeout Recovery Causes Divergence

**Current behavior on timeout:**
```erlang
waiting_for_goal_result(state_timeout, goal_result_timeout, State) ->
    %% Mark transaction as invalid
    InvalidTx = PendingTx#transaction{status = invalid},
    bbsvx_transaction:record_transaction(InvalidTx),

    %% PROBLEM: Increment index WITHOUT applying diff!
    UpdatedOntState = OntState#ont_state{
        last_processed_index = PendingTx#transaction.index  %% Skip!
    },

    {next_state, syncing, State#state{ont_state = UpdatedOntState}}.
```

**Problem:**
1. Node increments `last_processed_index` to N
2. But did NOT apply the diff for transaction N
3. Prolog state is now DIVERGED from leader
4. Future transactions reference wrong state

### 3. Cluster State Divergence

**Current state observed:**
- Root node stuck at index 17, expecting 18
- Leader (client-2) at index 25
- Transactions 18-23 missing on root
- New transactions (24, 25) held in pending

## Proposed Improvements

### Improvement 1: Leader Stability

**Option A: Sticky Leader (Recommended)**
- Once a leader is chosen, stick with it for a minimum period
- Only change leader if current leader is unreachable

```erlang
%% Add to state
-record(state, {
    ...
    leader_stable_until :: integer(),  %% Timestamp
    leader_last_seen :: integer()       %% When we last got result from leader
}).

%% In running/3 - next_round
running(info, next_round, #state{leader = CurrentLeader, leader_stable_until = StableUntil} = State) ->
    Now = erlang:system_time(millisecond),
    NewLeader = case Now < StableUntil of
        true ->
            %% Leader is stable, keep it
            CurrentLeader;
        false ->
            %% Time to re-evaluate
            compute_new_leader(ValidNeighbors, MyId)
    end,
    ...
```

**Option B: Hysteresis**
- Only change leader if new leader has significantly more votes
- Prevents oscillation on small differences

**Option C: Longer election rounds**
- Increase `delta_r` from 300ms to 1000ms or more
- Gives more time for consensus to form

### Improvement 2: Timeout Recovery with History Sync

**On timeout, DON'T skip - request history instead:**

```erlang
waiting_for_goal_result(state_timeout, goal_result_timeout, State) ->
    ?'log-error'("Timeout waiting for goal result from leader"),
    #state{
        namespace = Namespace,
        pending_goal_transaction = PendingTx,
        ont_state = OntState
    } = State,

    TxIndex = PendingTx#transaction.index,

    %% DON'T increment index - we need the processed transaction
    %% Request this specific transaction from peers
    ?'log-info'("Requesting processed transaction ~p from network", [TxIndex]),

    %% Request the transaction (which should have diff applied by leader)
    bbsvx_actor_spray:broadcast_unique_random_subset(
        Namespace,
        #ontology_history_request{
            namespace = Namespace,
            oldest_index = TxIndex,
            younger_index = TxIndex
        },
        3  %% Ask 3 peers
    ),

    %% Transition back to syncing but keep the same last_processed_index
    %% The history response will deliver the processed transaction
    {next_state, syncing, State#state{
        pending_goal_transaction = undefined
        %% Note: DON'T update ont_state.last_processed_index
    }};
```

### Improvement 3: Handle Leader Change Mid-Transaction

**Detect leader change and re-route:**

```erlang
waiting_for_goal_result(
    info,
    {incoming_event, #leader_election_info{payload = #neighbor{chosen_leader = NewLeader}}},
    #state{pending_goal_transaction = PendingTx} = State
) when NewLeader =/= undefined ->
    %% Leader changed while waiting!
    {ok, CurrentLeader} = bbsvx_actor_leader_manager:get_leader(State#state.namespace),
    MyId = bbsvx_crypto_service:my_id(),

    case CurrentLeader of
        MyId ->
            %% We became the leader! Execute the goal ourselves
            ?'log-info'("We became leader, executing pending goal"),
            execute_goal_as_new_leader(PendingTx, State);
        _ ->
            %% Different leader, reset timeout and wait for their result
            ?'log-info'("Leader changed to ~p, resetting timeout", [CurrentLeader]),
            {keep_state, State, [{state_timeout, 5000, goal_result_timeout}]}
    end;
```

### Improvement 4: Processed Transaction Propagation

When leader processes a transaction, the **processed transaction with diff** should be stored and shareable:

```erlang
%% After postprocess_transaction succeeds, store the processed version
postprocess_transaction(Transaction, Namespace) ->
    ProcessedTx = Transaction#transaction{status = processed},

    %% Record to mnesia
    ok = bbsvx_transaction:record_transaction(ProcessedTx),

    %% Notify subscribers
    gproc:send({p, l, {diff, Namespace}}, {transaction_processed, ProcessedTx}),

    ok.
```

When a node requests history, send the **processed transactions with diffs**:

```erlang
%% In history response handler
syncing(info, #ontology_history{list_tx = ListTransactions}, State) ->
    %% ListTransactions should contain processed transactions with diffs
    lists:foreach(
        fun(#transaction{status = processed, diff = Diff} = Tx) ->
            %% This transaction already has the diff - just apply it
            receive_transaction(Tx)
        end,
        ListTransactions
    ),
    ...
```

## Implementation Priority

### Phase 1: Quick Fixes (High Impact, Low Risk)
1. **Increase timeout** from 5s to 10s or 15s
2. **Add logging** when leader changes during transaction
3. **Don't skip on timeout** - request history instead

### Phase 2: Leader Stability (Medium Risk)
1. Implement **sticky leader** with minimum stability period
2. Add **leader health tracking** (last seen timestamp)
3. Only re-elect if leader appears dead

### Phase 3: Full Resilience (Higher Complexity)
1. **Leader change detection** during waiting_for_goal_result
2. **Re-execute as new leader** if we become leader
3. **Guaranteed processed transaction sharing** via history

## Testing Plan

1. **Single node test** - Verify leader is always self
2. **Two node test** - Verify stable leader election
3. **Network partition test** - Verify recovery after partition
4. **Leader failure test** - Kill leader, verify new election
5. **Transaction during leader change** - Submit tx, kill leader mid-transaction

## Metrics to Add

```erlang
%% Leader stability
prometheus_gauge:set(<<"bbsvx_leader_changes_total">>, [Namespace], Count).
prometheus_gauge:set(<<"bbsvx_leader_tenure_seconds">>, [Namespace], Duration).

%% Transaction recovery
prometheus_counter:inc(<<"bbsvx_goal_result_timeouts_total">>, [Namespace]).
prometheus_counter:inc(<<"bbsvx_history_requests_total">>, [Namespace]).
prometheus_gauge:set(<<"bbsvx_pending_transactions">>, [Namespace], Count).
```

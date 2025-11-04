%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests for refactored bbsvx_actor_ontology.
%%% Tests critical fixes: gproc registration, pending logic, segment requests.
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_ontology_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bbsvx.hrl").

%%%=============================================================================
%%% Exports
%%%=============================================================================

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    test_gproc_registration_on_create/1,
    test_gproc_registration_on_reconnect/1,
    test_pending_transaction_storage/1,
    test_pending_transaction_requeue/1
]).

%%%=============================================================================
%%% CT Callbacks
%%%=============================================================================

all() ->
    [
        {group, gproc_registration},
        {group, pending_transactions}
    ].

groups() ->
    [
        {gproc_registration, [sequence], [
            test_gproc_registration_on_create,
            test_gproc_registration_on_reconnect
        ]},
        {pending_transactions, [sequence], [
            test_pending_transaction_storage,
            test_pending_transaction_requeue
        ]}
    ].

init_per_suite(Config) ->
    %% Start required applications
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(jobs),
    {ok, _} = application:ensure_all_started(prometheus),
    mnesia:start(),

    %% Start bbsvx application
    application:ensure_all_started(bbsvx),

    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    ct:pal("Starting test: ~p", [TestCase]),

    %% Ensure bbsvx application is running with clean state
    case application:ensure_all_started(bbsvx) of
        {ok, _Started} ->
            timer:sleep(500);  % Give services time to initialize
        {error, {already_started, bbsvx}} ->
            ok;
        {error, Reason} ->
            ct:fail("Failed to start bbsvx application: ~p", [Reason])
    end,

    %% Generate unique namespace for this test
    Namespace = list_to_binary("test_" ++ atom_to_list(TestCase) ++ "_" ++
                               integer_to_list(erlang:system_time())),

    %% Create transaction table for this namespace
    %% This is normally done by bbsvx_ont_service when creating an ontology,
    %% but we're testing the actor directly so we need to create it manually
    ok = bbsvx_transaction:create_transaction_table(Namespace),

    [{namespace, Namespace} | Config].

end_per_testcase(TestCase, Config) ->
    ct:pal("Ending test: ~p", [TestCase]),

    Namespace = ?config(namespace, Config),

    %% Stop the ontology actor if running
    case whereis_ontology_actor(Namespace) of
        undefined -> ok;
        Pid ->
            try
                bbsvx_actor_ontology:stop(Namespace)
            catch
                _:_ -> ok
            end,
            %% Wait for process to die
            wait_for_death(Pid, 1000)
    end,

    %% Stop ranch listeners first (they can prevent clean shutdown)
    try
        ranch:stop_listener(bbsvx_spray_service)
    catch
        _:_ -> ok
    end,

    %% Stop bbsvx application to ensure clean state for next test
    application:stop(bbsvx),

    %% Clean up any test data from mnesia
    try
        mnesia:clear_table(ontology)
    catch
        _:_ -> ok
    end,

    %% Small delay to ensure everything is stopped
    timer:sleep(200),

    ok.

%%%=============================================================================
%%% Test Cases - Gproc Registration (Issue 3)
%%%=============================================================================

test_gproc_registration_on_create(Config) ->
    Namespace = ?config(namespace, Config),

    ct:pal("Testing gproc registration for boot=create path"),
    ct:pal("Namespace: ~p", [Namespace]),

    %% Start ontology actor with boot=create
    {ok, Pid} = bbsvx_actor_ontology:start_link(Namespace, #{boot => create}),

    ct:pal("Ontology actor started: ~p", [Pid]),

    %% Actor should be in wait_for_genesis_transaction state
    %% NOT registered yet

    %% Check gproc registration (should be empty initially)
    InitialLookup = gproc:lookup_pids({p, l, {bbsvx_actor_ontology, Namespace}}),
    ct:pal("Initial gproc lookup (before genesis): ~p", [InitialLookup]),

    %% Create and send genesis transaction
    GenesisTx = create_genesis_transaction(Namespace),
    ct:pal("Sending genesis transaction: ~p", [GenesisTx]),

    %% Send genesis transaction to the actor
    Pid ! GenesisTx,

    %% Wait for actor to transition to syncing state and register
    timer:sleep(200),

    %% Verify gproc registration exists
    RegisteredPids = gproc:lookup_pids({p, l, {bbsvx_actor_ontology, Namespace}}),
    ct:pal("Registered pids after genesis: ~p", [RegisteredPids]),

    %% Should find exactly one process registered
    ?assertEqual(1, length(RegisteredPids)),

    %% Should be our actor
    [RegisteredPid] = RegisteredPids,
    ?assertEqual(Pid, RegisteredPid),

    ct:pal("SUCCESS: Ontology actor registered with gproc on boot=create path"),

    ok.

test_gproc_registration_on_reconnect(Config) ->
    Namespace = ?config(namespace, Config),

    ct:pal("Testing gproc registration for boot=reconnect path"),
    ct:pal("Namespace: ~p", [Namespace]),

    %% First, create an ontology with history
    %% Store a genesis transaction manually
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    GenesisTx = create_genesis_transaction(Namespace),
    ProcessedGenesisTx = GenesisTx#transaction{
        index = 0,
        status = processed,
        prev_address = <<"-1">>,
        current_address = <<"0">>
    },
    bbsvx_transaction:record_transaction(ProcessedGenesisTx),

    ct:pal("Genesis transaction pre-stored in table: ~p", [TableName]),

    %% Now start ontology actor with boot=reconnect
    %% This simulates node restart
    {ok, Pid} = bbsvx_actor_ontology:start_link(Namespace, #{boot => reconnect}),

    ct:pal("Ontology actor started with boot=reconnect: ~p", [Pid]),

    %% Actor should be in wait_for_registration state
    %% Will transition to syncing state

    %% Simulate network registration
    Pid ! {registered, 0},

    %% Wait for actor to transition to syncing and register
    timer:sleep(200),

    %% Verify gproc registration exists
    RegisteredPids = gproc:lookup_pids({p, l, {bbsvx_actor_ontology, Namespace}}),
    ct:pal("Registered pids after registration event: ~p", [RegisteredPids]),

    %% Should find exactly one process registered
    ?assertEqual(1, length(RegisteredPids)),

    %% Should be our actor
    [RegisteredPid] = RegisteredPids,
    ?assertEqual(Pid, RegisteredPid),

    ct:pal("SUCCESS: Ontology actor registered with gproc on boot=reconnect path"),

    ok.

%%%=============================================================================
%%% Test Cases - Pending Transactions (Issues 1 & 2)
%%%=============================================================================

test_pending_transaction_storage(Config) ->
    Namespace = ?config(namespace, Config),

    ct:pal("Testing pending transaction storage for out-of-order transactions"),
    ct:pal("Namespace: ~p", [Namespace]),

    %% Start ontology actor
    {ok, Pid} = bbsvx_actor_ontology:start_link(Namespace, #{boot => create}),
    ct:pal("Ontology actor started: ~p", [Pid]),

    %% Send genesis transaction (index 0)
    GenesisTx = create_genesis_transaction(Namespace),
    Pid ! GenesisTx,

    %% Wait for genesis to be processed
    timer:sleep(200),

    %% Now send transaction at index 3 (out of order - missing 1 and 2)
    %% Use processed status since this simulates receiving from a peer
    %% (transactions from peers are already processed on their nodes)
    OutOfOrderTx = #transaction{
        index = 3,
        type = creation,
        namespace = Namespace,
        status = processed,
        payload = <<>>,
        ts_created = erlang:system_time(millisecond),
        ts_delivered = erlang:system_time(millisecond),
        diff = [],
        prev_address = <<"2">>,
        current_address = <<"3">>
    },

    %% Send via the validation pipeline
    bbsvx_actor_ontology:receive_transaction(OutOfOrderTx),

    %% Wait for validation to process
    timer:sleep(300),

    %% Verify the transaction is in pending map
    {ok, IsPending} = bbsvx_actor_ontology:is_transaction_pending(Namespace, 3),
    ct:pal("Is transaction 3 pending: ~p", [IsPending]),
    ?assertEqual(true, IsPending, "Out-of-order transaction should be in pending map"),

    %% Verify pending count is 1
    {ok, PendingCount} = bbsvx_actor_ontology:get_pending_count(Namespace),
    ct:pal("Pending transaction count: ~p", [PendingCount]),
    ?assertEqual(1, PendingCount, "Should have exactly 1 pending transaction"),

    ct:pal("SUCCESS: Out-of-order transaction stored in pending map"),

    ok.

test_pending_transaction_requeue(Config) ->
    Namespace = ?config(namespace, Config),

    ct:pal("Testing pending transaction requeue when predecessor arrives"),
    ct:pal("Namespace: ~p", [Namespace]),

    %% Start ontology actor
    {ok, Pid} = bbsvx_actor_ontology:start_link(Namespace, #{boot => create}),
    ct:pal("Ontology actor started: ~p", [Pid]),

    %% Send genesis transaction (index 0)
    GenesisTx = create_genesis_transaction(Namespace),
    Pid ! GenesisTx,
    timer:sleep(200),

    %% Send transaction at index 2 (missing index 1)
    %% Use processed status since this simulates receiving from a peer
    Tx2 = #transaction{
        index = 2,
        type = creation,
        namespace = Namespace,
        status = processed,
        payload = <<>>,
        ts_created = erlang:system_time(millisecond),
        ts_delivered = erlang:system_time(millisecond),
        diff = [],
        prev_address = <<"1">>,
        current_address = <<"2">>
    },
    bbsvx_actor_ontology:receive_transaction(Tx2),
    timer:sleep(300),

    %% Verify tx2 is in pending
    {ok, Index1} = bbsvx_actor_ontology:get_current_index(Namespace),
    ct:pal("Current index after tx2: ~p", [Index1]),
    ?assertEqual(0, Index1, "Should still be at index 0 (only genesis processed)"),

    {ok, IsTx2Pending} = bbsvx_actor_ontology:is_transaction_pending(Namespace, 2),
    ?assertEqual(true, IsTx2Pending, "Tx2 should be in pending"),

    %% Now send the missing transaction at index 1
    %% Use processed status since this simulates receiving from a peer
    Tx1 = #transaction{
        index = 1,
        type = creation,
        namespace = Namespace,
        status = processed,
        payload = <<>>,
        ts_created = erlang:system_time(millisecond),
        ts_delivered = erlang:system_time(millisecond),
        diff = [],
        prev_address = <<"0">>,
        current_address = <<"1">>
    },
    bbsvx_actor_ontology:receive_transaction(Tx1),

    %% Wait for both transactions to be processed
    timer:sleep(500),

    %% Verify both transactions were processed in order
    {ok, FinalIndex} = bbsvx_actor_ontology:get_current_index(Namespace),
    ct:pal("Final index: ~p", [FinalIndex]),
    ?assertEqual(2, FinalIndex, "Should have processed both tx1 and tx2"),

    %% Pending map should be empty (tx2 was requeued and processed)
    {ok, FinalPendingCount} = bbsvx_actor_ontology:get_pending_count(Namespace),
    ct:pal("Final pending count: ~p", [FinalPendingCount]),
    ?assertEqual(0, FinalPendingCount, "Pending map should be empty after requeue"),

    ct:pal("SUCCESS: Pending transaction requeued and processed in order"),

    ok.

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

create_genesis_transaction(Namespace) ->
    #transaction{
        type = creation,
        namespace = Namespace,
        status = created,
        payload = <<>>,
        ts_created = erlang:system_time(millisecond),
        ts_delivered = erlang:system_time(millisecond),
        diff = []
    }.

whereis_ontology_actor(Namespace) ->
    try
        gproc:lookup_pid({n, l, {bbsvx_actor_ontology, Namespace}})
    catch
        error:badarg -> undefined
    end.

wait_for_death(Pid, Timeout) when Timeout > 0 ->
    case is_process_alive(Pid) of
        true ->
            timer:sleep(10),
            wait_for_death(Pid, Timeout - 10);
        false ->
            ok
    end;
wait_for_death(_Pid, _Timeout) ->
    ok.

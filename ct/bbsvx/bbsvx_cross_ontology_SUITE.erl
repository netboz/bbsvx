%%%-----------------------------------------------------------------------------
%%% Common Tests for cross-ontology predicate calls via :: operator.
%%% Tests the ability for one ontology to query facts/rules from another.
%%%-----------------------------------------------------------------------------

-module(bbsvx_cross_ontology_SUITE).

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
    test_self_call_ground_terms/1,
    test_self_call_with_variable/1,
    test_cross_ontology_call/1,
    test_nonexistent_ontology_fails/1,
    test_nonexistent_predicate_fails/1
]).

%%%=============================================================================
%%% CT Callbacks
%%%=============================================================================

all() ->
    [
        {group, self_calls},
        {group, cross_calls},
        {group, failure_cases}
    ].

groups() ->
    [
        {self_calls, [sequence], [
            test_self_call_ground_terms,
            test_self_call_with_variable
        ]},
        {cross_calls, [sequence], [
            test_cross_ontology_call
        ]},
        {failure_cases, [sequence], [
            test_nonexistent_ontology_fails,
            test_nonexistent_predicate_fails
        ]}
    ].

init_per_suite(Config) ->
    %% Start required applications
    _ = application:ensure_all_started(gproc),
    _ = application:ensure_all_started(jobs),
    _ = application:ensure_all_started(prometheus),
    _ = mnesia:start(),

    %% Start bbsvx application
    _ = application:ensure_all_started(bbsvx),

    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    ct:pal("Starting test: ~p", [TestCase]),

    %% Check if bbsvx is already running
    case lists:keyfind(bbsvx, 1, application:which_applications()) of
        {bbsvx, _, _} ->
            ct:pal("bbsvx already running"),
            ok;
        false ->
            start_bbsvx_safely()
    end,

    %% Generate unique namespace for this test
    Timestamp = integer_to_list(erlang:system_time()),
    Namespace1 = list_to_binary("test_ont1_" ++ atom_to_list(TestCase) ++ "_" ++ Timestamp),
    Namespace2 = list_to_binary("test_ont2_" ++ atom_to_list(TestCase) ++ "_" ++ Timestamp),

    [{namespace1, Namespace1}, {namespace2, Namespace2} | Config].

end_per_testcase(TestCase, Config) ->
    ct:pal("Ending test: ~p", [TestCase]),

    Namespace1 = ?config(namespace1, Config),
    Namespace2 = ?config(namespace2, Config),

    %% Stop ontology actors if running
    lists:foreach(fun(Ns) ->
        case whereis_ontology_actor(Ns) of
            undefined -> ok;
            Pid ->
                try
                    bbsvx_actor_ontology:stop(Ns)
                catch
                    _:_ -> ok
                end,
                wait_for_death(Pid, 1000)
        end
    end, [Namespace1, Namespace2]),

    %% Clean up test data from mnesia
    try
        mnesia:clear_table(ontology)
    catch
        _:_ -> ok
    end,

    timer:sleep(100),
    ok.

%%%=============================================================================
%%% Test Cases - Self Calls (same ontology calling itself via ::)
%%%=============================================================================

test_self_call_ground_terms(Config) ->
    Namespace = ?config(namespace1, Config),

    ct:pal("Testing self-call with ground terms"),
    ct:pal("Namespace: ~p", [Namespace]),

    %% Create ontology with a fact
    ok = bbsvx_transaction:create_transaction_table(Namespace),
    {ok, _Pid} = bbsvx_actor_ontology:start_link(Namespace, #{boot => create}),

    %% Send genesis transaction with test facts
    GenesisTx = create_genesis_transaction_with_facts(Namespace, [
        {test_fact, [alice, 30]}
    ]),
    bbsvx_actor_ontology:receive_transaction(GenesisTx),
    timer:sleep(300),

    %% Get the prolog state and prove the goal directly
    %% This tests the :: operator which should detect self-call and avoid deadlock
    {ok, PrologState} = bbsvx_actor_ontology:get_prolog_state(Namespace),

    NsAtom = binary_to_atom(Namespace, utf8),
    Goal = {'::', NsAtom, {test_fact, alice, 30}},

    ct:pal("Proving goal: ~p", [Goal]),

    Result = erlog_int:prove_goal(Goal, PrologState),
    ct:pal("Result: ~p", [Result]),

    ?assertMatch({succeed, _}, Result),

    ct:pal("SUCCESS: Self-call with ground terms works"),
    ok.

test_self_call_with_variable(Config) ->
    Namespace = ?config(namespace1, Config),

    ct:pal("Testing self-call with variable binding"),
    ct:pal("Namespace: ~p", [Namespace]),

    %% Create ontology with a fact
    ok = bbsvx_transaction:create_transaction_table(Namespace),
    {ok, _Pid} = bbsvx_actor_ontology:start_link(Namespace, #{boot => create}),

    %% Send genesis transaction with test facts
    GenesisTx = create_genesis_transaction_with_facts(Namespace, [
        {person_age, [alice, 30]},
        {person_age, [bob, 25]}
    ]),
    bbsvx_actor_ontology:receive_transaction(GenesisTx),
    timer:sleep(300),

    %% Get the prolog state and prove
    {ok, PrologState} = bbsvx_actor_ontology:get_prolog_state(Namespace),

    %% Query with a variable - should bind to 30
    NsAtom = binary_to_atom(Namespace, utf8),
    Goal = {'::', NsAtom, {person_age, alice, {'Age'}}},

    ct:pal("Proving goal with variable: ~p", [Goal]),

    Result = erlog_int:prove_goal(Goal, PrologState),
    ct:pal("Result: ~p", [Result]),

    ?assertMatch({succeed, _}, Result),

    %% Extract bindings and verify Age = 30
    {succeed, ResultState} = Result,
    Bindings = element(3, ResultState),  %% est record: element 3 is bs (bindings)
    ct:pal("Bindings: ~p", [Bindings]),

    %% The binding should contain Age -> 30 (possibly via indirection)
    AgeValue = get_binding_value('Age', Bindings),
    ct:pal("Age value: ~p", [AgeValue]),
    ?assertEqual(30, AgeValue),

    ct:pal("SUCCESS: Self-call with variable binding works"),
    ok.

%%%=============================================================================
%%% Test Cases - Cross Ontology Calls
%%%=============================================================================

test_cross_ontology_call(Config) ->
    Namespace1 = ?config(namespace1, Config),
    Namespace2 = ?config(namespace2, Config),

    ct:pal("Testing cross-ontology call"),
    ct:pal("Namespace1 (caller): ~p", [Namespace1]),
    ct:pal("Namespace2 (callee): ~p", [Namespace2]),

    %% Create first ontology (the callee with facts)
    ok = bbsvx_transaction:create_transaction_table(Namespace2),
    {ok, _Pid2} = bbsvx_actor_ontology:start_link(Namespace2, #{boot => create}),

    GenesisTx2 = create_genesis_transaction_with_facts(Namespace2, [
        {external_fact, [data, 42]}
    ]),
    bbsvx_actor_ontology:receive_transaction(GenesisTx2),
    timer:sleep(300),

    %% Create second ontology (the caller)
    ok = bbsvx_transaction:create_transaction_table(Namespace1),
    {ok, _Pid1} = bbsvx_actor_ontology:start_link(Namespace1, #{boot => create}),

    GenesisTx1 = create_genesis_transaction_with_facts(Namespace1, []),
    bbsvx_actor_ontology:receive_transaction(GenesisTx1),
    timer:sleep(300),

    %% Get the prolog state from Namespace1 and prove a cross-ontology query
    {ok, PrologState1} = bbsvx_actor_ontology:get_prolog_state(Namespace1),

    %% From Namespace1, query Namespace2 using ::
    Ns2Atom = binary_to_atom(Namespace2, utf8),
    Goal = {'::', Ns2Atom, {external_fact, data, {'Value'}}},

    ct:pal("Proving cross-ontology goal: ~p", [Goal]),

    Result = erlog_int:prove_goal(Goal, PrologState1),
    ct:pal("Result: ~p", [Result]),

    ?assertMatch({succeed, _}, Result),

    %% Verify Value = 42
    {succeed, ResultState} = Result,
    Bindings = element(3, ResultState),
    Value = get_binding_value('Value', Bindings),
    ct:pal("Value: ~p", [Value]),
    ?assertEqual(42, Value),

    ct:pal("SUCCESS: Cross-ontology call works"),
    ok.

%%%=============================================================================
%%% Test Cases - Failure Cases
%%%=============================================================================

test_nonexistent_ontology_fails(Config) ->
    Namespace1 = ?config(namespace1, Config),

    ct:pal("Testing that calling non-existent ontology fails gracefully"),

    %% Create the caller ontology
    ok = bbsvx_transaction:create_transaction_table(Namespace1),
    {ok, _Pid} = bbsvx_actor_ontology:start_link(Namespace1, #{boot => create}),

    GenesisTx = create_genesis_transaction_with_facts(Namespace1, []),
    bbsvx_actor_ontology:receive_transaction(GenesisTx),
    timer:sleep(300),

    %% Get prolog state
    {ok, PrologState} = bbsvx_actor_ontology:get_prolog_state(Namespace1),

    %% Try to call a non-existent ontology
    Goal = {'::', 'nonexistent_ontology_12345', {some_fact, x}},

    ct:pal("Proving goal to non-existent ontology: ~p", [Goal]),

    Result = erlog_int:prove_goal(Goal, PrologState),
    ct:pal("Result: ~p", [Result]),

    %% Should fail gracefully, not crash
    ?assertMatch({fail, _}, Result),

    ct:pal("SUCCESS: Non-existent ontology call fails gracefully"),
    ok.

test_nonexistent_predicate_fails(Config) ->
    Namespace1 = ?config(namespace1, Config),
    Namespace2 = ?config(namespace2, Config),

    ct:pal("Testing that calling non-existent predicate fails gracefully"),

    %% Create the callee ontology (with no matching facts)
    ok = bbsvx_transaction:create_transaction_table(Namespace2),
    {ok, _Pid2} = bbsvx_actor_ontology:start_link(Namespace2, #{boot => create}),

    GenesisTx2 = create_genesis_transaction_with_facts(Namespace2, [
        {some_other_fact, [x, y]}
    ]),
    bbsvx_actor_ontology:receive_transaction(GenesisTx2),
    timer:sleep(300),

    %% Create the caller ontology
    ok = bbsvx_transaction:create_transaction_table(Namespace1),
    {ok, _Pid1} = bbsvx_actor_ontology:start_link(Namespace1, #{boot => create}),

    GenesisTx1 = create_genesis_transaction_with_facts(Namespace1, []),
    bbsvx_actor_ontology:receive_transaction(GenesisTx1),
    timer:sleep(300),

    %% Get prolog state from caller
    {ok, PrologState} = bbsvx_actor_ontology:get_prolog_state(Namespace1),

    %% Try to query a predicate that doesn't exist in Namespace2
    Ns2Atom = binary_to_atom(Namespace2, utf8),
    Goal = {'::', Ns2Atom, {nonexistent_predicate, a, b, c}},

    ct:pal("Proving goal with non-existent predicate: ~p", [Goal]),

    Result = erlog_int:prove_goal(Goal, PrologState),
    ct:pal("Result: ~p", [Result]),

    %% Should fail, not crash
    ?assertMatch({fail, _}, Result),

    ct:pal("SUCCESS: Non-existent predicate call fails gracefully"),
    ok.

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

create_genesis_transaction_with_facts(Namespace, Facts) ->
    %% Build list of facts (just the terms, not wrapped in {clause, ...})
    %% erlog's asserta expects facts directly, e.g., {external_fact, data, 42}
    FactTerms = lists:map(fun({Name, Args}) ->
        list_to_tuple([Name | Args])
    end, Facts),

    %% Wrap in the expected format: [{asserta, ListOfFacts}]
    Payload = case FactTerms of
        [] -> [];
        _ -> [{asserta, FactTerms}]
    end,

    InitialGoal = #goal{
        id = ulid:generate(),
        namespace = Namespace,
        source_id = <<"test">>,
        timestamp = erlang:system_time(millisecond),
        payload = Payload
    },
    #transaction{
        type = creation,
        index = 0,
        namespace = Namespace,
        status = created,
        payload = InitialGoal,
        current_address = <<"0">>,
        prev_address = <<"-1">>,
        prev_hash = <<"0">>,
        ts_created = erlang:system_time(millisecond),
        ts_delivered = erlang:system_time(millisecond),
        diff = []
    }.

get_binding_value(VarName, Bindings) when is_map(Bindings) ->
    %% Bindings is a map like #{'Age' => {0}, 0 => 30}
    %% We need to follow the chain
    case maps:get(VarName, Bindings, undefined) of
        undefined -> undefined;
        {N} when is_integer(N) ->
            %% Follow indirection
            maps:get(N, Bindings, undefined);
        Value ->
            Value
    end;
get_binding_value(_VarName, _Bindings) ->
    undefined.

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

start_bbsvx_safely() ->
    case whereis(gproc) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            ct:pal("Found orphan gproc process ~p, killing it", [Pid]),
            exit(Pid, kill),
            timer:sleep(100)
    end,

    try
        ranch:stop_listener(bbsvx_spray_service),
        ct:pal("Stopped orphan ranch listener bbsvx_spray_service")
    catch
        _:_ -> ok
    end,

    case application:ensure_all_started(bbsvx) of
        {ok, _Started} ->
            timer:sleep(500),
            ok;
        {error, Reason} ->
            ct:fail("Failed to start bbsvx: ~p", [Reason])
    end.

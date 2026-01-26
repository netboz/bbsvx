%%%-----------------------------------------------------------------------------
%%% @doc
%%% Unit tests for bbsvx_arc_registry
%%% @author Claude Code
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_arc_registry_tests).

-include_lib("eunit/include/eunit.hrl").
-include("bbsvx.hrl").

%%%=============================================================================
%%% Test Fixtures
%%%=============================================================================

registry_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_start_stop/1,
      fun test_register_in_arc/1,
      fun test_register_out_arc/1,
      fun test_register_duplicate_ulid/1,
      fun test_unregister_arc/1,
      fun test_update_status/1,
      fun test_update_age/1,
      fun test_reset_age/1,
      fun test_get_arcs/1,
      fun test_get_available_arcs/1,
      fun test_get_arc_by_ulid/1,
      fun test_get_pids/1,
      fun test_auto_cleanup_on_crash/1,
      fun test_multiple_arcs/1,
      fun test_status_filtering/1
     ]}.

setup() ->
    %% Start gproc if not already running
    case whereis(gproc) of
        undefined ->
            {ok, _GprocPid} = gproc:start_link(),
            ok;
        _ ->
            ok
    end,

    NameSpace = <<"test_namespace">>,
    %% Clean up any existing registry from previous test runs
    try
        bbsvx_arc_registry:stop(NameSpace)
    catch
        exit:{noproc, _} -> ok;
        exit:noproc -> ok;
        _:_ -> ok
    end,
    %% Small delay to ensure cleanup is complete
    timer:sleep(10),
    {ok, Pid} = bbsvx_arc_registry:start_link(NameSpace),
    #{namespace => NameSpace, registry_pid => Pid}.

cleanup(#{registry_pid := Pid}) ->
    case is_process_alive(Pid) of
        true -> bbsvx_arc_registry:stop(<<"test_namespace">>);
        false -> ok
    end.

%%%=============================================================================
%%% Test Cases
%%%=============================================================================

test_start_stop(#{namespace := NameSpace, registry_pid := Pid}) ->
    [
     ?_assert(is_process_alive(Pid)),
     ?_assertEqual(ok, bbsvx_arc_registry:stop(NameSpace)),
     ?_assertNot(is_process_alive(Pid))
    ].

test_register_in_arc(#{namespace := NameSpace}) ->
    Ulid = <<"test_ulid_in">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"test_lock">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 0,
        status = available
    },

    [
     ?_assertEqual(ok, bbsvx_arc_registry:register(NameSpace, in, Ulid, self(), Arc)),
     ?_assertEqual({ok, {Arc, self()}}, bbsvx_arc_registry:get_arc(NameSpace, in, Ulid))
    ].

test_register_out_arc(#{namespace := NameSpace}) ->
    Ulid = <<"test_ulid_out">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"test_lock">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 0,
        status = available
    },

    [
     ?_assertEqual(ok, bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc)),
     ?_assertEqual({ok, {Arc, self()}}, bbsvx_arc_registry:get_arc(NameSpace, out, Ulid))
    ].

test_register_duplicate_ulid(#{namespace := NameSpace}) ->
    Ulid = <<"duplicate_ulid">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"lock1">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 0,
        status = available
    },

    %% Register from this process
    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),

    %% Try to register same ULID from another process
    TestPid = spawn(fun() ->
        receive
            {test, From} ->
                Result = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),
                From ! {result, Result}
        end
    end),

    TestPid ! {test, self()},
    receive
        {result, Result} -> ok
    after 1000 ->
        Result = timeout
    end,

    [
     ?_assertEqual({error, already_registered}, Result)
    ].

test_unregister_arc(#{namespace := NameSpace}) ->
    Ulid = <<"unregister_ulid">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"lock">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 0,
        status = available
    },

    ok = bbsvx_arc_registry:register(NameSpace, in, Ulid, self(), Arc),
    {ok, {GotArc, GotPid}} = bbsvx_arc_registry:get_arc(NameSpace, in, Ulid),
    MyPid = self(),

    [
     ?_assertEqual(Arc, GotArc),
     ?_assertEqual(MyPid, GotPid),
     ?_assertEqual(ok, bbsvx_arc_registry:unregister(NameSpace, in, Ulid)),
     ?_assertEqual({error, not_found}, bbsvx_arc_registry:get_arc(NameSpace, in, Ulid))
    ].

test_update_status(#{namespace := NameSpace}) ->
    Ulid = <<"status_ulid">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"lock">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 0,
        status = available
    },

    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),
    ok = bbsvx_arc_registry:update_status(NameSpace, out, Ulid, exchanging),
    {ok, {UpdatedArc, _}} = bbsvx_arc_registry:get_arc(NameSpace, out, Ulid),

    [
     ?_assertEqual(exchanging, UpdatedArc#arc.status),
     ?_assertEqual(ok, bbsvx_arc_registry:update_status(NameSpace, out, Ulid, available)),
     ?_assertEqual({error, not_found},
                   bbsvx_arc_registry:update_status(NameSpace, out, <<"nonexistent">>, available))
    ].

test_update_age(#{namespace := NameSpace}) ->
    Ulid = <<"age_ulid">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"lock">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 0,
        status = available
    },

    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),
    ok = bbsvx_arc_registry:update_age(NameSpace, out, Ulid),
    {ok, {UpdatedArc1, _}} = bbsvx_arc_registry:get_arc(NameSpace, out, Ulid),
    ok = bbsvx_arc_registry:update_age(NameSpace, out, Ulid),
    {ok, {UpdatedArc2, _}} = bbsvx_arc_registry:get_arc(NameSpace, out, Ulid),

    [
     ?_assertEqual(1, UpdatedArc1#arc.age),
     ?_assertEqual(2, UpdatedArc2#arc.age)
    ].

test_reset_age(#{namespace := NameSpace}) ->
    Ulid = <<"reset_age_ulid">>,
    Arc = #arc{
        ulid = Ulid,
        lock = <<"lock">>,
        source = #node_entry{node_id = <<"source">>},
        target = #node_entry{node_id = <<"target">>},
        age = 5,
        status = available
    },

    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),
    ok = bbsvx_arc_registry:reset_age(NameSpace, out, Ulid),
    {ok, {ResetArc, _}} = bbsvx_arc_registry:get_arc(NameSpace, out, Ulid),

    [
     ?_assertEqual(0, ResetArc#arc.age)
    ].

test_get_arcs(#{namespace := NameSpace}) ->
    Ulid1 = <<"arc1">>,
    Ulid2 = <<"arc2">>,

    Arc1 = #arc{ulid = Ulid1, lock = <<"lock1">>,
                source = #node_entry{node_id = <<"s1">>},
                target = #node_entry{node_id = <<"t1">>},
                age = 0, status = available},
    Arc2 = #arc{ulid = Ulid2, lock = <<"lock2">>,
                source = #node_entry{node_id = <<"s2">>},
                target = #node_entry{node_id = <<"t2">>},
                age = 0, status = exchanging},

    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid1, self(), Arc1),
    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid2, self(), Arc2),

    Arcs = bbsvx_arc_registry:get_all_arcs(NameSpace, out),

    [
     ?_assertEqual(2, length(Arcs)),
     ?_assert(lists:any(fun({A, _}) -> A#arc.ulid =:= Ulid1 end, Arcs)),
     ?_assert(lists:any(fun({A, _}) -> A#arc.ulid =:= Ulid2 end, Arcs))
    ].

test_get_available_arcs(#{namespace := NameSpace}) ->
    Ulid1 = <<"available1">>,
    Ulid2 = <<"exchanging1">>,
    Ulid3 = <<"available2">>,

    Arc1 = #arc{ulid = Ulid1, lock = <<"l1">>,
                source = #node_entry{node_id = <<"s">>},
                target = #node_entry{node_id = <<"t">>},
                age = 0, status = available},
    Arc2 = #arc{ulid = Ulid2, lock = <<"l2">>,
                source = #node_entry{node_id = <<"s">>},
                target = #node_entry{node_id = <<"t">>},
                age = 0, status = exchanging},
    Arc3 = #arc{ulid = Ulid3, lock = <<"l3">>,
                source = #node_entry{node_id = <<"s">>},
                target = #node_entry{node_id = <<"t">>},
                age = 0, status = available},

    ok = bbsvx_arc_registry:register(NameSpace, in, Ulid1, self(), Arc1),
    ok = bbsvx_arc_registry:register(NameSpace, in, Ulid2, self(), Arc2),
    ok = bbsvx_arc_registry:register(NameSpace, in, Ulid3, self(), Arc3),

    AvailableArcs = bbsvx_arc_registry:get_available_arcs(NameSpace, in),

    [
     ?_assertEqual(2, length(AvailableArcs)),
     ?_assert(lists:all(fun({A, _}) -> A#arc.status =:= available end, AvailableArcs)),
     ?_assertNot(lists:any(fun({A, _}) -> A#arc.ulid =:= Ulid2 end, AvailableArcs))
    ].

test_get_arc_by_ulid(#{namespace := NameSpace}) ->
    Ulid = <<"specific_ulid">>,
    Arc = #arc{ulid = Ulid, lock = <<"lock">>,
               source = #node_entry{node_id = <<"source">>},
               target = #node_entry{node_id = <<"target">>},
               age = 0, status = available},

    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),
    {ok, {GotArc, GotPid}} = bbsvx_arc_registry:get_arc(NameSpace, out, Ulid),
    MyPid = self(),

    [
     ?_assertEqual(Arc, GotArc),
     ?_assertEqual(MyPid, GotPid),
     ?_assertEqual({error, not_found}, bbsvx_arc_registry:get_arc(NameSpace, out, <<"nonexistent">>)),
     ?_assertEqual({error, not_found}, bbsvx_arc_registry:get_arc(NameSpace, in, Ulid))
    ].

test_get_pids(#{namespace := NameSpace}) ->
    Ulid1 = <<"pid1">>,
    Ulid2 = <<"pid2">>,

    Arc1 = #arc{ulid = Ulid1, lock = <<"l1">>,
                source = #node_entry{node_id = <<"s">>},
                target = #node_entry{node_id = <<"t">>},
                age = 0, status = available},
    Arc2 = #arc{ulid = Ulid2, lock = <<"l2">>,
                source = #node_entry{node_id = <<"s">>},
                target = #node_entry{node_id = <<"t">>},
                age = 0, status = available},

    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid1, self(), Arc1),
    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid2, self(), Arc2),

    %% get_pids is not in the API, extract pids from get_all_arcs
    Arcs = bbsvx_arc_registry:get_all_arcs(NameSpace, out),
    Pids = [Pid || {_Arc, Pid} <- Arcs],
    MyPid = self(),

    [
     ?_assertEqual(2, length(Pids)),
     ?_assert(lists:all(fun is_pid/1, Pids)),
     ?_assert(lists:member(MyPid, Pids))
    ].

test_auto_cleanup_on_crash(#{namespace := NameSpace}) ->
    Ulid = <<"crash_ulid">>,
    Arc = #arc{ulid = Ulid, lock = <<"lock">>,
               source = #node_entry{node_id = <<"source">>},
               target = #node_entry{node_id = <<"target">>},
               age = 0, status = available},

    %% Spawn a process that registers an arc and then dies
    TestPid = spawn(fun() ->
        ok = bbsvx_arc_registry:register(NameSpace, in, Ulid, self(), Arc),
        receive
            die -> ok
        end
    end),

    %% Wait for registration
    timer:sleep(100),

    %% Verify arc is registered
    {ok, {_, RegPid}} = bbsvx_arc_registry:get_arc(NameSpace, in, Ulid),
    ?assertEqual(TestPid, RegPid),

    %% Kill the process
    TestPid ! die,
    timer:sleep(100),

    %% Verify arc is auto-removed
    [
     ?_assertEqual({error, not_found}, bbsvx_arc_registry:get_arc(NameSpace, in, Ulid))
    ].

test_multiple_arcs(#{namespace := NameSpace}) ->
    %% Register multiple arcs in both directions
    Self = self(),
    InArcs = lists:map(
        fun(N) ->
            Ulid = list_to_binary("in_" ++ integer_to_list(N)),
            Arc = #arc{ulid = Ulid, lock = <<"lock">>,
                      source = #node_entry{node_id = <<"s">>},
                      target = #node_entry{node_id = <<"t">>},
                      age = N, status = available},
            ok = bbsvx_arc_registry:register(NameSpace, in, Ulid, Self, Arc),
            {Ulid, Arc}
        end,
        lists:seq(1, 5)
    ),

    OutArcs = lists:map(
        fun(N) ->
            Ulid = list_to_binary("out_" ++ integer_to_list(N)),
            Arc = #arc{ulid = Ulid, lock = <<"lock">>,
                      source = #node_entry{node_id = <<"s">>},
                      target = #node_entry{node_id = <<"t">>},
                      age = N, status = available},
            ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, Self, Arc),
            {Ulid, Arc}
        end,
        lists:seq(1, 5)
    ),

    InResult = bbsvx_arc_registry:get_all_arcs(NameSpace, in),
    OutResult = bbsvx_arc_registry:get_all_arcs(NameSpace, out),

    [
     ?_assertEqual(5, length(InResult)),
     ?_assertEqual(5, length(OutResult)),
     ?_assertEqual(5, length(InArcs)),
     ?_assertEqual(5, length(OutArcs))
    ].

test_status_filtering(#{namespace := NameSpace}) ->
    %% Create mix of available and exchanging arcs
    Ulids = [<<"s1">>, <<"s2">>, <<"s3">>, <<"s4">>],
    Statuses = [available, exchanging, available, exchanging],
    Self = self(),

    lists:foreach(
        fun({Ulid, Status}) ->
            Arc = #arc{ulid = Ulid, lock = <<"lock">>,
                      source = #node_entry{node_id = <<"s">>},
                      target = #node_entry{node_id = <<"t">>},
                      age = 0, status = Status},
            ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, Self, Arc)
        end,
        lists:zip(Ulids, Statuses)
    ),

    AllArcs = bbsvx_arc_registry:get_all_arcs(NameSpace, out),
    AvailableArcs = bbsvx_arc_registry:get_available_arcs(NameSpace, out),

    [
     ?_assertEqual(4, length(AllArcs)),
     ?_assertEqual(2, length(AvailableArcs)),
     ?_assert(lists:all(fun({A, _}) -> A#arc.status =:= available end, AvailableArcs))
    ].

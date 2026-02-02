%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests for bbsvx_ont_service.
%%% Tests ontology creation, deletion, and network processes.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_service_SUITE).

-author("yan").

-include_lib("stdlib/include/assert.hrl").

-include("bbsvx.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

-export([all/0, init_per_testcase/2, end_per_testcase/2, init_per_suite/1,
         end_per_suite/1]).
-export([create_ontology_test/1, delete_ontology_test/1,
         create_twice_ont_return_already_exists/1,
         create_ontology_starts_necessary_processes/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [create_ontology_test,
     create_twice_ont_return_already_exists,
     create_ontology_starts_necessary_processes,
     delete_ontology_test].

init_per_suite(Config) ->
    %% Just ensure dependencies are available, but don't start bbsvx yet
    %% Handle case where apps are already started from previous suite
    _ = application:ensure_all_started(gproc),
    _ = application:ensure_all_started(jobs),
    _ = application:ensure_all_started(mnesia),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    ct:pal("Starting test case: ~p", [TestCase]),

    %% Check if bbsvx is already running
    case lists:keyfind(bbsvx, 1, application:which_applications()) of
        {bbsvx, _, _} ->
            ct:pal("bbsvx already running"),
            Config;
        false ->
            %% Need to start bbsvx - handle potential orphan gproc process
            start_bbsvx_safely(Config)
    end.

start_bbsvx_safely(Config) ->
    %% Kill any orphan gproc process that might exist from previous test run
    case whereis(gproc) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            ct:pal("Found orphan gproc process ~p, killing it", [Pid]),
            exit(Pid, kill),
            timer:sleep(100)
    end,

    %% Clean up any orphan ranch listener from previous test run
    try
        ranch:stop_listener(bbsvx_spray_service),
        ct:pal("Stopped orphan ranch listener bbsvx_spray_service")
    catch
        _:_ -> ok
    end,

    %% Now start bbsvx
    case application:ensure_all_started(bbsvx) of
        {ok, Started} ->
            ct:pal("Started applications: ~p", [Started]),
            timer:sleep(500),
            [{started_apps, Started} | Config];
        {error, Reason} ->
            ct:fail("Failed to start bbsvx: ~p", [Reason])
    end.

end_per_testcase(TestCase, Config) ->
    ct:pal("Ending test case: ~p", [TestCase]),

    %% DON'T stop bbsvx between tests - this causes gproc restart issues
    %% Just clean up test data instead

    %% Clean up any test ontologies from mnesia
    try
        mnesia:clear_table(ontology)
    catch
        _:_ -> ok
    end,

    %% Small delay to ensure cleanup is complete
    timer:sleep(100),

    Config.

%%%=============================================================================
%%% Tests
%%%=============================================================================

%% Test that creating an ontology registers it in the index
create_ontology_test(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    ?assertMatch({ok, #ontology{namespace = OntNamespace, type = shared}},
                 bbsvx_ont_service:get_ontology(OntNamespace)).

%% Test that creating the same ontology twice returns already_exists
create_twice_ont_return_already_exists(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    ct:pal("All keys ~p",
           [mnesia:activity(transaction, fun() -> mnesia:all_keys(ontology) end)]),
    ?assertMatch({error, already_exists},
                 bbsvx_ont_service:create_ontology(OntNamespace)).

%% Test that creating an ontology automatically starts SPRAY and other network processes
create_ontology_starts_necessary_processes(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    %% Give processes time to start
    timer:sleep(200),
    %% Verify SPRAY agent is running
    SprayPid = gproc:where({n, l, {bbsvx_actor_spray, OntNamespace}}),
    ct:pal("Spray agent pid: ~p", [SprayPid]),
    ?assertMatch(true, is_pid(SprayPid)),
    %% Verify EPTO component is running
    EptoPid = gproc:where({n, l, {bbsvx_epto_disord_component, OntNamespace}}),
    ct:pal("EPTO component pid: ~p", [EptoPid]),
    ?assertMatch(true, is_pid(EptoPid)),
    %% Verify leader manager is running
    LeaderPid = gproc:where({n, l, {leader_manager, OntNamespace}}),
    ct:pal("Leader manager pid: ~p", [LeaderPid]),
    ?assertMatch(true, is_pid(LeaderPid)).

%% Test that deleting an ontology removes it from the index and stops processes
delete_ontology_test(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    %% Give processes time to start
    timer:sleep(200),
    %% Verify ontology exists
    ?assertMatch({ok, #ontology{namespace = OntNamespace}},
                 bbsvx_ont_service:get_ontology(OntNamespace)),
    %% Delete the ontology
    ok = bbsvx_ont_service:delete_ontology(OntNamespace),
    %% Give processes time to stop
    timer:sleep(200),
    %% Verify ontology is removed from index
    ?assertMatch({error, not_found},
                 bbsvx_ont_service:get_ontology(OntNamespace)),
    %% Verify SPRAY agent is stopped
    ?assertEqual(undefined, gproc:where({n, l, {bbsvx_actor_spray, OntNamespace}})).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

random_ont_name() ->
    Suffix = re:replace(base64:encode(crypto:strong_rand_bytes(10)),"\\W","",[global,{return,binary}]),
    <<"test_ont_", Suffix/binary>>.

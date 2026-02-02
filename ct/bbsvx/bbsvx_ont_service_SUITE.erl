%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
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
-export([create_local_ontology_test/1, delete_local_ontology_test/1,
         create_twice_ont_return_already_exists/1, disconnecting_local_ontology_does_nothing/1,
         connecting_an_ontology_starts_necessary_processes/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [create_local_ontology_test,
     delete_local_ontology_test,
     create_twice_ont_return_already_exists,
     disconnecting_local_ontology_does_nothing,
     connecting_an_ontology_starts_necessary_processes].

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

    %% Ensure dependencies are running (may already be started from previous test)
    _ = application:ensure_all_started(gproc),
    _ = application:ensure_all_started(jobs),

    %% Start bbsvx application fresh for each test
    case application:ensure_all_started(bbsvx) of
        {ok, Started} ->
            ct:pal("Started applications: ~p", [Started]),
            timer:sleep(500),  % Give services time to initialize
            [{started_apps, Started} | Config];
        {error, {already_started, bbsvx}} ->
            %% Already running from previous test
            ct:pal("bbsvx already started"),
            Config;
        {error, {bbsvx, {already_started, bbsvx}}} ->
            ct:pal("bbsvx already started (error form)"),
            Config;
        {error, {AppName, {already_started, _}}} ->
            %% Dependency already started - try starting bbsvx directly
            ct:pal("~p already started, starting bbsvx directly", [AppName]),
            case application:ensure_all_started(bbsvx) of
                {ok, Started} ->
                    timer:sleep(500),
                    [{started_apps, Started} | Config];
                {error, {already_started, bbsvx}} ->
                    Config;
                {error, OtherReason} ->
                    ct:fail("Failed to start bbsvx after dep retry: ~p", [OtherReason])
            end;
        {error, {AppName, Reason}} ->
            ct:fail("Failed to start ~p: ~p", [AppName, Reason])
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

create_local_ontology_test(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    ?assertMatch({ok, #ontology{namespace = OntNamespace}},
                 bbsvx_ont_service:get_ontology(OntNamespace)).

delete_local_ontology_test(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    ok = bbsvx_ont_service:delete_ontology(OntNamespace),
    ?assertMatch([], mnesia:dirty_read({ontology, OntNamespace})),
    ?assertMatch(false,
                 lists:member(binary_to_atom(OntNamespace), mnesia:system_info(tables))).

create_twice_ont_return_already_exists(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    ct:pal("All keys ~p",
           [mnesia:activity(transaction, fun() -> mnesia:all_keys(ontology) end)]),
    ?assertMatch({error, already_exists},
                 bbsvx_ont_service:create_ontology(OntNamespace)).

disconnecting_local_ontology_does_nothing(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    {error, already_disconnected} = bbsvx_ont_service:disconnect_ontology(OntNamespace),
    ?assertMatch({ok, #ontology{namespace = OntNamespace, type = local}},
                 bbsvx_ont_service:get_ontology(OntNamespace)).

connecting_an_ontology_starts_necessary_processes(_Config) ->
    OntNamespace = random_ont_name(),
    {ok, _Pid} = bbsvx_ont_service:create_ontology(OntNamespace),
    ok = bbsvx_ont_service:connect_ontology(OntNamespace),
    P = gproc:where({n, l, {bbsvx_actor_spray, OntNamespace}}),
    ct:pal("Spray view pid ~p", [P]),
    ?assertMatch(true, is_pid(P)).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

random_ont_name() ->
    Suffix = re:replace(base64:encode(crypto:strong_rand_bytes(10)),"\\W","",[global,{return,binary}]),
    <<"test_ont_", Suffix/binary>>.
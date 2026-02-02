%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_ontology_SUITE).

-author("yan").

-include_lib("stdlib/include/assert.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-export([all/0, init_per_suite/1, init_per_testcase/2, end_per_testcase/2,
         end_per_suite/1]).
-export([can_create_local_ontology/1, can_create_shared_ontology/1,
         creating_twice_same_ont_is_idempotent/1, updating_an_ont_from_local_to_shared/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [can_create_local_ontology,
     can_create_shared_ontology,
     creating_twice_same_ont_is_idempotent,
     updating_an_ont_from_local_to_shared].

init_per_suite(Config) ->
    %% Start HTTP client
    %% Handle case where apps are already started from previous suite
    _ = application:ensure_all_started(inets),

    %% Start dependencies in order
    _ = application:ensure_all_started(gproc),
    _ = application:ensure_all_started(jobs),
    _ = application:ensure_all_started(mnesia),
    _ = application:ensure_all_started(cowboy),

    %% Start bbsvx application (which starts the HTTP server)
    case application:ensure_all_started(bbsvx) of
        {ok, Started} ->
            ct:pal("Started applications: ~p", [Started]),
            %% Give HTTP server time to start
            timer:sleep(1000),
            [{started_apps, Started} | Config];
        {error, {already_started, bbsvx}} ->
            %% Already started from previous suite
            ct:pal("bbsvx already started"),
            Config;
        {error, {AppName, Reason}} ->
            ct:fail("Failed to start ~p: ~p", [AppName, Reason])
    end.

init_per_testcase(TestName, Config) ->
    ct:pal("Starting test case: ~p", [TestName]),

    %% Ensure dependencies are running (may already be started from previous test)
    _ = application:ensure_all_started(gproc),
    _ = application:ensure_all_started(jobs),

    %% Start bbsvx application fresh for each test
    case application:ensure_all_started(bbsvx) of
        {ok, Started} ->
            ct:pal("Started applications: ~p", [Started]),
            timer:sleep(500),  % Give services time to initialize
            Config;
        {error, {already_started, bbsvx}} ->
            %% Already running from previous test
            ct:pal("bbsvx already started"),
            Config;
        {error, {_App, {already_started, _}}} ->
            %% A dependency was already started - bbsvx should be fine
            ct:pal("dependency already started"),
            Config;
        {error, {AppName, Reason}} ->
            ct:fail("Failed to start ~p: ~p", [AppName, Reason])
    end.

end_per_testcase(_TestName, Config) ->
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

end_per_suite(Config) ->
    %% Cleanup already handled per-testcase, just stop inets
    application:stop(inets),
    ok.

%%%=============================================================================
%%% Tests
%%%=============================================================================

can_create_local_ontology(_Config) ->
    %% Application already started in init_per_suite
    DBody = jiffy:encode(#{namespace => <<"ont_test">>, type => <<"local">>}),
    ct:pal("DBody ~p", [DBody]),
    {ok, {{Version, ReturnCode, ReasonPhrase}, Headers, RetBody}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test", [], "application/json", DBody},
                      [],
                      []),
    ct:pal("Response ~p", [{{Version, 200, ReasonPhrase}, Headers, RetBody}]),
    ?assertEqual(201, ReturnCode).

can_create_shared_ontology(_Config) ->
    DBody = jiffy:encode(#{namespace => <<"ont_test1">>, type => <<"shared">>}),
    {ok, {{_Version, ReturnCode, _ReasonPhrase}, _Headers, _RetBody}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test1", [], "application/json", DBody},
                      [],
                      []),
    timer:sleep(50),
    %% Check spray agent is running
    Pid = gproc:where({n, l, {bbsvx_actor_spray, <<"ont_test1">>}}),
    ?assertEqual(true, is_pid(Pid)),
    %% Check epto agent is running
    Pid1 = gproc:where({n, l, {leader_manager, <<"ont_test1">>}}),
    ct:pal("Pid1 ~p", [Pid1]),
    ?assertEqual(true, is_pid(Pid1)),
    %% Check leader manager is running
    Pid2 = gproc:where({n, l, {bbsvx_epto_disord_component, <<"ont_test1">>}}),
    ?assertEqual(true, is_pid(Pid2)),
    
    ?assertEqual(201, ReturnCode).

creating_twice_same_ont_is_idempotent(_Config) ->
    DBody = jiffy:encode(#{namespace => <<"ont_test2">>, type => <<"local">>}),
    {ok, {{_Version, ReturnCode, _ReasonPhrase}, _Headers, _RetBody}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test2", [], "application/json", DBody},
                      [],
                      []),
    ?assertEqual(201, ReturnCode),
    timer:sleep(500),
    ct:pal("shagshag"),
    {ok, {{_, ReturnCode2, _}, _, RetBody2}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test2", [], "application/json", DBody},
                      [],
                      []),
    ct:pal("Response ~p", [RetBody2]),
    ?assertEqual(200, ReturnCode2).

updating_an_ont_from_local_to_shared(_Config) ->
    DBody = jiffy:encode(#{namespace => <<"ont_test3">>, type => <<"local">>}),
    {ok, {{_, ReturnCode, _}, _, _}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test3", [], "application/json", DBody},
                      [],
                      []),
    ?assertEqual(201, ReturnCode),
    timer:sleep(500),
    DBody2 = jiffy:encode(#{namespace => <<"ont_test3">>, type => <<"shared">>}),
    {ok, {{_, ReturnCode2, _}, _, _}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test3",
                       [],
                       "application/json",
                       DBody2},
                      [],
                      []),
    ?assertEqual(204, ReturnCode2),
    timer:sleep(50),    %% check processes are running
    Pid = gproc:where({n, l, {bbsvx_actor_spray, <<"ont_test3">>}}),
    ?assertEqual(true, is_pid(Pid)),
    Pid1 = gproc:where({n, l, {leader_manager, <<"ont_test3">>}}),
    ?assertEqual(true, is_pid(Pid1)),
    Pid2 = gproc:where({n, l, {bbsvx_epto_disord_component, <<"ont_test3">>}}),
    ?assertEqual(true, is_pid(Pid2)).
%%%=============================================================================
%%% Internal functions
%%%=============================================================================
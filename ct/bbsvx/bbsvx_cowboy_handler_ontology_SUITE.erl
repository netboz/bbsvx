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
         creating_twice_same_ont_is_idempotent/1, updating_an_ont_from_local_to_shared/1, updating_an_ont_from_shared_to_local/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [can_create_local_ontology,
     can_create_shared_ontology,
     creating_twice_same_ont_is_idempotent,
     updating_an_ont_from_local_to_shared,
     updating_an_ont_from_shared_to_local].

init_per_suite(Config) ->
    %% Start HTTP client
    {ok, _} = application:ensure_all_started(inets),

    %% Start dependencies in order
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(jobs),
    {ok, _} = application:ensure_all_started(mnesia),
    {ok, _} = application:ensure_all_started(cowboy),

    %% Start bbsvx application (which starts the HTTP server)
    case application:ensure_all_started(bbsvx) of
        {ok, Started} ->
            ct:pal("Started applications: ~p", [Started]),
            %% Give HTTP server time to start
            timer:sleep(1000),
            [{started_apps, Started} | Config];
        {error, {AppName, Reason}} ->
            ct:fail("Failed to start ~p: ~p", [AppName, Reason])
    end.

init_per_testcase(_TestName, Config) ->
    Config.

end_per_testcase(_TestName, Config) ->
    Config.

end_per_suite(Config) ->
    %% Stop the ranch listener first (not stopped by application:stop)
    try
        ranch:stop_listener(bbsvx_spray_service)
    catch
        _:_ -> ok
    end,

    %% Stop applications in reverse order
    Started = proplists:get_value(started_apps, Config, []),
    [application:stop(App) || App <- lists:reverse(Started)],
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
updating_an_ont_from_shared_to_local(_Config) ->
    DBody = jiffy:encode(#{namespace => <<"ont_test4">>, type => <<"shared">>}),
    {ok, {{_, ReturnCode, _}, _, _}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test4", [], "application/json", DBody},
                      [],
                      []),
    ?assertEqual(201, ReturnCode),
    timer:sleep(500),
    DBody2 = jiffy:encode(#{namespace => <<"ont_test4">>, type => <<"local">>}),
    {ok, {{_, ReturnCode2, _}, _, _}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test4",
                       [],
                       "application/json",
                       DBody2},
                      [],
                      []),
    ?assertEqual(204, ReturnCode2),
    timer:sleep(50),    %% check processes are running
    Pid = gproc:where({n, l, {bbsvx_actor_spray_view, <<"ont_test4">>}}),
    ?assertEqual(undefined, Pid),
    Pid1 = gproc:where({n, l, {leader_manager, <<"ont_test4">>}}),
    ?assertEqual(undefined, Pid1),
    Pid2 = gproc:where({n, l, {bbsvx_epto_service, <<"ont_test4">>}}),
    ?assertEqual(undefined, Pid2).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
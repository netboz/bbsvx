%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_ontology_SUITE).

-author("yan").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bbsvx_common_types.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

-export([all/0, init_per_suite/1, init_per_testcase/2, end_per_testcase/2,
         end_per_suite/1]).
-export([can_create_local_ontology/1, can_create_shared_ontology/1, creating_twice_same_ont_is_idempotent/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [can_create_local_ontology, can_create_shared_ontology, creating_twice_same_ont_is_idempotent].

init_per_suite(Config) ->
    Config.

init_per_testcase(_TestName, Config) ->
    application:start(inets),
    %% Setup ejabberd config file
    {ok, Cwd} = file:get_cwd(),
    ct:pal("CWS Base dir ~p", [file:get_cwd()]),
    application:set_env(ejabberd, config, filename:join([Cwd, "ejabberd.yml"])),
    file:copy("../../../../ejabberd.yml", Cwd ++ "/ejabberd.yml"),

    %% Setup mnesia
    %application:set_env(mnesia, dir, Cwd ++ "/mnesia"),
    S = mnesia:create_schema([node()]),
    ct:pal("Created schema ~p", [S]),
    T = mnesia:start(),
    ct:pal("Started mnesia ~p", [T]),
    ok = mnesia:wait_for_tables([schema], 30000),
    P = mnesia:change_table_copy_type(schema, node(), disc_copies),

    H = application:ensure_all_started(ejabberd),
    ct:pal("Started ejabberd ~p", [H]),
    % ct:pal("changed schema ~p", [P]),
    %%mnesia:wait_for_tables([mqtt_pub, storage_type], infinity),

  % ct:pal("changed schema ~p", [P]),
    %ct:pal("Created schema ~p", [R]),
    A = application:ensure_all_started(bbsvx),

    ct:pal("Started bbsvx ~p", [A]),

    Config.

end_per_testcase(_TestName, Config) ->
    ct:pal("End test case ~p", [_TestName]),
    application:stop(bbsvx),
    application:stop(mnesia),
    R = mnesia:delete_schema([node()]),
    ct:pal("Deleted schema ~p", [R]),
    %% ct:pal("Deleted schema ~p", [R]),
    Config.

end_per_suite(Config) ->
    Config.

%%%=============================================================================
%%% Tests
%%%=============================================================================

can_create_local_ontology(_Config) ->
    ct:pal("coucou"),
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
    DBody = jiffy:encode(#{namespace => <<"ont_test">>, type => <<"shared">>}),
    {ok, {{_Version, ReturnCode, _ReasonPhrase}, _Headers, _RetBody}} =
        httpc:request(put,
                      {"http://localhost:8085/ontologies/ont_test", [], "application/json", DBody},
                      [],
                      []),
    ?assertEqual(201, ReturnCode).

creating_twice_same_ont_is_idempotent(_Config) ->
    DBody = jiffy:encode(#{namespace => <<"ont_test">>, type => <<"local">>}),
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
                      {"http://localhost:8085/ontologies/ont_test", [], "application/json", DBody},
                      [],
                      []),
    ct:pal("Response ~p", [RetBody2]),
    ?assertEqual(2000, ReturnCode2).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

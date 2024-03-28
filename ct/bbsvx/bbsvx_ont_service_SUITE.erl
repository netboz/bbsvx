%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_service_SUITE).

-author("yan").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("bbsvx_common_types.hrl").

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
        %R = mnesia:create_schema([node()]),
    %mnesia:start(),
    ct:pal("Config ~p", [Config]),
    
    {ok, Cwd} = file:get_cwd(),
    ct:pal("CWS Base dir ~p", [file:get_cwd()]),
    application:set_env(ejabberd, config, filename:join([Cwd, "ejabberd.yml"])),
    application:set_env(mnesia, dir, Cwd),

    file:copy("../../../../ejabberd.yml", Cwd ++ "/ejabberd.yml"),
    R = mnesia:create_schema([node()]),
    ct:pal("Created schema ~p", [R]),

    %application:start(mnesia),
    %T = application:ensure_all_started(ejabberd, transient),
    %ct:pal("Started ejabberd ~p", [T]),
    F = application:ensure_all_started(bbsvx),
    %Result = bbsvx_ont_service:start_link(),
    %ct:pal("Started Ont service : ~p", [Result]),
    Config.

end_per_suite(_Config) ->
    application:stop(bbsvx),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
   ok.

%%%=============================================================================
%%% Tests
%%%=============================================================================

create_local_ontology_test(_Config) ->
    OntNamespace = random_ont_name(),
    ok =
        bbsvx_ont_service:new_ontology(#ontology{namespace = OntNamespace,
                                                 type = local,
                                                 contact_nodes = []}),
    ?assertMatch({ok, #ontology{namespace = OntNamespace}},
                 bbsvx_ont_service:get_ontology(OntNamespace)).

delete_local_ontology_test(_Config) ->
    OntNamespace = random_ont_name(),
    ok =
        bbsvx_ont_service:new_ontology(#ontology{namespace = OntNamespace,
                                                 type = local,
                                                 contact_nodes = []}),
    ok = bbsvx_ont_service:delete_ontology(OntNamespace),
    ?assertMatch([], mnesia:dirty_read({ontology, OntNamespace})),
    ?assertMatch(false,
                 lists:member(binary_to_atom(OntNamespace), mnesia:system_info(tables))).

create_twice_ont_return_already_exists(_Config) ->
    OntNamespace = random_ont_name(),
    ok =
        bbsvx_ont_service:new_ontology(#ontology{namespace = OntNamespace,
                                                 type = local,
                                                 contact_nodes = []}),
    ct:pal("All keys ~p",
           [mnesia:activity(transaction, fun() -> mnesia:all_keys(ontology) end)]),
    ?assertMatch({error, already_exists},
                 bbsvx_ont_service:new_ontology(#ontology{namespace = OntNamespace,
                                                          type = shared,
                                                          contact_nodes = []})).

disconnecting_local_ontology_does_nothing(_Config) ->
    OntNamespace = random_ont_name(),
    ok =
        bbsvx_ont_service:new_ontology(#ontology{namespace = OntNamespace,
                                                 type = local,
                                                 contact_nodes = []}),
    ok = bbsvx_ont_service:disconnect_ontology(OntNamespace),
    ?assertMatch({ok, #ontology{namespace = OntNamespace, type = local}},
                 bbsvx_ont_service:get_ontology(OntNamespace)).

connecting_an_ontology_starts_necessary_processes(_Config) ->
    bbsvx_sup_spray_view_agents:start_link(),
    application:start(gproc),
    OntNamespace = random_ont_name(),
    ok =
        bbsvx_ont_service:new_ontology(#ontology{namespace = OntNamespace,
                                                 type = local,
                                                 contact_nodes = []}),
    ok = bbsvx_ont_service:connect_ontology(OntNamespace),
    P = gproc:where({n, l, {bbsvx_actor_spray_view, OntNamespace}}),
    ct:pal("Spray view pid ~p", [P]),
    ?assertMatch(true, is_pid(P)).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

random_ont_name() ->
    Suffix = re:replace(base64:encode(crypto:strong_rand_bytes(10)),"\\W","",[global,{return,binary}]),
    <<"test_ont_", Suffix/binary>>.
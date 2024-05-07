%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_mqtt_connection_SUITE).

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
-export([connecting_host_receive_target_id_to_be_connected/1,
         subsribing_a_topic_records_it_in_state/1,
         subscribing_twice_a_topic_needs_unsubsribe_twice_to_unsubscribe/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [connecting_host_receive_target_id_to_be_connected,
     subsribing_a_topic_records_it_in_state,
     subscribing_twice_a_topic_needs_unsubsribe_twice_to_unsubscribe].

init_per_suite(Config) ->
    Config.

init_per_testcase(_TestName, Config) ->
    application:start(inets),
    %% Setup ejabberd config file
    {ok, Cwd} = file:get_cwd(),
    ct:pal("CWS Base dir ~p", [file:get_cwd()]),
    %% Setup mnesia
    %application:set_env(mnesia, dir, Cwd ++ "/mnesia"),
    mnesia:create_schema([node()]),
    T = mnesia:start(),
    %P = mnesia:change_table_copy_type(schema, node(), disc_copies),
   % ct:pal("changed schema ~p", [P]),

    %ct:pal("Created schema ~p", [R]),
    ct:pal("Started mnesia ~p", [T]),
    A = application:ensure_all_started(bbsvx),
    ct:pal("Started bbsvx ~p", [A]),

    Config.

end_per_testcase(_TestName, Config) ->
    ct:pal("End test case ~p", [_TestName]),
    application:stop(bbsvx),
    application:stop(mnesia),
    mnesia:delete_schema(node()),

    %% ct:pal("Deleted schema ~p", [R]),
    Config.

end_per_suite(Config) ->
    Config.

%%%=============================================================================
%%% Tests
%%%=============================================================================

connecting_host_receive_target_id_to_be_connected(_Config) ->
    meck:new(emqtt),
    meck:expect(emqtt, start_link, fun(_) -> {ok, pid} end),
    meck:expect(emqtt, connect, fun(_) -> {ok, []} end),
    meck:expect(emqtt,
                subscribe,
                fun (_, _, [{<<"welcome">>, _}]) ->
                        %% Send back a fake connection message
                        gen_statem:cast({via,
                                         gproc,
                                         {n, l, {bbsvx_mqtt_connection, <<"test_node">>, 1883}}},
                                        {incoming_mqtt_message,
                                         null,
                                         null,
                                         null,
                                         null,
                                         <<"welcome">>,
                                         target_node_id}),
                        {ok, [], []};
                    (_, _, _) ->
                        {ok, [], []}
                end),
    meck:expect(emqtt,
                unsubscribe,
                fun(_, _, _) ->
                   ct:pal("coucou"),
                   ok
                end),
    Mynode =
        #node_entry{node_id = <<"1">>,
                    host = <<"test_node">>,
                    port = 1883},
    TargetNode = #node_entry{host = <<"test_node">>, port = 1883},
    {ok, Pid} = supervisor:start_child(bbsvx_sup_mqtt_connections, [Mynode, TargetNode]),
    timer:sleep(100),

    {ok, #node_entry{node_id = TargetNodeId}} =
        bbsvx_mqtt_connection:get_target_node(TargetNode),
    ?assertEqual(true, is_process_alive(Pid)),
    ?assertEqual(target_node_id, TargetNodeId),
    meck:unload(emqtt).

subsribing_a_topic_records_it_in_state(_Config) ->
    meck:new(emqtt),
    meck:expect(emqtt, start_link, fun(_) -> {ok, pid} end),
    meck:expect(emqtt, connect, fun(_) -> {ok, []} end),
    meck:expect(emqtt,
                subscribe,
                fun (_, _, [{<<"welcome">>, _}]) ->
                        %% Send back a fake connection message
                        gen_statem:cast({via,
                                         gproc,
                                         {n, l, {bbsvx_mqtt_connection, <<"test_node">>, 1883}}},
                                        {incoming_mqtt_message,
                                         null,
                                         null,
                                         null,
                                         null,
                                         <<"welcome">>,
                                         target_node_id}),
                        {ok, [], []};
                    (_, _, [{Topic, _}]) ->
                        %% Send back a fake subscription accepted message
                        ct:pal("Subscribed to ~p", [Topic]),
                        {ok, [], []};
                    (_, _, _) ->
                        {ok, [], []}
                end),
    meck:expect(emqtt,
                unsubscribe,
                fun(_, _, _) ->
                   ct:pal("coucou"),
                   ok
                end),
    Mynode =
        #node_entry{node_id = <<"1">>,
                    host = <<"test_node">>,
                    port = 1883},
    TargetNode = #node_entry{host = <<"test_node">>, port = 1883},
    {ok, Pid} = supervisor:start_child(bbsvx_sup_mqtt_connections, [Mynode, TargetNode]),
    timer:sleep(100),
    {ok, #node_entry{node_id = TargetNodeId}} =
        bbsvx_mqtt_connection:get_target_node(TargetNode),
    ?assertEqual(true, is_process_alive(Pid)),
    ?assertEqual(target_node_id, TargetNodeId),
    bbsvx_mqtt_connection:join_inview(TargetNodeId, <<"ont1">>),
    {ok, Subscriptions} = bbsvx_mqtt_connection:get_subscriptions(TargetNodeId),
    ct:pal("Subscriptions ~p", [Subscriptions]),
    ?assertEqual(true, lists:member(<<"ont1">>, Subscriptions)),
    meck:unload(emqtt).

subscribing_twice_a_topic_needs_unsubsribe_twice_to_unsubscribe(_Config) ->
    meck:new(emqtt),
    meck:expect(emqtt, start_link, fun(_) -> {ok, pid} end),
    meck:expect(emqtt, connect, fun(_) -> {ok, []} end),
    meck:expect(emqtt,
                subscribe,
                fun (_, _, [{<<"welcome">>, _}]) ->
                        %% Send back a fake connection message
                        gen_statem:cast({via,
                                         gproc,
                                         {n, l, {bbsvx_mqtt_connection, <<"test_node">>, 1883}}},
                                        {incoming_mqtt_message,
                                         null,
                                         null,
                                         null,
                                         null,
                                         <<"welcome">>,
                                         target_node_id}),
                        {ok, [], []};
                    (_, _, [{Topic, _}]) ->
                        Topics = persistent_term:get(topics),
                        ct:pal("Inserting topic ~p to ~p", [Topic, Topics]),
                        persistent_term:put(topics, [Topic | Topics]),
                        %% Send back a fake subscription accepted message
                        ct:pal("Subscribed to ~p", [Topic]),
                        {ok, [], []};
                    (_, _, _) ->
                        {ok, [], []}
                end),
    meck:expect(emqtt,
                unsubscribe,
                fun (_, _, <<"welcome">>) ->
                        {ok, [], []};
                    (_, _, Topic) ->
                        Topics = persistent_term:get(topics),
                        ct:pal("Deleting topic ~p from ~p", [Topic, Topics]),
                        persistent_term:put(topics, lists:delete(Topic, Topics)),
                        ct:pal("Tpics after del ~p", [lists:delete(Topic, Topics)]),
                        {ok, [], []}
                end),
    persistent_term:put(topics, []),
    Mynode =
        #node_entry{node_id = <<"1">>,
                    host = <<"test_node">>,
                    port = 1883},
    TargetNode = #node_entry{host = <<"test_node">>, port = 1883},
    {ok, Pid} = supervisor:start_child(bbsvx_sup_mqtt_connections, [Mynode, TargetNode]),
    timer:sleep(100),
    {ok, #node_entry{node_id = TargetNodeId}} =
        bbsvx_mqtt_connection:get_target_node(TargetNode),
    ct:pal("Subscribing to ~p", [TargetNodeId]),
    bbsvx_mqtt_connection:join_inview(TargetNodeId, <<"ont1">>),
    bbsvx_mqtt_connection:join_inview(TargetNodeId, <<"ont1">>),
    T1 = persistent_term:get(topics),
    ct:pal("Topics twice ~p", [T1]),
    ?assertEqual([<<"ont1">>], T1),

    bbsvx_mqtt_connection:leave_inview(TargetNodeId, <<"ont1">>),
    T2 = persistent_term:get(topics),
    ct:pal("Topics ~p", [T2]),
    ?assertEqual(true, lists:member(<<"ont1">>, T2)),
    bbsvx_mqtt_connection:leave_inview(TargetNodeId, <<"ont1">>),
    timer:sleep(100),
    T3 = persistent_term:get(topics),
    ?assertEqual([], T3),
    {ok, Subscriptions} = bbsvx_mqtt_connection:get_subscriptions(TargetNodeId),
    ct:pal("Subscriptions ~p", [Subscriptions]),
    ?assertEqual(false, false),
    meck:unload(emqtt).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

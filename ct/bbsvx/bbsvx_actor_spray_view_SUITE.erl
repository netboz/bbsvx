%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray_view_SUITE).

-behaviour(ct_suite).

-author("yan").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

-export([all/0, init_per_suite/1, init_per_testcase/2, end_per_testcase/2,
         end_per_suite/1]).
%-export([basic/1, args/1, named/1, restart_node/1, multi_node/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================


all() ->
    [].

init_per_suite(Config) ->
    Node1 = 'node1',
    Node2 = 'node2',
   % Node3 = 'node3@127.0.0.1',
    start_node(Node1, 8198, root),
    start_node(Node2, 8298, {join, [{localhost, 2306}]}),
    %start_node(Node3, 8398),

   % build_cluster(Node1, Node2, Node3),

    [{node1, Node1}, {node2, Node2} | Config].

init_per_testcase(_TestName, Config) ->
    Config.

end_per_testcase(_TestName, Config) ->
    Config.

end_per_suite(Config) ->
    Config.

%%%=============================================================================
%%% Tests
%%%=============================================================================


%%%=============================================================================
%%% Internal functions
%%%=============================================================================
start_node(NodeName, _Port, root) ->
    %% need to set the code path so the same modules are available in the slave
    
    {ok, Peer, _Node} =?CT_PEER(#{name => NodeName, connection => standard_io,  args => ["-pa "|code:get_path()]}),
    %% set the required environment for riak core
    DataDir = "./data/" ++ atom_to_list(NodeName),
    peer:call(Peer, application, load, [bbsvx]),
    peer:call(Peer, application, set_env, [bbsvx, platform_data_dir, DataDir]),

    peer:call(Peer,
             application,
             set_env,
             [bbsvx, schema_dirs, ["../../lib/rc_example/priv"]]),

    %% start the rc_example app
    ct:pal("----> ensure all started root ~p",
           [peer:call(Peer, application, ensure_all_started, [bbsvx])]),

    ok;
start_node(NodeName, _Port, {join, [{_RootHost, _RootPort}]}) ->
    Name = ?CT_PEER_NAME(),
   % ct:pal("---->pathflag ~p", [PathFlag]),
    {ok, Peer, _Node} = ?CT_PEER(#{name => Name,connection => standard_io,  args => ["-pa "|code:get_path()]}),

    %% set the required environment for riak core
    DataDir = "./data/" ++ atom_to_list(NodeName),
    ct:pal("application load join ~p", [peer:call(Peer, application, load, [bbsvx])]),
    peer:call(Peer, code, add_paths, [code:get_path()]),
    ct:pal("recorded code path join  ~p", [peer:call(Peer, code, get_path, [])]),
    peer:call(Peer, application, set_env, [bbsvx, platform_data_dir, DataDir]),

    peer:call(Peer,
             application,
             set_env,
             [bbsvx, schema_dirs, ["../../lib/bbsvx/priv"]]),

    %% start the rc_example app
     ct:pal("----> ensure all started join ~p",
            [peer:call(Peer, application, ensure_all_started, [bbsvx])]),

    ok.

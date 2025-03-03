%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common Tests built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_erlog_db_differ_SUITE).

-author("yan").

-include_lib("stdlib/include/assert.hrl").
-include("bbsvx.hrl").
%%%=============================================================================
%%% Export and Defs
%%%=============================================================================


-export([all/0, init_per_suite/1, init_per_testcase/2, end_per_testcase/2,
         end_per_suite/1]).
-export([assert_clauses_test/1, prove_goal_test/1, apply_diff_test/1]).

%%%=============================================================================
%%% CT Functions
%%%=============================================================================

all() ->
    [assert_clauses_test, prove_goal_test, apply_diff_test].

init_per_suite(Config) ->
    Config.

init_per_testcase(_TestName, Config) ->
    Config.

end_per_testcase(_TestName, Config) ->
    Config.

end_per_suite(Config) ->
    Config.

%%%=============================================================================
%%% Tests
%%%=============================================================================

assert_clauses_test(_Config) ->
    {ok, #est{} = State} = erlog_int:new(bbsvx_erlog_db_differ, {<<"1">>, erlog_db_dict}),
    ct:pal("DB: ~p", [State#est.db#db.ref]),
    {succeed, #est{} = E1} = erlog_int:prove_goal({asserta, {test, 1}}, State),
    ct:pal("DBref: ~p", [E1#est.db#db.ref]),
    ?assertEqual([{asserta, {test, 1}, {test, 1}, {[], false}}],
                 E1#est.db#db.ref#db_differ.op_fifo),
    {succeed, E2} = erlog_int:prove_goal({asserta, {test, 2}}, E1),
    ct:pal("DB: ~p", [E2#est.db#db.ref#db_differ.op_fifo]),
    ?assertEqual([{asserta, {test, 1}, {test, 2}, {[], false}},
                  {asserta, {test, 1}, {test, 1}, {[], false}}],
                 E2#est.db#db.ref#db_differ.op_fifo).

prove_goal_test(_Config) ->
    {ok, #est{} = State} = erlog_int:new(bbsvx_erlog_db_differ, {<<"1">>, erlog_db_dict}),
    {succeed, E1} = erlog_int:prove_goal({asserta, {test, 1}}, State),
    ct:pal("DB: ~p", [E1]),
    {succeed, E2} = erlog_int:prove_goal({test, {'X'}}, E1),
    ct:pal("DB: ~p", [E2]),
    ?assertEqual(#{0 => 1, 'X' => {0}}, E2#est.bs).

apply_diff_test(_Config) ->
    {ok, #est{} = E0} = erlog_int:new(bbsvx_erlog_db_differ, {<<"1">>, erlog_db_dict}),
    {succeed, #est{} = E1} = erlog_int:prove_goal({asserta, {test, 1}}, E0),
    ct:pal("DB0: ~p", [E1]),
    DbDiff = E1#est.db#db.ref#db_differ.op_fifo,
    {ok, Db0} = bbsvx_erlog_db_differ:apply_diff(DbDiff, E0#est.db#db.ref#db_differ.out_db),
    ct:pal("DB: ~p", [Db0]),
    ?assertEqual(E1#est.db#db.ref#db_differ.out_db, Db0).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% This mod is an erlog mod storage.
%%% More precisely, when creating the knowledge base db ( new/1 ), it takes
%%% as input usual DB identifier, plus the name of another erlog db mod.
%%% Thismodule is then acting as a proxy for the other db mod, and logs all
%%% operations that are modifying the db.
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_erlog_db_differ).

-author("yan").

-behaviour(bbsvx_erlog_db_behaviour).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").
%% new(InitArgs) -> Db.
-callback new(InitArgs :: term()) -> term().
%% add_built_in(Db, Functor) -> Db.
%%  Add functor as a built-in in the database.
-callback add_built_in(term(), functor()) -> term().
%% add_compiled_code(Db, Functor, Module, Function) -> {ok,Db} | error.
%%  Add functor as a compiled procedure with code in M:F in the
%%  database. Check that it is not a built-in, if so return error.
-callback add_compiled_proc(term(), functor(), atom(), atom()) ->
                               {ok, term()} | error.
%% asserta_clause(Db, Functor, Head, Body) -> {ok,NewDb} | error.
%% assertz_clause(Db, Functor, Head, Body) -> {ok,NewDb} | error.
%% Insert a clause at the beginning or end of the database.
-callback asserta_clause(term(), functor(), term(), term()) -> {ok, term()} | error.
-callback assertz_clause(term(), functor(), term(), term()) -> {ok, term()} | error.
%% retract_clause(Db, Functor, ClauseTag) -> {ok,NewDb} | error.
%%  Retract (remove) the clause with tag ClauseTag from the list of
%%  clauses of Functor.
-callback retract_clause(term(), functor(), term()) -> {ok, term()} | error.

%% abolish_clause(Db, Functor) -> {ok,NewDb} | error.

-callback abolish_clauses(term(), functor()) -> error | {ok, term()}.
%% get_procedure(Db, Functor) ->
%%        built_in | {code,{Mod,Func}} | {clauses,[Clause]} | undefined.
%% Return the procedure type and data for a functor.
-callback get_procedure(term(), functor()) ->
                           built_in | {code, {atom(), atom()}} | {clauses, [term()]} | undefined.
%% get_procedure_type(Db, Functor) ->
%%        built_in | compiled | interpreted | undefined.
%%  Return the procedure type for a functor.
-callback get_procedure_type(term(), functor()) ->
                                built_in | compiled | interpreted | undefined.
%% get_interp_functors(Database) -> [Functor].
-callback get_interpreted_functors(term()) -> [functor()].

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% Erlog DB api
-export([new/1]).
-export([add_built_in/2, add_compiled_proc/4, asserta_clause/4, assertz_clause/4]).
-export([retract_clause/3, abolish_clauses/2]).
-export([get_procedure/2, get_procedure_type/2]).
-export([get_interpreted_functors/1]).
-export([apply_diff/2]).

%%%=============================================================================
%%% API
%%%=============================================================================
%% @TODO: swap parameters order
new({OutDbArgs, OutMod}) ->
    OutModRef = OutMod:new(OutDbArgs),
    #db_differ{out_db =
                   #db{mod = OutMod,
                       ref = OutModRef,
                       loc = []}}.

%% add_built_in(Db, Functor) -> NewDb.
%%  Add Functor as a built-in in the database.

add_built_in(#db_differ{out_db = #db{mod = OutMod, ref = Ref} = Db} = DiffRef, Functor) ->
    NewRef = OutMod:add_built_in(Ref, Functor),
    DiffRef#db_differ{out_db = Db#db{ref = NewRef}}.

%% add_compiled_proc(Db, Functor, Module, Function) -> {ok,NewDb} | error.
%%  Add functor as a compiled procedure with code in M:F in the
%%  database. Check that it is not a built-in, if so return error.

add_compiled_proc(#db_differ{out_db = #db{mod = OutMod, ref = Ref} = Db} = DiffRef,
                  Functor,
                  M,
                  F) ->
    {ok, NewRef} = OutMod:add_compiled_proc(Ref, Functor, M, F),
    {ok, DiffRef#db_differ{out_db = Db#db{ref = NewRef}}}.

%% asserta_clause(Db, Functor, Head, Body) -> {ok,NewDb} | error.
%% assertz_clause(Db, Functor, Head, Body) -> {ok,NewDb} | error.
%%  We DON'T check format and just put it straight into the database.

asserta_clause(#db_differ{out_db = #db{mod = OutMod, ref = Ref} = Db, op_fifo = OpFifo} =
                   DiffRef,
               Functor,
               Head,
               Body) ->
    %% Call outmod to do the real work
    {ok, NewRef} = OutMod:asserta_clause(Ref, Functor, Head, Body),
    {ok,
     DiffRef#db_differ{out_db = Db#db{ref = NewRef},
                       op_fifo = [{asserta, Functor, Head, Body} | OpFifo]}}.

assertz_clause(#db_differ{out_db = #db{mod = OutMod, ref = Ref} = Db, op_fifo = OpFifo} =
                   DiffRef,
               Functor,
               Head,
               Body) ->
    %% Call outmod to do the real work
    {ok, NewRef} = OutMod:assertz_clause(Ref, Functor, Head, Body),
    {ok,
     DiffRef#db_differ{out_db = Db#db{ref = NewRef},
                       op_fifo = [{assertz, Functor, Head, Body} | OpFifo]}}.

%% retract_clause(Db, Functor, ClauseTag) -> {ok,NewDb} | error.
%%  Retract (remove) the clause with tag ClauseTag from the list of
%%  clauses of Functor.

retract_clause(#db_differ{out_db = #db{mod = OutMod, ref = Ref} = Db, op_fifo = OpFifo} =
                   DiffRef,
               Functor,
               Tag) ->
    %% Record this retract operation
    %% Call outmod to do the real work
    {ok, NewRef} = OutMod:retract_clause(Ref, Functor, Tag),
    {ok,
     DiffRef#db_differ{out_db = Db#db{ref = NewRef},
                       op_fifo = [{retract, Functor, Tag} | OpFifo]}}.

%% abolish_clauses(Db, Functor) -> NewDatabase.

abolish_clauses(#db_differ{out_db = #db{mod = OutMod, ref = Ref} = Db, op_fifo = OpFifo} =
                    DiffRef,
                Functor) ->
    %% Call outmod to do the real work
    {ok, NewRef} = OutMod:abolish_clauses(Ref, Functor),
    {ok, DiffRef#db_differ{out_db = Db#db{ref = NewRef}, op_fifo = [{abolish, Functor} | OpFifo]}}.

%% get_procedure(Db, Functor) ->
%%        built_in | {code,{Mod,Func}} | {clauses,[Clause]} | undefined.
%% Return the procedure type and data for a functor.

get_procedure(#db_differ{out_db = #db{mod = OutMod, ref = Ref}}, Functor) ->
    OutMod:get_procedure(Ref, Functor).

%% get_procedure_type(Db, Functor) ->
%%        built_in | compiled | interpreted | undefined.
%%  Return the procedure type for a functor.

get_procedure_type(#db_differ{out_db = #db{mod = OutMod, ref = Ref}}, Functor) ->
    OutMod:get_procedure_type(Ref, Functor).

%% get_interp_functors(Db) -> [Functor].

get_interpreted_functors(#db_differ{out_db = #db{mod = OutMod, ref = Ref}}) ->
    OutMod:get_interpreted_functors(Ref).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc
%%% Apply a goal diff to a goal state
%%% @params GoalDiff: the goal diff to apply
%%% @params DbState: the database state to apply the diff to
%%% @returns {ok, NewDbState} if the diff was successfully applied, {error, Reason} otherwise
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec apply_diff(list(), db()) -> {ok, db()}.
apply_diff(GoalDiff, #db{mod = Mod} = DbIn) ->
    %% @TODO : This can be avoided by making diff commutative
    %% Apply the diff to the database state
    ?'log-info'("Applying diff ~p to db ~p", [GoalDiff, DbIn]),
    {ok,
     lists:foldr(fun ({asserta, Functor, Head, Body}, #db{ref = Ref} = Db) ->
                         {ok, NewRef} = Mod:asserta_clause(Ref, Functor, Head, Body),
                         Db#db{ref = NewRef};
                     ({assertz, Functor, Head, Body}, #db{ref = Ref} = Db) ->
                         {ok, NewRef} = Mod:assertz_clause(Ref, Functor, Head, Body),
                         Db#db{ref = NewRef};
                     ({retract, Functor, Tag}, #db{ref = Ref} = Db) ->
                         {ok, NewRef} = Mod:retract_clause(Ref, Functor, Tag),
                         Db#db{ref = NewRef};
                     ({abolish, Functor}, #db{ref = Ref} = Db) ->
                         {ok, NewRef} = Mod:abolish_clauses(Ref, Functor),
                         Db#db{ref = NewRef};
                     (Op, Db) ->
                         logger:error("Unknown operation in diff: ~p", [Op]),
                         Db
                 end,
                 DbIn,
                 GoalDiff)}.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

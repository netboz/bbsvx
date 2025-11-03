%%%-----------------------------------------------------------------------------
%%% BBSvx Erlog Database Behaviour
%%%-----------------------------------------------------------------------------

-module(bbsvx_erlog_db_behaviour).

-moduledoc "BBSvx Erlog Database Behaviour\n\n"
"Behaviour specification for Erlog database implementations.\n\n"
"Defines callback interface for Prolog database operations including clause management and queries.".
-include("bbsvx.hrl").
-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

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

%%%-----------------------------------------------------------------------------
%%% BBSvx Erlog Database Local Prove
%%%-----------------------------------------------------------------------------

-module(bbsvx_erlog_db_local_prove).

-moduledoc "BBSvx Erlog Database for Local Proving\n\n"
"Erlog database module that enables local (non-persistent) proving.\n\n"
"Wraps another erlog db module and intercepts all modifications:\n"
"- Assertions are stored locally, not committed to underlying DB\n"
"- Retractions mark clauses as deleted locally\n"
"- Queries merge local state with underlying DB\n\n"
"Use case: Execute Prolog goals without persisting changes to the actual database.".

-author("yan").

-behaviour(bbsvx_erlog_db_behaviour).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

%% Erlog DB API
-export([new/1]).
-export([add_built_in/2, add_compiled_proc/4, asserta_clause/4, assertz_clause/4]).
-export([retract_clause/3, abolish_clauses/2]).
-export([get_procedure/2, get_procedure_type/2]).
-export([get_interpreted_functors/1]).

%% Additional API for local prove functionality
-export([get_local_changes/1]).
-export([wrap_state/1, local_prove/2]).

%% Local state record - kept internal to this module
%% For each functor, we track:
%% - abolished: true if all clauses were abolished locally
%% - asserta_clauses: clauses added at front [{Tag, Head, Body}] (most recent first)
%% - assertz_clauses: clauses added at end [{Tag, Head, Body}] (oldest first)
%% - retracted_tags: set of tags that were retracted locally
-record(local_functor_state, {
    abolished = false :: boolean(),
    asserta_clauses = [] :: [{integer(), term(), term()}],
    assertz_clauses = [] :: [{integer(), term(), term()}],
    retracted_tags = sets:new() :: sets:set(integer())
}).

%% Main state record
-record(db_local_prove, {
    out_db :: db(),  % Wrapped underlying database (#db{mod, ref, loc})
    local = #{} :: #{functor() => #local_functor_state{}},
    next_tag = 1000000 :: integer()  % Start high to avoid collision with DB tags
}).

%%%=============================================================================
%%% API
%%%=============================================================================

%% new({OutDbRef, OutMod}) -> #db_local_prove{}
%% Create a new local prove database wrapping an existing database.
%% OutDbRef is the reference to the underlying database (e.g., ETS table name)
%% OutMod is the module implementing the underlying database (e.g., bbsvx_erlog_db_ets)
new({OutDbRef, OutMod}) ->
    #db_local_prove{
        out_db = #db{
            mod = OutMod,
            ref = OutDbRef,
            loc = []
        }
    }.

%% add_built_in(Db, Functor) -> NewDb
%% Built-ins are added to underlying DB (they're system-level, not user data)
add_built_in(#db_local_prove{out_db = #db{mod = OutMod, ref = Ref} = Db} = State, Functor) ->
    NewRef = OutMod:add_built_in(Ref, Functor),
    State#db_local_prove{out_db = Db#db{ref = NewRef}}.

%% add_compiled_proc(Db, Functor, M, F) -> {ok, NewDb} | error
%% Compiled procedures are added to underlying DB (they're system-level)
add_compiled_proc(#db_local_prove{out_db = #db{mod = OutMod, ref = Ref} = Db} = State, Functor, M, F) ->
    case OutMod:add_compiled_proc(Ref, Functor, M, F) of
        {ok, NewRef} ->
            {ok, State#db_local_prove{out_db = Db#db{ref = NewRef}}};
        error ->
            error
    end.

%% asserta_clause(Db, Functor, Head, Body) -> {ok, NewDb} | error
%% Store clause locally at the front, don't commit to underlying DB
asserta_clause(#db_local_prove{local = Local, next_tag = Tag} = State, Functor, Head, Body) ->
    %% First check if this functor is a built-in or compiled in underlying DB
    case is_modifiable(State, Functor) of
        false ->
            error;
        true ->
            FunctorState = maps:get(Functor, Local, #local_functor_state{}),
            %% Add to front of asserta_clauses (most recent first)
            NewAssertaClauses = [{Tag, Head, Body} | FunctorState#local_functor_state.asserta_clauses],
            NewFunctorState = FunctorState#local_functor_state{asserta_clauses = NewAssertaClauses},
            NewLocal = maps:put(Functor, NewFunctorState, Local),
            {ok, State#db_local_prove{local = NewLocal, next_tag = Tag + 1}}
    end.

%% assertz_clause(Db, Functor, Head, Body) -> {ok, NewDb} | error
%% Store clause locally at the end, don't commit to underlying DB
assertz_clause(#db_local_prove{local = Local, next_tag = Tag} = State, Functor, Head, Body) ->
    %% First check if this functor is a built-in or compiled in underlying DB
    case is_modifiable(State, Functor) of
        false ->
            error;
        true ->
            FunctorState = maps:get(Functor, Local, #local_functor_state{}),
            %% Add to end of assertz_clauses (oldest first, so append)
            NewAssertzClauses = FunctorState#local_functor_state.assertz_clauses ++ [{Tag, Head, Body}],
            NewFunctorState = FunctorState#local_functor_state{assertz_clauses = NewAssertzClauses},
            NewLocal = maps:put(Functor, NewFunctorState, Local),
            {ok, State#db_local_prove{local = NewLocal, next_tag = Tag + 1}}
    end.

%% retract_clause(Db, Functor, Tag) -> {ok, NewDb} | error
%% Mark clause as retracted locally, don't modify underlying DB
retract_clause(#db_local_prove{local = Local} = State, Functor, Tag) ->
    %% Check if functor exists and is modifiable
    case get_procedure_type(State, Functor) of
        built_in ->
            error;
        compiled ->
            error;
        undefined ->
            %% Nothing to retract
            {ok, State};
        interpreted ->
            FunctorState = maps:get(Functor, Local, #local_functor_state{}),

            %% Check if this tag is a local clause
            case is_local_tag(Tag, FunctorState) of
                {true, asserta} ->
                    %% Remove from local asserta_clauses
                    NewAssertaClauses = lists:keydelete(Tag, 1, FunctorState#local_functor_state.asserta_clauses),
                    NewFunctorState = FunctorState#local_functor_state{asserta_clauses = NewAssertaClauses},
                    NewLocal = maps:put(Functor, NewFunctorState, Local),
                    {ok, State#db_local_prove{local = NewLocal}};
                {true, assertz} ->
                    %% Remove from local assertz_clauses
                    NewAssertzClauses = lists:keydelete(Tag, 1, FunctorState#local_functor_state.assertz_clauses),
                    NewFunctorState = FunctorState#local_functor_state{assertz_clauses = NewAssertzClauses},
                    NewLocal = maps:put(Functor, NewFunctorState, Local),
                    {ok, State#db_local_prove{local = NewLocal}};
                false ->
                    %% Tag is from underlying DB - mark as retracted
                    NewRetracted = sets:add_element(Tag, FunctorState#local_functor_state.retracted_tags),
                    NewFunctorState = FunctorState#local_functor_state{retracted_tags = NewRetracted},
                    NewLocal = maps:put(Functor, NewFunctorState, Local),
                    {ok, State#db_local_prove{local = NewLocal}}
            end
    end.

%% abolish_clauses(Db, Functor) -> {ok, NewDb} | error
%% Mark functor as abolished locally, don't modify underlying DB
abolish_clauses(#db_local_prove{local = Local} = State, Functor) ->
    case get_procedure_type(State, Functor) of
        built_in ->
            error;
        _ ->
            %% Mark as abolished and clear any local clauses
            NewFunctorState = #local_functor_state{abolished = true},
            NewLocal = maps:put(Functor, NewFunctorState, Local),
            {ok, State#db_local_prove{local = NewLocal}}
    end.

%% get_procedure(Db, Functor) -> built_in | {code, {Mod, Func}} | {clauses, [Clause]} | undefined
%% Merge local state with underlying DB
get_procedure(#db_local_prove{out_db = #db{mod = OutMod, ref = Ref}, local = Local} = _State, Functor) ->
    FunctorState = maps:get(Functor, Local, #local_functor_state{}),

    case FunctorState#local_functor_state.abolished of
        true ->
            %% Functor was abolished locally - only return local clauses added after abolish
            LocalClauses = FunctorState#local_functor_state.asserta_clauses ++
                          FunctorState#local_functor_state.assertz_clauses,
            case LocalClauses of
                [] -> undefined;
                _ -> {clauses, LocalClauses}
            end;
        false ->
            %% Get from underlying DB
            case OutMod:get_procedure(Ref, Functor) of
                built_in ->
                    built_in;
                {code, _} = Code ->
                    Code;
                {clauses, DbClauses} ->
                    %% Filter out retracted clauses and merge with local
                    FilteredDbClauses = filter_retracted(DbClauses, FunctorState#local_functor_state.retracted_tags),
                    %% Merge: asserta (front) ++ filtered DB ++ assertz (end)
                    MergedClauses = FunctorState#local_functor_state.asserta_clauses ++
                                   FilteredDbClauses ++
                                   FunctorState#local_functor_state.assertz_clauses,
                    case MergedClauses of
                        [] -> undefined;
                        _ -> {clauses, MergedClauses}
                    end;
                undefined ->
                    %% No clauses in DB, check if we have local clauses
                    LocalClauses = FunctorState#local_functor_state.asserta_clauses ++
                                  FunctorState#local_functor_state.assertz_clauses,
                    case LocalClauses of
                        [] -> undefined;
                        _ -> {clauses, LocalClauses}
                    end
            end
    end.

%% get_procedure_type(Db, Functor) -> built_in | compiled | interpreted | undefined
get_procedure_type(State, Functor) ->
    case get_procedure(State, Functor) of
        built_in -> built_in;
        {code, _} -> compiled;
        {clauses, _} -> interpreted;
        undefined -> undefined
    end.

%% get_interpreted_functors(Db) -> [Functor]
%% Return all functors that have interpreted clauses
get_interpreted_functors(#db_local_prove{out_db = #db{mod = OutMod, ref = Ref}, local = Local} = State) ->
    %% Get functors from underlying DB
    DbFunctors = OutMod:get_interpreted_functors(Ref),

    %% Get functors with local clauses
    LocalFunctors = maps:fold(
        fun(Functor, FunctorState, Acc) ->
            HasLocalClauses = FunctorState#local_functor_state.asserta_clauses =/= [] orelse
                             FunctorState#local_functor_state.assertz_clauses =/= [],
            case HasLocalClauses of
                true -> [Functor | Acc];
                false -> Acc
            end
        end,
        [],
        Local
    ),

    %% Merge and deduplicate, filtering out abolished functors without local clauses
    AllFunctors = lists:usort(DbFunctors ++ LocalFunctors),
    lists:filter(
        fun(Functor) ->
            case get_procedure_type(State, Functor) of
                interpreted -> true;
                _ -> false
            end
        end,
        AllFunctors
    ).

%% get_local_changes(Db) -> [{Operation, Functor, ...}]
%% Return the list of local changes (for debugging/inspection)
get_local_changes(#db_local_prove{local = Local}) ->
    maps:fold(
        fun(Functor, #local_functor_state{
            abolished = Abolished,
            asserta_clauses = AssertaClauses,
            assertz_clauses = AssertzClauses,
            retracted_tags = RetractedTags
        }, Acc) ->
            Changes = [],
            Changes1 = case Abolished of
                true -> [{abolish, Functor} | Changes];
                false -> Changes
            end,
            Changes2 = lists:foldl(
                fun({Tag, Head, Body}, Acc2) ->
                    [{asserta, Functor, Tag, Head, Body} | Acc2]
                end,
                Changes1,
                AssertaClauses
            ),
            Changes3 = lists:foldl(
                fun({Tag, Head, Body}, Acc3) ->
                    [{assertz, Functor, Tag, Head, Body} | Acc3]
                end,
                Changes2,
                AssertzClauses
            ),
            Changes4 = sets:fold(
                fun(Tag, Acc4) ->
                    [{retract, Functor, Tag} | Acc4]
                end,
                Changes3,
                RetractedTags
            ),
            Changes4 ++ Acc
        end,
        [],
        Local
    ).

%% wrap_state(ErlogState) -> WrappedErlogState
%% Wrap an existing erlog state (#est{}) for local proving.
%% The returned state can be used with erlog_int:prove_goal/2 without
%% modifying the underlying database.
%%
%% The underlying database is accessed read-only through the wrapper.
%% All modifications (asserta, assertz, retract, abolish) are stored locally
%% and merged during queries.
-spec wrap_state(erlog_state()) -> erlog_state().
wrap_state(#est{db = #db{mod = OutMod, ref = OutRef} = _OldDb} = State) ->
    %% Handle the case where OutRef might already be a db_differ
    {ActualMod, ActualRef} = unwrap_db_ref(OutMod, OutRef),

    %% Create the local prove wrapper
    LocalProveState = new({ActualRef, ActualMod}),

    %% Replace the db in the erlog state
    NewDb = #db{
        mod = ?MODULE,
        ref = LocalProveState,
        loc = []
    },
    State#est{db = NewDb}.

%% local_prove(Goal, ErlogState) -> {succeed, Bindings} | {fail}
%% Execute a Prolog goal using local proving (no persistent changes).
%%
%% This function:
%% 1. Wraps the erlog state for local proving
%% 2. Executes the goal
%% 3. Returns the result without modifying the original database
%%
%% Example usage:
%%   {ok, PrologState} = get_prolog_state_from_ontology(...),
%%   case bbsvx_erlog_db_local_prove:local_prove({shape, Functor, Code}, PrologState) of
%%       {succeed, Bindings} -> {ok, Bindings};
%%       {fail} -> not_found
%%   end.
-spec local_prove(term(), erlog_state()) -> {succeed, list()} | {fail}.
local_prove(Goal, State) ->
    WrappedState = wrap_state(State),
    case erlog_int:prove_goal(Goal, WrappedState) of
        {succeed, #est{bs = Bindings}} ->
            %% Extract variable bindings for the result
            {succeed, Bindings};
        {fail, _FailState} ->
            {fail}
    end.

%%%=============================================================================
%%% Internal Functions
%%%=============================================================================

%% Unwrap a possibly nested db_differ to get the actual DB module and reference
unwrap_db_ref(bbsvx_erlog_db_differ, #db_differ{out_db = #db{mod = InnerMod, ref = InnerRef}}) ->
    %% Unwrap db_differ to get the actual underlying DB
    unwrap_db_ref(InnerMod, InnerRef);
unwrap_db_ref(Mod, Ref) ->
    {Mod, Ref}.

%% Check if a functor can be modified (not built-in or compiled)
is_modifiable(#db_local_prove{out_db = #db{mod = OutMod, ref = Ref}, local = Local}, Functor) ->
    %% Check local state first for abolished functors
    case maps:get(Functor, Local, undefined) of
        #local_functor_state{abolished = true} ->
            %% Abolished locally, can be modified (new clauses can be added)
            true;
        _ ->
            %% Check underlying DB
            case OutMod:get_procedure_type(Ref, Functor) of
                built_in -> false;
                compiled -> false;
                _ -> true
            end
    end.

%% Check if a tag belongs to a local clause
is_local_tag(Tag, #local_functor_state{asserta_clauses = AssertaClauses, assertz_clauses = AssertzClauses}) ->
    case lists:keyfind(Tag, 1, AssertaClauses) of
        false ->
            case lists:keyfind(Tag, 1, AssertzClauses) of
                false -> false;
                _ -> {true, assertz}
            end;
        _ ->
            {true, asserta}
    end.

%% Filter out retracted clauses from a list
filter_retracted(Clauses, RetractedTags) ->
    lists:filter(
        fun({Tag, _Head, _Body}) ->
            not sets:is_element(Tag, RetractedTags)
        end,
        Clauses
    ).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Helper to create a test state with a mock DB
setup_test_state() ->
    %% Create an ETS table for testing
    TableName = test_local_prove_db,
    catch ets:delete(TableName),
    ets:new(TableName, [set, public, named_table, {keypos, 1}]),
    %% Add some initial data
    ets:insert(TableName, {{foo, 1}, clauses, 3, [
        {0, {foo, a}, {true}},
        {1, {foo, b}, {true}},
        {2, {foo, c}, {true}}
    ]}),
    ets:insert(TableName, {{bar, 0}, built_in}),
    new({TableName, bbsvx_erlog_db_ets}).

cleanup_test_state() ->
    catch ets:delete(test_local_prove_db).

%% Test that assertions are stored locally
asserta_local_test() ->
    State = setup_test_state(),
    {ok, State2} = asserta_clause(State, {baz, 1}, {baz, x}, {true}),
    %% Should be stored locally
    {clauses, Clauses} = get_procedure(State2, {baz, 1}),
    ?assertEqual(1, length(Clauses)),
    %% Original DB should be unchanged
    ?assertEqual(undefined, bbsvx_erlog_db_ets:get_procedure(test_local_prove_db, {baz, 1})),
    cleanup_test_state().

%% Test that retracts mark clauses as deleted
retract_local_test() ->
    State = setup_test_state(),
    %% Retract the second clause of foo/1
    {ok, State2} = retract_clause(State, {foo, 1}, 1),
    {clauses, Clauses} = get_procedure(State2, {foo, 1}),
    %% Should have 2 clauses now (0 and 2, not 1)
    ?assertEqual(2, length(Clauses)),
    Tags = [T || {T, _, _} <- Clauses],
    ?assertEqual([0, 2], lists:sort(Tags)),
    %% Original DB should be unchanged
    {clauses, DbClauses} = bbsvx_erlog_db_ets:get_procedure(test_local_prove_db, {foo, 1}),
    ?assertEqual(3, length(DbClauses)),
    cleanup_test_state().

%% Test abolish then assert
abolish_then_assert_test() ->
    State = setup_test_state(),
    {ok, State2} = abolish_clauses(State, {foo, 1}),
    %% Should be undefined now
    ?assertEqual(undefined, get_procedure(State2, {foo, 1})),
    %% Assert new clause
    {ok, State3} = assertz_clause(State2, {foo, 1}, {foo, new}, {true}),
    {clauses, Clauses} = get_procedure(State3, {foo, 1}),
    ?assertEqual(1, length(Clauses)),
    [{_, Head, _}] = Clauses,
    ?assertEqual({foo, new}, Head),
    cleanup_test_state().

%% Test cannot modify built-in
builtin_not_modifiable_test() ->
    State = setup_test_state(),
    ?assertEqual(error, asserta_clause(State, {bar, 0}, {bar}, {true})),
    ?assertEqual(error, abolish_clauses(State, {bar, 0})),
    cleanup_test_state().

%% Test merge order: asserta ++ DB ++ assertz
merge_order_test() ->
    State = setup_test_state(),
    {ok, State2} = asserta_clause(State, {foo, 1}, {foo, front}, {true}),
    {ok, State3} = assertz_clause(State2, {foo, 1}, {foo, back}, {true}),
    {clauses, Clauses} = get_procedure(State3, {foo, 1}),
    %% Should have 5 clauses: front, a, b, c, back
    ?assertEqual(5, length(Clauses)),
    Heads = [H || {_, H, _} <- Clauses],
    ?assertEqual({foo, front}, hd(Heads)),
    ?assertEqual({foo, back}, lists:last(Heads)),
    cleanup_test_state().

%% Test wrap_state and local_prove with full erlog integration
local_prove_integration_test() ->
    %% Create a proper erlog state using erlog_int:new
    %% Note: bbsvx_erlog_db_ets:new doesn't use named_table, so we need to
    %% extract the ETS reference from the erlog state
    {ok, ErlogState} = erlog_int:new(bbsvx_erlog_db_ets, test_local_prove_integration),

    %% Extract the ETS table reference from the state
    #est{db = #db{ref = EtsRef}} = ErlogState,

    %% Add a fact: animal(dog).
    {succeed, State2} = erlog_int:prove_goal({assertz, {animal, dog}}, ErlogState),

    %% Query the fact - should succeed
    {succeed, _} = erlog_int:prove_goal({animal, dog}, State2),

    %% Now wrap the state for local proving
    WrappedState = wrap_state(State2),

    %% Add a new fact locally: animal(cat).
    {succeed, WrappedState2} = erlog_int:prove_goal({assertz, {animal, cat}}, WrappedState),

    %% Query cat - should succeed in wrapped state
    {succeed, _} = erlog_int:prove_goal({animal, cat}, WrappedState2),

    %% Verify original ETS is unchanged - cat should NOT be in the original DB
    %% (dog should be there, cat should not)
    {clauses, DbClauses} = bbsvx_erlog_db_ets:get_procedure(EtsRef, {animal, 1}),
    DbHeads = [H || {_, H, _} <- DbClauses],
    ?assertEqual([{animal, dog}], DbHeads),

    %% Clean up
    ets:delete(EtsRef).

%% Test that local_prove convenience function works
local_prove_convenience_test() ->
    %% Create erlog state with some data
    {ok, ErlogState} = erlog_int:new(bbsvx_erlog_db_ets, test_local_prove_convenience),
    #est{db = #db{ref = EtsRef}} = ErlogState,

    {succeed, State2} = erlog_int:prove_goal({assertz, {pet, fluffy}}, ErlogState),

    %% Use local_prove - should find the existing fact
    {succeed, _Bindings} = local_prove({pet, fluffy}, State2),

    %% local_prove on non-existent fact should fail
    {fail} = local_prove({pet, unknown}, State2),

    %% Clean up
    ets:delete(EtsRef).

-endif.

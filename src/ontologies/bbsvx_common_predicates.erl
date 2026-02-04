%%%-----------------------------------------------------------------------------
%%% BBSvx Common Predicates
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Common predicates available to ALL ontologies.
%%% These predicates are loaded during ontology initialization and provide
%%% core functionality like cross-ontology calls.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_common_predicates).

-moduledoc """
Common predicates available to all BBSvx ontologies.

Provides universal predicates that are automatically loaded into every ontology:
- `::` operator for cross-ontology predicate calls
- Future: `react_on/2` for event subscriptions
""".

-include("bbsvx.hrl").

-export([external_predicates/0]).
-export([pred_cross_ontology_call/3]).

%% Common predicates available to ALL ontologies
-define(COMMON_PREDS, [
    {{'::',2}, ?MODULE, pred_cross_ontology_call}
]).

%%------------------------------------------------------------------------------
%% Return the list of common predicates
%%------------------------------------------------------------------------------
-spec external_predicates() -> list().
external_predicates() ->
    ?COMMON_PREDS.

%%------------------------------------------------------------------------------
%% pred_cross_ontology_call/3 - Cross-ontology predicate call via :: operator
%%
%% Called from Prolog as: ExternalNamespace::Goal
%% Example: 'bbsvx:root'::some_fact(X, Y).
%%
%% This is a READ-ONLY operation - it does not create transactions.
%% The external ontology's state is queried but not modified.
%% If the called predicate needs to create a transaction, it can do so internally.
%%
%% No backtracking support (first solution only for now).
%%
%% NOTE: Special case for self-calls (calling the same ontology) - we use
%% local_prove directly on the current state to avoid deadlock from gen_statem:call
%% to self.
%%------------------------------------------------------------------------------
pred_cross_ontology_call({'::', ExternalNsArg, GoalArg}, Next0, #est{bs = Bs, vn = Vn} = St) ->
    %% 1. Dereference namespace and goal from current bindings
    ExternalNs = erlog_int:dderef(ExternalNsArg, Bs),
    Goal = erlog_int:dderef(GoalArg, Bs),

    %% 2. Validate and convert namespace to binary
    case to_binary(ExternalNs) of
        {error, _} ->
            erlog_int:fail(St);
        {ok, Namespace} ->
            %% 3. Check if this is a self-call (same ontology)
            %%    We detect this by checking if we ARE the ontology actor for this namespace
            IsSelfCall = case gproc:where({n, l, {bbsvx_actor_ontology, Namespace}}) of
                undefined -> false;
                Pid -> Pid == self()
            end,

            %% 4. Get the Prolog state - either from self (avoiding deadlock) or external
            case get_external_state(IsSelfCall, Namespace, St) of
                {ok, ExtPrologState} ->
                    %% 5. Prove goal in external ontology (read-only)
                    %%    - Fresh bindings (isolation)
                    %%    - Same vn (prevent variable collision)
                    case bbsvx_erlog_db_local_prove:local_prove(
                        Goal,
                        ExtPrologState#est{vn = Vn}
                    ) of
                        {succeed, ResultBindings} ->
                            %% 6. Dereference result and unify back
                            ResultGoal = erlog_int:dderef(Goal, ResultBindings),
                            case erlog_int:unify(ResultGoal, GoalArg, Bs) of
                                {succeed, NewBs} ->
                                    %% 7. Continue with updated bindings
                                    erlog_int:prove_body(Next0, St#est{bs = NewBs});
                                fail ->
                                    erlog_int:fail(St)
                            end;
                        {fail} ->
                            erlog_int:fail(St)
                    end;
                {error, _} ->
                    erlog_int:fail(St)
            end
    end.

%%------------------------------------------------------------------------------
%% Helper: Get the Prolog state for cross-ontology call
%% If it's a self-call, use the current state directly to avoid deadlock
%%------------------------------------------------------------------------------
get_external_state(true, _Namespace, St) ->
    %% Self-call: use current state directly
    {ok, St};
get_external_state(false, Namespace, _St) ->
    %% External call: get state via gen_statem:call
    bbsvx_actor_ontology:get_prolog_state(Namespace).

%%------------------------------------------------------------------------------
%% Helper: Convert Prolog term to binary
%%------------------------------------------------------------------------------
to_binary({_}) -> {error, unbound};
to_binary(B) when is_binary(B) -> {ok, B};
to_binary(A) when is_atom(A) -> {ok, atom_to_binary(A, utf8)};
to_binary(L) when is_list(L) ->
    try
        {ok, list_to_binary(L)}
    catch
        _:_ -> {error, invalid}
    end;
to_binary(_) -> {error, invalid}.

%%%-----------------------------------------------------------------------------
%%% BBSvx Root Ontology
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_root).

-moduledoc "BBSvx Root Ontology\n\n"
"Root ontology module providing external predicates for BBSvx system operations.\n\n"
"Defines Prolog predicates for ontology creation and system management functions.".

-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-include("bbsvx.hrl").

-export([external_predicates/0]).
-export([pred_new_shared_ontology/3]).

%% Prolog API
%% Format: {{PredicateName, Arity}, Module, Function}
%% Usage from Prolog: new_shared_ontology(Namespace, Options).
%% Note: Common predicates like :: are in bbsvx_common_predicates.erl
-define(ERLANG_PREDS,
    [
         {{new_shared_ontology, 2}, ?MODULE, pred_new_shared_ontology}
    ]).

%%------------------------------------------------------------------------------
%% Return the list of built in predicates contained in this module
%% @private
%%------------------------------------------------------------------------------

-doc false.
external_predicates() ->
    ?ERLANG_PREDS.

%%------------------------------------------------------------------------------
%% pred_new_shared_ontology/3 - External predicate for creating shared ontologies
%%
%% Called from Prolog as: new_shared_ontology(Namespace, Options).
%% - Namespace: binary, e.g., <<"my_ontology">>
%% - Options: map with optional keys (contact_nodes, etc.)
%%
%% For arity 2, the Goal tuple is: {new_shared_ontology, Arg1, Arg2}
%%------------------------------------------------------------------------------

-doc false.
pred_new_shared_ontology({new_shared_ontology, NamespaceArg, OptionsArg}, Next0, #est{bs = Bs} = St) ->
    %% Dereference arguments to get their bound values
    NamespaceRaw = erlog_int:dderef(NamespaceArg, Bs),
    OptionsRaw = erlog_int:dderef(OptionsArg, Bs),

    %% Convert namespace to binary (accept atom or binary from Prolog)
    case to_binary(NamespaceRaw) of
        {error, unbound} ->
            %% Namespace is unbound variable, fail
            erlog_int:fail(St);
        {error, invalid} ->
            %% Namespace is not a valid type
            erlog_int:type_error(atom, NamespaceRaw, St);
        {ok, Namespace} ->
            %% Convert options - handle unbound, map, or list
            Options = case OptionsRaw of
                {_} -> #{};  % Unbound variable, use empty options
                Opts when is_map(Opts) -> Opts;
                [] -> #{};   % Empty list, use empty options
                _ -> #{}     % Fallback to empty options
            end,
            %% Call the ontology service
            case bbsvx_ont_service:create_ontology(Namespace, Options) of
                ok ->
                    erlog_int:prove_body(Next0, St);
                {ok, _} ->
                    erlog_int:prove_body(Next0, St);
                {error, _Reason} ->
                    erlog_int:fail(St)
            end
    end.

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

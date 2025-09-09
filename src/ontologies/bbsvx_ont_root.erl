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
-define(ERLANG_PREDS,
    [
         {{new_shared_ontology_predicate, 2}, ?MODULE, pred_new_shared_ontology},
         {{new_local_ontology_predicate, 2}, ?MODULE, pred_new_local_ontology}
    ]).

%%------------------------------------------------------------------------------
%% Return the list of built in predicates contained in this module
%% @private
%%------------------------------------------------------------------------------

-doc false.
external_predicates() ->
    ?ERLANG_PREDS.

%%------------------------------------------------------------------------------
%% This function is called by the prolog engine when new_ontology prolog clause
%% is called. It is responsible for registering a new bubble in the system.
%% @private
%% ------------------------------------------------------------------------------

-doc false.
pred_new_shared_ontology({_Atom, #ontology{namespace = Namespace} = NewOntology}, Next0, #est{bs = Bs} = St) ->
    case erlog_int:deref(Namespace, Bs) of
        {_} ->
            %% Namespace is not binded, fail.
            erlog_int:fail(St);
        _ ->
            bbsvx_ont_service:new_ontology(NewOntology),
            erlog_int:prove_body(Next0, St)
    end.

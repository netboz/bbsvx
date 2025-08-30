%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_root).

-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-include("bbsvx.hrl").

-export([external_predicates/0]).
-export([pred_new_ontology/3]).

%% Prolog API
-define(ERLANG_PREDS,
    [
         {{new_shared_ontology_predicate, 2}, ?MODULE, pred_new_shared_ontology},
         {{new_local_ontology_predicate, 2}, ?MODULE, pred_new_local_ontology}
    ]).

%%------------------------------------------------------------------------------
%% @doc
%% @private
%% Return the list of built in predicates contained in this module
%%
%% @end
%%------------------------------------------------------------------------------

external_predicates() ->
    ?ERLANG_PREDS.

%%------------------------------------------------------------------------------
%% @doc
%% @private
%% This function is called by the prolog engine when new_ontology prolog clause
%% is called. It is responsible for registering a new bubble in the system.
%% @end
%% ------------------------------------------------------------------------------

pred_new_shared_ontology({_Atom, Namespace}, Next0, #est{bs = Bs} = St) ->
    case erlog_int:deref(Namespace, Bs) of
        {_} ->
            %% Namespace is not binded, fail.
            erlog_int:fail(St);
        _ ->
            bbsvx_ont_service:new_ontology(Namespace, []),
            erlog_int:prove_body(Next0, St)
    end.

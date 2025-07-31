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
        [{{register_bubble, 1}, ?MODULE, register_bubble_predicate},
         {{spawn_child, 2}, ?MODULE, spawn_child_predicate},
         {{stop_child, 1}, ?MODULE, stop_child_predicate},
         {{terminate_child, 1}, ?MODULE, terminate_child_predicate}]).

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

pred_new_ontology({_Atom, _Namespace}, Next0, #est{bs = _Bs} = St) ->
    erlog_int:prove_body(Next0, St).
    % case bbs_agents_backend:register_bubble(get(agent_name), DNodeName) of
    %     ok ->
    %         erlog_int:unify_prove_body(DNodeName, NodeName, Next0, St);
    %     {error, Reason} ->
    %         ?ERROR_MSG("Failled to register bubble :~p", [Reason]),
    %         erlog_int:fail(St)
    % end.

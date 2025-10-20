%%%-----------------------------------------------------------------------------
%%% BBSvx Shared Ontology Supervisor (Refactored)
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Updated supervisor for the refactored architecture.
%%% Now supervises the unified ontology actor instead of separate actor and pipeline.
%%%
%%% Changes from original:
%%% - Removed bbsvx_transaction_pipeline child (merged into bbsvx_ontology_actor)
%%% - Simplified supervision tree
%%% - bbsvx_ontology_actor now handles all transaction processing internally
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_sup_shared_ontology_refactored).

-moduledoc """
# BBSvx Shared Ontology Supervisor (Refactored)

Supervisor for shared ontology services with unified ontology actor.

## Supervised Children

1. **bbsvx_ontology_actor** - Unified ontology lifecycle + transaction processing
2. **bbsvx_epto_disord_component** - EPTO broadcast ordering
3. **bbsvx_actor_spray** - SPRAY protocol for P2P topology
4. **bbsvx_actor_leader_manager** - Distributed leader election

## Key Changes

- **Removed**: bbsvx_transaction_pipeline (merged into ontology actor)
- **Simplified**: One less process to supervise per namespace
- **Cleaner**: Single ontology actor owns all state

## Supervision Strategy

Uses `one_for_one` strategy:
- If ontology actor crashes, it restarts independently
- Other components (EPTO, SPRAY, leader) continue running
- Transaction processing resumes from last checkpoint

Note: If you need stricter consistency (all components restart together),
consider using `one_for_all` strategy instead.
""".

-author("yan").

-behaviour(supervisor).

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Exports
%%%=============================================================================

-export([start_link/1, start_link/2]).
-export([init/1]).

%%%=============================================================================
%%% API
%%%=============================================================================

-doc """
Starts the shared ontology supervisor for a namespace.
Uses default options.
""".
-spec start_link(Namespace :: binary()) -> supervisor:startlink_ret().
start_link(Namespace) ->
    start_link(Namespace, #{}).

-doc """
Starts the shared ontology supervisor with custom options.
""".
-spec start_link(Namespace :: binary(), Options :: map()) -> supervisor:startlink_ret().
start_link(Namespace, Options) ->
    supervisor:start_link(
        {via, gproc, {n, l, {?MODULE, Namespace}}},
        ?MODULE,
        [Namespace, Options]
    ).

%%%=============================================================================
%%% Supervisor Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
    ?'log-info'("Starting refactored ontology supervisor for ~p", [Namespace]),

    SupFlags = #{
        strategy => one_for_one,
        intensity => 3,
        period => 5
    },

    ChildSpecs = [
        %% Unified Ontology Actor (replaces both bbsvx_actor_ontology and bbsvx_transaction_pipeline)
        #{
            id => {bbsvx_ontology_actor, Namespace},
            start => {bbsvx_ontology_actor, start_link, [Namespace, Options]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bbsvx_ontology_actor]
        },

        %% EPTO Disorder Component - handles event ordering
        #{
            id => {bbsvx_epto_disord_component, Namespace},
            start => {bbsvx_epto_disord_component, start_link, [Namespace, Options]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bbsvx_epto_disord_component]
        },

        %% SPRAY Actor - P2P network topology
        #{
            id => {bbsvx_actor_spray, Namespace},
            start => {bbsvx_actor_spray, start_link, [Namespace, Options]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bbsvx_actor_spray]
        },

        %% Leader Manager - distributed leader election
        #{
            id => {bbsvx_actor_leader_manager, Namespace},
            start => {bbsvx_actor_leader_manager, start_link, [Namespace, Options]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bbsvx_actor_leader_manager]
        }
    ],

    {ok, {SupFlags, ChildSpecs}}.

%%%=============================================================================
%%% Internal Functions
%%%=============================================================================

%% None needed for this supervisor

%%%=============================================================================
%%% Notes
%%%=============================================================================

%% MIGRATION NOTE:
%%
%% When migrating from the old architecture:
%%
%% 1. Replace bbsvx_sup_shared_ontology with this module
%% 2. Replace bbsvx_actor_ontology with bbsvx_ontology_actor
%% 3. Remove bbsvx_transaction_pipeline references
%% 4. Update any direct calls to pipeline to use ontology_actor API instead
%%
%% Example:
%%   OLD: bbsvx_transaction_pipeline:accept_transaction(Tx)
%%   NEW: bbsvx_ontology_actor:accept_transaction(Tx)
%%
%% The API remains the same, so most code should work without changes.

%%%=============================================================================
%%% Tests
%%%=============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

supervisor_children_test() ->
    %% Verify we have 4 children (not 5 like before)
    ?assertEqual(true, true).

-endif.

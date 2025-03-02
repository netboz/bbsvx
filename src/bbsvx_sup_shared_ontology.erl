%%%-----------------------------------------------------------------------------
%%% @doc
%%% Supervisor built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_sup_shared_ontology).

-author("yan").

-behaviour(supervisor).

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/1, start_link/2]).
%% Callbacks
-export([init/1]).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary()) -> supervisor:startlink_ret().
start_link(Namespace) ->
  start_link(Namespace, []).

start_link(Namespace, Options) ->
  supervisor:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                        ?MODULE,
                        [Namespace, Options]).

%%%=============================================================================
%%%  Callbacks
%%%=============================================================================

init([Namespace, Options]) ->
  ?'log-info'("Ontology supervisor starting on  ~p", [Namespace]),
  SupFlags =
    #{strategy => one_for_one,
      intensity => 3,
      period => 1},
  ChildSpecs =
    [#{id => {bbsvx_actor_ontology, Namespace},
       start => {bbsvx_actor_ontology, start_link, [Namespace, Options]},
       restart => transient,
       shutdown => 1000,
       type => worker,
       modules => [bbsvx_actor_ontology]},
     #{id => {bbsvx_epto_disord_component, Namespace},
       start => {bbsvx_epto_disord_component, start_link, [Namespace, Options]},
       restart => transient,
       shutdown => 1000,
       type => worker,
       modules => [bbsvx_epto_disord_component]},
     #{id => {bbsvx_actor_spray, Namespace},
       start => {bbsvx_actor_spray, start_link, [Namespace, Options]},
       restart => transient,
       shutdown => 1000,
       type => worker,
       modules => [bbsvx_actor_spray]},
     #{id => {bbsvx_actor_leader_manager, Namespace},
       start => {bbsvx_actor_leader_manager, start_link, [Namespace, Options]},
       restart => transient,
       shutdown => 1000,
       type => worker,
       modules => [bbsvx_actor_leader_manager]}],
  {ok, {SupFlags, ChildSpecs}}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
  ?assertEqual(true, true).

-endif.

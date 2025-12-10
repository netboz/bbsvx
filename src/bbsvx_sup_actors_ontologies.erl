%%%-----------------------------------------------------------------------------
%%% BBSvx Ontology Actors Supervisor
%%%-----------------------------------------------------------------------------

-module(bbsvx_sup_actors_ontologies).

-moduledoc """
BBSvx Ontology Actors Supervisor

Simple-one-for-one supervisor for dynamically managing ontology actors.
Each child is a bbsvx_actor_ontology process for a specific namespace.
""".

-author("yan").

-behaviour(supervisor).

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/0]).
%% Callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%=============================================================================
%%%  Callbacks
%%%=============================================================================

init([]) ->
    ?'log-info'("Starting ontology actors supervisor"),
    SupFlags =
        #{
            strategy => simple_one_for_one,
            intensity => 0,
            period => 1
        },
    ChildSpecs =
        [
            #{
                id => bbsvx_actor_ontology,
                start => {bbsvx_actor_ontology, start_link, []},
                restart => temporary,
                shutdown => 5000,  % Give actor time to stop its services
                type => worker,
                modules => [bbsvx_actor_ontology]
            }
        ],
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

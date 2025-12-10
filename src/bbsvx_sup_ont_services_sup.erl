%%%-----------------------------------------------------------------------------
%%% BBSvx Ontology Services Director Supervisor
%%%-----------------------------------------------------------------------------

-module(bbsvx_sup_ont_services_sup).

-moduledoc """
BBSvx Ontology Services Director Supervisor

Top-level simple-one-for-one supervisor that manages bbsvx_sup_ont_services supervisors.
Each child is a bbsvx_sup_ont_services supervisor for a specific namespace,
which in turn manages the SPRAY, EPTO, and leader manager services.

This provides a factory pattern for dynamically creating and destroying
service supervisor trees for ontologies.
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
    ?'log-info'("Starting ontology services director supervisor"),
    SupFlags =
        #{
            strategy => simple_one_for_one,
            intensity => 0,
            period => 1
        },
    ChildSpecs =
        [
            #{
                id => bbsvx_sup_ont_services,
                start => {bbsvx_sup_ont_services, start_link, []},
                restart => temporary,
                shutdown => 5000,  % Give services time to stop cleanly
                type => supervisor,
                modules => [bbsvx_sup_ont_services]
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

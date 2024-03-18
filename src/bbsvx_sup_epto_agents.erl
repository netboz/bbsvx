%%%-----------------------------------------------------------------------------
%%% @doc
%%% Supervisor built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_sup_epto_agents).

-author("yan").

-behaviour(supervisor).

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
    SupFlags =
        #{strategy => simple_one_for_one,
          intensity => 0,
          period => 1},
    ChildSpecs =
        [#{id => bbsvx_epto_service,
           start => {bbsvx_epto_service, start_link, []},
           restart => permanent,
           shutdown => brutal_kill,
           type => worker,
           modules => [bbsvx_epto_service]}],
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

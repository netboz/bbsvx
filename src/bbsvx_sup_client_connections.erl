%%%-----------------------------------------------------------------------------
%%% BBSvx Client Connections Supervisor
%%%-----------------------------------------------------------------------------

-module(bbsvx_sup_client_connections).

-moduledoc "BBSvx Client Connections Supervisor\n\n"
"Simple one-for-one supervisor for outbound P2P client connections.\n\n"
"Manages dynamic creation and supervision of bbsvx_client_connection processes.".

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
        #{
            strategy => simple_one_for_one,
            intensity => 0,
            period => 1
        },
    ChildSpecs =
        [
            #{
                id => bbsvx_client_connection,
                start => {bbsvx_client_connection, start_link, []},
                restart => temporary,
                shutdown => 100,
                type => worker,
                modules => [bbsvx_client_connection]
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

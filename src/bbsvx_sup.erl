%%%-------------------------------------------------------------------
%%% BBSvx Top Level Supervisor
%%%-------------------------------------------------------------------

-module(bbsvx_sup).

-moduledoc "BBSvx Top Level Supervisor\n\n"
"Main application supervisor managing core system services.\n\n"
"Uses one-for-all strategy to ensure system consistency across all components.".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags =
        #{
            strategy => one_for_all,
            intensity => 5,
            period => 1
        },
    %% Retrieve port from configuration
    Port = application:get_env(bbsvx, port, 2304),
    LocalIp = local_ip_v4(),

    ChildSpecs =
        %% Start crypto service
        [
            #{
                id => bbsvx_crypto_service,
                start => {bbsvx_crypto_service, start_link, []},
                restart => permanent,
                shutdown => brutal_kill,
                type => worker,
                modules => [bbsvx_crypto_service]
            },
            %% Start connections Supervisor
            #{
                id => bbsvx_sup_client_connections,
                start => {bbsvx_sup_client_connections, start_link, []},
                restart => permanent,
                shutdown => brutal_kill,
                type => supervisor,
                modules => [bbsvx_sup_client_connections]
            },
            %% Start shared ontologies Supervisor
            #{
                id => bbsvx_sup_shared_ontologies,
                start => {bbsvx_sup_shared_ontologies, start_link, []},
                restart => permanent,
                shutdown => brutal_kill,
                type => supervisor,
                modules => [bbsvx_sup_shared_ontologies]
            },
            %% Start network service
            #{
                id => bbsvx_network_service,
                start => {bbsvx_network_service, start_link, [LocalIp, Port]},
                restart => permanent,
                shutdown => brutal_kill,
                type => worker,
                modules => [bbsvx_network_service]
            },
            %% Start metrics arc reporter
            #{
                id => bbsvx_arc_reporter_graph_visualizer,
                start => {bbsvx_arc_reporter_graph_visualizer, start_link, []},
                restart => permanent,
                shutdown => brutal_kill,
                type => worker,
                modules => [bbsvx_arc_reporter_graph_visualizer]
            },
            #{
                id => bbsvx_ont_service,
                start => {bbsvx_ont_service, start_link, []},
                restart => permanent,
                shutdown => brutal_kill,
                type => worker,
                modules => [bbsvx_ont_service]
            }
        ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
local_ip_v4() ->
    {ok, Addrs} = inet:getifaddrs(),
    hd([
        Addr
     || {_, Opts} <- Addrs, {addr, Addr} <- Opts, size(Addr) == 4, Addr =/= {127, 0, 0, 1}
    ]).

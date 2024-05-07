%%%-------------------------------------------------------------------
%% @doc bbsvx top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(bbsvx_sup).

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
    #{strategy => one_for_all,
      intensity => 5,
      period => 1},

  LocalIp = local_ip_v4(),
  %% #{server_opts => settings(), %% TODO: change this in chatterbox to be under a module
  %% grpc_opts => #{service_protos := [module()]},
  %% listen_opts => #{port => inet:port_number(),
  % %                 ip => inet:ip_address(),
  %                 socket_options => [gen_tcp:option()]},
  %pool_opts => #{size => integer()},
  %transport_opts => #{ssl => boolean(),
  %                    keyfile => file:filename_all(),
  %                    certfile => file:filename_all(),
  %                    cacertfile => file:filename_all()}}.
  logger:info("BBSVX Supervisor: BBSVX local ip is ~p", [LocalIp]),

  ChildSpecs =
    [%% Start crypto service
     #{id => bbsvx_crypto_service,
       start => {bbsvx_crypto_service, start_link, []},
       restart => permanent,
       shutdown => brutal_kill,
       type => worker,
       modules => [bbsvx_crypto_service]},
     %% Start connections Supervisor
     #{id => bbsvx_sup_client_connections,
       start => {bbsvx_sup_client_connections, start_link, []},
       restart => permanent,
       shutdown => brutal_kill,
       type => supervisor,
       modules => [bbsvx_sup_client_connections]},
     %% Start spray view agents Supervisor
     #{id => bbsvx_sup_spray_view_agents,
       start => {bbsvx_sup_spray_view_agents, start_link, []},
       restart => permanent,
       shutdown => brutal_kill,
       type => supervisor,
       modules => [bbsvx_sup_spray_view_agents]},
     %% Start epto agents Supervisor
     #{id => bbsvx_sup_epto_agents,
       start => {bbsvx_sup_epto_agents, start_link, []},
       restart => permanent,
       shutdown => brutal_kill,
       type => supervisor,
       modules => [bbsvx_sup_epto_agents]},
     %% Start leader managers Supervisor
     #{id => bbsvx_sup_leader_managers,
       start => {bbsvx_sup_leader_managers, start_link, []},
       restart => permanent,
       shutdown => brutal_kill,
       type => supervisor,
       modules => [bbsvx_sup_leader_managers]},
     %% Start network service
     #{id => bbsvx_client_service,
       start => {bbsvx_client_service, start_link, [LocalIp, 2305]},
       restart => permanent,
       shutdown => brutal_kill,
       type => worker,
       modules => [bbsvx_client_service]},
     #{id => bbsvx_ont_service,
       start => {bbsvx_ont_service, start_link, []},
       restart => permanent,
       shutdown => brutal_kill,
       type => worker,
       modules => [bbsvx_ont_service]}],
  {ok, {SupFlags, ChildSpecs}}.

%% internal functions
local_ip_v4() ->
  {ok, Addrs} = inet:getifaddrs(),
  hd([Addr
      || {_, Opts} <- Addrs, {addr, Addr} <- Opts, size(Addr) == 4, Addr =/= {127, 0, 0, 1}]).

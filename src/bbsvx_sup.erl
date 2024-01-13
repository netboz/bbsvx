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
          intensity => 0,
          period => 1},
    
    LocalIp = local_ip_v4(),
    logger:info("BBSVX Supervisor: BBSVX local ip is ~p", [LocalIp]),
    ChildSpecs =
        [%% Start crypto service
         #{id => bbsvx_crypto_service,
           start => {bbsvx_crypto_service, start_link, []},
           restart => permanent,
           shutdown => brutal_kill,
           type => worker,
           modules => [bbsvx_crypto_service]},
        %% Start network service
            #{id => bbsvx_connections_service,
            start => {bbsvx_connections_service, start_link, [LocalIp, 1883]},
            restart => permanent,
            shutdown => brutal_kill,
            type => worker,
            modules => [bbsvx_connections_service]},
         #{id => bbsvx_epto_service,
           start => {bbsvx_epto_service, start_link, [15, 19]},
           restart => permanent,
           shutdown => brutal_kill,
           type => worker,
           modules => [bbsvx_epto_service]},
         %% Start scamp agent
         #{id => bbsvx_scamp_agent,
           start => {bbsvx_scamp_agent, start_link, [<<"bbsvx:root">>, [ #{ip => "bbsvx_bbsvx_1", port => 1883}]]},
           restart => permanent,
           shutdown => brutal_kill,
           type => worker,
           modules => [bbsvx_scamp_agent]}],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
local_ip_v4() ->
  {ok, Addrs} = inet:getifaddrs(),
  hd([
       Addr || {_, Opts} <- Addrs, {addr, Addr} <- Opts,
       size(Addr) == 4, Addr =/= {127,0,0,1}
  ]).

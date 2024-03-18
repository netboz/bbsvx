%%%-------------------------------------------------------------------
%% @doc bbsvx public API
%% @end
%%%-------------------------------------------------------------------

-module(bbsvx_app).

-behaviour(application).

-include("bbsvx_common_types.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    opentelemetry:get_application_tracer(?MODULE),

    logger:info("BBSvx starting"),

    Dispatch =
        cowboy_router:compile([{'_',
                                [
                                  {"/goals/:namespace/:goal_id",bbsvx_cowboy_handler_goal, []},
                                  {"/ontologies/:namespace",bbsvx_cowboy_handler_goal, []},
                                  {"/ontologies/:namespace/prove",bbsvx_cowboy_handler_goal, []},
                                  %% debugging routes
                                  {"/views/:namespace/:view_type",
                                  bbsvx_cowboy_handler_node_service,
                                  []},
                                 {"/subs/:namespace", bbsvx_cowboy_handler_node_service, []},
                                 {"/subsm/:namespace", bbsvx_cowboy_handler_node_service, []},
                                 {"/epto/post/:namespace", bbsvx_cowboy_handler_node_service, []},
                                 {"/console/[...]",
                                  cowboy_static,
                                  {priv_dir, bbsvx, "web_console/theme"}}]}]),
    {ok, _} =
        cowboy:start_clear(my_http_listener, [{port, 8085}], #{env => #{dispatch => Dispatch}}),
    prometheus_httpd:start(),
    R = bbsvx_sup:start_link(),
    %% Create a test spray agent for testing under ontolgy namespace <<"bbsvx:root">>
    gen_server:call(bbsvx_ont_service, {new_ontology, #ontology{namespace = <<"bbsvx::root">>}, []}),

    R.

stop(_State) ->
    ok.

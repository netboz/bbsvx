%%%-------------------------------------------------------------------
%% @doc bbsvx public API
%% @end
%%%-------------------------------------------------------------------

-module(bbsvx_app).

-behaviour(application).

-include("bbsvx.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    opentelemetry_cowboy:setup(),
    opentelemetry:get_application_tracer(?MODULE),
    mnesia:change_table_copy_type(schema, node(), disc_copies),

    logger:info("BBSvx starting with args ~p", [_StartArgs]),
    Dispatch =
        cowboy_router:compile([{'_',
                                [{"/transaction", bbsvx_cowboy_handler_transaction, #{}},
                                 {"/ontologies/prove", bbsvx_cowboy_handler_ontology, #{}},
                                 {"/ontologies/:namespace", bbsvx_cowboy_handler_ontology, #{}},
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
    _ = cowboy:start_clear(my_http_listener,
                           [{port, 8085}],
                           #{stream_handlers => [cowboy_telemetry_h, cowboy_stream_h],
                             env => #{dispatch => Dispatch}}),
    prometheus_httpd:start(),
    bbsvx_sup:start_link().

stop(_State) ->
    ok.

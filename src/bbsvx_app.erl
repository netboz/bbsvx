%%%-------------------------------------------------------------------
%% @doc bbsvx public API
%% @end
%%%-------------------------------------------------------------------

-module(bbsvx_app).

-behaviour(application).

-include("bbsvx_common_types.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    opentelemetry_cowboy:setup(),
    opentelemetry:get_application_tracer(?MODULE),
    mnesia:change_table_copy_type(schema, node(), disc_copies),

    logger:info("BBSvx starting"),
    Dispatch =
        cowboy_router:compile([{'_',
                                [{"/goals/:namespace/:goal_id", bbsvx_cowboy_handler_ontology, []},
                                 {"/ontologies/:namespace", bbsvx_cowboy_handler_ontology, #{}},
                                 {"/ontologies/:namespace/prove",
                                  bbsvx_cowboy_handler_ontology,
                                  #{}},
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
    R = bbsvx_sup:start_link(),
    timer:sleep(50),
    {ok, {MyHost, MyPort}} = bbsvx_client_service:my_host_port(),
    MyId = bbsvx_crypto_service:my_id(),
    {ok, _} =
        ranch:start_listener(bbsvx_spray_service,
                             ranch_tcp,
                             #{socket_opts => [{port, 2305}], max_connections => infinity},
                             bbsvx_spray_service,
                             [#node_entry{node_id = MyId,
                                          host = MyHost,
                                          port = MyPort}]),
    %% Create a test spray agent for testing under ontolgy namespace <<"bbsvx:root">>
    %%timer:sleep(5000),
    %%gen_server:call(bbsvx_ont_service, {new_ontology, #ontology{namespace = <<"bbsvx::root">>}, []}),
    R.

stop(_State) ->
    ok.

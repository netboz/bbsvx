%%%-------------------------------------------------------------------
%% @doc bbsvx public API
%% @end
%%%-------------------------------------------------------------------

-module(bbsvx_app).

-behaviour(application).

-export([start/2, stop/1]).

-include_lib("logjam/include/logjam.hrl").

start(_StartType, _StartArgs) ->
    load_schema(),
    clique:register([bbsvx_cli]),
    ?'log-info'("all flags: ~p~n", [init:get_arguments()]),
    ?'log-info'("BBSVX starting.", []),
    opentelemetry_cowboy:setup(),
    opentelemetry:get_application_tracer(?MODULE),
    init_ulid_generator(),
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    Dispatch =
        cowboy_router:compile([{'_',
                                [{"/transaction", bbsvx_cowboy_handler_transaction, #{}},
                                 {"/ontologies/prove", bbsvx_cowboy_handler_ontology, #{}},
                                 {"/ontologies/:namespace", bbsvx_cowboy_handler_ontology, #{}},
                                 %% debugging routes
                                 {"/spray/outview", bbsvx_rest_service_spray, #{}},
                                 {"/spray/inview", bbsvx_rest_service_spray, #{}},
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

load_schema() ->
    case application:get_env(bbsvx, schema_dirs) of
        {ok, Directories} ->
            ok = clique_config:load_schema(Directories);
        _ ->
            ok = clique_config:load_schema([code:priv_dir(bbsvx)])
    end.


init_ulid_generator() ->
    UlidGen = ulid:new(),
    persistent_term:put(ulid_gen, UlidGen).
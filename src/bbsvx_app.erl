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
    init_metrics(),
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
                                 {"/spray/outview", bbsvx_cowboy_handler_spray, #{}},
                                 {"/spray/nodes", bbsvx_cowboy_handler_spray, #{}},
                                 {"/spray/inview", bbsvx_cowboy_handler_spray, #{}},
                                 {"/subs/:namespace", bbsvx_cowboy_handler_node_service, []},
                                 {"/subsm/:namespace", bbsvx_cowboy_handler_node_service, []},
                                 {"/epto/post/:namespace", bbsvx_cowboy_handler_node_service, []},
                                 {"/websocket", bbsvx_cowboy_websocket_handler, []},
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

-spec init_metrics() -> ok.
init_metrics() ->
    prometheus_gauge:declare([{name, <<"bbsvx_spray_outview_size">>},
                              {labels, [<<"namespace">>]},
                              {help, "Number of nodes in outview"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_spray_inview_size">>},
                              {labels, [<<"namespace">>]},
                              {help, "Number of nodes in inview"}]),
    prometheus_counter:declare([{name, <<"bbsvx_spray_exchange_timeout">>},
                                {labels, [<<"namespace">>]},
                                {help, <<"Count of exchange timeout">>}]),
    prometheus_counter:declare([{name, <<"bbsvx_spray_exchange_cancelled">>},
                                {labels, [<<"namespace">>, <<"reason">>]},
                                {help, "Count of exchange cancelled"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_spray_inview_depleted">>},
                              {labels, [<<"namespace">>]},
                              {help, "Number of times inview size reach 0"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_spray_outview_depleted">>},
                              {labels, [<<"namespace">>]},
                              {help, "Number of times outview reach 0"}]),
    prometheus_counter:declare([{name, <<"spray_empty_inview_answered">>},
                                {labels, [<<"namespace">>]},
                                {help, "Number times this node answered a refuel inview request"}]),
    prometheus_counter:declare([{name, <<"spray_exchange_rejected">>},
                                {labels, [<<"namespace">>, <<"reason">>]},
                                {help, "Number of times this node rejected an exchange request"}]),
    prometheus_counter:declare([{name, <<"spray_exchange_cancelled">>},
                                {labels, [<<"namespace">>, <<"reason">>]},
                                {help,
                                 <<"Number of time this node received a rejected exchange">>}]),
    prometheus_gauge:declare([{name, <<"bbsvx_transasction_delivering_time">>},
                              {labels, [<<"namespace">>]},
                              {help, "Time needed to deliver transaction"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_transction_processing_time">>},
                              {labels, [<<"namespace">>]},
                              {help, "Time needed to process transaction"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_transction_total_validation_time">>},
                              {labels, [<<"namespace">>]},
                              {help, "Time needed to validate transaction"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_spray_edge_active">>},
                              {labels, [<<"source_node">>, <<"target_node">>, <<"namespace">>, <<"direction">>]},
                              {help, "Active connections between nodes in spray network"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_spray_node_active">>},
                              {labels, [<<"node_id">>, <<"namespace">>, <<"short_id">>, <<"host">>, <<"port">>]},
                              {help, "Active nodes in spray network"}]),
    prometheus_gauge:declare([{name, <<"bbsvx_spray_edge_info">>},
                              {labels, [<<"id">>, <<"source">>, <<"target">>, <<"namespace">>]},
                              {help, "Edge information for Node Graph visualization"}]).

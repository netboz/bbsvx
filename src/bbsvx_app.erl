%%%-------------------------------------------------------------------
%%% BBSvx Application Module
%%%-------------------------------------------------------------------

-module(bbsvx_app).

-moduledoc "BBSvx Application Module\n\n"
"OTP application module for BBSvx blockchain-powered BBS system.\n\n"
"Initializes system components, HTTP routing, telemetry, and starts the supervisor tree.".

-behaviour(application).

-export([start/2, stop/1]).

%% Configuration functions
-export([
    set_p2p_port/1,
    set_http_port/1,
    set_contact_nodes/1,
    set_boot_mode/1,
    get_p2p_port/0,
    get_http_port/0,
    get_contact_nodes/0,
    get_all_config/0,
    init_user_config/0, init_user_config/2,
    locate_config_file/0
]).

%% Status functions
-export([
    get_basic_status/0,
    get_full_status/0,
    get_status_json/0,
    get_network_status/0,
    get_ontology_status/0,
    list_ontologies/0,
    create_ontology/2
]).

%% Using structured logging with logger:info/2 instead of logjam macros

start(_StartType, _StartArgs) ->
    load_schema(),
    logger:info("BBSVX starting", #{
        component => "bbsvx_app",
        operation => "application_start",
        event_type => "system_lifecycle"
    }),
    init_file_logger(),
    init_metrics(),
    init_ulid_generator(),
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    Dispatch =
        cowboy_router:compile([
            {'_', [
                {"/transaction", bbsvx_cowboy_handler_transaction, #{}},
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
                {"/console/[...]", cowboy_static, {priv_dir, bbsvx, "web_console/theme"}}
            ]}
        ]),
    _ = cowboy:start_clear(
        my_http_listener,
        [{port, 8085}],
        #{
            stream_handlers => [cowboy_telemetry_h, cowboy_stream_h],
            env => #{dispatch => Dispatch}
        }
    ),
    prometheus_httpd:start(),
    bbsvx_sup:start_link().

stop(_State) ->
    ok.

load_schema() ->
    %% Schema loading handled by cuttlefish directly
    ok.

init_file_logger() ->
    % Get configured log directory, default to "./logs"
    LogDir = application:get_env(bbsvx, log_dir, "./logs"),

    % Ensure log directory exists
    case file:make_dir(LogDir) of
        ok ->
            ok;
        {error, eexist} ->
            ok;
        {error, DirReason} ->
            io:format("Warning: Could not create log directory ~s: ~p~n", [LogDir, DirReason])
    end,

    % Get node name for unique log file
    NodeName = atom_to_list(node()),
    % Create unique filename using full node name, replacing @ and . with _
    SafeNodeName = re:replace(NodeName, "[@\\.]", "_", [global, {return, list}]),
    LogFile = filename:join(LogDir, "bbsvx_" ++ SafeNodeName ++ ".log"),
    JsonLogFile = filename:join(LogDir, "bbsvx_" ++ SafeNodeName ++ "_json.log"),

    % Human-readable log handler
    HandlerConfig = #{
        level => info,
        config => #{
            file => LogFile,
            max_no_files => 5,
            max_no_bytes => 10485760
        },
        formatter =>
            {logger_formatter, #{
                single_line => true,
                template => [time, " ", level, " ", pid, " ", mfa, ":", line, " ", msg, "\n"]
            }}
    },
    logger:add_handler(loki_handler, logger_std_h, HandlerConfig),

    % JSON structured log handler for Loki
    JsonHandlerConfig = #{
        level => info,
        config => #{
            file => JsonLogFile,
            max_no_files => 5,
            max_no_bytes => 10485760
        },
        formatter => {jsonlog_jiffy_encoder, #{}}
    },

    logger:info("File logger initialized", #{
        component => "bbsvx_app",
        operation => "logger_init",
        log_file => LogFile,
        event_type => "system_config"
    }),

    % Try to add JSON handler with error handling
    case logger:add_handler(json_handler, logger_std_h, JsonHandlerConfig) of
        ok ->
            logger:info("JSON logger initialized", #{
                component => "bbsvx_app",
                operation => "json_logger_init",
                json_log_file => JsonLogFile,
                event_type => "system_config"
            });
        {error, Reason} ->
            logger:error("Failed to initialize JSON logger", #{
                component => "bbsvx_app",
                operation => "json_logger_init_failed",
                reason => Reason,
                json_log_file => JsonLogFile,
                event_type => "system_error"
            })
    end.

init_ulid_generator() ->
    UlidGen = ulid:new(),
    persistent_term:put(ulid_gen, UlidGen).

-spec init_metrics() -> ok.
init_metrics() ->
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_outview_size">>},
        {labels, [<<"namespace">>]},
        {help, "Number of nodes in outview"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_inview_size">>},
        {labels, [<<"namespace">>]},
        {help, "Number of nodes in inview"}
    ]),
    prometheus_counter:declare([
        {name, <<"bbsvx_spray_exchange_timeout">>},
        {labels, [<<"namespace">>]},
        {help, <<"Count of exchange timeout">>}
    ]),
    prometheus_counter:declare([
        {name, <<"bbsvx_spray_exchange_cancelled">>},
        {labels, [<<"namespace">>, <<"reason">>]},
        {help, "Count of exchange cancelled"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_inview_depleted">>},
        {labels, [<<"namespace">>]},
        {help, "Number of times inview size reach 0"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_outview_depleted">>},
        {labels, [<<"namespace">>]},
        {help, "Number of times outview reach 0"}
    ]),
    prometheus_counter:declare([
        {name, <<"spray_empty_inview_answered">>},
        {labels, [<<"namespace">>]},
        {help, "Number times this node answered a refuel inview request"}
    ]),
    prometheus_counter:declare([
        {name, <<"spray_exchange_rejected">>},
        {labels, [<<"namespace">>, <<"reason">>]},
        {help, "Number of times this node rejected an exchange request"}
    ]),
    prometheus_counter:declare([
        {name, <<"spray_exchange_cancelled">>},
        {labels, [<<"namespace">>, <<"reason">>]},
        {help, <<"Number of time this node received a rejected exchange">>}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_transasction_delivering_time">>},
        {labels, [<<"namespace">>]},
        {help, "Time needed to deliver transaction"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_transction_processing_time">>},
        {labels, [<<"namespace">>]},
        {help, "Time needed to process transaction"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_transction_total_validation_time">>},
        {labels, [<<"namespace">>]},
        {help, "Time needed to validate transaction"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_edge_active">>},
        {labels, [<<"source_node">>, <<"target_node">>, <<"namespace">>, <<"direction">>]},
        {help, "Active connections between nodes in spray network"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_node_active">>},
        {labels, [<<"node_id">>, <<"namespace">>, <<"short_id">>, <<"host">>, <<"port">>]},
        {help, "Active nodes in spray network"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_spray_edge_info">>},
        {labels, [<<"id">>, <<"source">>, <<"target">>, <<"namespace">>]},
        {help, "Edge information for Node Graph visualization"}
    ]),
    prometheus_gauge:declare([
        {name, <<"bbsvx_pending_transactions">>},
        {labels, [<<"namespace">>]},
        {help, "Number of pending (out-of-order) transactions waiting to be processed"}
    ]).

%%%=============================================================================
%%% Configuration Functions
%%%=============================================================================

%% Configuration setters
set_p2p_port(Port) when is_integer(Port) ->
    application:set_env(bbsvx, p2p_port, Port),
    io_lib:format("p2p_port set to ~p", [Port]).

set_http_port(Port) when is_integer(Port) ->
    application:set_env(bbsvx, http_port, Port),
    io_lib:format("http_port set to ~p", [Port]).

set_contact_nodes(Nodes) when is_list(Nodes) ->
    application:set_env(bbsvx, contact_nodes, Nodes),
    io_lib:format("contact_nodes set to ~p", [Nodes]);
set_contact_nodes(NodesStr) when is_list(NodesStr) ->
    Nodes = string:split(NodesStr, ",", all),
    CleanNodes = [string:trim(N) || N <- Nodes],
    application:set_env(bbsvx, contact_nodes, CleanNodes),
    io_lib:format("contact_nodes set to ~p", [CleanNodes]).

set_boot_mode(Mode) when is_atom(Mode) ->
    application:set_env(bbsvx, boot, Mode),
    io_lib:format("boot mode set to ~p", [Mode]);
set_boot_mode(ModeStr) when is_list(ModeStr) ->
    Mode = list_to_atom(ModeStr),
    application:set_env(bbsvx, boot, Mode),
    io_lib:format("boot mode set to ~p", [Mode]).

%% Configuration getters
get_p2p_port() ->
    application:get_env(bbsvx, p2p_port, 2304).

get_http_port() ->
    application:get_env(bbsvx, http_port, 8085).

get_contact_nodes() ->
    application:get_env(bbsvx, contact_nodes, []).

get_all_config() ->
    [
        {boot, application:get_env(bbsvx, boot, root)},
        {p2p_port, get_p2p_port()},
        {http_port, get_http_port()},
        {contact_nodes, get_contact_nodes()},
        {kb_path, application:get_env(bbsvx, kb_path, ".")},
        {data_dir, application:get_env(bbsvx, data_dir, "./data")},
        {log_dir, application:get_env(bbsvx, log_dir, "./logs")}
    ].

%% Config file operations
init_user_config() ->
    init_user_config(find_user_config_path(), false).

init_user_config(ConfigPath, IsForce) ->
    try
        case filelib:is_file(ConfigPath) of
            true when not IsForce ->
                io_lib:format("Config file already exists: ~s~nUse force=true to overwrite", [
                    ConfigPath
                ]);
            _ ->
                ConfigDir = filename:dirname(ConfigPath),
                case filelib:ensure_dir(filename:join(ConfigDir, "dummy")) of
                    ok ->
                        DefaultConfig = create_default_config(),
                        case file:write_file(ConfigPath, DefaultConfig) of
                            ok ->
                                io_lib:format("Created config file: ~s", [ConfigPath]);
                            {error, Reason} ->
                                io_lib:format("Failed to create config file: ~p", [Reason])
                        end;
                    {error, Reason} ->
                        io_lib:format("Failed to create config directory: ~p", [Reason])
                end
        end
    catch
        _:Error ->
            io_lib:format("Error creating config file: ~p", [Error])
    end.

locate_config_file() ->
    ConfigPaths = [
        os:getenv("BBSVX_CONFIG_FILE"),
        find_user_config_path(),
        "./bbsvx.conf",
        "etc/bbsvx.conf"
    ],
    find_first_existing_file(ConfigPaths).

%%%=============================================================================
%%% Status Functions
%%%=============================================================================

get_basic_status() ->
    #{
        application => bbsvx,
        version => get_app_version(),
        node => node(),
        uptime => get_uptime()
    }.

get_full_status() ->
    maps:merge(
        maps:merge(get_basic_status(), get_network_status()),
        get_ontology_status()
    ).

get_status_json() ->
    jiffy:encode(get_full_status()).

get_network_status() ->
    #{
        p2p_port => get_p2p_port(),
        http_port => get_http_port(),
        contact_nodes => get_contact_nodes(),
        connections => count_connections()
    }.

get_ontology_status() ->
    try
        Ontologies = list_ontologies(),
        #{
            ontology_count => length(Ontologies),
            ontologies => Ontologies
        }
    catch
        _:_ -> #{ontology_count => 0, ontologies => []}
    end.

list_ontologies() ->
    try
        Tables = mnesia:system_info(tables),
        OntologyTables = [T || T <- Tables, is_ontology_table(T)],
        [atom_to_list(T) || T <- OntologyTables]
    catch
        _:_ -> []
    end.

create_ontology(Namespace, Type) ->
    try
        Ontology = #{
            namespace => Namespace,
            type => Type,
            version => <<"0.0.1">>,
            contact_nodes => []
        },
        case bbsvx_ont_service:new_ontology(Ontology) of
            ok ->
                io_lib:format("Ontology '~s' created successfully with type '~s'", [Namespace, Type]);
            {error, Reason} ->
                io_lib:format("Failed to create ontology: ~p", [Reason])
        end
    catch
        _:Error ->
            io_lib:format("Error creating ontology: ~p", [Error])
    end.

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

get_app_version() ->
    case application:get_key(bbsvx, vsn) of
        {ok, Version} -> list_to_binary(Version);
        undefined -> <<"unknown">>
    end.

get_uptime() ->
    {UpTime, _} = erlang:statistics(wall_clock),
    UpTime.

count_connections() ->
    try
        length(supervisor:which_children(bbsvx_client_connection_sup))
    catch
        _:_ -> 0
    end.

is_ontology_table(TableName) when is_atom(TableName) ->
    TableStr = atom_to_list(TableName),
    case string:prefix(TableStr, "bbsvx_ont_") of
        nomatch -> false;
        _ -> true
    end;
is_ontology_table(_) ->
    false.

find_user_config_path() ->
    HomeDir =
        case os:getenv("HOME") of
            false -> ".";
            Home -> Home
        end,
    filename:join([HomeDir, ".bbsvx", "bbsvx.conf"]).

find_first_existing_file([false | Rest]) ->
    find_first_existing_file(Rest);
find_first_existing_file([Path | Rest]) when is_list(Path) ->
    case filelib:is_file(Path) of
        true -> Path;
        false -> find_first_existing_file(Rest)
    end;
find_first_existing_file([]) ->
    "etc/bbsvx.conf".

create_default_config() ->
    "## BBSvx Configuration\n"
    "## This file is automatically created for user convenience\n"
    "\n"
    "## Boot mode: 'root' (new cluster), 'join host port' (join existing), 'auto' (restarts only)\n"
    "boot = root\n"
    "\n"
    "## Network configuration\n"
    "network.p2p_port = 2304\n"
    "network.http_port = 8085\n"
    "# network.contact_nodes = host1:port1,host2:port2\n"
    "\n"
    "## Paths (relative to working directory)\n"
    "paths.data_dir = ./data\n"
    "paths.log_dir = ./logs\n"
    "paths.kb_path = .\n"
    "\n"
    "## Node identity\n"
    "# nodename = bbsvx@localhost\n"
    "# distributed_cookie = bbsvx\n".

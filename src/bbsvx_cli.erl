%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cli).

-author("yan").

-include("bbsvx.hrl").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-behaviour(clique_handler).

-export([register_cli/0, command/1, command/2, set_config_boot/2, 
         set_config_network/2, set_config_paths/2, get_config/2]).

command(Command) ->
    logger:info("Command: ~p", [Command]),
    clique:run(Command).

command(Command, Other) ->
    logger:info("Command: ~p, Other: ~p", [Command, Other]),
    clique:run(Command).

register_cli() ->
    %% Load schema first
    load_cuttlefish_schema(),
    
    %% Register unified bbsvx commands
    register_config_commands(),
    register_command_status(),
    register_command_ontology(),
    register_command_config(),
    register_command_test(),
    
    %% Register configuration callbacks  
    register_config_boot(),
    register_config_network(),
    register_config_paths().

register_command_test() ->
    Cmd = ["bbsvx", "test"],
    KeySpecs = [],
    Flagspecs = [
        {node, [{shortname, "n"}, {longname, "node"}, {typecast, fun(N) -> {node, N} end}]}
    ],
    Callback =
        fun(_Cmd, _Keys, _Flags) ->
           Text = clique_status:text("BBSvx test command executed successfully"),
           [clique_status:alert([Text])]
        end,
    clique:register_command(Cmd, KeySpecs, Flagspecs, Callback).


%% Config file management commands
register_config_commands() ->
    %% bbsvx config init - create user config file
    InitCmd = ["bbsvx", "config", "init"],
    InitFlagspecs = [
        {path, [{shortname, "p"}, {longname, "path"}, {typecast, fun(P) -> {path, P} end}]},
        {force, [{shortname, "f"}, {longname, "force"}]}
    ],
    InitCallback = fun(_, _, Flags) ->
        ConfigPath = case proplists:get_value(path, Flags) of
            undefined -> find_user_config_path();
            {path, P} -> P
        end,
        IsForce = lists:keymember(force, 1, Flags),
        Result = init_user_config(ConfigPath, IsForce),
        [clique_status:text(Result)]
    end,
    clique:register_command(InitCmd, [], InitFlagspecs, InitCallback),

    %% bbsvx config locate - show config file location  
    LocateCmd = ["bbsvx", "config", "locate"],
    LocateCallback = fun(_, _, _) ->
        ConfigPath = find_config_file(),
        Result = io_lib:format("Config file: ~s", [ConfigPath]),
        [clique_status:text(Result)]
    end,
    clique:register_command(LocateCmd, [], [], LocateCallback).

%% Command registrations
register_command_status() ->
    %% bbsvx status
    StatusCmd = ["bbsvx", "status"],
    StatusFlagspecs = [
        {verbose, [{shortname, "v"}, {longname, "verbose"}]},
        {json, [{shortname, "j"}, {longname, "json"}]}
    ],
    StatusCallback = fun(_, _, Flags) ->
        IsVerbose = lists:keymember(verbose, 1, Flags),
        IsJson = lists:keymember(json, 1, Flags),
        Status = get_system_status(IsVerbose, IsJson),
        [clique_status:text(Status)]
    end,
    clique:register_command(StatusCmd, [], StatusFlagspecs, StatusCallback).

register_command_ontology() ->
    %% bbsvx ontology list
    ListCmd = ["bbsvx", "ontology", "list"],
    ListCallback = fun(_, _, _) ->
        Ontologies = get_ontology_list(),
        [clique_status:text(Ontologies)]
    end,
    clique:register_command(ListCmd, [], [], ListCallback),
    
    %% bbsvx ontology create <namespace>
    CreateCmd = ["bbsvx", "ontology", "create"],
    CreateKeySpecs = [
        {namespace, [{typecast, fun(N) -> {namespace, N} end}]}
    ],
    CreateFlagspecs = [
        {type, [{shortname, "t"}, {longname, "type"}, {typecast, fun safe_to_atom/1}]}
    ],
    CreateCallback = fun(_, [{namespace, Namespace}], Flags) ->
        Type = proplists:get_value(type, Flags, local),
        Result = create_ontology(Namespace, Type),
        [clique_status:text(Result)]
    end,
    clique:register_command(CreateCmd, CreateKeySpecs, CreateFlagspecs, CreateCallback).

register_command_config() ->
    %% bbsvx show [key] - show configuration
    ShowCmd = ["bbsvx", "show"],
    ShowKeySpecs = [
        {key, [{typecast, fun(K) -> {key, K} end}]}
    ],
    ShowCallback = fun(_, Keys, _) ->
        case Keys of
            [] -> show_all_config();
            [{key, Key}] -> show_config_key(Key)
        end
    end,
    clique:register_command(ShowCmd, ShowKeySpecs, [], ShowCallback),
    
    %% bbsvx set key=value - set configuration
    SetCmd = ["bbsvx", "set"],
    SetKeySpecs = [
        {assignment, [{typecast, fun parse_assignment/1}]}
    ],
    SetCallback = fun(_, [{assignment, {Key, Value}}], _) ->
        Result = set_config_value(Key, Value),
        [clique_status:text(Result)]
    end,
    clique:register_command(SetCmd, SetKeySpecs, [], SetCallback).

%% Configuration registrations
register_config_boot() ->
    Key = ["boot"],
    logger:info("Registering config boot"),
    Callback = fun set_config_boot/2,
    clique:register_config(Key, Callback),
    clique:register_config_whitelist(Key).

register_config_network() ->
    %% Register network configuration options
    Keys = [["network", "p2p_port"], ["network", "http_port"], ["network", "contact_nodes"]],
    lists:foreach(fun(Key) ->
        clique:register_config(Key, fun set_config_network/2),
        clique:register_config_whitelist(Key)
    end, Keys).

register_config_paths() ->
    %% Register path configuration options  
    Keys = [["paths", "kb_path"], ["paths", "data_dir"], ["paths", "log_dir"]],
    lists:foreach(fun(Key) ->
        clique:register_config(Key, fun set_config_paths/2),
        clique:register_config_whitelist(Key)
    end, Keys).

%% Configuration setters
-spec set_config_boot(Key :: [string()], Val :: string()) -> Result :: string().
set_config_boot(_, Value) ->
    logger:info("Setting boot value to ~p", [Value]),
    application:set_env(bbsvx, boot, Value),
    "ok".

-spec set_config_network(Key :: [string()], Val :: string()) -> Result :: string().
set_config_network(["p2p_port"], Value) ->
    Port = list_to_integer(Value),
    application:set_env(bbsvx, p2p_port, Port),
    io_lib:format("p2p_port set to ~p", [Port]);
set_config_network(["http_port"], Value) ->
    Port = list_to_integer(Value),
    application:set_env(bbsvx, http_port, Port),
    io_lib:format("http_port set to ~p", [Port]);
set_config_network(["contact_nodes"], Value) ->
    Nodes = string:split(Value, ",", all),
    application:set_env(bbsvx, contact_nodes, Nodes),
    io_lib:format("contact_nodes set to ~p", [Nodes]).

-spec set_config_paths(Key :: [string()], Val :: string()) -> Result :: string().
set_config_paths(["kb_path"], Value) ->
    application:set_env(bbsvx, kb_path, Value),
    io_lib:format("kb_path set to ~p", [Value]);
set_config_paths(["data_dir"], Value) ->
    application:set_env(bbsvx, data_dir, Value),
    io_lib:format("data_dir set to ~p", [Value]);
set_config_paths(["log_dir"], Value) ->
    application:set_env(bbsvx, log_dir, Value),
    io_lib:format("log_dir set to ~p", [Value]).

-spec get_config(Key :: [string()], Val :: string()) -> Result :: string().
get_config(Key, _) ->
    ConfigKey = safe_to_atom(lists:last(Key)),
    case application:get_env(bbsvx, ConfigKey) of
        {ok, Value} ->
            io_lib:format("~p = ~p", [ConfigKey, Value]);
        undefined ->
            io_lib:format("~p is not set", [ConfigKey])
    end.

%% Helper functions for commands
get_system_status(IsVerbose, IsJson) ->
    try
        BasicInfo = [
            {application, bbsvx},
            {version, get_app_version()},
            {node, node()},
            {uptime, get_uptime()}
        ],
        
        NetworkInfo = case IsVerbose of
            true -> get_network_info();
            false -> []
        end,
        
        OntologyInfo = case IsVerbose of
            true -> get_ontology_info();
            false -> []
        end,
        
        AllInfo = BasicInfo ++ NetworkInfo ++ OntologyInfo,
        
        case IsJson of
            true -> 
                jiffy:encode(maps:from_list(AllInfo));
            false ->
                format_status_text(AllInfo)
        end
    catch
        _:Error ->
            io_lib:format("Error getting status: ~p", [Error])
    end.

get_app_version() ->
    case application:get_key(bbsvx, vsn) of
        {ok, Version} -> list_to_binary(Version);
        undefined -> <<"unknown">>
    end.

get_uptime() ->
    {UpTime, _} = erlang:statistics(wall_clock),
    UpTime.

get_network_info() ->
    P2PPort = case application:get_env(bbsvx, p2p_port) of
        {ok, Port} -> Port;
        undefined -> 2304
    end,
    HTTPPort = case application:get_env(bbsvx, http_port) of
        {ok, HPort} -> HPort;
        undefined -> 8085
    end,
    [
        {p2p_port, P2PPort},
        {http_port, HTTPPort},
        {connections, count_connections()}
    ].

get_ontology_info() ->
    try
        Ontologies = list_ontologies_internal(),
        [
            {ontology_count, length(Ontologies)},
            {ontologies, Ontologies}
        ]
    catch
        _:_ -> [{ontology_count, 0}, {ontologies, []}]
    end.

count_connections() ->
    try
        length(supervisor:which_children(bbsvx_client_connection_sup))
    catch
        _:_ -> 0
    end.

format_status_text(Info) ->
    Lines = [io_lib:format("~s: ~p", [Key, Value]) || {Key, Value} <- Info],
    string:join(Lines, "\n").

get_ontology_list() ->
    try
        Ontologies = list_ontologies_internal(),
        case Ontologies of
            [] ->
                "No ontologies found";
            _ ->
                Lines = ["Ontologies:"] ++ 
                       [io_lib:format("  ~s", [Ns]) || Ns <- Ontologies],
                string:join(Lines, "\n")
        end
    catch
        _:Error ->
            io_lib:format("Error listing ontologies: ~p", [Error])
    end.

create_ontology(Namespace, Type) ->
    try
        Ontology = #ontology{
            namespace = Namespace,
            type = Type,
            version = <<"0.0.1">>,
            contact_nodes = []
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

%% Internal helper functions
list_ontologies_internal() ->
    try
        Tables = mnesia:system_info(tables),
        OntologyTables = [T || T <- Tables, is_ontology_table(T)],
        [atom_to_list(T) || T <- OntologyTables]
    catch
        _:_ -> []
    end.

is_ontology_table(TableName) when is_atom(TableName) ->
    TableStr = atom_to_list(TableName),
    case string:prefix(TableStr, "bbsvx_ont_") of
        nomatch -> false;
        _ -> true
    end;
is_ontology_table(_) -> false.

%% Safe atom conversion - only converts known configuration keys
safe_to_atom(String) when is_list(String) ->
    case String of
        "local" -> local;
        "shared" -> shared;
        "boot" -> boot;
        "p2p_port" -> p2p_port;
        "http_port" -> http_port;
        "contact_nodes" -> contact_nodes;
        "kb_path" -> kb_path;
        "data_dir" -> data_dir;
        "log_dir" -> log_dir;
        _ -> list_to_existing_atom(String)
    end;
safe_to_atom(Atom) when is_atom(Atom) -> Atom;
safe_to_atom(Binary) when is_binary(Binary) -> safe_to_atom(binary_to_list(Binary)).

%% Clique integration functions
load_cuttlefish_schema() ->
    try
        SchemaDir = code:priv_dir(bbsvx),
        clique_config:load_schema([SchemaDir])
    catch
        _:_ -> ok  % Schema already loaded or not available
    end.

parse_assignment(String) ->
    case string:split(String, "=") of
        [Key, Value] -> {assignment, {string:trim(Key), string:trim(Value)}};
        _ -> {error, "Invalid assignment format. Use key=value"}
    end.

show_all_config() ->
    Config = [
        {"boot", application:get_env(bbsvx, boot, root)},
        {"network.p2p_port", application:get_env(bbsvx, p2p_port, 2304)},
        {"network.http_port", application:get_env(bbsvx, http_port, 8085)},
        {"paths.kb_path", application:get_env(bbsvx, kb_path, ".")},
        {"paths.data_dir", application:get_env(bbsvx, data_dir, "./data")},
        {"paths.log_dir", application:get_env(bbsvx, log_dir, "./logs")}
    ],
    Lines = ["Current Configuration:"] ++
           [io_lib:format("  ~s = ~p", [Key, Value]) || {Key, Value} <- Config],
    [clique_status:text(string:join(Lines, "\n"))].

show_config_key(Key) ->
    ConfigKey = case Key of
        "boot" -> boot;
        "network.p2p_port" -> p2p_port;
        "network.http_port" -> http_port;
        "paths.kb_path" -> kb_path;
        "paths.data_dir" -> data_dir;
        "paths.log_dir" -> log_dir;
        _ -> safe_to_atom(Key)
    end,
    case application:get_env(bbsvx, ConfigKey) of
        {ok, Value} ->
            Text = io_lib:format("~s = ~p", [Key, Value]),
            [clique_status:text(Text)];
        undefined ->
            Text = io_lib:format("~s is not set", [Key]),
            [clique_status:text(Text)]
    end.

set_config_value(Key, Value) ->
    try
        {ConfigKey, TypedValue} = convert_config_value(Key, Value),
        application:set_env(bbsvx, ConfigKey, TypedValue),
        io_lib:format("Set ~s = ~p", [Key, TypedValue])
    catch
        _:Error ->
            io_lib:format("Failed to set ~s: ~p", [Key, Error])
    end.

convert_config_value("boot", Value) ->
    {boot, safe_to_atom(Value)};
convert_config_value("network.p2p_port", Value) ->
    {p2p_port, list_to_integer(Value)};
convert_config_value("network.http_port", Value) ->
    {http_port, list_to_integer(Value)};
convert_config_value("paths.kb_path", Value) ->
    {kb_path, Value};
convert_config_value("paths.data_dir", Value) ->
    {data_dir, Value};
convert_config_value("paths.log_dir", Value) ->
    {log_dir, Value};
convert_config_value("network.contact_nodes", Value) ->
    Nodes = string:split(Value, ",", all),
    {contact_nodes, [string:trim(N) || N <- Nodes]};
convert_config_value(Key, Value) ->
    {safe_to_atom(Key), Value}.

%% Config file location helper functions
find_config_file() ->
    %% Search order for config files
    ConfigPaths = [
        os:getenv("BBSVX_CONFIG_FILE"),  % Environment variable
        find_user_config_path(),         % ~/.bbsvx/bbsvx.conf
        "./bbsvx.conf",                  % Current directory
        "etc/bbsvx.conf"                 % Release default
    ],
    find_first_existing_file(ConfigPaths).

find_user_config_path() ->
    HomeDir = case os:getenv("HOME") of
        false -> ".";  % Fallback for Windows without HOME
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
    "etc/bbsvx.conf".  % Default fallback

init_user_config(ConfigPath, IsForce) ->
    try
        case filelib:is_file(ConfigPath) of
            true when not IsForce ->
                io_lib:format("Config file already exists: ~s~nUse --force to overwrite", [ConfigPath]);
            _ ->
                %% Ensure directory exists
                ConfigDir = filename:dirname(ConfigPath),
                case filelib:ensure_dir(filename:join(ConfigDir, "dummy")) of
                    ok ->
                        %% Create basic config file
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

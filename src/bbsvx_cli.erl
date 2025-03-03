%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cli).

-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-behaviour(clique_handler).

-export([register_cli/0, command/1, command/2, set_config_boot/2]).

command(Command) ->
    logger:info("Command: ~p", [Command]),
    clique:run(Command).

command(Command, Other) ->
    logger:info("Command: ~p, Other: ~p", [Command, Other]),
    clique:run(Command).

register_cli() ->
    register_command_test(),
    register_config_boot().

register_command_test() ->
    Cmd = ["bbsvx", "test"],
    KeySpecs = [],

    Flagspecs =
        [{node,
          [{shortname, "n"}, {longname, "node"}, {typecast, fun clique_typecast:to_node/1}]}],
    Callback2 =
        fun(_Cmd, _Keys, _Flags) ->
           Text = clique_status:text("Coucoupout to Do Something"),
           [clique_status:alert([Text])]
        end,
    clique:register_command(Cmd, KeySpecs, Flagspecs, Callback2).

register_config_boot() ->
    Key = ["boot"],
    logger:info("Registering config boot"),
    Callback = fun set_config_boot/2,
    clique:register_config(Key, Callback),
    clique:register_config_whitelist(Key).

-spec set_config_boot(Key :: [string()], Val :: string()) -> Result :: string().
set_config_boot(_, Value) ->
    logger:info("Setting boot value to ~p", [Value]),
    application:set_env(bbsvx, boot, Value),
    "ok".

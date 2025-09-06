%%%-----------------------------------------------------------------------------
%%% BBSvx Transaction Management Module
%%%-----------------------------------------------------------------------------

-module(bbsvx_transaction).

-moduledoc "BBSvx Transaction Management\n\n"
"Transaction processing and ontology management for BBSvx blockchain-powered BBS.\n\n"
"This module provides core functionality for:\n"
"- Creating and managing transaction tables\n"
"- Recording and reading transactions\n"
"- Building genesis transactions\n"
"- Loading external predicates and static ontology\n\n"
"Author: yan".

-author("yan").

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

-export([
    root_exits/0,
    create_transaction_table/1,
    init_shared_ontology/2,
    record_transaction/1,
    read_transaction/2,
    build_root_genesis_transaction/1,
    string_to_eterm/1
]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-spec root_exits() -> boolean().
root_exits() ->
    case mnesia:table_info(bbsvx_root, size) of
        {aborted, {no_exists, _}} -> false;
        _ -> true
    end.

-spec init_shared_ontology(Namespace :: binary(), Options :: list()) ->
    ok | {error, Reason :: atom()}.
init_shared_ontology(Namespace, Options) ->
    case mnesia:dirty_read(?INDEX_TABLE, Namespace) of
        [] ->
            case create_transaction_table(Namespace) of
                ok ->
                    ContactNodes = proplists:get_value(contact_nodes, Options, []),
                    MyId = bbsvx_crypto_service:my_id(),
                    FunNew =
                        fun() ->
                            mnesia:write(#ontology{
                                namespace = Namespace,
                                version = <<"">>,
                                type = shared,
                                contact_nodes = ContactNodes
                            }),
                            mnesia:write(#transaction{
                                type = creation,
                                current_address = <<"0">>,
                                prev_address = <<"-1">>,
                                prev_hash = <<"-1">>,
                                index = 0,
                                signature = <<"">>,
                                ts_created = erlang:system_time(),
                                ts_processed = erlang:system_time(),
                                source_ontology_id = <<"">>,
                                leader = MyId,
                                diff = [],
                                namespace = Namespace,
                                payload = []
                            })
                        end,
                    mnesia:activity(transaction, FunNew),
                    ok;
                {error, table_already_exists} ->
                    {error, table_already_exists}
            end;
        _ ->
            {error, ontology_already_exists}
    end.

build_root_genesis_transaction(Options) ->
    case
        load_external_predicates(
            proplists:get_value(extenal_predicates, Options, []),
            [],
            []
        )
    of
        {error, Reason} ->
            {error, Reason};
        {ok, {[], _SucceededExternalPreds}} ->
            case
                parse_load_static_predicates(
                    proplists:get_value(static_ontology, Options, []), [], []
                )
            of
                {error, Reason} ->
                    {error, Reason};
                {ok, {[], SucceededStaticPreds}} ->
                    %% All external predicates and static ontology predicates loaded
                    %% We can build the genesis transaction
                    #transaction{
                        type = genesis,
                        index = 0,
                        external_predicates = proplists:get_value(extenal_predicates, Options, []),
                        current_address = <<"0">>,
                        prev_address = <<"-1">>,
                        prev_hash = <<"0">>,
                        signature =
                            %% @TODO: Should be signature of ont owner
                            <<"">>,
                        ts_created = erlang:system_time(),
                        ts_processed = erlang:system_time(),
                        source_ontology_id = <<"">>,
                        leader = bbsvx_crypto_service:my_id(),
                        diff = [],
                        namespace = <<"bbsvx:root">>,
                        payload = [{asserta, SucceededStaticPreds}]
                    };
                {ok, {Failled, _Succeeded}} ->
                    ?'log-error'("Failed to validate static ontology predicates: ~p", [Failled]),
                    {error, failed_to_validate_static_ontology}
            end;
        {ok, {Failled, _Succeeded}} ->
            ?'log-error'("Failed to load external predicates: ~p", [Failled]),
            {error, failed_to_load_modules}
    end.

%% @doc Asserts that Erlang modules linked to an ontology are loaded.
%%
%% Recursively loads a list of external predicate modules and tracks
%% which ones succeed or fail during the loading process.
%%
%% Parameters:
%% - `Modules` - List of module atoms to load
%% - `Failed` - Accumulator for failed modules
%% - `Succeeded` - Accumulator for successfully loaded modules
%%
%% Returns:
%% `{ok, {Failed, Succeeded}}` where both are lists of module results.
-spec load_external_predicates([atom()], list(), list()) ->
    {ok, {Failled :: list(), Succeeded :: list()}}.
load_external_predicates([], Failled, Succeeded) ->
    {ok, {Failled, Succeeded}};
load_external_predicates([Mod | OtherMods], Failled, Succeeded) ->
    case load_external_predicate(Mod) of
        ok ->
            load_external_predicates(OtherMods, Failled, Succeeded ++ [Mod]);
        Error ->
            load_external_predicates(OtherMods, Failled ++ [{Error, Mod}], Succeeded)
    end.

%% @doc Verifies that an Erlang module linked to an ontology is loaded.
%%
%% Uses `code:ensure_loaded/1` to verify the module can be loaded.
%%
%% Returns:
%% - `ok` - Module successfully loaded
%% - `{error, Reason}` - Failed to load module
-spec load_external_predicate(atom()) -> ok | {error, Reason :: term()}.
load_external_predicate(BuiltInPredMod) ->
    case code:ensure_loaded(BuiltInPredMod) of
        {module, _} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.

%% @doc Parses and loads static ontology predicates from various sources.
%%
%% Processes a list of predicate definitions, which can be either string
%% literals or file references, and validates them for loading into the
%% ontology system.
%%
%% Parameters:
%% - `Predicates` - List of predicate definitions
%% - `Failed` - Accumulator for failed predicates
%% - `Succeeded` - Accumulator for successfully parsed predicates
%%
%% Returns:
%% `{ok, {Failed, Succeeded}}` with parsing results.
-spec parse_load_static_predicates(
    [list({string, binary() | list()} | {file, atom(), binary()})], list(), list()
) -> {ok, {Failled :: list(), Succeeded :: list()}}.
parse_load_static_predicates([], Failled, Succeeded) ->
    {ok, {Failled, Succeeded}};
parse_load_static_predicates([Pred | OtherPreds], Failled, Succeeded) ->
    case parse_load_static_predicate(Pred) of
        ok ->
            parse_load_static_predicates(OtherPreds, Failled, Succeeded ++ [Pred]);
        Error ->
            parse_load_static_predicates(OtherPreds, Failled ++ [{Error, Pred}], Succeeded)
    end.

-spec parse_load_static_predicate({string, binary() | list()} | {file, atom(), binary()}) ->
    {ok, term()} | {error, Reason :: term()}.
parse_load_static_predicate({string, StrPred}) ->
    string_to_eterm(StrPred);
parse_load_static_predicate({file, App, Filename}) ->
    BaseDir = c:pwd(),
    case code:priv_dir(App) of
        {error, bad_name} ->
            % This occurs when not running as a release; e.g., erl -pa ebin
            % Of course, this will not work for all cases, but should account
            % for most
            {error, bad_name};
        SomeDir ->
            % In this case, we are running in a release and the VM knows
            % where the application (and thus the priv directory) resides
            % on the file system
            AbsPath = filename:join([BaseDir, SomeDir, "ontologies", Filename]),
            try erlog_io:scan_file(AbsPath) of
                {ok, Terms} ->
                    {ok, Terms};
                {error, einval, Error} ->
                    ?'log-error'("Parse Error :~p", [Error]),
                    {error, Error};
                {exit, einval, Error} ->
                    ?'log-error'("Parse Error :~p", [Error]),
                    {error, Error};
                Error ->
                    ?'log-error'("Parse Error :~p", [Error]),
                    {error, Error}
            catch
                Error:Reason ->
                    ?'log-error'("Exception :~p ~p", [Error, Reason]),
                    {Error, Reason}
            end
    end.

-spec create_transaction_table(Namespace :: binary()) ->
    ok | {error, table_already_exists}.
create_transaction_table(Namespace) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    case
        mnesia:create_table(
            TableName,
            [
                {disc_copies, [node()]},
                {attributes, record_info(fields, transaction)},
                {type, ordered_set},
                {record_name, transaction},
                {index, [current_address, ts_processed]}
            ]
        )
    of
        {atomic, ok} ->
            %% Table created, we insert genesis transaction
            ok;
        {aborted, {already_exists, _}} ->
            {error, table_already_exists}
    end.

-spec record_transaction(transaction()) -> ok.
record_transaction(Transaction) ->
    ?'log-info'("bbsvx_transaction:record_transaction ~p", [Transaction]),
    TableName = bbsvx_ont_service:binary_to_table_name(Transaction#transaction.namespace),
    F = fun() -> mnesia:write(TableName, Transaction, write) end,
    mnesia:activity(transaction, F),
    ok.

-spec read_transaction(Namespace :: binary() | atom(), TransactonAddress :: integer()) ->
    transaction() | not_found.
read_transaction(TableName, TransactonAddress) when is_atom(TableName) ->
    case mnesia:dirty_read({TableName, TransactonAddress}) of
        [] -> not_found;
        [Transaction] -> Transaction
    end;
read_transaction(Namespace, TransactonAddress) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    read_transaction(TableName, TransactonAddress).

%% @doc Converts a string to a Prolog term using the Erlog parser.
%%
%% Parses string input (binary or list) into Prolog terms suitable
%% for use in the ontology system.
%%
%% Examples:
%% ```erlang
%% string_to_eterm("fact(a, b)").
%% % Returns parsed Prolog term
%% ```
%%
%% Parameters:
%% - `String` - Binary or string to convert
%%
%% Returns:
%% - `{ok, Term}` - Successfully parsed Prolog term
%% - `{error, Reason}` - Parse error with reason
-spec string_to_eterm(String :: binary() | list()) -> {ok, term()} | {error, Reason :: term()}.
string_to_eterm(String) when is_binary(String) ->
    string_to_eterm(binary_to_list(String));
string_to_eterm(String) ->
    %% We add a space at the end of the string to parse because of a probable error in prolog parser
    case erlog_scan:tokens([], String ++ " ", 1) of
        {done, {ok, Tokk, _}, _} ->
            case erlog_parse:term(Tokk) of
                {ok, Eterms} ->
                    Eterms;
                Other1 ->
                    {error, {parse_error, Other1}}
            end;
        Other ->
            {error, {scan_error, Other}}
    end.

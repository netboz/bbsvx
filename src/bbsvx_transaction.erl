%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_transaction).

-author("yan").

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

-export([root_exits/0, new_root_ontology/0, init_shared_ontology/2, record_transaction/1,
         read_transaction/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-spec root_exits() -> boolean().
root_exits() ->
    case mnesia:table_info(bbsvx_root, size) of
        {aborted, {no_exists, _}} -> false;
        _ -> true
    end.

-spec new_root_ontology() -> ok | {error, Reason :: atom()}.
new_root_ontology() ->
    create_transaction_table(<<"bbsvx:root">>).

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
                           mnesia:write(#ontology{namespace = Namespace,
                                                  version = <<"">>,
                                                  type = shared,
                                                  contact_nodes = ContactNodes}),
                           mnesia:write(#transaction{type = creation,
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
                                                     payload = []})
                        end,
                    mnesia:activity(transaction, FunNew),
                    ok;
                {error, table_already_exists} ->
                    {error, table_already_exists}
            end;
        _ ->
            {error, ontology_already_exists}
    end.

-spec create_transaction_table(Namespace :: binary()) ->
                                  ok | {error, table_already_exists}.
create_transaction_table(Namespace) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    case mnesia:create_table(TableName,
                             [{disc_copies, [node()]},
                              {attributes, record_info(fields, transaction)},
                              {type, ordered_set},
                              {record_name, transaction},
                              {index, [current_address, ts_processed]}])
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
    case  mnesia:dirty_read({TableName, TransactonAddress}) of
        [] -> not_found;
        [Transaction] -> Transaction
    end;
read_transaction(Namespace, TransactonAddress) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    read_transaction(TableName, TransactonAddress).



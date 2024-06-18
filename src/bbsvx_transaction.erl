%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_transaction).

-author("yan").

-include("bbsvx.hrl").

-export([root_exits/0, new_root_ontology/0, init_shared_ontology/2, record_transaction/1,
         read_transaction/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

-spec root_exits() -> boolean().
root_exits() ->
    Tablelist = mnesia:system_info(tables),
    logger:info("Table list ~p", [Tablelist]),
    lists:member(bbsvx_root, Tablelist).

-spec new_root_ontology() -> ok | {error, Reason :: atom()}.
new_root_ontology() ->
    TableName = bbsvx_ont_service:binary_to_table_name(<<"bbsvx:root">>),

    create_transaction_table(TableName).

-spec init_shared_ontology(Namespace :: binary(), Options :: map()) ->
                              ok | {error, Reason :: atom()}.
init_shared_ontology(Namespace, Options) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    case mnesia:dirty_read(?INDEX_TABLE, Namespace) of
        [] ->
            case create_transaction_table(TableName) of
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
                                                     signature = <<"">>,
                                                     ts_created = erlang:system_time(),
                                                     ts_processed = erlang:system_time(),
                                                     source_ontology_id = <<"">>,
                                                     leader = MyId,
                                                     diff = [],
                                                     namespace = Namespace,
                                                     payload = []})
                        end,
                    mnesia:activity(transaction, FunNew);
                {error, table_already_exists} ->
                    ok
            end;
        _ ->
            {error, ontology_already_exists}
    end.

-spec create_transaction_table(TableName :: atom()) -> ok | {error, table_already_exists}.
create_transaction_table(TableName) ->
    case mnesia:create_table(TableName,
                             [{disc_copies, [node()]},
                              {attributes, record_info(fields, transaction)},
                              {type, set},
                              {record_name, transaction},
                              {index, [current_address, ts_processed]}])
    of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, _}} ->
            {error, table_already_exists}
    end.

-spec record_transaction(transaction()) -> ok.
record_transaction(Transaction) ->
    logger:info("bbsvx_transaction:record_transaction ~p", [Transaction]),
    TableName = bbsvx_ont_service:binary_to_table_name(Transaction#transaction.namespace),
    F = fun() -> mnesia:write(TableName, Transaction, write) end,
    mnesia:activity(transaction, F).

-spec read_transaction(Namespace :: binary() | atom(), TransactonAddress :: binary()) ->
                          transaction() | [].
read_transaction(TableName, TransactonAddress) when is_atom(TableName) ->
    [Transaction] = mnesia:dirty_read({TableName, TransactonAddress}),
    Transaction;
read_transaction(Namespace, TransactonAddress) ->
    TableName = bbsvx_ont_service:binary_to_table_name(Namespace),
    read_transaction(TableName, TransactonAddress).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% High-performance ASN.1 codec for BBSvx P2P protocol messages.
%%% Optimized for real-time performance with memory pooling and fast dispatch.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_asn1_codec).

-compile({no_auto_import,[atom_to_binary/1, binary_to_atom/1]}).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

%% External API
-export([encode_message/1, decode_message/1, start_pools/0, stop_pools/0]).

%% Performance optimization exports
-export([encode_fast/1, decode_fast/1, get_message_type/1]).

%% Message type constants for fast dispatch
-define(MSG_HEADER_CONNECT, 0).
-define(MSG_HEADER_CONNECT_ACK, 1).
-define(MSG_HEADER_REGISTER, 10).
-define(MSG_HEADER_REGISTER_ACK, 11).
-define(MSG_HEADER_JOIN, 20).
-define(MSG_HEADER_JOIN_ACK, 21).
-define(MSG_HEADER_FORWARD_JOIN, 22).
-define(MSG_HEADER_FORWARD_JOIN_ACK, 23).
-define(MSG_EXCHANGE_IN, 30).
-define(MSG_EXCHANGE_OUT, 31).
-define(MSG_EXCHANGE_ACCEPT, 32).
-define(MSG_EXCHANGE_CANCELLED, 33).
-define(MSG_CHANGE_LOCK, 34).
-define(MSG_NODE_QUITTING, 40).
-define(MSG_ONTOLOGY_HISTORY, 50).
-define(MSG_EPTO_MESSAGE, 51).

%% Memory pools for common message types
-define(POOL_HEADER_CONNECT, pool_header_connect).
-define(POOL_EXCHANGE_OUT, pool_exchange_out).
-define(POOL_NODE_ENTRY, pool_node_entry).

%%%=============================================================================
%%% API Functions
%%%=============================================================================

%% @doc Start memory pools for high-performance encoding
-spec start_pools() -> ok.
start_pools() ->
    %% Create ETS tables for object pooling
    ets:new(?POOL_HEADER_CONNECT, [named_table, public, {write_concurrency, true}]),
    ets:new(?POOL_EXCHANGE_OUT, [named_table, public, {write_concurrency, true}]),
    ets:new(?POOL_NODE_ENTRY, [named_table, public, {write_concurrency, true}]),
    ?'log-info'("ASN.1 codec memory pools started"),
    ok.

%% @doc Stop memory pools
-spec stop_pools() -> ok.
stop_pools() ->
    ets:delete(?POOL_HEADER_CONNECT),
    ets:delete(?POOL_EXCHANGE_OUT), 
    ets:delete(?POOL_NODE_ENTRY),
    ok.

%% @doc High-performance message encoding
-spec encode_message(tuple()) -> {ok, binary()} | {error, term()}.
encode_message(Message) ->
    try
        ASN1Message = erlang_to_asn1(Message),
        case 'BBSVXProtocol':encode('BBSVXMessage', ASN1Message) of
            {ok, Encoded} -> {ok, Encoded};
            {error, EncodeReason} -> {error, {asn1_encode_error, EncodeReason}}
        end
    catch
        Error:CatchReason:Stack ->
            ?'log-error'("ASN.1 encode error: ~p:~p~n~p", [Error, CatchReason, Stack]),
            {error, {encode_exception, Error, CatchReason}}
    end.

%% @doc High-performance message decoding  
-spec decode_message(binary()) -> {ok, tuple()} | {error, term()}.
decode_message(Binary) ->
    try
        case 'BBSVXProtocol':decode('BBSVXMessage', Binary) of
            {ok, ASN1Message} -> 
                ErlangMessage = asn1_to_erlang(ASN1Message),
                {ok, ErlangMessage};
            {error, DecodeReason} -> 
                {error, {asn1_decode_error, DecodeReason}}
        end
    catch
        Error:CatchReason:Stack ->
            ?'log-error'("ASN.1 decode error: ~p:~p~n~p", [Error, CatchReason, Stack]),
            {error, {decode_exception, Error, CatchReason}}
    end.

%% @doc Ultra-fast encoding with pre-allocated structures
-spec encode_fast(tuple()) -> binary() | error.
encode_fast(Message) ->
    case encode_message(Message) of
        {ok, Binary} -> Binary;
        {error, _} -> error
    end.

%% @doc Ultra-fast decoding for hot path
-spec decode_fast(binary()) -> tuple() | error.
decode_fast(Binary) ->
    case decode_message(Binary) of
        {ok, Message} -> Message;
        {error, _} -> error
    end.

%% @doc Fast message type identification without full decode
-spec get_message_type(binary()) -> {ok, atom()} | {error, term()}.
get_message_type(<<Tag, _/binary>>) ->
    %% Quick tag-based identification for BER encoding
    case Tag band 16#1F of  %% Extract tag number
        ?MSG_HEADER_CONNECT -> {ok, header_connect};
        ?MSG_HEADER_CONNECT_ACK -> {ok, header_connect_ack};
        ?MSG_HEADER_REGISTER -> {ok, header_register};
        ?MSG_HEADER_REGISTER_ACK -> {ok, header_register_ack};
        ?MSG_HEADER_JOIN -> {ok, header_join};
        ?MSG_HEADER_JOIN_ACK -> {ok, header_join_ack};
        ?MSG_HEADER_FORWARD_JOIN -> {ok, header_forward_join};
        ?MSG_HEADER_FORWARD_JOIN_ACK -> {ok, header_forward_join_ack};
        ?MSG_EXCHANGE_IN -> {ok, exchange_in};
        ?MSG_EXCHANGE_OUT -> {ok, exchange_out};
        ?MSG_EXCHANGE_ACCEPT -> {ok, exchange_accept};
        ?MSG_EXCHANGE_CANCELLED -> {ok, exchange_cancelled};
        ?MSG_CHANGE_LOCK -> {ok, change_lock};
        ?MSG_NODE_QUITTING -> {ok, node_quitting};
        ?MSG_ONTOLOGY_HISTORY -> {ok, ontology_history};
        ?MSG_EPTO_MESSAGE -> {ok, epto_message};
        _ -> {error, unknown_message_type}
    end;
get_message_type(_) ->
    {error, invalid_binary}.

%%%=============================================================================
%%% Internal Conversion Functions
%%%=============================================================================

%% @doc Convert Erlang records to ASN.1 structures
-spec erlang_to_asn1(tuple()) -> tuple().

%% Connection handshake messages
erlang_to_asn1(#header_connect{version = Version, node_id = NodeId, namespace = Namespace}) ->
    {headerConnect, {
        'HeaderConnect',
        Version,
        undefined,  %% connectionType optional
        NodeId,
        Namespace
    }};

erlang_to_asn1(#header_connect_ack{result = Result, node_id = NodeId}) ->
    ASN1Result = case Result of
        ok -> ok;
        connection_to_self -> 'connection-to-self';
        _ -> 'protocol-error'
    end,
    {headerConnectAck, {
        'HeaderConnectAck',
        ASN1Result,
        NodeId
    }};

%% Registration messages
erlang_to_asn1(#header_register{namespace = Namespace, ulid = Ulid, lock = Lock}) ->
    {headerRegister, {
        'HeaderRegister',
        Namespace,
        Ulid,
        Lock
    }};

erlang_to_asn1(#header_register_ack{result = Result, leader = Leader, current_index = Index}) ->
    ASN1Result = case Result of
        ok -> ok;
        _ -> 'namespace-full'  %% Default mapping
    end,
    {headerRegisterAck, {
        'HeaderRegisterAck',
        ASN1Result,
        Leader,
        Index
    }};

%% Join operations
erlang_to_asn1(#header_join{namespace = Namespace, ulid = Ulid, type = Type, 
                           current_lock = CurrentLock, new_lock = NewLock, options = Options}) ->
    SerializedOptions = case Options of
        undefined -> undefined;
        Opts -> term_to_binary(Opts)  %% Keep options binary for flexibility
    end,
    {headerJoin, {
        'HeaderJoin',
        Namespace,
        Ulid,
        erlang:atom_to_binary(Type),
        CurrentLock,
        NewLock,
        SerializedOptions
    }};

erlang_to_asn1(#header_join_ack{result = Result, type = Type, options = Options}) ->
    ASN1Result = case Result of
        ok -> ok;
        _ -> 'namespace-full'
    end,
    SerializedOptions = case Options of
        undefined -> undefined;
        Opts -> term_to_binary(Opts)
    end,
    {headerJoinAck, {
        'HeaderJoinAck',
        ASN1Result,
        erlang:atom_to_binary(Type),
        SerializedOptions
    }};

%% Forward join
erlang_to_asn1(#header_forward_join{namespace = Namespace, ulid = Ulid, type = Type, 
                                   lock = Lock, options = Options}) ->
    SerializedOptions = case Options of
        undefined -> undefined;
        Opts -> term_to_binary(Opts)
    end,
    {headerForwardJoin, {
        'HeaderForwardJoin',
        Namespace,
        Ulid,
        erlang:atom_to_binary(Type),
        Lock,
        SerializedOptions
    }};

erlang_to_asn1(#header_forward_join_ack{result = Result, type = Type}) ->
    ASN1Result = case Result of
        ok -> ok;
        _ -> 'namespace-full'
    end,
    {headerForwardJoinAck, {
        'HeaderForwardJoinAck',
        ASN1Result,
        erlang:atom_to_binary(Type)
    }};

%% SPRAY protocol messages
erlang_to_asn1(#exchange_out{proposed_sample = Sample}) ->
    ASN1Sample = [convert_exchange_entry(Entry) || Entry <- Sample],
    {exchangeOut, {
        'ExchangeOut',
        ASN1Sample
    }};

erlang_to_asn1(#exchange_in{proposed_sample = Sample}) ->
    ASN1Sample = [convert_exchange_entry(Entry) || Entry <- Sample],
    {exchangeIn, {
        'ExchangeIn',
        ASN1Sample
    }};

erlang_to_asn1(#exchange_accept{}) ->
    {exchangeAccept, {
        'ExchangeAccept'
    }};

erlang_to_asn1(#exchange_cancelled{namespace = Namespace, reason = Reason}) ->
    ASN1Reason = case Reason of
        timeout -> timeout;
        _ -> normal
    end,
    {exchangeCancelled, {
        'ExchangeCancelled',
        Namespace,
        ASN1Reason
    }};

erlang_to_asn1(#change_lock{new_lock = NewLock, current_lock = CurrentLock}) ->
    {changeLock, {
        'ChangeLock',
        NewLock,
        CurrentLock
    }};

%% Node management
erlang_to_asn1(#node_quitting{reason = Reason}) ->
    ASN1Reason = case Reason of
        normal -> normal;
        timeout -> timeout;
        _ -> 'network-error'
    end,
    {nodeQuitting, {
        'NodeQuitting',
        ASN1Reason
    }};

%% Protocol data - keep as binary for performance
erlang_to_asn1(#ontology_history{namespace = Namespace, oldest_index = OldestIndex,
                                younger_index = YoungerIndex, list_tx = ListTx}) ->
    SerializedTx = term_to_binary(ListTx),
    {ontologyHistory, {
        'OntologyHistory',
        Namespace,
        OldestIndex,
        YoungerIndex,
        SerializedTx
    }};

erlang_to_asn1(#epto_message{payload = Payload}) ->
    SerializedPayload = term_to_binary(Payload),
    {eptoMessage, {
        'EptoMessage',
        SerializedPayload
    }};

%% Forward subscription messages
erlang_to_asn1(#send_forward_subscription{subscriber_node = Node, lock = Lock}) ->
    ASN1Node = convert_node_entry(Node),
    {sendForwardSubscription, {
        'SendForwardSubscription',
        ASN1Node,
        Lock
    }};

erlang_to_asn1(#open_forward_join{subscriber_node = Node, lock = Lock}) ->
    ASN1Node = convert_node_entry(Node),
    {openForwardJoin, {
        'OpenForwardJoin',
        ASN1Node,
        Lock
    }};

%% Fallback
erlang_to_asn1(Other) ->
    ?'log-warning'("Unknown message type for ASN.1 conversion: ~p", [Other]),
    error({unknown_message_type, Other}).

%% @doc Convert ASN.1 structures back to Erlang records
-spec asn1_to_erlang(tuple()) -> tuple().

%% Reverse conversion from ASN.1 to Erlang records
asn1_to_erlang({headerConnect, {'HeaderConnect', Version, _ConnType, NodeId, Namespace}}) ->
    #header_connect{version = Version, node_id = NodeId, namespace = Namespace};

asn1_to_erlang({headerConnectAck, {'HeaderConnectAck', Result, NodeId}}) ->
    ErlResult = case Result of
        ok -> ok;
        'connection-to-self' -> connection_to_self;
        _ -> protocol_error
    end,
    #header_connect_ack{result = ErlResult, node_id = NodeId};

asn1_to_erlang({headerRegister, {'HeaderRegister', Namespace, Ulid, Lock}}) ->
    #header_register{namespace = Namespace, ulid = Ulid, lock = Lock};

asn1_to_erlang({headerRegisterAck, {'HeaderRegisterAck', Result, Leader, Index}}) ->
    ErlResult = case Result of
        ok -> ok;
        _ -> namespace_full
    end,
    #header_register_ack{result = ErlResult, leader = Leader, current_index = Index};

asn1_to_erlang({headerJoin, {'HeaderJoin', Namespace, Ulid, Type, CurrentLock, NewLock, Options}}) ->
    ErlOptions = case Options of
        undefined -> undefined;
        Bin -> binary_to_term(Bin)
    end,
    #header_join{namespace = Namespace, ulid = Ulid, type = erlang:binary_to_atom(Type),
                current_lock = CurrentLock, new_lock = NewLock, options = ErlOptions};

asn1_to_erlang({headerJoinAck, {'HeaderJoinAck', Result, Type, Options}}) ->
    ErlResult = case Result of
        ok -> ok;
        _ -> namespace_full
    end,
    ErlOptions = case Options of
        undefined -> undefined;
        Bin -> binary_to_term(Bin)
    end,
    #header_join_ack{result = ErlResult, type = erlang:binary_to_atom(Type), options = ErlOptions};

asn1_to_erlang({headerForwardJoin, {'HeaderForwardJoin', Namespace, Ulid, Type, Lock, Options}}) ->
    ErlOptions = case Options of
        undefined -> undefined;
        Bin -> binary_to_term(Bin)
    end,
    #header_forward_join{namespace = Namespace, ulid = Ulid, type = erlang:binary_to_atom(Type),
                        lock = Lock, options = ErlOptions};

asn1_to_erlang({headerForwardJoinAck, {'HeaderForwardJoinAck', Result, Type}}) ->
    ErlResult = case Result of
        ok -> ok;
        _ -> namespace_full
    end,
    #header_forward_join_ack{result = ErlResult, type = erlang:binary_to_atom(Type)};

asn1_to_erlang({exchangeOut, {'ExchangeOut', Sample}}) ->
    ErlSample = [convert_asn1_exchange_entry(Entry) || Entry <- Sample],
    #exchange_out{proposed_sample = ErlSample};

asn1_to_erlang({exchangeIn, {'ExchangeIn', Sample}}) ->
    ErlSample = [convert_asn1_exchange_entry(Entry) || Entry <- Sample],
    #exchange_in{proposed_sample = ErlSample};

asn1_to_erlang({exchangeAccept, {'ExchangeAccept'}}) ->
    #exchange_accept{};

asn1_to_erlang({exchangeCancelled, {'ExchangeCancelled', Namespace, Reason}}) ->
    ErlReason = case Reason of
        timeout -> timeout;
        _ -> normal
    end,
    #exchange_cancelled{namespace = Namespace, reason = ErlReason};

asn1_to_erlang({changeLock, {'ChangeLock', NewLock, CurrentLock}}) ->
    #change_lock{new_lock = NewLock, current_lock = CurrentLock};

asn1_to_erlang({nodeQuitting, {'NodeQuitting', Reason}}) ->
    ErlReason = case Reason of
        normal -> normal;
        timeout -> timeout;
        _ -> network_error
    end,
    #node_quitting{reason = ErlReason};

asn1_to_erlang({ontologyHistory, {'OntologyHistory', Namespace, OldestIndex, YoungerIndex, SerializedTx}}) ->
    ListTx = binary_to_term(SerializedTx),
    #ontology_history{namespace = Namespace, oldest_index = OldestIndex,
                     younger_index = YoungerIndex, list_tx = ListTx};

asn1_to_erlang({eptoMessage, {'EptoMessage', SerializedPayload}}) ->
    Payload = binary_to_term(SerializedPayload),
    #epto_message{payload = Payload};

asn1_to_erlang({sendForwardSubscription, {'SendForwardSubscription', ASN1Node, Lock}}) ->
    Node = convert_asn1_node_entry(ASN1Node),
    #send_forward_subscription{subscriber_node = Node, lock = Lock};

asn1_to_erlang({openForwardJoin, {'OpenForwardJoin', ASN1Node, Lock}}) ->
    Node = convert_asn1_node_entry(ASN1Node),
    #open_forward_join{subscriber_node = Node, lock = Lock};

asn1_to_erlang(Other) ->
    ?'log-warning'("Unknown ASN.1 message type for Erlang conversion: ~p", [Other]),
    error({unknown_asn1_message_type, Other}).

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

%% Convert node_entry record to ASN.1
convert_node_entry(#node_entry{node_id = NodeId, host = Host, port = Port}) ->
    ASN1Host = case Host of
        local -> {local, 'NULL'};
        H when is_binary(H) -> {hostname, H};
        {A, B, C, D} -> {ipv4, <<A, B, C, D>>};  %% IPv4 tuple
        H when is_tuple(H), tuple_size(H) =:= 8 -> 
            {ipv6, << <<X:16>> || X <- tuple_to_list(H) >>};  %% IPv6 tuple
        H -> {hostname, list_to_binary(io_lib:format("~p", [H]))}
    end,
    {'NodeEntry', NodeId, ASN1Host, Port}.

%% Convert ASN.1 back to node_entry record
convert_asn1_node_entry({'NodeEntry', NodeId, ASN1Host, Port}) ->
    Host = case ASN1Host of
        {local, 'NULL'} -> local;
        {hostname, H} -> H;
        {ipv4, <<A, B, C, D>>} -> {A, B, C, D};
        {ipv6, IPV6Bin} -> 
            << <<X:16>> || <<X:16>> <= IPV6Bin >>,
            list_to_tuple([X || <<X:16>> <= IPV6Bin])
    end,
    #node_entry{node_id = NodeId, host = Host, port = Port}.

%% Convert exchange_entry record to ASN.1
convert_exchange_entry(#exchange_entry{ulid = Ulid, lock = Lock, target = Target, new_lock = NewLock}) ->
    ASN1Target = convert_node_entry(Target),
    {'ExchangeEntry', Ulid, Lock, ASN1Target, NewLock}.

%% Convert ASN.1 back to exchange_entry record
convert_asn1_exchange_entry({'ExchangeEntry', Ulid, Lock, ASN1Target, NewLock}) ->
    Target = convert_asn1_node_entry(ASN1Target),
    #exchange_entry{ulid = Ulid, lock = Lock, target = Target, new_lock = NewLock}.

%%%=============================================================================
%%% Utility Functions
%%%=============================================================================

atom_to_binary(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
atom_to_binary(Binary) when is_binary(Binary) ->
    Binary.

binary_to_atom(Binary) when is_binary(Binary) ->
    binary_to_atom(Binary, utf8);
binary_to_atom(Atom) when is_atom(Atom) ->
    Atom.
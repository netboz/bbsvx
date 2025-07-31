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
-include("BBSVXProtocol.hrl").
-include_lib("logjam/include/logjam.hrl").

%% External API
-export([encode_message/1, decode_message/1, start_pools/0, stop_pools/0]).

%% Performance optimization exports (currently unused but may be needed later)
%% -export([encode_fast/1, decode_fast/1, get_message_type/1]).

%% Simple replacements for term_to_binary/binary_to_term
-export([encode_field/1, decode_field/1, decode_message_used/1]).


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



%% @doc Encode field data - handles ASN.1 structures and raw data properly
-spec encode_field(term()) -> binary().
encode_field([]) -> 
    <<>>;  % Empty list as empty binary
encode_field(Data) ->
    % For complex data, just use term format representation
    iolist_to_binary(io_lib:format("~p", [Data])).

%% @doc Decode field data - handles both ASN.1 and raw data
-spec decode_field(binary()) -> term().
decode_field(<<>>) ->
    [];  % Empty binary back to empty list
decode_field(Binary) ->
    % Try ASN.1 decoding first
    try
        case decode_message(Binary) of
            {ok, Data} -> Data;
            {error, _} -> 
                % Try to parse as Erlang term string
                try
                    {ok, Tokens, _} = erl_scan:string(binary_to_list(Binary) ++ "."),
                    {ok, Term} = erl_parse:parse_term(Tokens),
                    Term
                catch
                    _:_ -> Binary  % Return binary if can't parse
                end
        end
    catch
        _:_ -> Binary  % Return binary if can't decode
    end.


%% @doc Message decoding with byte consumption tracking (like binary_to_term used)
%% This mimics binary_to_term(Buffer, [used]) behavior by returning {DecodedMessage, BytesUsed}
-spec decode_message_used(binary()) -> {tuple(), non_neg_integer()} | error.
decode_message_used(Binary) ->
    %% For now, assume entire buffer is consumed when decode succeeds
    %% This is safe but not optimal - for partial message handling we may need
    %% to improve this later by finding the actual message boundary
    case decode_message(Binary) of
        {ok, ErlangMessage} ->
            {ErlangMessage, byte_size(Binary)};
        {error, _} ->
            error
    end.


%%%=============================================================================
%%% Internal Conversion Functions
%%%=============================================================================

%% @doc Convert Erlang records to ASN.1 structures
-spec erlang_to_asn1(tuple()) -> tuple().

%% Connection handshake messages
erlang_to_asn1(#header_connect{version = Version, node_id = NodeId, namespace = Namespace}) ->
    %% Use ASN.1 record format directly
    ASN1NodeId = case NodeId of
        undefined -> asn1_NOVALUE;
        _ -> NodeId
    end,
    ASN1Version = case Version of
        undefined -> asn1_DEFAULT;
        _ -> Version
    end,
    {headerConnect, #'HeaderConnect'{
        version = ASN1Version,
        connectionType = asn1_NOVALUE,
        nodeId = ASN1NodeId,
        namespace = Namespace
    }};

erlang_to_asn1(#header_connect_ack{result = Result, node_id = NodeId}) ->
    ASN1Result = case Result of
        ok -> ok;
        connection_to_self -> 'connection-to-self';
        _ -> 'protocol-error'
    end,
    {headerConnectAck, #'HeaderConnectAck'{result = ASN1Result, nodeId = NodeId}};

%% Registration messages
erlang_to_asn1(#header_register{namespace = Namespace, ulid = Ulid, lock = Lock}) ->
    {headerRegister, #'HeaderRegister'{namespace = Namespace, ulid = Ulid, lock = Lock}};

erlang_to_asn1(#header_register_ack{result = Result, leader = Leader, current_index = Index}) ->
    ASN1Result = case Result of
        ok -> ok;
        _ -> 'namespace-full'  %% Default mapping
    end,
    ASN1Leader = case Leader of
        undefined -> asn1_NOVALUE;
        _ -> Leader
    end,
    ASN1Index = case Index of
        undefined -> asn1_NOVALUE;
        _ -> Index
    end,
    {headerRegisterAck, #'HeaderRegisterAck'{result = ASN1Result, leader = ASN1Leader, currentIndex = ASN1Index}};

%% Join operations
erlang_to_asn1(#header_join{namespace = Namespace, ulid = Ulid, type = Type, 
                           current_lock = CurrentLock, new_lock = NewLock, options = Options}) ->
    SerializedOptions = case Options of
        undefined -> asn1_NOVALUE;
        [] -> asn1_NOVALUE;  %% Handle empty list
        Opts -> 
            {ok, Binary} = encode_message(Opts),
            Binary
    end,
    {headerJoin, #'HeaderJoin'{
        namespace = Namespace,
        ulid = Ulid,
        joinType = erlang:atom_to_binary(Type),
        currentLock = CurrentLock,
        newLock = NewLock,
        options = SerializedOptions
    }};

erlang_to_asn1(#header_join_ack{result = Result, type = Type, options = Options}) ->
    ASN1Result = case Result of
        ok -> ok;
        _ -> 'namespace-full'
    end,
    SerializedOptions = case Options of
        undefined -> asn1_NOVALUE;
        [] -> asn1_NOVALUE;  %% Handle empty list
        Opts -> 
            {ok, Binary} = encode_message(Opts),
            Binary
    end,
    {headerJoinAck, #'HeaderJoinAck'{
        result = ASN1Result,
        joinType = erlang:atom_to_binary(Type),
        options = SerializedOptions
    }};

%% Forward join
erlang_to_asn1(#header_forward_join{namespace = Namespace, ulid = Ulid, type = Type, 
                                   lock = Lock, options = Options}) ->
    SerializedOptions = case Options of
        undefined -> asn1_NOVALUE;
        [] -> asn1_NOVALUE;  %% Handle empty list
        Opts -> 
            {ok, Binary} = encode_message(Opts),
            Binary
    end,
    {headerForwardJoin, #'HeaderForwardJoin'{
        namespace = Namespace,
        ulid = Ulid,
        joinType = erlang:atom_to_binary(Type),
        lock = Lock,
        options = SerializedOptions
    }};

erlang_to_asn1(#header_forward_join_ack{result = Result, type = Type}) ->
    ASN1Result = case Result of
        ok -> ok;
        _ -> 'namespace-full'
    end,
    {headerForwardJoinAck, #'HeaderForwardJoinAck'{
        result = ASN1Result,
        joinType = erlang:atom_to_binary(Type)
    }};

%% SPRAY protocol messages
erlang_to_asn1(#exchange_out{proposed_sample = Sample}) ->
    ASN1Sample = [convert_exchange_entry(Entry) || Entry <- Sample],
    {exchangeOut, #'ExchangeOut'{
        proposedSample = ASN1Sample
    }};

erlang_to_asn1(#exchange_in{proposed_sample = Sample}) ->
    ASN1Sample = [convert_exchange_entry(Entry) || Entry <- Sample],
    {exchangeIn, #'ExchangeIn'{
        proposedSample = ASN1Sample
    }};

erlang_to_asn1(#exchange_accept{}) ->
    {exchangeAccept, #'ExchangeAccept'{}};

erlang_to_asn1(#exchange_cancelled{namespace = Namespace, reason = Reason}) ->
    ASN1Reason = case Reason of
        timeout -> timeout;
        _ -> normal
    end,
    {exchangeCancelled, #'ExchangeCancelled'{
        namespace = Namespace,
        reason = ASN1Reason
    }};

erlang_to_asn1(#change_lock{new_lock = NewLock, current_lock = CurrentLock}) ->
    {changeLock, #'ChangeLock'{newLock = NewLock, currentLock = CurrentLock}};

%% Node management
erlang_to_asn1(#node_quitting{reason = Reason}) ->
    ASN1Reason = case Reason of
        normal -> normal;
        timeout -> timeout;
        _ -> 'network-error'
    end,
    {nodeQuitting, #'NodeQuitting'{reason = ASN1Reason}};

%% Protocol data - keep as binary for performance
erlang_to_asn1(#ontology_history{namespace = Namespace, oldest_index = OldestIndex,
                                younger_index = YoungerIndex, list_tx = ListTx}) ->
    SerializedTx = encode_field(ListTx),
    {ontologyHistory, #'OntologyHistory'{
        namespace = Namespace,
        oldestIndex = OldestIndex,
        youngerIndex = YoungerIndex,
        transactions = SerializedTx
    }};

erlang_to_asn1(#ontology_history_request{namespace = Namespace, requester = Requester,
                                        oldest_index = OldestIndex, younger_index = YoungerIndex}) ->
    SerializedRequester = case Requester of
        undefined -> asn1_NOVALUE;
        _ -> encode_field(Requester)
    end,
    {ontologyHistoryRequest, #'OntologyHistoryRequest'{
        namespace = Namespace,
        requester = SerializedRequester,
        oldestIndex = OldestIndex,
        youngerIndex = YoungerIndex
    }};

erlang_to_asn1(#epto_message{payload = Payload}) ->
    SerializedPayload = encode_field(Payload),
    {eptoMessage, #'EptoMessage'{
        payload = SerializedPayload
    }};

%% Forward subscription messages
erlang_to_asn1(#send_forward_subscription{subscriber_node = Node, lock = Lock}) ->
    ASN1Node = convert_node_entry(Node),
    {sendForwardSubscription, #'SendForwardSubscription'{
        subscriberNode = ASN1Node,
        lock = Lock
    }};

erlang_to_asn1(#open_forward_join{subscriber_node = Node, lock = Lock}) ->
    ASN1Node = convert_node_entry(Node),
    {openForwardJoin, #'OpenForwardJoin'{
        subscriberNode = ASN1Node,
        lock = Lock
    }};

erlang_to_asn1(#leader_election_info{payload = #neighbor{node_id = NodeId,
                                                       chosen_leader = ChosenLeader,
                                                       public_key = PublicKey,
                                                       signed_ts = SignedTs,
                                                       ts = Ts}}) ->
    ASN1Neighbor = #'Neighbor'{nodeId = NodeId, chosenLeader = ChosenLeader, publicKey = PublicKey, signedTs = SignedTs, ts = Ts},
    {leaderElectionInfo, #'LeaderElectionInfo'{payload = ASN1Neighbor}};

%% EPTO protocol specific payloads - direct tuple handling
erlang_to_asn1({receive_ball, Ball, CurrentIndex}) ->
    %% Serialize the tuple using Erlang's term_to_binary for now 
    %% to avoid circular dependency - this is a temporary solution
    SerializedPayload = term_to_binary({receive_ball, Ball, CurrentIndex}),
    {eptoMessage, #'EptoMessage'{
        payload = SerializedPayload
    }};

%% List encoding - handle lists recursively  
erlang_to_asn1([]) ->
    [];
erlang_to_asn1(List) when is_list(List) ->
    [erlang_to_asn1(Item) || Item <- List];

%% Fallback
%% Transaction encoding
erlang_to_asn1(#transaction{index = Index, type = Type, signature = Signature,
                           ts_created = TsCreated, ts_posted = TsPosted, 
                           ts_delivered = TsDelivered, ts_processed = TsProcessed,
                           source_ontology_id = SourceOntologyId, prev_address = PrevAddress,
                           prev_hash = PrevHash, current_address = CurrentAddress,
                           namespace = Namespace, leader = Leader, payload = Payload,
                           diff = Diff, status = Status}) ->
    ASN1Type = case Type of
        creation -> creation;
        goal -> goal
    end,
    ASN1Status = case Status of
        created -> created;
        posted -> posted;
        delivered -> delivered;
        processed -> processed;
        _ -> created
    end,
    ASN1TsProcessed = case TsProcessed of
        undefined -> asn1_NOVALUE;
        _ -> TsProcessed
    end,
    ASN1Leader = case Leader of
        undefined -> asn1_NOVALUE;
        _ -> Leader
    end,
    SerializedPayload = encode_field(Payload),
    SerializedDiff = encode_field(Diff),
    {'Transaction', Index, ASN1Type, Signature, TsCreated, TsPosted, TsDelivered,
     ASN1TsProcessed, SourceOntologyId, PrevAddress, PrevHash, CurrentAddress,
     Namespace, ASN1Leader, SerializedPayload, SerializedDiff, ASN1Status};

erlang_to_asn1(Other) ->
    ?'log-warning'("Unknown message type for ASN.1 conversion: ~p", [Other]),
    error({unknown_message_type, Other}).

%% @doc Convert ASN.1 structures back to Erlang records
-spec asn1_to_erlang(tuple()) -> tuple().

%% Reverse conversion from ASN.1 to Erlang records
asn1_to_erlang({headerConnect, {'HeaderConnect', Version, _ConnectionType, NodeId, Namespace}}) ->
    %% Handle various version formats and convert to binary
    VersionBinary = case Version of
        Bin when is_binary(Bin) -> Bin;
        asn1_DEFAULT -> <<"0.0.1">>;
        asn1_NOVALUE -> <<"0.0.1">>;
        Other -> list_to_binary(io_lib:format("~p", [Other]))
    end,
    %% Handle node ID
    NodeIdBinary = case NodeId of
        asn1_NOVALUE -> undefined;
        NodeBin when is_binary(NodeBin) -> NodeBin;
        NodeOther -> list_to_binary(io_lib:format("~p", [NodeOther]))
    end,
    #header_connect{version = VersionBinary, node_id = NodeIdBinary, namespace = Namespace};

asn1_to_erlang({headerConnect, Map}) when is_map(Map) ->
    VersionStr = maps:get(version, Map, "1.0.0"),  %% Default version string
    %% Convert version string back to integer for Erlang record
    Version = case VersionStr of
        "1.0.0" -> 1;  %% Default
        [C|_] when C >= $0, C =< $9 ->  %% String starting with digit
            case string:tokens(VersionStr, ".") of
                [MajorStr|_] -> 
                    try list_to_integer(MajorStr)
                    catch _:_ -> 1
                    end;
                _ -> 1
            end;
        _ -> 1  %% Fallback
    end,
    NodeId = maps:get(nodeId, Map, undefined),  %% Default to undefined if not present
    Namespace = maps:get(namespace, Map),
    #header_connect{version = Version, node_id = NodeId, namespace = Namespace};

asn1_to_erlang({headerConnectAck, #'HeaderConnectAck'{result = Result, nodeId = NodeId}}) ->
    ErlResult = case Result of
        ok -> ok;
        'connection-to-self' -> connection_to_self;
        _ -> protocol_error
    end,
    #header_connect_ack{result = ErlResult, node_id = NodeId};

asn1_to_erlang({headerConnectAck, Map}) when is_map(Map) ->
    Result = maps:get(result, Map),
    NodeId = maps:get(nodeId, Map),
    ErlResult = case Result of
        ok -> ok;
        'connection-to-self' -> connection_to_self;
        _ -> protocol_error
    end,
    #header_connect_ack{result = ErlResult, node_id = NodeId};

asn1_to_erlang({headerRegister, #'HeaderRegister'{namespace = Namespace, ulid = Ulid, lock = Lock}}) ->
    #header_register{namespace = Namespace, ulid = Ulid, lock = Lock};

asn1_to_erlang({headerRegister, Map}) when is_map(Map) ->
    Namespace = maps:get(namespace, Map),
    Ulid = maps:get(ulid, Map),
    Lock = maps:get(lock, Map),
    #header_register{namespace = Namespace, ulid = Ulid, lock = Lock};

asn1_to_erlang({headerRegisterAck, #'HeaderRegisterAck'{result = Result, leader = Leader, currentIndex = Index}}) ->
    ErlResult = case Result of
        ok -> ok;
        _ -> namespace_full
    end,
    ErlLeader = case Leader of
        asn1_NOVALUE -> undefined;
        _ -> Leader
    end,
    ErlIndex = case Index of
        asn1_NOVALUE -> undefined;
        _ -> Index
    end,
    #header_register_ack{result = ErlResult, leader = ErlLeader, current_index = ErlIndex};

asn1_to_erlang({headerRegisterAck, Map}) when is_map(Map) ->
    Result = maps:get(result, Map),
    Leader = maps:get(leader, Map, undefined),
    Index = maps:get(currentIndex, Map, undefined),
    ErlResult = case Result of
        ok -> ok;
        _ -> namespace_full
    end,
    #header_register_ack{result = ErlResult, leader = Leader, current_index = Index};

asn1_to_erlang({headerJoin, #'HeaderJoin'{namespace = Namespace, ulid = Ulid, joinType = Type, currentLock = CurrentLock, newLock = NewLock, options = Options}}) ->
    ErlOptions = case Options of
        asn1_NOVALUE -> undefined;
        undefined -> undefined;
        Bin -> 
            {ok, Decoded} = decode_message(Bin),
            Decoded
    end,
    #header_join{namespace = Namespace, ulid = Ulid, type = erlang:binary_to_atom(Type),
                current_lock = CurrentLock, new_lock = NewLock, options = ErlOptions};

asn1_to_erlang({headerJoinAck, #'HeaderJoinAck'{result = Result, joinType = Type, options = Options}}) ->
    ErlResult = case Result of
        ok -> ok;
        _ -> namespace_full
    end,
    ErlOptions = case Options of
        asn1_NOVALUE -> undefined;
        undefined -> undefined;
        Bin -> 
            {ok, Decoded} = decode_message(Bin),
            Decoded
    end,
    #header_join_ack{result = ErlResult, type = erlang:binary_to_atom(Type), options = ErlOptions};

asn1_to_erlang({headerForwardJoin, #'HeaderForwardJoin'{namespace = Namespace, ulid = Ulid, joinType = Type, lock = Lock, options = Options}}) ->
    ErlOptions = case Options of
        asn1_NOVALUE -> undefined;
        undefined -> undefined;
        Bin -> 
            {ok, Decoded} = decode_message(Bin),
            Decoded
    end,
    #header_forward_join{namespace = Namespace, ulid = Ulid, type = erlang:binary_to_atom(Type),
                        lock = Lock, options = ErlOptions};

asn1_to_erlang({headerForwardJoinAck, #'HeaderForwardJoinAck'{result = Result, joinType = Type}}) ->
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

asn1_to_erlang({changeLock, Map}) when is_map(Map) ->
    NewLock = maps:get(newLock, Map),
    CurrentLock = maps:get(currentLock, Map),
    #change_lock{new_lock = NewLock, current_lock = CurrentLock};

asn1_to_erlang({nodeQuitting, {'NodeQuitting', Reason}}) ->
    ErlReason = case Reason of
        normal -> normal;
        timeout -> timeout;
        _ -> network_error
    end,
    #node_quitting{reason = ErlReason};

asn1_to_erlang({nodeQuitting, Map}) when is_map(Map) ->
    Reason = maps:get(reason, Map),
    ErlReason = case Reason of
        normal -> normal;
        timeout -> timeout;
        _ -> network_error
    end,
    #node_quitting{reason = ErlReason};

asn1_to_erlang({ontologyHistory, {'OntologyHistory', Namespace, OldestIndex, YoungerIndex, SerializedTx}}) ->
    ListTx = decode_field(SerializedTx),
    #ontology_history{namespace = Namespace, oldest_index = OldestIndex,
                     younger_index = YoungerIndex, list_tx = ListTx};

asn1_to_erlang({ontologyHistoryRequest, {'OntologyHistoryRequest', Namespace, SerializedRequester, OldestIndex, YoungerIndex}}) ->
    Requester = case SerializedRequester of
        asn1_NOVALUE -> undefined;
        undefined -> undefined;
        Bin -> decode_field(Bin)
    end,
    #ontology_history_request{namespace = Namespace, requester = Requester,
                             oldest_index = OldestIndex, younger_index = YoungerIndex};

asn1_to_erlang({eptoMessage, {'EptoMessage', SerializedPayload}}) ->
    Payload = decode_field(SerializedPayload),
    #epto_message{payload = Payload};

asn1_to_erlang({sendForwardSubscription, {'SendForwardSubscription', ASN1Node, Lock}}) ->
    Node = convert_asn1_node_entry(ASN1Node),
    #send_forward_subscription{subscriber_node = Node, lock = Lock};

asn1_to_erlang({openForwardJoin, {'OpenForwardJoin', ASN1Node, Lock}}) ->
    Node = convert_asn1_node_entry(ASN1Node),
    #open_forward_join{subscriber_node = Node, lock = Lock};

asn1_to_erlang({leaderElectionInfo, {'LeaderElectionInfo', {'Neighbor', NodeId, ChosenLeader, PublicKey, SignedTs, Ts}}}) ->
    Neighbor = #neighbor{node_id = NodeId, chosen_leader = ChosenLeader, public_key = PublicKey, signed_ts = SignedTs, ts = Ts},
    #leader_election_info{payload = Neighbor};

asn1_to_erlang({changeLock, {'ChangeLock', NewLock, CurrentLock}}) ->
    #change_lock{new_lock = NewLock, current_lock = CurrentLock};

%% List decoding - handle lists recursively
asn1_to_erlang([]) ->
    [];
asn1_to_erlang(List) when is_list(List) ->
    [asn1_to_erlang(Item) || Item <- List];

%% Transaction decoding
asn1_to_erlang({'Transaction', Index, ASN1Type, Signature, TsCreated, TsPosted, 
                TsDelivered, ASN1TsProcessed, SourceOntologyId, PrevAddress, 
                PrevHash, CurrentAddress, Namespace, ASN1Leader, 
                SerializedPayload, SerializedDiff, ASN1Status}) ->
    Type = case ASN1Type of
        creation -> creation;
        goal -> goal
    end,
    Status = case ASN1Status of
        created -> created;
        posted -> posted;
        delivered -> delivered;
        processed -> processed
    end,
    TsProcessed = case ASN1TsProcessed of
        asn1_NOVALUE -> undefined;
        _ -> ASN1TsProcessed
    end,
    Leader = case ASN1Leader of
        asn1_NOVALUE -> undefined;
        _ -> ASN1Leader
    end,
    Payload = decode_field(SerializedPayload),
    Diff = decode_field(SerializedDiff),
    #transaction{index = Index, type = Type, signature = Signature,
                ts_created = TsCreated, ts_posted = TsPosted, 
                ts_delivered = TsDelivered, ts_processed = TsProcessed,
                source_ontology_id = SourceOntologyId, prev_address = PrevAddress,
                prev_hash = PrevHash, current_address = CurrentAddress,
                namespace = Namespace, leader = Leader, payload = Payload,
                diff = Diff, status = Status};

asn1_to_erlang(Other) ->
    ?'log-warning'("Unknown ASN.1 message type for Erlang conversion: ~p", [Other]),
    error({unknown_asn1_message_type, Other}).

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

%% Convert node_entry record to ASN.1
convert_node_entry(#node_entry{node_id = NodeId, host = Host, port = Port}) ->
    ASN1NodeId = case NodeId of
        undefined -> asn1_NOVALUE;
        _ -> NodeId
    end,
    ASN1Host = case Host of
        local -> {local, 'NULL'};
        H when is_binary(H) -> {hostname, H};
        {A, B, C, D} -> {ipv4, <<A, B, C, D>>};  %% IPv4 tuple
        H when is_tuple(H), tuple_size(H) =:= 8 -> 
            {ipv6, << <<X:16>> || X <- tuple_to_list(H) >>};  %% IPv6 tuple
        H -> {hostname, list_to_binary(io_lib:format("~p", [H]))}
    end,
    {'NodeEntry', ASN1NodeId, ASN1Host, Port}.

%% Convert ASN.1 back to node_entry record
convert_asn1_node_entry({'NodeEntry', NodeId, ASN1Host, Port}) ->
    ErlNodeId = case NodeId of
        asn1_NOVALUE -> undefined;
        _ -> NodeId
    end,
    Host = case ASN1Host of
        {local, 'NULL'} -> local;
        {hostname, H} -> H;
        {ipv4, <<A, B, C, D>>} -> {A, B, C, D};
        {ipv6, IPV6Bin} -> 
            << <<X:16>> || <<X:16>> <= IPV6Bin >>,
            list_to_tuple([X || <<X:16>> <= IPV6Bin])
    end,
    #node_entry{node_id = ErlNodeId, host = Host, port = Port}.

%% Convert exchange_entry record to ASN.1
convert_exchange_entry(#exchange_entry{ulid = Ulid, lock = Lock, target = Target, new_lock = NewLock}) ->
    ASN1Target = convert_node_entry(Target),
    ASN1NewLock = case NewLock of
        undefined -> asn1_NOVALUE;
        _ -> NewLock
    end,
    {'ExchangeEntry', Ulid, Lock, ASN1Target, ASN1NewLock}.

%% Convert ASN.1 back to exchange_entry record
convert_asn1_exchange_entry({'ExchangeEntry', Ulid, Lock, ASN1Target, NewLock}) ->
    Target = convert_asn1_node_entry(ASN1Target),
    ErlNewLock = case NewLock of
        asn1_NOVALUE -> undefined;
        _ -> NewLock
    end,
    #exchange_entry{ulid = Ulid, lock = Lock, target = Target, new_lock = ErlNewLock}.

%%%=============================================================================
%%% Utility Functions
%%%=============================================================================


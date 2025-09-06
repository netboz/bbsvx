%%%-------------------------------------------------------------------
%% @doc Structured logging helpers for BBSvx with Loki labels
%% @end
%%%-------------------------------------------------------------------
-module(bbsvx_structured_logging).

-export([
    log_spray_event/4,
    log_connection_event/4,
    log_leader_election_event/4,
    log_ontology_event/4,
    log_transaction_event/4
]).

%% @doc Log SPRAY protocol events
-spec log_spray_event(atom(), binary(), map(), any()) -> ok.
log_spray_event(Operation, Ulid, ExtraData, Message) ->
    logger:info(
        Message,
        maps:merge(
            #{
                component => "spray",
                operation => atom_to_binary(Operation),
                ulid => Ulid,
                node => atom_to_binary(node()),
                event_type => "spray_protocol"
            },
            ExtraData
        )
    ).

%% @doc Log connection events
-spec log_connection_event(inbound | outbound, binary(), map(), any()) -> ok.
log_connection_event(Direction, PeerNode, ExtraData, Message) ->
    logger:info(
        Message,
        maps:merge(
            #{
                component => "connection",
                direction => atom_to_binary(Direction),
                peer_node => PeerNode,
                node => atom_to_binary(node()),
                event_type => "network_connection"
            },
            ExtraData
        )
    ).

%% @doc Log leader election events
-spec log_leader_election_event(atom(), binary(), map(), any()) -> ok.
log_leader_election_event(Operation, Namespace, ExtraData, Message) ->
    logger:info(
        Message,
        maps:merge(
            #{
                component => "leader_election",
                operation => atom_to_binary(Operation),
                namespace => Namespace,
                node => atom_to_binary(node()),
                event_type => "consensus"
            },
            ExtraData
        )
    ).

%% @doc Log ontology events
-spec log_ontology_event(atom(), binary(), map(), any()) -> ok.
log_ontology_event(Operation, Namespace, ExtraData, Message) ->
    logger:info(
        Message,
        maps:merge(
            #{
                component => "ontology",
                operation => atom_to_binary(Operation),
                namespace => Namespace,
                node => atom_to_binary(node()),
                event_type => "knowledge_base"
            },
            ExtraData
        )
    ).

%% @doc Log transaction events
-spec log_transaction_event(atom(), binary(), map(), any()) -> ok.
log_transaction_event(Operation, TransactionId, ExtraData, Message) ->
    logger:info(
        Message,
        maps:merge(
            #{
                component => "transaction",
                operation => atom_to_binary(Operation),
                ulid => TransactionId,
                node => atom_to_binary(node()),
                event_type => "blockchain"
            },
            ExtraData
        )
    ).

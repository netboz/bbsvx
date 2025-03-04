-include_lib("erlog/src/erlog_int.hrl").

-define(INDEX_TABLE, ontology).
-define(CONNECTION_TIMEOUT, 2000).
-define(LOCK_SIZE, 16).

-record(ontology,
        {namespace :: binary(),
         type :: shared | local,
         version :: binary(),
         last_update = 0 :: integer(),
         contact_nodes = [] :: [node_entry()]}).
%% Goal storage
-record(goal,
        {%% @TODO: rename id to address
         id :: binary(),
         timestamp :: integer(),
         namespace :: binary(),
         %%     leader :: binary(),
         source_id :: binary(),
         diff :: term(),
         payload :: term()}).
-record(goal_result,
        {namespace = <<>> :: binary(),
         result :: atom(),
         diff :: term(),
         address :: binary(),
         signature :: binary()}).

-type goal_result() :: #goal_result{}.

-record(ontology_history,
        {namespace :: binary(),
         oldest_index :: integer(),
         younger_index :: integer(),
         list_tx :: [transaction()]}).
-record(ontology_history_request,
        {namespace :: binary(),
         requester :: arc() | undefined,
         oldest_index :: integer(),
         younger_index :: integer()}).
-record(db_differ, {out_db :: db(), op_fifo = [] :: [functor()]}).

%%%==============================================================================
%%% Ontology related records
%%% @doc: These records are used to define the ontology that is shared between
%%% the nodes.
%%% @author yan
%%% @end
%%%==============================================================================

-record(ont_state,
        {namespace :: binary(),
         previous_ts :: integer(),
         current_ts :: integer(),
         prolog_state :: erlog_state(),
         local_index = -1 :: integer(),
         current_index = 0 :: integer(),
         current_address :: binary(),
         next_address :: binary(),
         contact_nodes :: [node_entry()]}).

-type ont_state() :: #ont_state{}.

%%%=============================================================================
%%% Transactions related records
%%% @doc: These records are used to define the transactions that are exchanged
%%% between the nodes.
%%% @author yan
%%% @end
%%%=============================================================================

-record(transaction,
        {index = 0 :: integer(),
         type :: creation | goal,
         signature :: binary(),
         ts_created = 0 :: integer(),
         ts_posted = 0 :: integer(),
         ts_delivered = 0 :: integer(),
         ts_processed :: integer(),
         source_ontology_id :: binary(),
         prev_address :: binary(),
         prev_hash :: binary(),
         current_address :: binary(),
         namespace :: binary(),
         leader :: binary() | undefined,
         payload :: term(),
         diff = [] :: [term()],
         status = created :: atom()}).
-record(transaction_payload_init_ontology,
        {namespace :: binary(), contact_nodes = [] :: [node_entry()]}).

-type transaction() :: #transaction{}.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Network related records
%%% @doc: These records are used to define the network messages exchanged
%%% between the nodes.
%%% @author yan
%%% @private
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type inet_address() :: inet:hostname() | inet:ip_address().

-record(node_entry,
        {node_id :: binary() | undefined,
         host :: inet_address() | binary() | local,
         port = 2304 :: inet:port_number()}).

-type node_entry() :: #node_entry{}.

-record(connection, {node_id :: binary(), namespace :: binary(), host, port, pid}).
%% @TODO: what is the need for both neighbor and node_entry ?
-record(neighbor,
        {node_id :: binary(),
         chosen_leader :: binary() | undefined,
         public_key :: binary(),
         signed_ts :: binary(),
         ts :: integer()}).
-record(arc,
        {ulid :: binary(),
         lock = <<>> :: binary(),
         source :: node_entry(),
         target :: node_entry(),
         age = 0 :: non_neg_integer()}).

-type arc() :: #arc{}.
-type neighbor() :: #neighbor{}.
-type neighbors() :: [neighbor()].
-type ontology() :: #ontology{}.
-type goal() :: #goal{}.
-type db() :: #db{}.

%%%%%%%%%%% Events %%%%%%%%%%%%%
-record(incoming_event, {origin_arc :: binary(), direction :: in | out, event :: term()}).

-type incoming_event() :: #incoming_event{}.

-record(evt_registration_accepted, {ulid :: binary(), source :: node_entry()}).

-type evt_registration_accepted() :: #evt_registration_accepted{}.

-record(evt_arc_connected_in,
        {ulid :: binary(),
         source :: node_entry(),
         lock :: binary(),
         spread :: {boolean(), binary()} | undefined}).
-record(evt_arc_connected_out,
        {ulid :: binary(),
         target :: node_entry(),
         lock :: binary(),
         spread :: {boolean(), binary()} | undefined}).
-record(evt_arc_swapped_in,
        {ulid :: binary(), newlock :: binary(), new_source :: node_entry()}).
-record(evt_connection_error,
        {ulid :: binary(), direction :: in | out, reason :: term(), node :: node_entry()}).
-record(evt_arc_disconnected, {ulid :: binary(), direction :: in | out}).
-record(evt_end_exchange, {exchanged_ulids :: [binary()]}).
-record(evt_node_quitted,
        {reason :: atom(),
         direction :: in | out,
         node_id :: binary() | undefined,
         host :: inet_address() | binary() | local,
         port :: inet:port_number()}).

%%%%%%%%%%% Network protocol messages %%%%%%%%%%%%%

-define(PROTOCOL_VERSION, <<"0.0.1">>).

%% Opens the connection to another node
-record(header_connect,
        {version = ?PROTOCOL_VERSION :: binary(),
         connection_type :: atom(),
         node_id :: binary(),
         namespace :: binary()}).
%% Confirms the connection is openned
-record(header_connect_ack, {result = <<>> :: term(), node_id :: binary()}).
%% Ask openened connection to register our node
-record(header_register, {namespace :: binary(), ulid :: binary(), lock :: binary()}).
%% Confirm registration
-record(header_register_ack,
        {result = <<>> :: term(), leader :: binary(), current_index :: integer()}).
%% Ask openened connection to join the node as a forwarded connection from registration
-record(header_forward_join,
        {namespace :: binary(),
         ulid :: binary(),
         type :: atom(),
         lock :: binary(),
         options :: [tuple()]}).
-record(header_forward_join_ack, {result = <<>> :: term(), type :: atom()}).
%% Ask openened connection to join the node following an exchange
-record(header_join,
        {namespace :: binary(),
         ulid :: binary(),
         type :: atom(),
         current_lock :: binary(),
         new_lock :: binary(),
         options :: [tuple()]}).
-record(header_join_ack,
        {result = <<>> :: term(),
         type :: atom(),
         options :: list()}). %%leader :: binary(), current_index :: integer()}).
-record(exchange_in, {proposed_sample :: [exchange_entry()]}).
-record(change_lock, {new_lock :: binary(), current_lock :: binary()}).
-record(exchange_entry,
        {ulid :: binary(),
         lock :: binary(),
         target :: node_entry(),
         new_lock :: binary() | undefined}).
-record(node_quitting, {reason :: atom()}).

-type exchange_entry() :: #exchange_entry{}.

-record(epto_message, {payload :: term()}).
-record(send_forward_subscription, {subscriber_node :: node_entry(), lock :: binary()}).
-record(open_forward_join, {subscriber_node :: node_entry(), lock :: binary()}).
-record(leader_election_info, {payload :: term()}).
-record(exchange_out, {proposed_sample :: [exchange_entry()]}).
-record(exchange_accept, {}).
-record(exchange_cancelled, {namespace = <<>> :: binary(), reason :: atom()}).
-record(registered,
        {registered_arc :: arc(), current_index :: integer(), leader :: binary()}).

-opaque erlog_state() :: #est{}.

-export_type([erlog_state/0]).

-type functor() :: tuple().
-type erlog_return(Value) :: {Value, erlog_state()}.

-record(peer_connect_to_sample, {connected_arc_ulid :: binary()}).

-type peer_connect_to_sample() :: #peer_connect_to_sample{}.

%%%==============================================================================
%%% Epto related records
%%% @doc: These records are used to define the Epto protocol that is shared
%%% between the nodes.
%%% @author yan
%%% @end
%%%==============================================================================

-record(epto_event,
        {id :: binary(),
         ts :: integer(),
         last_index :: integer() | undefined,
         ttl = 0 :: integer(),
         source_id :: binary(),
         namespace :: binary(),
         payload :: term()}).

-include_lib("erlog/src/erlog_int.hrl").

-define(INDEX_TABLE, ontology).

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
         leader :: binary(),
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
         oldest_index :: binary(),
         younger_index :: binary(),
         list_tx :: [transaction()]}).
-record(ontology_history_request,
        {namespace :: binary(),
         requester :: node_entry(),
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
         previous_ts :: binary(),
         current_ts :: binary(),
         prolog_state :: erlog_state(),
         local_index = 0 :: integer(),
         current_index = 0 :: integer(),
         current_address :: binary(),
         next_address :: binary()}).

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
         ts_created :: integer(),
         ts_processed :: integer(),
         source_ontology_id :: binary(),
         prev_address :: binary(),
         prev_hash :: binary(),
         current_address :: binary(),
         namespace :: binary(),
         leader :: binary(),
         payload :: term(),
         diff :: term(),
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

-record(node_entry,
        {node_id :: binary() | undefined,
         host :: binary() | undefined,
         port = 1883 :: integer(),
         age = 0 :: integer(),
         pid :: pid() | undefined}).
-record(connection, {node_id :: binary(), namespace :: binary(), host, port, pid}).

-type node_entry() :: #node_entry{}.

%% @TODO: what is the need for both neighbor and node_entry ?
-record(neighbor,
        {node_id :: binary(),
         chosen_leader :: binary() | undefined,
         public_key :: binary(),
         signed_ts :: binary(),
         ts :: integer()}).

-type neighbor() :: #neighbor{}.
-type neighbors() :: [neighbor()].
-type ontology() :: #ontology{}.
-type goal() :: #goal{}.
-type db() :: #db{}.

%%%%%%%%%%% Network protocol messages %%%%%%%%%%%%%

-define(PROTO_VERSION, <<"0.0.1">>).

-record(header_connect,
        {version = ?PROTO_VERSION :: binary(),
         connection_type :: atom(),
         namespace :: binary(),
         origin_node :: node_entry()}).
-record(header_connect_ack, {result = <<>> :: term(), node_id :: binary()}).
-record(header_register, {namespace :: binary()}).
-record(header_register_ack, {result = <<>> :: term(), leader :: binary(), current_index :: integer()}).
-record(header_join, {namespace :: binary()}).
-record(header_join_ack, {result = <<>> :: term(), leader :: binary(), current_index :: integer()}).
-record(epto_message, {payload :: term()}).
-record(empty_inview, {node :: node_entry()}).
-record(forward_subscription,
        {namespace = <<>> :: binary(), subscriber_node :: node_entry()}).
-record(leader_election_info, {payload :: term()}).
-record(exchange_out,
        {namespace = <<>> :: binary(),
         origin_node :: node_entry(),
         proposed_sample :: [node_entry()]}).
-record(exchange_in,
        {namespace = <<>> :: binary(),
         origin_node :: node_entry(),
         proposed_sample :: [node_entry()]}).
-record(exchange_accept, {}).
-record(exchange_end, {namespace = <<>> :: binary()}).
-record(exchange_cancelled, {namespace = <<>> :: binary(), reason :: atom()}).

-opaque erlog_state() :: #est{}.

-export_type([erlog_state/0]).

-type functor() :: tuple().
-type erlog_return(Value) :: {Value, erlog_state()}.

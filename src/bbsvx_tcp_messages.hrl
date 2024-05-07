-define(PROTO_VERSION, <<"0.0.1">>).

-record(header_connect,
        {version = ?PROTO_VERSION :: binary(),
         connection_type :: atom(),
         namespace :: binary(),
         origin_node :: node_entry()}).
-record(header_connect_ack, {result = <<>> :: binary(), node_id :: binary()}).
-record(header_register, {namespace :: binary()}).
-record(header_register_ack, {result = <<>> :: binary(), leader :: binary()}).
-record(header_join, {namespace :: binary()}).
-record(header_join_ack, {result = <<>> :: binary()}).
-record(increase_inview, {}).
-record(increase_inview_ack, {result = <<>> :: binary(), target_node  :: node_entry()}).

-record(leave_inview, {}).
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
-record(exchange_cancelled, {namespace = <<>> :: binary(), reason :: atom()}).
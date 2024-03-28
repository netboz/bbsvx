-define(MAX_UINT32, 4294967295).

-record(node_entry,
{node_id :: binary() | undefined, host :: binary()| undefined, port = 1883 :: integer(), age = 0 :: integer()}).

-record(ontology, {namespace :: binary(), type :: atom(), version :: binary(), last_update = 0 :: integer(), contact_nodes :: list(node_entry())}).

%% Goal storage
-record(goal, {id :: binary(), timestamp :: integer()  ,namespace :: binary(), source_id :: binary(), payload :: term()}).

-type node_entry() :: #node_entry{}.
-type ontology() :: #ontology{}.
-type goal() :: #goal{}.
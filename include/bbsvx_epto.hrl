-record(event, {
    id :: binary(),
    ts :: integer(),
    last_index :: integer() | undefined,
    ttl = 0 :: integer(),
    source_id :: binary(),
    namespace :: binary(),
    payload :: term()
}).

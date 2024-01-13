-record(event,
        {id :: binary(),
         ts :: integer(),
         ttl = 0 :: integer(),
         source_id :: binary(),
         namespace :: binary(),
         payload :: term()}).
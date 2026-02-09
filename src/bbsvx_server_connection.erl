%%%-----------------------------------------------------------------------------
%%% BBSvx Server Connection
%%%-----------------------------------------------------------------------------

-module(bbsvx_server_connection).

-moduledoc "BBSvx Server Connection\n\n"
"Gen State Machine for handling incoming P2P connections using Ranch protocol.\n\n"
"Manages connection states, protocol handshakes, and message forwarding for SPRAY protocol.".

-author("yan").

-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-dialyzer(no_undefined_callbacks).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([stop/0]).
%% Ranch Protocol Callbacks
-export([
    start_link/3,
    accept_exchange/2,
    reject_exchange/2,
    exchange_end/1,
    send_history/2,
    accept_join/2,
    accept_register/2,
    peer_connect_to_sample/2
]).
-export([init/1]).
%% Gen State Machine Callbacks
-export([code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([authenticate/3, wait_for_subscription/3, connected/3]).

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

%% Helper to encode messages properly
encode_message_helper(Message) ->
    {ok, EncodedMessage} = bbsvx_protocol_codec:encode(Message),
    EncodedMessage.

%% Format host (IP tuple or binary) to Prolog tuple format: ip(A,B,C,D)
format_host_for_prolog({A, B, C, D}) when is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    lists:flatten(io_lib:format("ip(~p,~p,~p,~p)", [A, B, C, D]));
format_host_for_prolog(Host) when is_binary(Host) ->
    binary_to_list(Host);
format_host_for_prolog(Host) when is_list(Host) ->
    Host;
format_host_for_prolog(_) ->
    "unknown".

-record(state, {
    ref :: any(),
    my_ulid :: binary() | undefined,
    lock = <<>> :: binary(),
    socket,
    namespace :: binary() | undefined,
    my_node :: #node_entry{},
    origin_node :: #node_entry{} | undefined,
    transport :: atom(),
    buffer = <<>>
}).

-type state() :: #state{}.

%%%=============================================================================
%%% Protocol API
%%% This is the API that ranch will use to communicate with the protocol.
%%%=============================================================================

start_link(Ref, Transport, Opts) ->
    gen_statem:start_link(?MODULE, {Ref, Transport, Opts}, []).

init({Ref, Transport, [MyNode]}) ->
    ?'log-info'("Node ~p Initializing server connection. Transport :~p", [MyNode, Transport]),

    {ok, authenticate, #state{
        my_node = MyNode,
        transport = Transport,
        ref = Ref
    }}.

accept_register(ConnectionPid, #header_register_ack{} = Header) ->
    gen_statem:call(ConnectionPid, {accept_register, Header}).

accept_join(ConnectionPid, #header_join_ack{} = Header) ->
    gen_statem:call(ConnectionPid, {accept_join, Header}).

%% TODO: Review cast/call logic here
accept_exchange(ConnectionPid, ProposedSample) ->
    gen_statem:call(ConnectionPid, {exchange_out, ProposedSample}).

reject_exchange(ConnectionPid, Reason) ->
    gen_statem:cast(ConnectionPid, {reject_exchange, Reason}).

exchange_end(ConnectionPid) ->
    gen_statem:cast(ConnectionPid, {exchange_end}).

send_history(ConnectionPid, #ontology_history{} = History) ->
    gen_statem:cast(ConnectionPid, {send_history, History}).

peer_connect_to_sample(ConnectionPid, #peer_connect_to_sample{} = Msg) ->
    gen_statem:cast(ConnectionPid, {peer_connect_to_sample, Msg}).

%%%=============================================================================
%%% Gen Statem API
%%%=============================================================================

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================


%%%=============================================================================
%%% Terminate Callbacks
%%%=============================================================================

terminate(
    normal,
    connected,
    #state{
        namespace = NameSpace,
        origin_node = OriginNode,
        my_ulid = _MyUlid
    } =
        State
) ->
    ?'log-info'(
        "~p Terminating conenction IN from ...~p   Reason ~p",
        [?MODULE, OriginNode, normal]
    ),
    prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
    ranch_tcp:send(
        State#state.socket,
        encode_message_helper(#header_connection_closed{
            namespace = State#state.namespace,
            ulid = State#state.my_ulid,
            reason = normal
        })
    ),
    gen_tcp:close(State#state.socket),
    %% evt_arc_disconnected is now emitted by arc_registry when it detects process DOWN
    void;
%% Called when other side (exchange initiator) indicates it closed this arc because it was mirrored
terminate(
    {shutdown, mirrored},
    connected,
    #state{
        namespace = NameSpace,
        origin_node = OriginNode,
        my_ulid = _MyUlid
    } = State
) ->
    ?'log-info'(
        "~p Other side requested to terminate conenction IN from ...~p   Reason ~p",
        [?MODULE, OriginNode, mirrored]
    ),
    prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
    gen_tcp:close(State#state.socket),
    %% evt_arc_disconnected is now emitted by arc_registry when it detects process DOWN
    void;
%% Here the connection is swapped ( meaning this connection will replace another server connection as we are
%% changing the orgin)
terminate(
    {shutdown, {swap, _NewOrigin, _NewLock}},
    connected,
    #state{namespace = NameSpace, my_ulid = MyUlid, origin_node = OriginNode} =
        State
) ->
    ?'log-info'(
        "~p Terminating conenction IN from ...~p   Reason ~p (swap)",
        [?MODULE, OriginNode, swap]
    ),
    %% Decrement gauge - this connection is being replaced by a new one with same ULID
    %% The new connection will increment the gauge, so we must decrement here
    prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
    ranch_tcp:send(
        State#state.socket,
        encode_message_helper(#header_connection_closed{
            namespace = State#state.namespace,
            ulid = State#state.my_ulid,
            reason = swapped
        })
    ),
    gen_tcp:close(State#state.socket),
    void;
%% Handle terminate when state is still mirrored_state tuple (before first event transformed it)
terminate(Reason, _CurrentState, {mirrored_state, Ulid, NameSpace, _MyNode, OriginNode, _Lock, Socket, _Buffer}) ->
    ?'log-warning'(
        "~p Terminating connection with mirrored_state from ~p   Reason ~p",
        [?MODULE, OriginNode, Reason]
    ),
    gen_tcp:close(Socket),
    %% Don't decrement inview - arc_registry already swapped to outview
    void;
terminate(Reason, _CurrentState, #state{namespace = NameSpace, my_ulid = MyUlid, origin_node = OriginNode} = State) ->
    ?'log-warning'(
        "~p Terminating unconnected connection IN from...~p   Reason ~p",
        [?MODULE, OriginNode, Reason]
    ),
    ranch_tcp:send(
        State#state.socket,
        encode_message_helper(#header_connection_closed{
            namespace = State#state.namespace,
            ulid = State#state.my_ulid,
            reason = Reason
        })
    ),
    gen_tcp:close(State#state.socket),
    prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

%% authenticate/3
%% This is the first state of the connection. It is responsible for
%% authenticating the connection at the node level.
%% TODO: Implement authentication. Authentication should be done
%% by querying the ontology and excpect a succeed result from the proved goal

-spec authenticate(enter | info, any(), state()) ->
    {keep_state, state()} | {next_state, atom(), state()} | {stop, any(), state()}.
authenticate(enter, _, #state{ref = Ref, transport = Transport} = State) ->
    {ok, Socket} = ranch:handshake(Ref, 500),
    {ok, {Host, _Port}} = Transport:peername(Socket),

    ok = Transport:setopts(Socket, [{active, once}]),
    %% Perform any required state initialization here.
    %% TODO: Fx literal port number
    {keep_state, State#state{socket = Socket, origin_node = #node_entry{host = Host, port = 2304}}};
authenticate(
    info,
    {tcp, _Ref, BinData},
    #state{
        origin_node = #node_entry{} = OriginNode,
        my_node = #node_entry{node_id = MyNodeId}
    } =
        State
) when
    is_binary(BinData) andalso MyNodeId =/= undefined
->
    %% Perform authentication
    Decoded =
        case bbsvx_protocol_codec:decode_message_used(BinData) of
            {DecodedTerm, Index} when is_number(Index) ->
                <<_:Index/binary, Rest/binary>> = BinData,
                {ok, DecodedTerm, Rest};
            error ->
                logger:error("Failed to decode binary data: ~p", [BinData]),
                {error, "Failed to decode binary data"}
        end,
    case Decoded of
        {ok, #header_connect{node_id = MyNodeId}, _} ->
            ?'log-warning'("~p Connection to self   ~p", [?MODULE, MyNodeId]),
            %% Connecting to self
            ranch_tcp:send(
                State#state.socket,
                encode_message_helper(#header_connect_ack{
                    node_id = MyNodeId,
                    result = connection_to_self
                })
            ),
            {stop, normal, State};
        {ok, #header_connect{node_id = IncomingNodeId} = Header, NewBuffer} ->
            ranch_tcp:send(
                State#state.socket,
                encode_message_helper(#header_connect_ack{
                    node_id =
                        State#state.my_node#node_entry.node_id,
                    result = ok
                })
            ),
            ranch_tcp:setopts(State#state.socket, [{active, once}]),
            {next_state, wait_for_subscription, State#state{
                buffer = NewBuffer,
                origin_node = OriginNode#node_entry{node_id = IncomingNodeId},
                namespace = Header#header_connect.namespace
            }};
        {error, Reason} ->
            logger:error("Failed to decode binary data: ~p", [Reason]),
            {stop, normal, State}
    end;
%% catch all
authenticate(Type, Event, State) ->
    ?'log-warning'("~p Unmanaged event ~p", [?MODULE, {authenticate, {Type, Event}}]),
    {keep_state, State}.

%% wait_for_subscription/3
%% This state is responsible for waiting for the subscription message.
%% Upon the subscription message, it will be decided if the connection is
%% a join, register or forward subscription.
%% Lock is checked at this stage.
wait_for_subscription(enter, _, State) ->
    {keep_state, State};
wait_for_subscription(
    info,
    {tcp, _Ref, BinData},
    #state{
        buffer = Buffer
    } =
        State
) ->
    ConcatBuffer = <<Buffer/binary, BinData/binary>>,
    case bbsvx_protocol_codec:decode_message_used(ConcatBuffer) of
        {DecodedTerm, Index} when is_integer(Index) ->
            <<_:Index/binary, Rest/binary>> = ConcatBuffer,
            process_subscription_header(DecodedTerm, State#state{buffer = Rest});
        error ->
            logger:error("Failed to decode binary data: ~p", [BinData]),
            {error, subscription_header_decode_failed}
    end;
%% catch all
wait_for_subscription(Type, Data, State) ->
    ?'log-warning'("~p Unamaneged event ~p", [?MODULE, {Type, Data}]),
    {keep_state, State}.

%% Enter connected state from client_connection module switch (in-place mirror: client→server)
%% Transform mirrored_state tuple into proper server_connection state record
connected(
    enter,
    _PrevState,
    {mirrored_state, Ulid, NameSpace, MyNode, OriginNode, Lock, Socket, Buffer}
) ->
    ?'log-info'("~p Entered connected state via module switch (client→server mirror), transforming state", [?MODULE]),

    %% Transform into proper state record
    NewState = #state{
        ref = undefined,  % Not needed for established connections
        my_ulid = Ulid,
        lock = Lock,
        socket = Socket,
        namespace = NameSpace,
        my_node = MyNode,
        origin_node = OriginNode,  % Was target_node in client, now origin_node in server
        transport = ranch_tcp,
        buffer = Buffer
    },

    %% Register with gproc for inview (arc_registry already updated by client_connection)
    gproc:reg(
        {p, l, {inview, NameSpace}},
        #arc{
            age = 0,
            ulid = Ulid,
            target = MyNode,
            lock = Lock,
            source = OriginNode
        }
    ),

    %% Note: metrics already updated by client_connection before module switch

    {keep_state, NewState};
%% Normal enter to connected state
connected(
    enter,
    _,
    #state{
        namespace = NameSpace,
        my_ulid = MyUlid,
        lock = Lock,
        my_node = MyNode,
        origin_node = OriginNode
    } =
        State
) ->
    gproc:reg(
        {p, l, {inview, NameSpace}},
        #arc{
            age = 0,
            ulid = MyUlid,
            target = MyNode,
            lock = Lock,
            source = OriginNode
        }
    ),

    prometheus_gauge:inc(<<"bbsvx_spray_inview_size">>, [NameSpace]),

    {keep_state, State};
%% Catch-all for mirrored_state: transform on first event (enter callback doesn't fire for same-state)
connected(Type, Event, {mirrored_state, Ulid, NameSpace, MyNode, OriginNode, Lock, Socket, Buffer}) ->
    ?'log-info'("~p Transforming mirrored_state to proper state on first event", [?MODULE]),
    NewState = #state{
        ref = undefined,
        my_ulid = Ulid,
        lock = Lock,
        socket = Socket,
        namespace = NameSpace,
        my_node = MyNode,
        origin_node = OriginNode,
        transport = ranch_tcp,
        buffer = Buffer
    },
    %% Unregister from outview (was client_connection) before registering as inview
    try gproc:unreg({p, l, {outview, NameSpace}}) catch _:_ -> ok end,
    %% Register with gproc for inview (arc_registry already updated by client_connection)
    gproc:reg(
        {p, l, {inview, NameSpace}},
        #arc{
            age = 0,
            ulid = Ulid,
            target = MyNode,
            lock = Lock,
            source = OriginNode
        }
    ),
    connected(Type, Event, NewState);
connected(info, {tcp, _Ref, BinData}, #state{buffer = Buffer, my_ulid = MyUlid} = State) ->
    parse_packet(<<Buffer/binary, BinData/binary>>, keep_state, State);
connected(info, #incoming_event{event = #peer_connect_to_sample{} = Msg}, State) ->
    ?'log-info'(
        "~p sending peer connect to sample to  ~p",
        [?MODULE, State#state.origin_node]
    ),
    ranch_tcp:send(State#state.socket, encode_message_helper(Msg)),
    {keep_state, State};
connected(info, #incoming_event{event = #header_register_ack{} = Header}, State) ->
    ?'log-info'(
        "~p sending register ack to  ~p    header : ~p",
        [?MODULE, State#state.origin_node, Header]
    ),
    ranch_tcp:send(State#state.socket, encode_message_helper(Header)),
    {keep_state, State};
connected({call, From}, {accept_join, #header_join_ack{} = Header}, State) ->
    ?'log-info'("~p sending join ack to  ~p", [?MODULE, State#state.origin_node]),
    ranch_tcp:send(State#state.socket, encode_message_helper(Header)),
    gen_statem:reply(From, ok),
    {keep_state, State};
connected(
    {call, From},
    {close, Reason},
    #state{} = State
) ->
    ?'log-info'(
        "~p closing connection from  ~p to us. Reason : ~p",
        [?MODULE, State#state.origin_node, Reason]
    ),
    gen_statem:reply(From, ok),
    {stop, Reason, State};
connected(
    info,
    #incoming_event{event = #exchange_out{proposed_sample = ProposedSample}},
    #state{} = State
) ->
    ?'log-info'("~p sending exchange out to  ~p", [?MODULE, State#state.origin_node]),
    ranch_tcp:send(
        State#state.socket,
        encode_message_helper(#exchange_out{proposed_sample = ProposedSample})
    ),
    {keep_state, State};
connected(info, {reject, Reason}, #state{namespace = NameSpace} = State) ->
    ?'log-info'("~p sending exchange cancelled to  ~p", [?MODULE, State#state.origin_node]),
    Result =
        ranch_tcp:send(
            State#state.socket,
            encode_message_helper(#exchange_cancelled{namespace = NameSpace, reason = Reason})
        ),
    ?'log-info'("~p Exchange cancelled sent ~p", [?MODULE, Result]),
    {keep_state, State};
connected(cast, {send_history, #ontology_history{} = History}, State) ->
    ?'log-info'("~p sending history to  ~p", [?MODULE, State#state.origin_node]),
    ranch_tcp:send(State#state.socket, encode_message_helper(History)),
    {keep_state, State};
connected(info, {send, Data}, State) ->
    ranch_tcp:send(State#state.socket, encode_message_helper(Data)),
    {keep_state, State};
%% Handle switch_to_client cast from arc_registry:trigger_mirror
%% This performs an in-place mirror: server_connection becomes client_connection (inview→outview)
%% Note: We don't verify locks here - arc_registry is the source of truth
connected(cast, {switch_to_client, CurrentLock, NewLock},
          #state{my_ulid = Ulid, namespace = NameSpace, socket = Socket,
                 my_node = MyNode, origin_node = OriginNode,
                 buffer = Buffer, transport = Transport} = _State) ->
    ?'log-info'("~p Switch to client triggered for arc ~p (in-place mirror)", [?MODULE, Ulid]),

    %% 1. Send header_connection_closed to notify peer about mirror
    Transport:send(Socket, encode_message_helper(#header_connection_closed{
        namespace = NameSpace,
        ulid = Ulid,
        reason = mirrored
    })),

    %% 2. Update arc registry: move from inview to outview
    case bbsvx_arc_registry:swap_direction(NameSpace, Ulid, CurrentLock, NewLock, in, out) of
        ok ->
            ?'log-info'("~p Arc ~p direction swapped in->out, switching to client_connection", [?MODULE, Ulid]),

            %% 3. Unregister from gproc inview before module switch
            try gproc:unreg({p, l, {inview, NameSpace}}) catch _:_ -> ok end,

            %% 4. Update metrics
            prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
            prometheus_gauge:inc(<<"bbsvx_spray_outview_size">>, [NameSpace]),

            %% 5. Create state for client_connection
            %% Note: In a mirror, source/target swap:
            %% - I was server (origin_node=OriginNode, my_node=MyNode)
            %% - I become client (my_node=MyNode, target_node=OriginNode)
            MirroredState = {mirrored_state,
                            Ulid,
                            NameSpace,
                            MyNode,        % my_node stays the same
                            OriginNode,    % becomes target_node in client
                            NewLock,
                            Socket,
                            Buffer},

            %% 6. Switch to client_connection module
            {next_state, connected, MirroredState,
             [{change_callback_module, bbsvx_client_connection}]};
        {error, Reason} ->
            ?'log-error'("~p Failed to swap arc direction for mirror: ~p", [?MODULE, Reason]),
            {stop, {shutdown, mirror_swap_failed}}
    end;
connected(
    info,
    {tcp_closed, _Ref},
    #state{namespace = NameSpace, my_ulid = MyUlid} = State
) ->
    ?'log-info'(
        "Namespace : ~p ; Node :~p Connection in from ~p closed...",
        [NameSpace, MyUlid, State#state.origin_node]
    ),
    {stop, normal, State};
connected(info, {terminate, Reason}, State) ->
    ?'log-info'(
        "~p Terminating connection from ~p   Reason ~p",
        [?MODULE, State#state.origin_node, Reason]
    ),
    {stop, Reason, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

parse_packet(<<>>, Action, State) ->
    {Action, State#state{buffer = <<>>}};
parse_packet(
    Buffer,
    Action,
    #state{
        namespace = NameSpace,
        my_ulid = MyUlid,
        origin_node =
            #node_entry{
                host = Host,
                port = Port,
                node_id = NodeId
            }
    } =
        State
) ->
    Decoded =
        case bbsvx_protocol_codec:decode_message_used(Buffer) of
            {DecodedEvent, NbBytesUsed} when is_number(NbBytesUsed) ->
                {complete, DecodedEvent, NbBytesUsed};
            error ->
                ?'log-info'("SERVER_CONNECTION: Decode failed, buffer_size=~p bytes, first_bytes=~p",
                           [byte_size(Buffer), binary:part(Buffer, 0, min(20, byte_size(Buffer)))]),
                {incomplete, Buffer}
        end,

    case Decoded of
        {complete, #transaction{} = Transacion, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            bbsvx_actor_ontology:receive_transaction(Transacion),
            parse_packet(BinLeft, Action, State);
        {complete, #ontology_history_request{namespace = NameSpace} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            gproc:send(
                {n, l, {bbsvx_actor_ontology, NameSpace}},
                Event#ontology_history_request{requester = MyUlid}
            ),
            parse_packet(BinLeft, Action, State);
        {complete, #exchange_in{} = Msg, Index} ->
            ?'log-info'("SERVER_CONNECTION: Received exchange_in from arc ~p: ~p", [MyUlid, Msg]),
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace, MyUlid, Msg),
            parse_packet(BinLeft, Action, State);
        {complete, #change_lock{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            %% TODO: Update the lock at the connection level
            parse_packet(BinLeft, Action, State#state{lock = Event#change_lock.new_lock});
        {complete, #exchange_cancelled{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace, MyUlid, Event),
            parse_packet(BinLeft, Action, State);
        {complete, #exchange_accept{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace, MyUlid, Event),
            parse_packet(BinLeft, Action, State);
        {complete, #open_forward_join{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace, MyUlid, Event),
            parse_packet(BinLeft, Action, State);
        {complete, #epto_message{payload = Payload}, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            gproc:send({p, l, {epto_event, NameSpace}}, {incoming_event, Payload}),
            parse_packet(BinLeft, Action, State);
        {complete, #leader_election_info{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            gproc:send({p, l, {leader_election, NameSpace}}, {incoming_event, Event}),
            parse_packet(BinLeft, Action, State);
        {complete, #header_connection_closed{reason = mirrored}, Index} ->
            %% Mirror swap: this arc is being converted from inview to outview
            %% Instead of stopping, we switch to client_connection module to handle outview messages
            ?'log-info'("~p Mirror swap initiated - switching to client_connection module", [?MODULE]),
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            %% Swap arc direction in registry (in -> out) while keeping same process
            NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),
            case bbsvx_arc_registry:swap_direction(NameSpace, MyUlid, State#state.lock, NewLock, in, out) of
                ok ->
                    %% Unregister from gproc inview before module switch
                    try gproc:unreg({p, l, {inview, NameSpace}}) catch _:_ -> ok end,
                    %% Create tagged state for client_connection to transform
                    %% Format: {mirrored_state, ulid, namespace, my_node, target_node, lock, socket, buffer}
                    MirroredState = {mirrored_state,
                                     MyUlid,
                                     NameSpace,
                                     State#state.my_node,
                                     State#state.origin_node,  % origin becomes target
                                     NewLock,
                                     State#state.socket,
                                     BinLeft},
                    %% Emit event for the direction change
                    arc_event(NameSpace, MyUlid, #evt_arc_mirrored_in{
                        ulid = MyUlid,
                        newlock = NewLock,
                        source = State#state.origin_node,
                        destination = State#state.my_node
                    }),
                    prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
                    prometheus_gauge:inc(<<"bbsvx_spray_outview_size">>, [NameSpace]),
                    {next_state, connected, MirroredState,
                     [{change_callback_module, bbsvx_client_connection}]};
                {error, Reason} ->
                    ?'log-error'("~p Failed to swap arc direction: ~p", [?MODULE, Reason]),
                    {stop, {shutdown, mirror_swap_failed}, State}
            end;
        {complete, #header_connection_closed{reason = Reason} = Event, Index} ->
            ?'log-info'("~p Connection closed event received ~p", [?MODULE, Event]),

            {stop, {shutdown, Reason}, State};
        {complete, #node_quitting{reason = Reason} = Event, _Index} ->
            ?'log-notice'("~p Event received ~p", [?MODULE, Event]),
            arc_event(
                NameSpace,
                MyUlid,
                #evt_node_quitted{
                    direction = in,
                    node_id = NodeId,
                    host = Host,
                    port = Port,
                    reason = Reason
                }
            ),

            {stop, Reason, State};
        {complete, Event, Index} ->
            ?'log-warn'("~p Event received ~p", [?MODULE, Event]),
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            parse_packet(BinLeft, Action, State);
        {incomplete, Buffer} ->
            ?'log-info'("~p Incomplete packet received", [?MODULE]),
            {keep_state, State#state{buffer = Buffer}};
        Else ->
            ?'log-warning'("~p Unmanaged event ~p", [?MODULE, Else]),
            parse_packet(Buffer, Action, State)
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% process_subscription_header/2
%% Process the subscription header received from the client. Subscription means
%% the client wants to join the ontology mesh. Thiq is the second step of the
%% connection process.
%% %%------------------------------------------------------------------------------
-spec process_subscription_header(term(), state()) ->
    {next_state, atom(), state()} | {stop, any(), state()}.

%% Process new node joining the ontology mesh
process_subscription_header(
    #header_register{ulid = Ulid, lock = Lock, namespace = NameSpace},
    #state{namespace = NameSpace, transport = Transport, socket = Socket, origin_node = OriginNode} =
        State
) when OriginNode =/= undefined ->
    %% Extract node info for network registry
    NodeId = OriginNode#node_entry.node_id,
    Host = OriginNode#node_entry.host,
    Port = OriginNode#node_entry.port,
    Timestamp = erlang:system_time(microsecond),

    %% Check if node can connect (not already registered) via local prove
    CanConnect = case bbsvx_actor_ontology:get_prolog_state(NameSpace) of
        {ok, PrologState} ->
            %% Check precondition: node must NOT already be registered
            Precondition = {'\\+', {is_network_node, NodeId}},
            case bbsvx_erlog_db_local_prove:local_prove(Precondition, PrologState) of
                {succeed, _Bindings} ->
                    %% Precondition met - node is not registered
                    true;
                {fail} ->
                    %% Precondition failed - node already registered
                    ?'log-warning'("Node ~p already registered in network registry, rejecting", [NodeId]),
                    false
            end;
        {error, Reason} ->
            %% Cannot get Prolog state - allow connection but log warning
            ?'log-warning'("Cannot verify node registration (reason: ~p), allowing connection", [Reason]),
            true
    end,

    case CanConnect of
        false ->
            %% Reject the connection - node already registered
            Transport:send(
                Socket,
                encode_message_helper(#header_register_ack{
                    result = {error, already_registered},
                    leader = undefined,
                    current_index = 0
                })
            ),
            {stop, normal, State};

        true ->
            %% Register this arc process with arc_registry (single call)
            Arc = #arc{
                ulid = Ulid,
                lock = Lock,
                source = OriginNode,
                target = State#state.my_node,
                age = 0,
                status = accepting_register
            },
            ok = bbsvx_arc_registry:register(NameSpace, in, Ulid, self(), Arc),

            %% Broadcast transaction to register node in network registry
            %% This will assert network_node(NodeId, Host, Port, Timestamp) via action mechanism
            %% Format: goal(connect_predicate(...)) - wrapped for action execution
            NodeIdAtom = binary_to_list(NodeId),
            HostTerm = format_host_for_prolog(Host),
            ConnectGoal = io_lib:format("goal(connect_predicate('~s', ~s, ~p, ~p))",
                                        [NodeIdAtom, HostTerm, Port, Timestamp]),
            ConnectGoalBin = list_to_binary(lists:flatten(ConnectGoal)),
            case bbsvx_ont_service:prove(NameSpace, ConnectGoalBin) of
                {ok, _GoalId} ->
                    ?'log-info'("Broadcast connect_predicate transaction for node ~p", [NodeId]);
                {error, ProveError} ->
                    ?'log-warning'("Failed to broadcast connect_predicate: ~p", [ProveError])
            end,

            %% Notify spray agent to add to inview
            arc_event(
                NameSpace,
                Ulid,
                #evt_arc_connected_in{
                    ulid = Ulid,
                    lock = Lock,
                    source = OriginNode,
                    spread = {true, Lock},
                    connection_type = register
                }
            ),
            %% Acknledge the registration and activate socket
            %% TODO : Fix leader initialisation, it should be requested
            %% from the ontology
            Transport:send(
                Socket,
                encode_message_helper(#header_register_ack{
                    result = ok,
                    leader = OriginNode#node_entry.node_id,
                    current_index = 0
                })
            ),
            Transport:setopts(Socket, [{active, true}]),

            %% Mark arc as available for exchanges now that it's fully connected
            bbsvx_arc_registry:update_status(NameSpace, in, Ulid, available),

            {next_state, connected, State#state{my_ulid = Ulid}}
    end;
process_subscription_header(
    #header_forward_join{ulid = Ulid, lock = Lock},
    #state{namespace = NameSpace, transport = Transport, socket = Socket, origin_node = OriginNode} =
        State
) when NameSpace =/= undefined andalso OriginNode =/= undefined ->
    %% TOO: There is no security here. Lock should be checked against the
    %% registration lock as an exemple.
    %% Register this arc process with arc_registry (single call)
    Arc = #arc{
        ulid = Ulid,
        lock = Lock,
        source = OriginNode,
        target = State#state.my_node,
        age = 0,
        status = accepting_forward_join
    },
    ok = bbsvx_arc_registry:register(NameSpace, in, Ulid, self(), Arc),

    %% Notify spray agent to add this new arc to inview
    arc_event(
        NameSpace,
        Ulid,
        #evt_arc_connected_in{
            ulid = Ulid,
            lock = Lock,
            source = OriginNode,
            connection_type = forward_join
        }
    ),
    %% Acknledge the registration and activate socket
    %% TODO: type seems unused
    Transport:send(
        Socket,
        encode_message_helper(#header_forward_join_ack{result = ok, type = forward_join})
    ),
    Transport:setopts(State#state.socket, [{active, true}]),

    %% Mark arc as available for exchanges now that it's fully connected
    bbsvx_arc_registry:update_status(NameSpace, in, Ulid, available),

    {next_state, connected, State#state{
        my_ulid = Ulid,
        lock = Lock
    }};
process_subscription_header(
    #header_join{
        type = mirror = Type,
        ulid = Ulid,
        current_lock = CurrentLock,
        new_lock = NewLock,
        options = Options
    },
    #state{namespace = NameSpace, transport = Transport, socket = Socket, origin_node = OriginNode} =
        State
) when NameSpace =/= undefined andalso OriginNode =/= undefined ->
    ?'log-info'("Mirror connection exchange  ~p   current lock ~p", [Ulid, CurrentLock]),
    %% This is a mirror connection, so we should already have a
    %% server connection under this arc ulid.
    %% Mirror connections is a corner case of swapping :
    %% in spay the initiator of and exchange, will see the arc
    %% on which it emitted the exchange request, be reverser
    %% (destination becomes source and source becomes destination).

    %% IMPORTANT: Send header_join_ack BEFORE calling mirror()!
    %% This ensures B's new client_connection receives the ack and registers
    %% its arc BEFORE we call mirror() which stops A's old client_connection
    %% (sending header_connection_closed to B's old server_connection).
    %% This ordering prevents the race condition where B's old server terminates
    %% before B's new client has registered its arc.
    Transport:send(
        Socket,
        encode_message_helper(#header_join_ack{
            result = ok,
            type = Type,
            options = Options
        })
    ),
    Transport:setopts(Socket, [{active, true}]),

    %% Now that B's new client has received the ack, we can safely call mirror()
    %% which will stop A's old client_connection
    case bbsvx_arc_registry:mirror(NameSpace, OriginNode, Ulid, CurrentLock, NewLock, self()) of
        ok ->
            ?'log-info'("~p Mirror arc lock updated ~p -> ~p", [?MODULE, CurrentLock, NewLock]),
            {next_state, connected, State#state{
                my_ulid = Ulid,
                lock = NewLock
            }};
        {error, Reason} ->
            ?'log-warning'("~p Mirror arc lock update failed ~p", [?MODULE, Reason]),
            {stop, normal, State}
    end;

process_subscription_header(
    #header_join{
        type = normal = Type,
        ulid = Ulid,
        current_lock = CurrentLock,
        new_lock = NewLock,
        options = Options
    },
    #state{
        namespace = NameSpace,
        transport = Transport,
        socket = Socket,
        origin_node = OriginNode
    } = State
) when NameSpace =/= undefined andalso OriginNode =/= undefined ->
    ?'log-info'("~p Normal connection ~p   current lock ~p", [?MODULE, Ulid, CurrentLock]),
        ?'log-info'("~p Ulid ~p", [?MODULE, Ulid]),

    %% This is a swapped connection, so we shoud already have a
    %% server connection undr this arc ulid.

    case bbsvx_arc_registry:swap(NameSpace, OriginNode, Ulid, CurrentLock, NewLock, self()) of
        ok ->
            Transport:send(
                Socket,
                encode_message_helper(#header_join_ack{
                    result = ok,
                    type = Type,
                    options = Options
                })
            ),

            Transport:setopts(Socket, [{active, true}]),

            {next_state, connected, State#state{
                my_ulid = Ulid,
                lock = NewLock
            }};
        {error, Reason} ->
            ?'log-warning'("~p Swap arc lock update failed ~p", [?MODULE, Reason]),
            Transport:send(
                Socket,
                encode_message_helper(#header_join_ack{
                    result = {error, lock_mismatch},
                    type = Type,
                    options = Options
                })
            ),
            {stop, normal, State}
    end.

%%-----------------------------------------------------------------------------
%% ontology_arc_event/3
%% Send an event related to arcs events on this namespace
%% ----------------------------------------------------------------------------
-spec arc_event(binary(), binary(), term()) -> ok.
arc_event(NameSpace, MyUlid, Event) ->
    gproc:send(
        {p, l, {spray_exchange, NameSpace}},
        #incoming_event{
            event = Event,
            direction = in,
            origin_arc = MyUlid
        }
    ).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

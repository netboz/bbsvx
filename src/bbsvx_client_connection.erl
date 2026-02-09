%%%-----------------------------------------------------------------------------
%%% BBSvx Client Connection Module
%%%-----------------------------------------------------------------------------

-module(bbsvx_client_connection).

-moduledoc "BBSvx Client Connection Module"
"Gen State Machine for managing outbound P2P connections in SPRAY protocol."
"Handles connection establishment, registration, arc exchanges, and message forwarding.".

-behaviour(gen_statem).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(HEADER_TIMEOUT, 2000).

%% External API
-export([start_link/5, start_link/8, stop/0, new/4, send/2, get_lock/1]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([connect/3, register/3, forward_join/3, join/3, connected/3]).
%% All state events
-export([handle_event/3]).

%%%=============================================================================
%%% Helper Functions
%%%=============================================================================

%% Helper to encode messages properly
encode_message_helper(Message) ->
    {ok, EncodedMessage} = bbsvx_protocol_codec:encode(Message),
    EncodedMessage.

-record(state, {
    ulid :: binary(),
    type :: register | join | forward_join,
    namespace :: binary(),
    my_node :: node_entry(),
    target_node :: node_entry(),
    join_timer :: reference() | undefined,
    current_lock :: binary(),
    socket :: gen_tcp:socket() | undefined,
    options :: [tuple()],
    buffer :: binary()
}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(
    join,
    binary(),
    node_entry(),
    node_entry(),
    binary(),
    binary(),
    atom(),
    [term()]
) ->
    gen_statem:start_ret().
start_link(join, NameSpace, MyNode, TargetNode, Ulid, Lock, Type, Options) ->
    gen_statem:start_link(
        ?MODULE,
        [join, NameSpace, MyNode, TargetNode, Ulid, Lock, Type, Options],
        []
    ).

-spec start_link(
    forward_join | register,
    binary(),
    node_entry(),
    node_entry(),
    [term()]
) ->
    gen_statem:start_ret().
start_link(forward_join, NameSpace, MyNode, TargetNode, Options) ->
    Ulid = ulid:new(),
    gen_statem:start_link(
        ?MODULE,
        [forward_join, NameSpace, MyNode, TargetNode, Options, Ulid],
        []
    );
start_link(register, NameSpace, MyNode, TargetNode, Options) ->
    Ulid = ulid:new(),
    gen_statem:start_link(
        ?MODULE,
        [register, NameSpace, MyNode, TargetNode, Options, Ulid],
        []
    ).

new(Type, NameSpace, MyNode, TargetNode) ->
    supervisor:start_child(
        bbsvx_sup_client_connections,
        [Type, NameSpace, MyNode, TargetNode]
    ).

-spec send(pid() | term(), term()) -> ok | {error, term()}.
send(NodePid, Event) when is_pid(NodePid) ->
    gen_statem:cast(NodePid, {send, Event});
send(Else, Event) ->
    ?'log-warn'("Invalid pid ~p when sending ; ~p", [Else, Event]),
    {error, invalid_pid}.

stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([forward_join, NameSpace, MyNode, TargetNode, Options, Ulid]) ->
    ?'log-info'("Initializing forward join connection fromage ~p, to ~p", [MyNode, TargetNode]),
    Lock = get_lock(?LOCK_SIZE),

    %% Register this arc process with arc_registry
    Arc = #arc{
        ulid = Ulid,
        lock = Lock,
        source = MyNode,
        target = TargetNode,
        age = 0,
        status = join_forwarding
    },
    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),

    {ok, connect, #state{
        type = forward_join,
        namespace = NameSpace,
        my_node = MyNode,
        current_lock = Lock,
        ulid = Ulid,
        buffer = <<>>,
        options = Options,
        target_node = TargetNode
    }};
init([join, NameSpace, MyNode, TargetNode, Ulid, TargetLock, Type, Options]) ->
    process_flag(trap_exit, true),
    ?'log-info'(
        "Initializing join connection, exchanged arc ~p, to ~p   type "
        ": ~p",
        [Ulid, TargetNode, Type]
    ),

    %% Register arc with arc_registry for lock validation during handshake
    Arc = #arc{
        ulid = Ulid,
        lock = TargetLock,
        source = MyNode,
        target = TargetNode,
        age = 0,
        status = joining
    },
    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),

    %% We have CONNECTION_TIMEOUT to connect to the target node
    %% Start a timer to notify timeout
    JoinTimer = erlang:send_after(?CONNECTION_TIMEOUT, self(), {close, connection_timeout}),
    {ok, connect, #state{
        type = Type,
        namespace = NameSpace,
        my_node = MyNode,
        ulid = Ulid,
        current_lock = TargetLock,
        join_timer = JoinTimer,
        buffer = <<>>,
        options = Options,
        target_node = TargetNode
    }};
init([register, NameSpace, MyNode, TargetNode, Options, Ulid]) ->
    process_flag(trap_exit, true),
    ?'log-info'(
        "Initializing register connection from ~p, to ~p",
        [
            {MyNode#node_entry.node_id, MyNode#node_entry.host},
            {TargetNode#node_entry.node_id, TargetNode#node_entry.host}
        ]
    ),
    Lock = get_lock(?LOCK_SIZE),

    %% Register this arc process with arc_registry
    Arc = #arc{
        ulid = Ulid,
        lock = Lock,
        source = MyNode,
        target = TargetNode,
        age = 0,
        status = registering
    },
    ok = bbsvx_arc_registry:register(NameSpace, out, Ulid, self(), Arc),

    {ok, connect, #state{
        type = register,
        namespace = NameSpace,
        ulid = Ulid,
        current_lock = Lock,
        my_node = MyNode,
        buffer = <<>>,
        options = Options,
        target_node = TargetNode
    }}.

%%%=============================================================================
%%% Terminate Callbacks
%%% Note: evt_arc_disconnected events are now emitted by arc_registry when it
%%% detects process DOWN. This ensures exactly-once event emission for all cases.
%%%=============================================================================

%% Called from arc_registry when this outgoing arc is mirrored
terminate(
    {shutdown, mirror},
    connected,
    #state{ulid = _MyUlid, namespace = NameSpace, my_node = _MyNode} = State
) ->
    ?'log-info'(
        "~p Terminating connection from ~p, to ~p while in state ~p "
        "with reason ~p",
        [?MODULE, State#state.my_node, State#state.target_node, connected, mirror]
    ),
    prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
    ranch_tcp:send(
        State#state.socket,
        encode_message_helper(#header_connection_closed{
            namespace = State#state.namespace,
            ulid = State#state.ulid,
            reason = mirrored
        })
    ),
    gen_tcp:close(State#state.socket),
    ok;
%% Called when other side indicates it closed this arc because it was swapped
terminate(
    {shutdown, swapped},
    connected,
    #state{ulid = _MyUlid, namespace = NameSpace, my_node = _MyNode} = State
) ->
    ?'log-info'(
        "~p Terminating connection from ~p, to ~p while in state ~p "
        "with reason ~p",
        [?MODULE, State#state.my_node, State#state.target_node, connected, swapped]
    ),
    prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
    ok;
terminate(
    Reason, connected, #state{ulid = _MyUlid, namespace = NameSpace, my_node = _MyNode} = State
) ->
    ?'log-info'(
        "~p Terminating connection from ~p, to ~p while in state ~p "
        "with reason ~p",
        [?MODULE, State#state.my_node, State#state.target_node, connected, Reason]
    ),
    prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
    ok;
terminate(
    Reason, PreviousState, #state{ulid = _MyUlid, namespace = NameSpace, my_node = _MyNode} = State
) ->
    ?'log-warning'(
        "~p Terminating connection from ~p, to ~p while in state ~p "
        "with reason ~p",
        [?MODULE, State#state.my_node, State#state.target_node, PreviousState, Reason]
    ),
    prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
    ok;
%% Handle terminate with mirrored_state (during module switch before state transformation)
terminate(
    Reason, PreviousState, {mirrored_state, Ulid, _NameSpace, MyNode, TargetNode, _Lock, Socket, _Buffer}
) ->
    ?'log-warning'(
        "~p Terminating mirrored connection from ~p, to ~p while in state ~p "
        "with reason ~p",
        [?MODULE, MyNode, TargetNode, PreviousState, Reason]
    ),
    %% Metrics already updated by server_connection before module switch
    %% Just close the socket if still open
    case Socket of
        undefined -> ok;
        _ -> gen_tcp:close(Socket)
    end,
    ?'log-info'("~p Mirrored connection ~p terminated cleanly", [?MODULE, Ulid]),
    ok.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
-spec connect(
    gen_statem:event_type() | enter,
    atom() | {tcp, gen_tcp:socket(), binary()} | {tcp_closed, _Socket},
    state()
) ->
    gen_statem:state_function_result().
connect(
    enter,
    _,
    #state{
        namespace = NameSpace,
        my_node = #node_entry{node_id = NodeId} = MyNode,
        ulid = MyUlid,
        target_node = #node_entry{host = TargetHost, port = TargetPort} = TargetNode
    } =
        State
) when
    NodeId =/= undefined
->
    TargetHostInet =
        case TargetHost of
            Th when is_binary(TargetHost) ->
                binary_to_list(Th);
            Th ->
                Th
        end,
    case
        gen_tcp:connect(
            TargetHostInet,
            TargetPort,
            [
                binary,
                {packet, 0},
                {active, true},
                {sndbuf, 4194304},
                {recbuf, 4194304},
                {nodelay, true},
                {keepalive, true}
            ],
            ?CONNECTION_TIMEOUT
        )
    of
        {ok, Socket} ->
            {ok, EncodedMessage} = bbsvx_protocol_codec:encode(#header_connect{
                namespace = NameSpace,
                node_id = NodeId
            }),
            ok = gen_tcp:send(Socket, EncodedMessage),
            {keep_state, State#state{socket = Socket}, ?HEADER_TIMEOUT};
        {error, Reason} ->
            arc_event(
                NameSpace,
                MyUlid,
                {connection_error, Reason, #arc{
                    target = TargetNode,
                    source = MyNode,
                    ulid = MyUlid
                }}
            ),
            logger:error(
                "Could not connect to ~p:~p   Reason : ~p",
                [TargetHost, TargetPort, Reason]
            ),
            {stop, normal}
    end;
connect(
    info,
    {tcp, Socket, Bin},
    #state{
        namespace = NameSpace,
        type = Type,
        ulid = MyUlid,
        current_lock = CurrentLock,
        options = Options,
        target_node = TargetNode
    } =
        State
) ->
    case bbsvx_protocol_codec:decode_message_used(Bin) of
        {#header_connect_ack{node_id = TargetNodeId} = ConnectHeader, ByteRead} when
            is_number(ByteRead)
        ->
            case ConnectHeader#header_connect_ack.result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = Bin,
                    %% Update arc target with actual node_id in registry
                    bbsvx_arc_registry:update_target_node_id(NameSpace, out, MyUlid, TargetNodeId),

                    case Type of
                        register ->
                            gen_tcp:send(
                                Socket,
                                encode_message_helper(#header_register{
                                    namespace = NameSpace,
                                    lock = CurrentLock,
                                    ulid = MyUlid
                                })
                            ),
                            {next_state, register,
                                State#state{
                                    socket = Socket,
                                    buffer = BinLeft,
                                    target_node =
                                        TargetNode#node_entry{node_id = TargetNodeId}
                                },
                                ?HEADER_TIMEOUT};
                        forward_join ->
                            gen_tcp:send(
                                Socket,
                                encode_message_helper(#header_forward_join{
                                    namespace = NameSpace,
                                    ulid = MyUlid,
                                    type = Type,
                                    lock = CurrentLock,
                                    options = Options
                                })
                            ),
                            {next_state, forward_join,
                                State#state{
                                    socket = Socket,
                                    buffer = BinLeft,
                                    target_node =
                                        TargetNode#node_entry{node_id = TargetNodeId}
                                },
                                ?HEADER_TIMEOUT};
                        mirror ->
                            NewLock = get_lock(?LOCK_SIZE),
                            %% Update arc lock in registry
                            {ok, {Arc, _Pid}} = bbsvx_arc_registry:get_arc(NameSpace, out, MyUlid),
                            UpdatedArc = Arc#arc{lock = NewLock},
                            ok = bbsvx_arc_registry:register(NameSpace, out, MyUlid, self(), UpdatedArc),

                            gen_tcp:send(
                                Socket,
                                encode_message_helper(#header_join{
                                    namespace = NameSpace,
                                    ulid = MyUlid,
                                    current_lock = CurrentLock,
                                    new_lock = NewLock,
                                    type = Type,
                                    options = Options
                                })
                            ),
                            {next_state, join,
                                State#state{
                                    socket = Socket,
                                    current_lock = NewLock,
                                    buffer = BinLeft,
                                    target_node =
                                        TargetNode#node_entry{node_id = TargetNodeId}
                                },
                                ?HEADER_TIMEOUT};
                        normal ->
                            NewLock = get_lock(?LOCK_SIZE),
                            %% Update arc lock in registry
                            {ok, {Arc, _Pid}} = bbsvx_arc_registry:get_arc(NameSpace, out, MyUlid),
                            UpdatedArc = Arc#arc{lock = NewLock},
                            ok = bbsvx_arc_registry:register(NameSpace, out, MyUlid, self(), UpdatedArc),

                            gen_tcp:send(
                                Socket,
                                encode_message_helper(#header_join{
                                    namespace = NameSpace,
                                    ulid = MyUlid,
                                    current_lock = CurrentLock,
                                    new_lock = NewLock,
                                    type = Type,
                                    options = Options
                                })
                            ),
                            {next_state, join,
                                State#state{
                                    socket = Socket,
                                    buffer = BinLeft,
                                    current_lock = NewLock,
                                    target_node =
                                        TargetNode#node_entry{node_id = TargetNodeId}
                                },
                                ?HEADER_TIMEOUT}
                    end;
                OtherConnectionResult ->
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_connection_error{
                            ulid = MyUlid,
                            direction = out,
                            node = TargetNode,
                            reason = OtherConnectionResult
                        }
                    ),

                    logger:warning(
                        "~p Connection to ~p refused : ~p with reason ~p",
                        [?MODULE, TargetNode, Type, OtherConnectionResult]
                    ),
                    {stop, normal}
            end;
        _ ->
            logger:error("Invalid header received~n"),
            arc_event(
                NameSpace,
                MyUlid,
                #evt_connection_error{
                    ulid = MyUlid,
                    direction = out,
                    node = TargetNode,
                    reason = invalid_header
                }
            ),

            {stop, normal}
    end;
connect(
    info,
    {tcp_closed, _Socket},
    #state{
        namespace = NameSpace,
        target_node = TargetNode,
        ulid = MyUlid
    }
) ->
    arc_event(
        NameSpace,
        MyUlid,
        #evt_connection_error{
            ulid = MyUlid,
            direction = out,
            node = TargetNode,
            reason = tcp_closed
        }
    ),

    logger:error("Connection closed~n"),
    {stop, normal};
connect(
    timeout,
    _,
    #state{
        namespace = NameSpace,
        target_node = TargetNode,
        my_node = MyNode,
        ulid = MyUlid
    }
) ->
    arc_event(
        NameSpace,
        MyUlid,
        #evt_connection_error{
            ulid = MyUlid,
            direction = out,
            node = TargetNode,
            reason = timeout
        }
    ),
    ?'log-error'(
        "Arc connection timeout :~p",
        [
            #arc{
                source = MyNode,
                target = TargetNode,
                ulid = MyUlid
            }
        ]
    ),
    {stop, normal};
%% Ignore all other events
connect(Type, Event, State) ->
    ?'log-warning'("Connecting Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

%% Contacting inview state - registering to a contact node
register(enter, _, State) ->
    {keep_state, State};
register(
    info,
    {tcp, Socket, Bin},
    #state{
        namespace = NameSpace,
        buffer = Buffer,
        ulid = MyUlid,
        current_lock = CurrentLock,
        target_node = TargetNode
    } =
        State
) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case bbsvx_protocol_codec:decode_message_used(ConcatBuf) of
        {
            #header_register_ack{
                result = Result,
                current_index = CurrentIndex,
                leader = Leader
            },
            ByteRead
        } when
            is_number(ByteRead)
        ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    ?'log-info'(
                        "~p registering to ~p accepted   header ~p~n",
                        [
                            ?MODULE,
                            TargetNode,
                            #header_register_ack{
                                result = Result,
                                current_index = CurrentIndex,
                                leader = Leader
                            }
                        ]
                    ),
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_arc_connected_out{
                            ulid = MyUlid,
                            lock = CurrentLock,
                            target = TargetNode,
                            connection_type = register
                        }
                    ),

                    %% Mark arc as available for exchanges now that it's fully connected
                    bbsvx_arc_registry:update_status(NameSpace, out, MyUlid, available),

                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    logger:error(
                        "~p registering to ~p refused : ~p~n",
                        [?MODULE, State#state.target_node, Else]
                    ),
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_connection_error{
                            ulid = MyUlid,
                            node = TargetNode,
                            direction = out,
                            reason = Else
                        }
                    ),

                    {stop, normal, State}
            end;
        _ ->
            logger:error("Invalid header received~n"),
            arc_event(
                NameSpace,
                MyUlid,
                #evt_connection_error{
                    ulid = MyUlid,
                    direction = out,
                    node = TargetNode,
                    reason = invalid_header
                }
            ),
            {stop, normal, State}
    end;
%% Timeout
register(
    timeout,
    _,
    #state{
        namespace = NameSpace,
        ulid = Ulid,
        target_node = TargetNode
    } =
        State
) ->
    logger:error("Contact timeout~n"),
    arc_event(
        NameSpace,
        Ulid,
        #evt_connection_error{
            ulid = Ulid,
            direction = out,
            reason = timeout,
            node = TargetNode
        }
    ),

    {stop, normal, State};
%% Ignore all other events
register(Type, Event, State) ->
    ?'log-warning'("Registering Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

forward_join(enter, _, State) ->
    {keep_state, State};
forward_join(
    info,
    {tcp, Socket, Bin},
    #state{
        namespace = NameSpace,
        target_node = TargetNode,
        ulid = MyUlid,
        current_lock = CurrentLock,
        type = Type,
        buffer = Buffer
    } =
        State
) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case bbsvx_protocol_codec:decode_message_used(ConcatBuf) of
        {#header_forward_join_ack{result = Result, type = Type}, ByteRead} when
            is_number(ByteRead)
        ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    %% Notify our join request was accepted
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_arc_connected_out{
                            target = TargetNode,
                            lock = CurrentLock,
                            ulid = MyUlid, 
                            connection_type = forward_join
                        }
                    ),

                    %% Mark arc as available for exchanges now that it's fully connected
                    bbsvx_arc_registry:update_status(NameSpace, out, MyUlid, available),

                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    ?'log-error'(
                        "~p Forward joining ~p refused : ~p~n",
                        [?MODULE, TargetNode, Else]
                    ),
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_connection_error{
                            ulid = MyUlid,
                            direction = out,
                            reason = Else,
                            node = TargetNode
                        }
                    ),
                    {stop, normal, State}
            end;
        Else ->
            logger:error(
                "~p Invalid forward header received from ~p   Header ~p",
                [?MODULE, TargetNode, Else]
            ),
            arc_event(
                NameSpace,
                MyUlid,
                #evt_connection_error{
                    ulid = MyUlid,
                    direction = out,
                    reason = invalid_forward_header,
                    node = TargetNode
                }
            ),

            {stop, normal, State}
    end;
%% Timeout
forward_join(
    timeout,
    _,
    #state{
        namespace = NameSpace,
        target_node = TargetNode,
        ulid = Ulid
    } =
        State
) ->
    ?'log-error'("Forward join timeout to node : ~p", [?MODULE, TargetNode]),
    arc_event(
        NameSpace,
        Ulid,
        #evt_connection_error{
            ulid = Ulid,
            direction = out,
            reason = timeout,
            node = TargetNode
        }
    ),
    {stop, normal, State};
%% Ignore all other events
forward_join(Type, Event, State) ->
    ?'log-warning'("Forward Join Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

join(enter, _, State) ->
    {keep_state, State};
join(
    info,
    {tcp, Socket, Bin},
    #state{
        namespace = NameSpace,
        target_node = TargetNode,
        current_lock = CurrentLock,
        join_timer = JoinTimer,
        ulid = MyUlid,
        buffer = Buffer
    } =
        State
) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case bbsvx_protocol_codec:decode_message_used(ConcatBuf) of
        {#header_join_ack{result = Result}, ByteRead} when is_number(ByteRead) ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    %% Cancel connection timerout
                    erlang:cancel_timer(JoinTimer),
                    ?'log-info'(
                        "~p Joining accepted  Ulid: ~p on namespace ~p",
                        [?MODULE, TargetNode, NameSpace]
                    ),
                    %% Notify our join request was accepted
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_arc_connected_out{
                            ulid = MyUlid,
                            lock = CurrentLock,
                            target = TargetNode,
                            connection_type = join
                        }
                    ),

                    %% Mark arc as available for exchanges now that it's fully connected
                    bbsvx_arc_registry:update_status(NameSpace, out, MyUlid, available),

                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    logger:error("~p Joining ~p refused : ~p~n", [?MODULE, TargetNode, Else]),
                    arc_event(
                        NameSpace,
                        MyUlid,
                        #evt_connection_error{
                            ulid = MyUlid,
                            direction = out,
                            reason = Else,
                            node = TargetNode
                        }
                    ),
                    {stop, normal, State}
            end;
        Other ->
            logger:error("~p Invalid header received from ~p   Header ~pn", [?MODULE, TargetNode, Other]),
            gproc:send(
                {p, l, {?MODULE, NameSpace}},
                {connection_error, invalid_header, NameSpace, TargetNode}
            ),
            {stop, normal, State}
    end;
%% Timeout
join(
    timeout,
    _,
    #state{
        namespace = NameSpace,
        target_node = TargetNode,
        ulid = Ulid
    } =
        State
) ->
    logger:error("~p Join timeout~n", [?MODULE]),
    arc_event(
        NameSpace,
        Ulid,
        #evt_connection_error{
            ulid = Ulid,
            direction = out,
            reason = timeout,
            node = TargetNode
        }
    ),
    {stop, normal, State};
%% Ignore all other events
join(Type, Event, State) ->
    ?'log-warning'("Join Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

-spec connected(
    gen_statem:event_type() | enter,
    {tcp, gen_tcp:socket(), binary()}
    | {tcp_closed, gen_tcp:socket()}
    | incoming_event()
    | {send, term()}
    | reset_age
    | inc_age
    | {terminate, term()},
    state()
) ->
    gen_statem:state_function_result().
%% Handle enter from server_connection module switch (mirrored_state format)
%% This happens when a server_connection receives header_connection_closed{reason=mirrored}
%% and switches callback module to client_connection via change_callback_module action
connected(
    enter,
    _PrevState,
    {mirrored_state, Ulid, NameSpace, MyNode, TargetNode, Lock, Socket, Buffer}
) ->
    ?'log-info'("~p Entered connected state via module switch (mirror), transforming state", [?MODULE]),
    %% Transform mirrored_state into proper client_connection state record
    NewState = #state{
        ulid = Ulid,
        type = connected,  % Already connected
        namespace = NameSpace,
        my_node = MyNode,
        target_node = TargetNode,
        join_timer = undefined,
        current_lock = Lock,
        socket = Socket,
        options = [],
        buffer = Buffer
    },
    %% Arc direction swap and metrics already handled by server_connection before module switch
    %% Just keep the new state and continue as a normal client connection
    {keep_state, NewState};

connected(
    enter,
    _,
    #state{
        namespace = NameSpace,
        ulid = MyUlid
    } =
        State
) ->
    %% Update arc status to available now that connection is established
    %% (process is already registered via via tuple)
    ok = bbsvx_arc_registry:update_status(NameSpace, out, MyUlid, available),
    prometheus_gauge:inc(<<"bbsvx_spray_outview_size">>, [NameSpace]),

    {keep_state, State};
connected(info, {tcp, _Socket, BinData}, #state{buffer = Buffer} = State) ->
    parse_packet(<<Buffer/binary, BinData/binary>>, State);
%% Note: reset_age and inc_age are now handled directly by bbsvx_actor_spray
%% via bbsvx_arc_registry API calls, so these message handlers are removed
connected(
    info,
    #incoming_event{event = #open_forward_join{} = Msg},
    #state{socket = Socket} = State
) when
    Socket =/= undefined
->
    ?'log-info'(
        "~p Forwarding subscription ~p   to ~p",
        [?MODULE, Msg, State#state.target_node]
    ),
    gen_tcp:send(Socket, encode_message_helper(Msg)),
    {keep_state, State};
connected(info, {send, Event}, #state{socket = Socket} = State) when
    Socket =/= undefined ->
    gen_tcp:send(Socket, encode_message_helper(Event)),
    {keep_state, State};
%% Handle switch_to_server cast from arc_registry:trigger_mirror
%% This performs an in-place mirror: client_connection becomes server_connection
connected(cast, {switch_to_server, CurrentLock, NewLock},
          #state{ulid = Ulid, namespace = NameSpace, socket = Socket,
                 my_node = MyNode, target_node = TargetNode,
                 current_lock = CurrentLock, buffer = Buffer} = _State) ->
    ?'log-info'("~p Switch to server triggered for arc ~p (in-place mirror)", [?MODULE, Ulid]),

    %% 1. Send header_connection_closed to notify peer about mirror
    ranch_tcp:send(Socket, encode_message_helper(#header_connection_closed{
        namespace = NameSpace,
        ulid = Ulid,
        reason = mirrored
    })),

    %% 2. Update arc registry: move from outview to inview
    case bbsvx_arc_registry:swap_direction(NameSpace, Ulid, CurrentLock, NewLock, out, in) of
        ok ->
            ?'log-info'("~p Arc ~p direction swapped out->in, switching to server_connection", [?MODULE, Ulid]),

            %% 3. Update metrics
            prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
            prometheus_gauge:inc(<<"bbsvx_spray_inview_size">>, [NameSpace]),

            %% 4. Create state for server_connection
            %% Note: In a mirror, source/target swap:
            %% - I was client (source=MyNode, target=TargetNode)
            %% - I become server (origin_node=TargetNode, my_node=MyNode)
            MirroredState = {mirrored_state,
                            Ulid,
                            NameSpace,
                            MyNode,        % my_node stays the same
                            TargetNode,    % becomes origin_node in server
                            NewLock,
                            Socket,
                            Buffer},

            %% 5. Switch to server_connection module
            {next_state, connected, MirroredState,
             [{change_callback_module, bbsvx_server_connection}]};
        {error, Reason} ->
            ?'log-error'("~p Failed to swap arc direction for mirror: ~p", [?MODULE, Reason]),
            {stop, {shutdown, mirror_swap_failed}}
    end;
%% Handle switch_to_server with lock mismatch
connected(cast, {switch_to_server, ExpectedLock, _NewLock},
          #state{ulid = Ulid, current_lock = ActualLock}) ->
    ?'log-error'("~p Switch to server failed for arc ~p - lock mismatch (expected ~p, got ~p)",
                [?MODULE, Ulid, ExpectedLock, ActualLock]),
    {stop, {shutdown, lock_mismatch}};
connected(info, {tcp_closed, Socket}, #state{socket = Socket, ulid = MyUlid}) ->
    ?'log-info'("~p Connection out closed ~p Reason tcp_closed", [?MODULE, MyUlid]),
    {stop, normal};
%% Handle tcp_closed during module switch (before state is transformed)
connected(info, {tcp_closed, Socket}, {mirrored_state, Ulid, _Ns, _MyNode, _TargetNode, _Lock, Socket, _Buffer}) ->
    ?'log-info'("~p Connection out closed (during mirror) ~p Reason tcp_closed", [?MODULE, Ulid]),
    {stop, normal};
connected(info, {terminate, Reason}, #state{ulid = MyUlid}) ->
    ?'log-info'("~p Connection out closed ~p Reason ~p", [?MODULE, MyUlid, Reason]),
    {stop, normal};
%% Handle terminate during module switch (before state is transformed)
connected(info, {terminate, Reason}, {mirrored_state, Ulid, _Ns, _MyNode, _TargetNode, _Lock, _Socket, _Buffer}) ->
    ?'log-info'("~p Connection out closed (during mirror) ~p Reason ~p", [?MODULE, Ulid, Reason]),
    {stop, normal};
%% Ignore all other events with normal state
connected(Type, Event, #state{socket = Socket} = State) ->
    ?'log-warning'(
        "~p Connected Ignoring event ~p  on socket ~p ~n",
        [?MODULE, {Type, Event}, Socket]
    ),
    {keep_state, State};
%% Transform mirrored_state on first event (since enter callback doesn't fire for same-state transition)
%% This handles the case where change_callback_module preserves the state name (connected → connected)
connected(Type, Event, {mirrored_state, Ulid, NameSpace, MyNode, TargetNode, Lock, Socket, Buffer}) ->
    ?'log-info'("~p Transforming mirrored_state to proper state on first event", [?MODULE]),
    %% Transform to proper state record
    NewState = #state{
        ulid = Ulid,
        type = connected,
        namespace = NameSpace,
        my_node = MyNode,
        target_node = TargetNode,
        join_timer = undefined,
        current_lock = Lock,
        socket = Socket,
        options = [],
        buffer = Buffer
    },
    %% Re-dispatch the event with the transformed state
    connected(Type, Event, NewState).

%%%=============================================================================
%%% All state events
%%%=============================================================================
handle_event(info, {close, connection_timeout}, State) ->
    ?'log-info'("~p Connection timeout", [?MODULE]),
    {stop, normal, State};
%% Catch all
handle_event(Type, Event, State) ->
    ?'log-warning'("~p Unmanaged event ~p", [?MODULE, {Type, Event}]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% Generate and return a lock
-spec get_lock(Length :: non_neg_integer()) -> binary().
get_lock(Length) ->
    base64:encode(
        crypto:strong_rand_bytes(Length)
    ).

%% Send an event related to arc events on this namespace
-spec arc_event(binary(), binary(), term()) -> ok.
arc_event(NameSpace, MyUlid, Event) ->
    gproc:send(
        {p, l, {spray_exchange, NameSpace}},
        #incoming_event{
            event = Event,
            direction = out,
            origin_arc = MyUlid
        }
    ).

ontology_event(NameSpace, Event) ->
    gproc:send({p, l, {bbsvx_actor_ontology, NameSpace}}, Event).

-spec parse_packet(binary(), state()) -> gen_statem:state_function_result().
parse_packet(<<>>, State) ->
    {keep_state, State#state{buffer = <<>>}};
parse_packet(
    Buffer,
    #state{
        namespace = NameSpace,
        ulid = MyUlid,
        target_node = #node_entry{node_id = TargetNodeId, host = Host, port = Port}
    } =
        State
) ->
    Decoded =
        case bbsvx_protocol_codec:decode_message_used(Buffer) of
            {DecodedEvent, NbBytesUsed} when is_number(NbBytesUsed) ->
                {complete, DecodedEvent, NbBytesUsed};
            error ->
                ?'log-notice'("Parsing incomplete : ~p~n", [error]),
                {incomplete, Buffer}
        end,

    case Decoded of
        %% Ontology management messages
        {complete, #ontology_history{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            ?'log-info'(
                "Connection received Ontology history ~p     ~p~n",
                [
                    Event#ontology_history.oldest_index,
                    Event#ontology_history.younger_index
                ]
            ),
            ontology_event(NameSpace, Event),
            parse_packet(BinLeft, State);
        %% Spray related messages
        {complete, #exchange_cancelled{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            ?'log-info'("Connection received Exchange cancelled ~p~n", [Event]),
            arc_event(NameSpace, MyUlid, Event),
            parse_packet(BinLeft, State);
        {complete, #exchange_out{} = Event, Index} ->
            ?'log-info'("Client Connection received Exchange out ~p~n", [Event]),
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace, MyUlid, Event),
            parse_packet(BinLeft, State);
        {complete, #exchange_accept{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace, MyUlid, Event),
            parse_packet(BinLeft, State);
        {complete, #registered{current_index = CurrentIndex}, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            ?'log-info'("Client Connection received registration info (current_index=~p)",
                        [CurrentIndex]),
            %% Forward registration to ontology actor
            gproc:send({n, l, {bbsvx_actor_ontology, NameSpace}}, {registered, CurrentIndex}),
            parse_packet(BinLeft, State);
        {complete, #header_connection_closed{reason = mirrored}, Index} ->
            %% Mirror swap: the peer's server_connection switched to client_connection
            %% and is notifying us. We need to switch from client_connection to server_connection.
            ?'log-info'("~p Client received mirror notification for arc ~p, switching to server_connection",
                       [?MODULE, MyUlid]),
            <<_:Index/binary, BinLeft/binary>> = Buffer,

            %% Generate new lock for the mirrored arc
            NewLock = get_lock(?LOCK_SIZE),

            %% Update arc registry: move from outview to inview
            case bbsvx_arc_registry:swap_direction(NameSpace, MyUlid, State#state.current_lock, NewLock, out, in) of
                ok ->
                    ?'log-info'("~p Arc ~p direction swapped out->in, switching to server_connection", [?MODULE, MyUlid]),

                    %% Update metrics
                    prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
                    prometheus_gauge:inc(<<"bbsvx_spray_inview_size">>, [NameSpace]),

                    %% Create state for server_connection
                    %% Note: In receiving mirror notification:
                    %% - I was client (my_node=MyNode, target_node=TargetNode)
                    %% - I become server (my_node=MyNode, origin_node=TargetNode)
                    MirroredState = {mirrored_state,
                                    MyUlid,
                                    NameSpace,
                                    State#state.my_node,     % my_node stays the same
                                    State#state.target_node, % becomes origin_node in server
                                    NewLock,
                                    State#state.socket,
                                    BinLeft},

                    %% Switch to server_connection module
                    {next_state, connected, MirroredState,
                     [{change_callback_module, bbsvx_server_connection}]};
                {error, Reason} ->
                    ?'log-error'("~p Failed to swap arc direction for mirror: ~p", [?MODULE, Reason]),
                    {stop, {shutdown, mirror_swap_failed}, State}
            end;
        {complete, #header_connection_closed{reason = Reason}, Index} ->
            %% Other side notify us about the connection being closed
            <<_:Index/binary, _BinLeft/binary>> = Buffer,
            {stop, {shutdown, Reason}, State};
        {complete, #node_quitting{reason = Reason2}, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(
                NameSpace,
                MyUlid,
                #evt_node_quitted{
                    reason = Reason2,
                    direction = out,
                    node_id = TargetNodeId,
                    host = Host,
                    port = Port
                }
            ),
            parse_packet(BinLeft, State);
        {complete, {terminate, Reason}, Index} ->
            <<_:Index/binary, _BinLeft/binary>> = Buffer,
            ?'log-info'("Connection received terminate message: ~p", [Reason]),
            {stop, normal};
        %% Catch-all for unexpected server-side messages (may arrive after module switch)
        %% This handles messages like open_forward_join, exchange_in, etc. that were in flight
        {complete, UnexpectedMsg, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            ?'log-warning'("~p Received unexpected message (possibly in-flight during module switch): ~p",
                          [?MODULE, UnexpectedMsg]),
            parse_packet(BinLeft, State);
        {incomplete, Buffer} ->
            {keep_state, State#state{buffer = Buffer}}
    end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

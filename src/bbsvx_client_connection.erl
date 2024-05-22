%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_client_connection).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_tcp_messages.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(CONNECTION_TIMEOUT, 1000).
-define(HEADER_TIMEOUT, 500).

%% External API
-export([start_link/4, stop/0, new/4, send/2]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([connect/3, register/3, join/3, connected/3]).

-record(state,
        {type :: register | join,
         namespace :: binary(),
         my_node :: node_entry(),
         target_node :: node_entry(),
         socket :: inet:socket() | undefined,
         buffer :: binary()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(contact | join_inview, binary(), node_entry(), node_entry()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Type, Namespace, #node_entry{} = MyNode, #node_entry{} = TargetNode) ->
    logger:info("Startlinking connection to ~p", [TargetNode]),
    gen_statem:start_link(?MODULE, [Type, Namespace, MyNode, TargetNode], []).

new(Type, Namespace, MyNode, TargetNode) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [Type, Namespace, MyNode, TargetNode]).

-spec send(pid(), term()) -> ok.
send(NodePid, Event) ->
    gen_statem:cast(NodePid, {send, Event}).

stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Type, Namespace, MyNode, TargetNode]) ->
    logger:info("Initializing connection from ~p, to ~p",
                [{TargetNode#node_entry.node_id, TargetNode#node_entry.host},
                 {MyNode#node_entry.node_id, MyNode#node_entry.host}]),
    MyPid = self(),
    {ok,
     connect,
     #state{type = Type,
            namespace = Namespace,
            my_node = MyNode,
            buffer = <<>>,
            target_node = TargetNode#node_entry{pid = MyPid}}}.

terminate(Reason, PreviousState, State) ->
    logger:info("~p Terminating connection from ~p, to ~p while in state ~p "
                "with reason ~p",
                [?MODULE, State#state.my_node, State#state.target_node, PreviousState, Reason]),
    ok.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
-spec connect(enter, any(), state()) -> {keep_state, state()}.
connect(enter,
        _,
        #state{namespace = Namespace,
               my_node = MyNode,
               target_node = #node_entry{host = TargetHost, port = TargetPort} = TargetNode} =
            State) ->
    TargetHostInet =
        case TargetHost of
            Th when is_binary(TargetHost) ->
                binary_to_list(Th);
            Th ->
                Th
        end,
    logger:info("Connecting to ~p", [TargetNode]),
    case gen_tcp:connect(TargetHostInet,
                         TargetPort,
                         [binary,
                          {packet, 0},
                          {active, true},
                          {sndbuf, 4194304},
                          {recbuf, 4194304},
                          {nodelay, true},
                          {keepalive, true}],
                         ?CONNECTION_TIMEOUT)
    of
        {ok, Socket} ->
            ok =
                gen_tcp:send(Socket,
                             term_to_binary(#header_connect{namespace = Namespace,
                                                            origin_node = MyNode})),
            {keep_state, State#state{socket = Socket}, ?HEADER_TIMEOUT};
        {error, Reason} ->
            event_connection_error(Reason, Namespace, TargetNode),
            logger:error("Could not connect to ~p:~p~n", [TargetHost, TargetPort]),
            {stop, Reason}
    end;
connect(info,
        {tcp, Socket, Bin},
        #state{namespace = Namespace,
               type = Type,
               target_node = TargetNode} =
            State) ->
    case binary_to_term(Bin, [safe, used]) of
        {#header_connect_ack{node_id = TargetNodeId} = ConnectHeader, ByteRead} ->
            case ConnectHeader#header_connect_ack.result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = Bin,

                    logger:info("Connected to ~p   nodeID: ~p~n",
                                [State#state.target_node, TargetNodeId]),

                    case Type of
                        register ->
                            gen_tcp:send(Socket,
                                         term_to_binary(#header_register{namespace = Namespace})),
                            {next_state,
                             register,
                             State#state{socket = Socket,
                                         buffer = BinLeft,
                                         target_node =
                                             TargetNode#node_entry{node_id = TargetNodeId}},
                             ?HEADER_TIMEOUT};
                        join ->
                            gen_tcp:send(Socket,
                                         term_to_binary(#header_join{namespace = Namespace})),
                            {next_state,
                             join,
                             State#state{socket = Socket,
                                         buffer = BinLeft,
                                         target_node =
                                             TargetNode#node_entry{node_id = TargetNodeId}},
                             ?HEADER_TIMEOUT}
                    end;
                OtherConnectionResult ->
                    event_connection_error(OtherConnectionResult, Namespace, TargetNode),
                    logger:warning("~p Connection to ~p refused : ~p with reason ~p",
                                   [?MODULE, TargetNode, Type, OtherConnectionResult]),
                    {stop, normal}
            end;
        _ ->
            logger:error("Invalid header received~n"),
            event_connection_error(invalid_header, Namespace, TargetNode),
            {stop, normal}
    end;
connect(info,
        {tcp_closed, _Socket},
        #state{namespace = Namespace, target_node = TargetNode}) ->
    gproc:send({p, l, {?MODULE, Namespace}},
               {connection_error, tcp_closed, Namespace, TargetNode}),
    logger:error("Connection closed~n"),
    {stop, normal};
connect(timeout, _, #state{namespace = Namespace, target_node = TargetNode}) ->
    event_connection_error(timeout, Namespace, TargetNode),
    logger:error("Connection timeout~n"),
    {stop, normal};
%% Ignore all other events
connect(Type, Event, State) ->
    logger:info("Connecting Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

%%-----------------------------------------------------------------------------
%% @doc
%% Contacting inview state
%% We are regsitering to a contact node
%% @end
register(enter, _, State) ->
    {keep_state, State};
register(info,
         {tcp, Socket, Bin},
         #state{namespace = Namespace,
                buffer = Buffer,
                target_node = TargetNode} =
             State) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case binary_to_term(ConcatBuf, [safe, used]) of
        {#header_register_ack{result = Result}, ByteRead} ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    logger:error("~p registering to ~p refused : ~p~n",
                                 [?MODULE, State#state.target_node, Else]),

                    gproc:send({p, l, {p, l, {?MODULE, Namespace}}},
                               {connection_error, registration_refused, Namespace, TargetNode}),

                    {stop, normal, State}
            end;
        _ ->
            logger:error("Invalid header received~n"),
            gproc:send({p, l, {?MODULE, Namespace}},
                       {connection_error, invalid_header, State#state.namespace, TargetNode}),
            {stop, normal, State}
    end;
%% Timeout
register(timeout, _, #state{namespace = Namespace, target_node = TargetNode} = State) ->
    logger:error("Contact timeout~n"),
    gproc:send({p, l, {?MODULE, Namespace}},
               {connection_error, timeout, State#state.namespace, TargetNode}),
    {stop, normal, State}.

join(enter, _, State) ->
    {keep_state, State};
join(info,
     {tcp, Socket, Bin},
     #state{namespace = Namespace,
            target_node = TargetNode,
            buffer = Buffer} =
         State) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case binary_to_term(ConcatBuf, [safe, used]) of
        {#header_join_ack{result = Result}, ByteRead} ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    logger:error("~p Joining ~p refused : ~p~n", [?MODULE, TargetNode, Else]),
                    gproc:send({p, l, {?MODULE, Namespace}},
                               {connection_error, join_refused, Namespace, TargetNode}),
                    {stop, normal, State}
            end;
        _ ->
            logger:error("~p Invalid header received from ~p~n", [?MODULE, TargetNode]),
            gproc:send({p, l, {?MODULE, Namespace}},
                       {connection_error, invalid_header, Namespace, TargetNode}),
            {stop, normal, State}
    end;
%% Timeout
join(timeout, _, #state{namespace = Namespace, target_node = TargetNode} = State) ->
    logger:error("~p Join timeout~n", [?MODULE]),
    gproc:send({p,
                l,
                {?MODULE, State#state.namespace, State#state.target_node#node_entry.node_id}},
               {connection_error, timeout, Namespace, TargetNode}),
    {stop, normal, State}.

connected(enter,
          _,
          #state{type = Type,
                 namespace = Namespace,
                 target_node = TargetNode} =
              State) ->
    MyPid = self(),
    logger:info("~p Connected to ~p MyPid ~p target node pid ~p",
                [?MODULE, TargetNode, MyPid, TargetNode#node_entry.pid]),
    gproc:send({p, l, {?MODULE, Namespace}},
               {connected, Namespace, TargetNode, {outview, Type}}),
    {keep_state, State};
connected(info, {tcp, _Socket, BinData}, #state{buffer = Buffer} = State) ->
    parse_packet(<<Buffer/binary, BinData/binary>>, keep_state, State);
connected(cast, #forward_subscription{} = Subscription, State) ->
    logger:info("~p Forwarding subscription static ~p   to ~p",
                [?MODULE, Subscription, State#state.target_node]),
    gen_tcp:send(State#state.socket, term_to_binary(Subscription)),
    {keep_state, State};
connected(cast, {send, Event}, State) ->
    gen_tcp:send(State#state.socket, term_to_binary(Event)),
    {keep_state, State};
connected({call, From},
          {disconnect, Reason},
          #state{namespace = Namespace, target_node = TargetNode}) ->
    logger:info("~p Disconnecting with reason ~p   pid ~p",
                [?MODULE, Reason, TargetNode#node_entry.pid]),
    logger:info("My pid : ~p  target node pid ~p", [self(), TargetNode#node_entry.pid]),
    gproc:send({p, l, {?MODULE, Namespace}},
               {connection_terminated, {out, Reason}, Namespace, TargetNode}),
    gen_statem:reply(From, ok),
    {stop, normal};
connected(info,
          {tcp_closed, Socket},
          #state{socket = Socket,
                 namespace = Namespace,
                 target_node = TargetNode}) ->
    logger:info("~p Connection closed~n", [?MODULE]),
    %% Notify spay agent to remove all occurences of this connection
    gproc:send({p, l, {?MODULE, Namespace}},
               {connection_terminated, {out, tcp_closed}, Namespace, TargetNode}),
    {stop, tcp_closed};
%% Ignore all other events
connected(Type, Event, State) ->
    logger:info("~p Connected Ignoring event ~p  on socket ~p ~n",
                [?MODULE, {Type, Event}, State#state.socket]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

event_connection_error(Reason, Namespace, TargetNode) ->
    logger:error("~p Connection error ~p to ~p~n", [?MODULE, Reason, TargetNode]),
    gproc:send({p, l, {?MODULE, Namespace}},
               {connection_error, Reason, Namespace, TargetNode}).

event_spray(Event, Namespace) ->
    gproc:send({p, l, {?MODULE, Namespace}}, {incoming_event, Event}).

-spec parse_packet(binary(), term(), state()) -> {term(), state()}.
parse_packet(<<>>, Action, State) ->
    {Action, State#state{buffer = <<>>}};
parse_packet(Buffer, Action, #state{namespace = Namespace} = State) ->
    Decoded =
        try binary_to_term(Buffer, [used]) of
            {DecodedEvent, NbBytesUsed} ->
                {complete, DecodedEvent, NbBytesUsed}
        catch
            Error:Reason ->
                logger:info("Parsing incomplete : ~p~n", [{Error, Reason}]),
                {incomplete, Buffer}
        end,

    case Decoded of
        {complete, #exchange_cancelled{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            logger:info("~p Incoming event ~p", [?MODULE, Event]),
            event_spray(Event, Namespace),
            parse_packet(BinLeft, Action, State);
        {complete, #exchange_out{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            logger:info("~p Incoming event ~p", [?MODULE, Event]),
            event_spray(Event, Namespace),
            parse_packet(BinLeft, Action, State);
        {complete, #exchange_accept{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            logger:info("~p Incoming event ~p", [?MODULE, Event]),
            event_spray(Event, Namespace),
            parse_packet(BinLeft, Action, State);
        {complete, #exchange_end{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            logger:info("~p Incoming event ~p", [?MODULE, Event]),
            event_spray(Event, Namespace),
            parse_packet(BinLeft, Action, State);
        {complete, Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            logger:info("~p Incoming event ~p", [?MODULE, Event]),
            event_spray(Event, Namespace),
            parse_packet(BinLeft, Action, State);
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

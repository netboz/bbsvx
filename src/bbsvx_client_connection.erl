%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_client_connection).

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

-record(state,
        {ulid :: binary(),
         type :: register | join | forward_join,
         namespace :: binary(),
         my_node :: node_entry(),
         target_node :: node_entry(),
         join_timer :: reference() | undefined,
         current_lock :: binary(),
         socket :: gen_tcp:socket() | undefined,
         options :: [tuple()],
         buffer :: binary()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(join,
                 binary(),
                 node_entry(),
                 node_entry(),
                 binary(),
                 binary(),
                 atom(),
                 [term()]) ->
                    gen_statem:start_ret().
start_link(join, NameSpace, MyNode, TargetNode, Ulid, Lock, Type, Options) ->
    gen_statem:start_link(?MODULE,
                          [join, NameSpace, MyNode, TargetNode, Ulid, Lock, Type, Options],
                          []).

-spec start_link(forward_join | register,
                 binary(),
                 node_entry(),
                 node_entry(),
                 [term()]) ->
                    gen_statem:start_ret().
start_link(forward_join, NameSpace, MyNode, TargetNode, Options) ->
    gen_statem:start_link(?MODULE,
                          [forward_join, NameSpace, MyNode, TargetNode, Options],
                          []);
start_link(register, NameSpace, MyNode, TargetNode, Options) ->
    gen_statem:start_link(?MODULE, [register, NameSpace, MyNode, TargetNode, Options], []).

new(Type, NameSpace, MyNode, TargetNode) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [Type, NameSpace, MyNode, TargetNode]).

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

init([forward_join, NameSpace, MyNode, TargetNode, Options]) ->
    ?'log-info'("Initializing forward join connection from ~p, to ~p", [MyNode, TargetNode]),
    Lock = get_lock(?LOCK_SIZE),
    Ulid = get_ulid(),
    gproc:reg({n, l, {arc, out, Ulid}}, Lock),
    {ok,
     connect,
     #state{type = forward_join,
            namespace = NameSpace,
            my_node = MyNode,
            current_lock = Lock,
            ulid = Ulid,
            buffer = <<>>,
            options = Options,
            target_node = TargetNode}};
init([join, NameSpace, MyNode, TargetNode, Ulid, TargetLock, Type, Options]) ->
    process_flag(trap_exit, true),
    ?'log-info'("Initializing join connection, exchanged arc ~p, to ~p   type "
                ": ~p",
                [Ulid, TargetNode, Type]),

    gproc:reg({n, l, {arc, out, Ulid}}, TargetLock),
    %% We have CONNECTION_TIMEOUT to connect to the target node
    %% Start a timer to notify timeout
    JoinTimer = erlang:send_after(?CONNECTION_TIMEOUT, self(), {close, connection_timeout}),
    {ok,
     connect,
     #state{type = Type,
            namespace = NameSpace,
            my_node = MyNode,
            ulid = Ulid,
            current_lock = TargetLock,
            join_timer = JoinTimer,
            buffer = <<>>,
            options = Options,
            target_node = TargetNode}};
init([register, NameSpace, MyNode, TargetNode, Options]) ->
    process_flag(trap_exit, true),
    ?'log-info'("Initializing register connection from ~p, to ~p",
                [{MyNode#node_entry.node_id, MyNode#node_entry.host},
                 {TargetNode#node_entry.node_id, TargetNode#node_entry.host}]),
    Lock = get_lock(?LOCK_SIZE),

    Ulid = get_ulid(),
    gproc:reg({n, l, {arc, out, Ulid}}, Lock),
    {ok,
     connect,
     #state{type = register,
            namespace = NameSpace,
            ulid = Ulid,
            current_lock = Lock,
            my_node = MyNode,
            buffer = <<>>,
            options = Options,
            target_node = TargetNode}}.

terminate(Reason, connected, #state{ulid = MyUlid, namespace = NameSpace} = State) ->
    ?'log-info'("~p Terminating connection from ~p, to ~p while in state ~p "
                "with reason ~p",
                [?MODULE, State#state.my_node, State#state.target_node, connected, Reason]),
    arc_event(NameSpace, MyUlid, #evt_arc_disconnected{ulid = MyUlid, direction = out}),
    prometheus_gauge:dec(<<"bbsvx_spray_outview_size">>, [NameSpace]),
    ok;
terminate(Reason, PreviousState, State) ->
    ?'log-info'("~p Terminating connection from ~p, to ~p while in state ~p "
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
-spec connect(gen_statem:event_type() | enter,
              atom() | {tcp, gen_tcp:socket(), binary()} | {tcp_closed, _Socket},
              state()) ->
                 gen_statem:state_function_result().
connect(enter,
        _,
        #state{namespace = NameSpace,
               my_node = #node_entry{node_id = NodeId} = MyNode,
               ulid = MyUlid,
               target_node = #node_entry{host = TargetHost, port = TargetPort} = TargetNode} =
            State)
    when NodeId =/= undefined ->
    TargetHostInet =
        case TargetHost of
            Th when is_binary(TargetHost) ->
                binary_to_list(Th);
            Th ->
                Th
        end,
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
                             term_to_binary(#header_connect{namespace = NameSpace,
                                                            node_id = NodeId})),
            {keep_state, State#state{socket = Socket}, ?HEADER_TIMEOUT};
        {error, Reason} ->
            arc_event(NameSpace,
                      MyUlid,
                      {connection_error,
                       Reason,
                       #arc{target = TargetNode,
                            source = MyNode,
                            ulid = MyUlid}}),
            logger:error("Could not connect to ~p:~p   Reason : ~p",
                         [TargetHost, TargetPort, Reason]),
            {stop, normal}
    end;
connect(info,
        {tcp, Socket, Bin},
        #state{namespace = NameSpace,
               type = Type,
               ulid = MyUlid,
               current_lock = CurrentLock,
               options = Options,
               target_node = TargetNode} =
            State) ->
    case binary_to_term(Bin, [safe, used]) of
        {#header_connect_ack{node_id = TargetNodeId} = ConnectHeader, ByteRead}
            when is_number(ByteRead) ->
            case ConnectHeader#header_connect_ack.result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = Bin,

                    case Type of
                        register ->
                            gen_tcp:send(Socket,
                                         term_to_binary(#header_register{namespace = NameSpace,
                                                                         lock = CurrentLock,
                                                                         ulid = MyUlid})),
                            {next_state,
                             register,
                             State#state{socket = Socket,
                                         buffer = BinLeft,
                                         target_node =
                                             TargetNode#node_entry{node_id = TargetNodeId}},
                             ?HEADER_TIMEOUT};
                        forward_join ->
                            gen_tcp:send(Socket,
                                         term_to_binary(#header_forward_join{namespace = NameSpace,
                                                                             ulid = MyUlid,
                                                                             type = Type,
                                                                             lock = CurrentLock,
                                                                             options = Options})),
                            {next_state,
                             forward_join,
                             State#state{socket = Socket,
                                         buffer = BinLeft,
                                         target_node =
                                             TargetNode#node_entry{node_id = TargetNodeId}},
                             ?HEADER_TIMEOUT};
                        mirror ->
                            NewLock = get_lock(?LOCK_SIZE),
                            gproc:set_value({n, l, {arc, out, MyUlid}}, NewLock),

                            gen_tcp:send(Socket,
                                         term_to_binary(#header_join{namespace = NameSpace,
                                                                     ulid = MyUlid,
                                                                     current_lock = CurrentLock,
                                                                     new_lock = NewLock,
                                                                     type = Type,
                                                                     options = Options})),
                            {next_state,
                             join,
                             State#state{socket = Socket,
                                         current_lock = NewLock,
                                         buffer = BinLeft,
                                         target_node =
                                             TargetNode#node_entry{node_id = TargetNodeId}},
                             ?HEADER_TIMEOUT};
                        normal ->
                            NewLock = get_lock(?LOCK_SIZE),
                            gproc:set_value({n, l, {arc, out, MyUlid}}, NewLock),
                            gen_tcp:send(Socket,
                                         term_to_binary(#header_join{namespace = NameSpace,
                                                                     ulid = MyUlid,
                                                                     current_lock = CurrentLock,
                                                                     new_lock = NewLock,
                                                                     type = Type,
                                                                     options = Options})),
                            {next_state,
                             join,
                             State#state{socket = Socket,
                                         buffer = BinLeft,
                                         current_lock = NewLock,
                                         target_node =
                                             TargetNode#node_entry{node_id = TargetNodeId}},
                             ?HEADER_TIMEOUT}
                    end;
                OtherConnectionResult ->
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_connection_error{ulid = MyUlid,
                                                    direction = out,
                                                    node = TargetNode,
                                                    reason = OtherConnectionResult}),

                    logger:warning("~p Connection to ~p refused : ~p with reason ~p",
                                   [?MODULE, TargetNode, Type, OtherConnectionResult]),
                    {stop, normal}
            end;
        _ ->
            logger:error("Invalid header received~n"),
            arc_event(NameSpace,
                      MyUlid,
                      #evt_connection_error{ulid = MyUlid,
                                            direction = out,
                                            node = TargetNode,
                                            reason = invalid_header}),

            {stop, normal}
    end;
connect(info,
        {tcp_closed, _Socket},
        #state{namespace = NameSpace,
               target_node = TargetNode,
               ulid = MyUlid}) ->
    arc_event(NameSpace,
              MyUlid,
              #evt_connection_error{ulid = MyUlid,
                                    direction = out,
                                    node = TargetNode,
                                    reason = tcp_closed}),

    logger:error("Connection closed~n"),
    {stop, normal};
connect(timeout,
        _,
        #state{namespace = NameSpace,
               target_node = TargetNode,
               my_node = MyNode,
               ulid = MyUlid}) ->
    arc_event(NameSpace,
              MyUlid,
              #evt_connection_error{ulid = MyUlid,
                                    direction = out,
                                    node = TargetNode,
                                    reason = timeout}),
    ?'log-error'("Arc connection timeout :~p",
                 [#arc{source = MyNode,
                       target = TargetNode,
                       ulid = MyUlid}]),
    {stop, normal};
%% Ignore all other events
connect(Type, Event, State) ->
    ?'log-warning'("Connecting Ignoring event ~p~n", [{Type, Event}]),
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
         #state{namespace = NameSpace,
                buffer = Buffer,
                ulid = MyUlid,
                current_lock = CurrentLock,
                target_node = TargetNode} =
             State) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case binary_to_term(ConcatBuf, [safe, used]) of
        {#header_register_ack{result = Result,
                              current_index = CurrentIndex,
                              leader = Leader},
         ByteRead}
            when is_number(ByteRead) ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    ?'log-info'("~p registering to ~p accepted   header ~p~n",
                                [?MODULE,
                                 TargetNode,
                                 #header_register_ack{result = Result,
                                                      current_index = CurrentIndex,
                                                      leader = Leader}]),
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_arc_connected_out{ulid = MyUlid,
                                                     lock = CurrentLock,
                                                     target = TargetNode}),

                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    logger:error("~p registering to ~p refused : ~p~n",
                                 [?MODULE, State#state.target_node, Else]),
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_connection_error{ulid = MyUlid,
                                                    node = TargetNode,
                                                    direction = out,
                                                    reason = Else}),

                    {stop, normal, State}
            end;
        _ ->
            logger:error("Invalid header received~n"),
            arc_event(NameSpace,
                      MyUlid,
                      #evt_connection_error{ulid = MyUlid,
                                            direction = out,
                                            node = TargetNode,
                                            reason = invalid_header}),
            {stop, normal, State}
    end;
%% Timeout
register(timeout,
         _,
         #state{namespace = NameSpace,
                ulid = Ulid,
                target_node = TargetNode} =
             State) ->
    logger:error("Contact timeout~n"),
    arc_event(NameSpace,
              Ulid,
              #evt_connection_error{ulid = Ulid,
                                    direction = out,
                                    reason = timeout,
                                    node = TargetNode}),

    {stop, normal, State};
%% Ignore all other events
register(Type, Event, State) ->
    ?'log-warning'("Registering Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

forward_join(enter, _, State) ->
    {keep_state, State};
forward_join(info,
             {tcp, Socket, Bin},
             #state{namespace = NameSpace,
                    target_node = TargetNode,
                    ulid = MyUlid,
                    current_lock = CurrentLock,
                    type = Type,
                    buffer = Buffer} =
                 State) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case binary_to_term(ConcatBuf, [safe, used]) of
        {#header_forward_join_ack{result = Result, type = Type}, ByteRead}
            when is_number(ByteRead) ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    %% Notify our join request was accepted
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_arc_connected_out{target = TargetNode,
                                                     lock = CurrentLock,
                                                     ulid = MyUlid}),

                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    ?'log-error'("~p Forward joining ~p refused : ~p~n",
                                 [?MODULE, TargetNode, Else]),
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_connection_error{ulid = MyUlid,
                                                    direction = out,
                                                    reason = Else,
                                                    node = TargetNode}),
                    {stop, normal, State}
            end;
        Else ->
            logger:error("~p Invalid forward header received from ~p   Header ~p",
                         [?MODULE, TargetNode, Else]),
            arc_event(NameSpace,
                      MyUlid,
                      #evt_connection_error{ulid = MyUlid,
                                            direction = out,
                                            reason = invalid_forward_header,
                                            node = TargetNode}),

            {stop, normal, State}
    end;
%% Timeout
forward_join(timeout,
             _,
             #state{namespace = NameSpace,
                    target_node = TargetNode,
                    ulid = Ulid} =
                 State) ->
    ?'log-error'("Forward join timeout to node : ~p", [?MODULE, TargetNode]),
    arc_event(NameSpace,
              Ulid,
              #evt_connection_error{ulid = Ulid,
                                    direction = out,
                                    reason = timeout,
                                    node = TargetNode}),
    {stop, normal, State};
%% Ignore all other events
forward_join(Type, Event, State) ->
    ?'log-warning'("Forward Join Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

join(enter, _, State) ->
    {keep_state, State};
join(info,
     {tcp, Socket, Bin},
     #state{namespace = NameSpace,
            target_node = TargetNode,
            current_lock = CurrentLock,
            join_timer = JoinTimer,
            ulid = MyUlid,
            buffer = Buffer} =
         State) ->
    ConcatBuf = <<Buffer/binary, Bin/binary>>,
    case binary_to_term(ConcatBuf, [safe, used]) of
        {#header_join_ack{result = Result}, ByteRead} when is_number(ByteRead) ->
            case Result of
                ok ->
                    <<_:ByteRead/binary, BinLeft/binary>> = ConcatBuf,
                    %% Cancel connection timerout
                    erlang:cancel_timer(JoinTimer),
                    ?'log-info'("~p Joining accepted  Ulid: ~p on namespace ~p",
                                [?MODULE, TargetNode, NameSpace]),
                    %% Notify our join request was accepted
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_arc_connected_out{ulid = MyUlid,
                                                     lock = CurrentLock,
                                                     target = TargetNode}),

                    {next_state, connected, State#state{socket = Socket, buffer = BinLeft}};
                Else ->
                    logger:error("~p Joining ~p refused : ~p~n", [?MODULE, TargetNode, Else]),
                    arc_event(NameSpace,
                              MyUlid,
                              #evt_connection_error{ulid = MyUlid,
                                                    direction = out,
                                                    reason = Else,
                                                    node = TargetNode}),
                    {stop, normal, State}
            end;
        _ ->
            logger:error("~p Invalid header received from ~p~n", [?MODULE, TargetNode]),
            gproc:send({p, l, {?MODULE, NameSpace}},
                       {connection_error, invalid_header, NameSpace, TargetNode}),
            {stop, normal, State}
    end;
%% Timeout
join(timeout,
     _,
     #state{namespace = NameSpace,
            target_node = TargetNode,
            ulid = Ulid} =
         State) ->
    logger:error("~p Join timeout~n", [?MODULE]),
    arc_event(NameSpace,
              Ulid,
              #evt_connection_error{ulid = Ulid,
                                    direction = out,
                                    reason = timeout,
                                    node = TargetNode}),
    {stop, normal, State};
%% Ignore all other events
join(Type, Event, State) ->
    ?'log-warning'("Join Ignoring event ~p~n", [{Type, Event}]),
    {keep_state, State}.

-spec connected(gen_statem:event_type() | enter,
                {tcp, gen_tcp:socket(), binary()} |
                {tcp_closed, gen_tcp:socket()} |
                incoming_event() |
                {send, term()} |
                reset_age |
                inc_age |
                {terminate, term()},
                state()) ->
                   gen_statem:state_function_result().
connected(enter,
          _,
          #state{namespace = NameSpace,
                 target_node = TargetNode,
                 my_node = MyNode,
                 ulid = MyUlid} =
              State) ->
    gproc:reg({p, l, {outview, NameSpace}},
              #arc{source = MyNode,
                   target = TargetNode,
                   lock = State#state.current_lock,
                   ulid = MyUlid}),
    prometheus_gauge:inc(<<"bbsvx_spray_outview_size">>, [NameSpace]),

    {keep_state, State};
connected(info, {tcp, _Socket, BinData}, #state{buffer = Buffer} = State) ->
    parse_packet(<<Buffer/binary, BinData/binary>>, State);
connected(info, reset_age, #state{namespace = NameSpace} = State) ->
    #arc{} = Arc = gproc:get_value({p, l, {outview, NameSpace}}),
    gproc:set_value({p, l, {outview, NameSpace}}, Arc#arc{age = 0}),
    {keep_state, State};
connected(info, inc_age, #state{namespace = NameSpace} = State) ->
    #arc{age = CurrentAge} = Arc = gproc:get_value({p, l, {outview, NameSpace}}),
    gproc:set_value({p, l, {outview, NameSpace}}, Arc#arc{age = CurrentAge + 1}),
    {keep_state, State};
connected(info,
          #incoming_event{event = #open_forward_join{} = Msg},
          #state{socket = Socket} = State)
    when Socket =/= undefined ->
    ?'log-info'("~p Forwarding subscription ~p   to ~p",
                [?MODULE, Msg, State#state.target_node]),
    gen_tcp:send(Socket, term_to_binary(Msg)),
    {keep_state, State};
connected(info, {send, Event}, #state{socket = Socket} = State)
    when Socket =/= undefined ->
    gen_tcp:send(Socket, term_to_binary(Event)),
    {keep_state, State};
connected(info, {tcp_closed, Socket}, #state{socket = Socket, ulid = MyUlid}) ->
    ?'log-info'("~p Connection out closed ~p Reason tcp_closed", [?MODULE, MyUlid]),
    {stop, normal};
connected(info, {terminate, Reason}, #state{ulid = MyUlid}) ->
    ?'log-info'("~p Connection out closed ~p Reason ~p", [?MODULE, MyUlid, Reason]),
    {stop, normal};
%% Ignore all other events
connected(Type, Event, State) ->
    ?'log-warning'("~p Connected Ignoring event ~p  on socket ~p ~n",
                   [?MODULE, {Type, Event}, State#state.socket]),
    {keep_state, State}.

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

%%-----------------------------------------------------------------------------
%% @doc
%% get_lock/0
%% generate and return a lock
%% @end
-spec get_lock(Length :: non_neg_integer()) -> binary().
get_lock(Length) ->
    base64:encode(
        crypto:strong_rand_bytes(Length)).

%%-----------------------------------------------------------------------------
%% @doc
%% get_ulid/0
%% Return an unique identifier
%% @end
%% ----------------------------------------------------------------------------
-spec get_ulid() -> binary().
get_ulid() ->
    UlidGen = persistent_term:get(ulid_gen),
    {NewGen, Ulid} = ulid:generate(UlidGen),
    persistent_term:put(ulid_gen, NewGen),
    Ulid.

%%-----------------------------------------------------------------------------
%% @doc
%% ontology_arc_event/3
%% Send an event related to arcs events on this namespace
%% @end
%% ----------------------------------------------------------------------------
-spec arc_event(binary(), binary(), term()) -> ok.
arc_event(NameSpace, MyUlid, Event) ->
    gproc:send({p, l, {spray_exchange, NameSpace}},
               #incoming_event{event = Event,
                               direction = out,
                               origin_arc = MyUlid}).

ontology_event(NameSpace, Event) ->
    gproc:send({p, l, {bbsvx_actor_ontology, NameSpace}}, Event).

-spec parse_packet(binary(), state()) -> gen_statem:state_function_result().
parse_packet(<<>>, State) ->
    {keep_state, State#state{buffer = <<>>}};
parse_packet(Buffer,
             #state{namespace = NameSpace,
                    ulid = MyUlid,
                    target_node = #node_entry{node_id = TargetNodeId, host = Host, port = Port}} =
                 State) ->
    Decoded =
        try binary_to_term(Buffer, [used]) of
            {DecodedEvent, NbBytesUsed} when is_number(NbBytesUsed) ->
                {complete, DecodedEvent, NbBytesUsed}
        catch
            Error:Reason ->
                ?'log-notice'("Parsing incomplete : ~p~n", [{Error, Reason}]),
                {incomplete, Buffer}
        end,

    case Decoded of
        %% Ontology management messages
        {complete, #ontology_history{} = Event, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            ?'log-info'("Connection received Ontology history ~p     ~p~n",
                        [Event#ontology_history.oldest_index,
                         Event#ontology_history.younger_index]),
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
        {complete, #node_quitting{reason = Reason2}, Index} ->
            <<_:Index/binary, BinLeft/binary>> = Buffer,
            arc_event(NameSpace,
                      MyUlid,
                      #evt_node_quitted{reason = Reason2,
                                        direction = out,
                                        node_id = TargetNodeId,
                                        host = Host,
                                        port = Port}),
            parse_packet(BinLeft, State);
        {incomplete, Buffer} ->
            {keep_state, State#state{buffer = Buffer}}
    end.



-spec build_metric_view_name(NameSpace :: binary(), MetricName :: binary()) -> atom().
build_metric_view_name(NameSpace, MetricName) ->
    binary_to_atom(iolist_to_binary([MetricName,
                                     binary:replace(NameSpace, <<":">>, <<"_">>)])).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

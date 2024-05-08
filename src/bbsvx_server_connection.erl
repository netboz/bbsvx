%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_server_connection).

-author("yan").

-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include("bbsvx_common_types.hrl").
-include("bbsvx_tcp_messages.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([stop/0]).
%% Ranch Protocol Callbacks
-export([start_link/3, accept_exchange/2, reject_exchange/2]).
-export([init/1]).
%% Gen State Machine Callbacks
-export([code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([authenticate/3, wait_for_subscription/3, connected/3]).

-record(state,
        {ref :: ranch_tcp:ref(),
         socket :: ranch_tcp:socket(),
         size = 0 :: integer(),
         namespace :: binary(),
         mynode :: #node_entry{},
         origin_node :: #node_entry{},
         transport :: ranch_transport:transport(),
         buffer = <<>>}).

%%%=============================================================================
%%% Protocol API
%%% This is the API that ranch will use to communicate with the protocol.
%%%=============================================================================

start_link(Ref, Transport, Opts) ->
  logger:info("~p Incoming connection from ~p...", [?MODULE, Opts]),
  gen_statem:start_link(?MODULE, {Ref, Transport, Opts}, []).

init({Ref, Transport, [MyNode]}) ->
  logger:info("Initializing bbsvx_spray_service...~p  Transport :~p", [MyNode, Transport]),
  %% Perform any required state initialization here.
  {ok,
   authenticate,
   #state{mynode = MyNode,
          transport = Transport,
          ref = Ref}}.

accept_exchange(ConnectionPid, ProposedSample) ->
  gen_statem:call(ConnectionPid, {exchange_out, ProposedSample}).

reject_exchange(ConnectionPid, Reason) ->
  gen_statem:cast(ConnectionPid, {reject_exchange, Reason}).

%%%=============================================================================
%%% Gen Statem API
%%%=============================================================================

-spec stop() -> ok.
stop() ->
  gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

terminate(_Reason, _State, _Data) ->
  logger:info("~p Terminating...~p   Reason ~p", [?MODULE, _State, _Reason]),
  void.

code_change(_Vsn, State, Data, _Extra) ->
  {ok, State, Data}.

callback_mode() ->
  [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

authenticate(enter, _, #state{ref = Ref, transport = Transport} = State) ->
  {ok, Socket} = ranch:handshake(Ref),
  ok = Transport:setopts(Socket, [{active, once}]),
  %% Perform any required state initialization here.
  {keep_state, State#state{socket = Socket}};
authenticate(info,
             {tcp, _Ref, BinData},
             #state{mynode = #node_entry{node_id = MyNodeId}} = State) ->
  %% Perform authentication
  logger:info("Authenticating...~p", [binary_to_term(BinData, [used])]),
  Decoded =
    try binary_to_term(BinData, [safe, used]) of
      {DecodedTerm, Index} ->
        <<_:Index/binary, Rest/binary>> = BinData,
        {ok, DecodedTerm, Rest}
    catch
      _:_ ->
        logger:error("Failed to decode binary data: ~p", [BinData]),
        {error, "Failed to decode binary data"}
    end,
  MyPid = self(),
  case Decoded of
    {ok, #header_connect{origin_node = #node_entry{node_id = MyNodeId}}, _} ->
      %% Connecting to self
      ranch_tcp:send(State#state.socket,
                     term_to_binary(#header_connect_ack{node_id = MyNodeId,
                                                        result = connection_to_self})),
      {stop, normal, State};
    {ok,
     #header_connect{origin_node = OriginNode, namespace = Namespace} = Header,
     NewBuffer} ->
      logger:info("~p Decoded header_connect: ~p", [?MODULE, Decoded]),

      gproc:send({p, l, {?MODULE, Header#header_connect.namespace}},
                 {incoming_client_connection, Namespace, OriginNode#node_entry{pid = MyPid}}),

      ranch_tcp:send(State#state.socket,
                     term_to_binary(#header_connect_ack{node_id =
                                                          State#state.mynode#node_entry.node_id,
                                                        result = ok})),
      ranch_tcp:setopts(State#state.socket, [{active, once}]),
      {next_state,
       wait_for_subscription,
       State#state{buffer = NewBuffer,
                   namespace = Header#header_connect.namespace,
                   origin_node = OriginNode#node_entry{pid = MyPid}}};
    {error, Reason} ->
      logger:error("Failed to decode binary data: ~p", [Reason]),
      {stop, normal, State}
  end.

wait_for_subscription(enter, _, State) ->
  {keep_state, State};
wait_for_subscription(info,
                      {tcp, _Ref, BinData},
                      #state{namespace = Namespace,
                             origin_node = OriginNode,
                             socket = Socket,
                             buffer = Buffer,
                             transport = Transport} =
                        State) ->
  logger:info("Waiting for subscription...~p", [binary_to_term(BinData, [used])]),
  ConcatBuffer = <<Buffer/binary, BinData/binary>>,
  Decoded =
    try binary_to_term(ConcatBuffer, [safe, used]) of
      {DecodedTerm, Index} ->
        <<_:Index/binary, Rest/binary>> = ConcatBuffer,
        {ok, DecodedTerm, Rest}
    catch
      _:_ ->
        logger:error("Failed to decode binary data: ~p", [BinData]),
        {error, "Failed to decode binary data"}
    end,
  case Decoded of
    {ok, #header_register{} = Header, NewBuffer} ->
      logger:info("~p Decoded header_contact: ~p", [?MODULE, Decoded]),
      %% Get current leader
      %{ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
      Transport:send(State#state.socket,
                     term_to_binary(#header_register_ack{result = ok, leader = bob})),
      Transport:setopts(State#state.socket, [{active, true}]),
      %% Notify spray agent to add to inview
      gproc:send({p, l, {ontology, Header#header_register.namespace}},
                 {connected, Namespace, OriginNode, {inview, register}}),
      {next_state, connected, State#state{buffer = NewBuffer}};
    {ok, #header_join{}, NewBuffer} ->
      logger:info("~p Decoded header_join_inview: ~p", [?MODULE, Decoded]),
      Transport:send(Socket, term_to_binary(#header_join_ack{result = ok})),
      Transport:setopts(Socket, [{active, true}]),
      %% Notify spray agent to add to inview
      gproc:send({p, l, {ontology, Namespace}},
                 {connected, Namespace, OriginNode, {inview, join}}),
      {next_state, connected, State#state{buffer = NewBuffer}};
 
    {error, _} ->
      logger:error("~p Failed to decode binary data: ~p", [?MODULE, BinData]),
      {stop, normal, State}
  end;
%% Cathc all
wait_for_subscription(Type, Data, State) ->
  logger:info("~p Unamaneged event ~p", [?MODULE, {Type, Data}]),
  {keep_state, State}.

connected(enter, _, State) ->
  {keep_state, State};
connected({call, From}, {exchange_out, ProposedSample}, State) ->
  logger:info("~p sending exchange out to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket,
                 term_to_binary(#exchange_out{namespace = State#state.namespace,
                                              origin_node = State#state.mynode,
                                              proposed_sample = ProposedSample})),
  gen_statem:reply(From, ok),
  {keep_state, State};
connected(cast, {reject_exchange, Reason}, State) ->
  logger:info("~p sending exchange cancelled to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket,
                 term_to_binary(#exchange_cancelled{namespace = State#state.namespace,
                                                    reason = Reason})),
  {keep_state, State};
connected(info, {tcp, _Ref, BinData}, #state{buffer = Buffer} = State) ->
  logger:info("~p Connected state~p Received", [?MODULE, binary_to_term(BinData, [used])]),
  ParseResult = parse_packet(<<Buffer/binary, BinData/binary>>, keep_state, State),

  case ParseResult of
    {keep_state, NewState} ->
      {keep_state, NewState};
    {next_state, NextState, NewState, Timeout} ->
      {next_state, NextState, NewState, Timeout};
    Else ->
      logger:warning("~p Unmanaged event ~p", [?MODULE, Else]),
      {keep_state, State}
  end;
connected(info,
          {tcp_closed, _Ref},
          #state{namespace = Namespace, origin_node = OriginNode} = State) ->
  logger:info("~p Connection closed...~p", [?MODULE, State#state.origin_node]),
  gproc:send({p, l, {ontology, State#state.namespace}},
             {connection_terminated, {in, tcp_closed}, Namespace, OriginNode}),

  {stop, normal, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

parse_packet(<<>>, Action, State) ->
  {Action, State#state{buffer = <<>>}};
parse_packet(Buffer,
             Action,
             #state{size = Size} = #state{namespace = Namespace} = State) ->
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
    {complete, #increase_inview{}, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      logger:info("~p Increase inview received from ~p", [?MODULE, State#state.origin_node]),
      Transport = State#state.transport,
      Transport:send(State#state.socket,
                     term_to_binary(#increase_inview_ack{result = ok,
                                                         target_node = State#state.mynode})),

      gproc:send({p, l, {ontology, Namespace}}, {add_to_view, inview, State#state.origin_node}),

      parse_packet(BinLeft, Action, State#state{size = Size + 1});
    {complete, #leave_inview{}, Index} ->
      logger:info("~p Leave inview received from ~p", [?MODULE, State#state.origin_node]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {ontology, Namespace}},
                 {remove_from_view, inview, State#state.origin_node#node_entry.node_id}),

      parse_packet(BinLeft, Action, State#state{size = Size - 1});
    {complete, #empty_inview{node = Node}, Index} ->
      logger:info("~p Empty inview received from ~p", [?MODULE, Node]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,

      gproc:send({p, l, {ontology, Namespace}}, {empty_view, Node}),

      parse_packet(BinLeft, Action, State);
    {complete,
     #exchange_in{origin_node = OriginNode, proposed_sample = ProposedSample},
     Index} ->
      logger:info("~p Exchange in received from ~p", [?MODULE, OriginNode]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      MyPid = self(),
      gproc:send({p, l, {ontology, Namespace}},
                 {partial_view_exchange_in,
                  Namespace,
                  OriginNode#node_entry{pid = MyPid},
                  ProposedSample}),

      parse_packet(BinLeft, Action, State);
    {complete, #exchange_end{} = Event, Index} ->
      logger:info("~p Exchange end received", [?MODULE]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {spray_exchange, Namespace}}, {incoming_event, Event}),


      parse_packet(BinLeft, Action, State);
    {complete, #forward_subscription{subscriber_node = SubscriberNode}, Index} ->
      logger:info("~p Forward subscription received for ~p   from ~p",
                  [?MODULE, SubscriberNode, State#state.origin_node]),
      logger:info("Current action ~p", [Action]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {ontology, Namespace}},
                 {forwarded_subscription, Namespace, #node_entry{} = SubscriberNode}),

      parse_packet(BinLeft, Action, State);
    {complete, Event, Index} ->
      logger:info("~p Event received ~p", [?MODULE, Event]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {?MODULE, State#state.namespace, element(1, Event)}},
                 {incoming_event, State#state.namespace, Event}),

      parse_packet(BinLeft, Action, State);
    {incomplete, Buffer} ->
      logger:info("~p Incomplete packet received", [?MODULE]),
      {keep_state, State#state{buffer = Buffer}};
    Else ->
      logger:info("~p Unmanaged event ~p", [?MODULE, Else]),
      parse_packet(Buffer, Action, State)
  end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
  ?assertEqual(true, true).

-endif.

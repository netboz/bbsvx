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
-export([start_link/3, accept_exchange/2, reject_exchange/2, exchange_end/1,
         send_history/2, accept_join/2, accept_register/2]).
-export([init/1]).
%% Gen State Machine Callbacks
-export([code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([authenticate/3, wait_for_subscription/3, connected/3]).

-record(state,
        {ref :: ranch_tcp:ref(),
         socket :: ranch_tcp:socket(),
         namespace :: binary() | undefined,
         mynode :: #node_entry{},
         origin_node :: #node_entry{} | undefined,
         transport :: ranch_transport:transport(),
         buffer = <<>>}).

-type state() :: #state{}.

%%%=============================================================================
%%% Protocol API
%%% This is the API that ranch will use to communicate with the protocol.
%%%=============================================================================

start_link(Ref, Transport, Opts) ->
  ?'log-info'("~p Incoming connection on ~p...", [?MODULE, Opts]),
  gen_statem:start_link(?MODULE, {Ref, Transport, Opts}, []).

init({Ref, Transport, [MyNode]}) ->
  ?'log-info'("Initializing server connection ~p  Transport :~p", [MyNode, Transport]),
  %% Perform any required state initialization here.
  {ok,
   authenticate,
   #state{mynode = MyNode,
          transport = Transport,
          ref = Ref}}.

accept_register(ConnectionPid, #header_register_ack{} = Header) ->
  gen_statem:call(ConnectionPid, {accept_register, Header}).

accept_join(ConnectionPid, #header_join_ack{} = Header) ->
  gen_statem:call(ConnectionPid, {accept_join, Header}).

%% @TODO: Review cast/call logic here
accept_exchange(ConnectionPid, ProposedSample) ->
  gen_statem:call(ConnectionPid, {exchange_out, ProposedSample}).

reject_exchange(ConnectionPid, Reason) ->
  gen_statem:cast(ConnectionPid, {reject_exchange, Reason}).

exchange_end(ConnectionPid) ->
  gen_statem:cast(ConnectionPid, {exchange_end}).

send_history(ConnectionPid, #ontology_history{} = History) ->
  gen_statem:cast(ConnectionPid, {send_history, History}).

%%%=============================================================================
%%% Gen Statem API
%%%=============================================================================

-spec stop() -> ok.
stop() ->
  gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

terminate(Reason, State, _Data) ->
  ?'log-info'("~p Terminating...~p   Reason ~p", [?MODULE, State, Reason]),
  void.

code_change(_Vsn, State, Data, _Extra) ->
  {ok, State, Data}.

callback_mode() ->
  [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

-spec authenticate(enter | info, any(), state()) ->
                    {keep_state, state()} | {next_state, atom(), state()} | {stop, any(), state()}.
authenticate(enter, _, #state{ref = Ref, transport = Transport} = State) ->
  {ok, Socket} = ranch:handshake(Ref),
  ok = Transport:setopts(Socket, [{active, once}]),
  %% Perform any required state initialization here.
  {keep_state, State#state{socket = Socket}};
authenticate(info,
             {tcp, _Ref, BinData},
             #state{mynode = #node_entry{node_id = MyNodeId}} = State) ->
  %% Perform authentication
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
      %% Get current leader
      Transport:setopts(State#state.socket, [{active, true}]),
      %% Notify spray agent to add to inview
      gproc:send({p, l, {ontology, Header#header_register.namespace}},
                 {connected, Namespace, OriginNode, {inview, register}}),
      {next_state, connected, State#state{buffer = NewBuffer}};
    {ok, #header_join{}, NewBuffer} ->
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
  ?'log-warning'("~p Unamaneged event ~p", [?MODULE, {Type, Data}]),
  {keep_state, State}.

connected({call, From}, {accept_register, #header_register_ack{} = Header}, State) ->
  ?'log-info'("~p sending register ack to  ~p    header : ~p",
              [?MODULE, State#state.origin_node, Header]),
  ranch_tcp:send(State#state.socket, term_to_binary(Header)),
  gen_statem:reply(From, ok),
  {keep_state, State};
connected({call, From}, {accept_join, #header_join_ack{} = Header}, State) ->
  ?'log-info'("~p sending join ack to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket, term_to_binary(Header)),
  gen_statem:reply(From, ok),
  {keep_state, State};
connected(enter, _, State) ->
  {keep_state, State};
connected({call, From}, {exchange_out, ProposedSample}, State) ->
  ?'log-info'("~p sending exchange out to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket,
                 term_to_binary(#exchange_out{namespace = State#state.namespace,
                                              origin_node = State#state.mynode,
                                              proposed_sample = ProposedSample})),
  gen_statem:reply(From, ok),
  {keep_state, State};
connected(cast, {reject_exchange, Reason}, State) ->
  ?'log-info'("~p sending exchange cancelled to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket,
                 term_to_binary(#exchange_cancelled{namespace = State#state.namespace,
                                                    reason = Reason})),
  {keep_state, State};
connected(cast, {exchange_end}, State) ->
  ?'log-info'("~p sending exchange end to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket,
                 term_to_binary(#exchange_end{namespace = State#state.namespace})),
  {keep_state, State};
connected(cast, {send_history, #ontology_history{} = History}, State) ->
  ?'log-info'("~p sending history to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket, term_to_binary(History)),
  {keep_state, State};
connected(info, {tcp, _Ref, BinData}, #state{buffer = Buffer} = State) ->
  parse_packet(<<Buffer/binary, BinData/binary>>, keep_state, State);
connected(info,
          {tcp_closed, _Ref},
          #state{namespace = Namespace, origin_node = OriginNode} = State) ->
  ?'log-info'("~p Connection closed...~p", [?MODULE, State#state.origin_node]),
  gproc:send({p, l, {ontology, State#state.namespace}},
             {connection_terminated, {in, tcp_closed}, Namespace, OriginNode}),

  {stop, normal, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

parse_packet(<<>>, Action, State) ->
  {Action, State#state{buffer = <<>>}};
parse_packet(Buffer, Action, #state{namespace = Namespace} = State) ->
  Decoded =
    try binary_to_term(Buffer, [used]) of
      {DecodedEvent, NbBytesUsed} ->
        {complete, DecodedEvent, NbBytesUsed}
    catch
      _Error:_Reason ->
        {incomplete, Buffer}
    end,

  case Decoded of
    {complete, #transaction{} = Transacion, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      bbsvx_transaction_pipeline:receive_transaction(Transacion),
      parse_packet(BinLeft, Action, State);
    {complete,
     #ontology_history_request{namespace = Namespace, requester = Requester} = Event,
     Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({n, l, {bbsvx_actor_ontology, Namespace}},
                 Event#ontology_history_request{requester = Requester#node_entry{pid = self()}}),
      parse_packet(BinLeft, Action, State);
    {complete,
     #exchange_in{origin_node = OriginNode, proposed_sample = ProposedSample},
     Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      MyPid = self(),
      gproc:send({p, l, {ontology, Namespace}},
                 {partial_view_exchange_in,
                  Namespace,
                  OriginNode#node_entry{pid = MyPid},
                  ProposedSample}),

      parse_packet(BinLeft, Action, State);
    {complete, #exchange_end{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      event_spray_exchange(Namespace, Event),
      parse_packet(BinLeft, Action, State);
    {complete, #exchange_cancelled{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      event_spray_exchange(Namespace, Event),
      parse_packet(BinLeft, Action, State);
    {complete, #exchange_accept{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      event_spray_exchange(Namespace, Event),
      parse_packet(BinLeft, Action, State);
    {complete, #forward_subscription{subscriber_node = SubscriberNode}, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {ontology, Namespace}},
                 {forwarded_subscription, Namespace, #node_entry{} = SubscriberNode}),
      parse_packet(BinLeft, Action, State);
    {complete, #epto_message{payload = Payload}, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {epto_event, Namespace}}, {incoming_event, Payload}),
      parse_packet(BinLeft, Action, State);
    {complete, #leader_election_info{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {leader_election, Namespace}}, {incoming_event, Event}),
      parse_packet(BinLeft, Action, State);
    {complete, Event, Index} ->
      ?'log-error'("~p Event received ~p", [?MODULE, Event]),
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      gproc:send({p, l, {?MODULE, State#state.namespace, element(1, Event)}},
                 {incoming_event, State#state.namespace, Event}),

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

event_spray_exchange(Namespace, Event) ->
  gproc:send({p, l, {spray_exchange, Namespace}}, {incoming_event, Event}).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
  ?assertEqual(true, true).

-endif.

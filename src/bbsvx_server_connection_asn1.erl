%%%-----------------------------------------------------------------------------
%%% @doc
%%% ASN.1 version of bbsvx_server_connection.
%%% Clean replacement using ASN.1 encoding instead of term_to_binary.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_server_connection_asn1).

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
         send_history/2, accept_join/2, accept_register/2, peer_connect_to_sample/2]).
-export([init/1]).
%% Gen State Machine Callbacks
-export([code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([authenticate/3, wait_for_subscription/3, connected/3]).

-record(state,
        {ref :: any(),
         my_ulid :: binary() | undefined,
         lock = <<>> :: binary(),
         socket,
         namespace :: binary() | undefined,
         my_node :: #node_entry{},
         origin_node :: #node_entry{} | undefined,
         transport :: atom(),
         buffer = <<>>}).

-type state() :: #state{}.

%%%=============================================================================
%%% Protocol API
%%% This is the API that ranch will use to communicate with the protocol.
%%%=============================================================================

start_link(Ref, Transport, Opts) ->
  gen_statem:start_link(?MODULE, {Ref, Transport, Opts}, []).

init({Ref, Transport, [MyNode]}) ->
  ?'log-info'("Node ~p Initializing server connection. Transport :~p", [MyNode, Transport]),

  {ok,
   authenticate,
   #state{my_node = MyNode,
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

terminate(normal,
          connected,
          #state{namespace = NameSpace,
                 origin_node = OriginNode,
                 my_ulid = MyUlid} =
            State) ->
  ?'log-info'("~p Normally Terminating conenction IN from ...~p   Reason ~p",
              [?MODULE, OriginNode, normal]),
  prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
  gen_tcp:close(State#state.socket),
  arc_event(NameSpace, MyUlid, #evt_arc_disconnected{direction = in, ulid = MyUlid}),
  void;
terminate(OtherReason,
          connected,
          #state{namespace = NameSpace,
                 origin_node = OriginNode,
                 my_ulid = MyUlid} =
            State) ->
  ?'log-info'("~p Terminating conenction IN from ...~p   Reason ~p",
              [?MODULE, OriginNode, OtherReason]),
  prometheus_gauge:dec(<<"bbsvx_spray_inview_size">>, [NameSpace]),
  gen_tcp:close(State#state.socket),
  arc_event(NameSpace, MyUlid, #evt_arc_disconnected{direction = in, ulid = MyUlid}),
  void;
terminate(Reason, _CurrentState, #state{origin_node = OriginNode} = State) ->
  ?'log-info'("~p Terminating unconnected connection IN from...~p   Reason ~p",
              [?MODULE, OriginNode, Reason]),
  gen_tcp:close(State#state.socket),
  void.

code_change(_Vsn, State, Data, _Extra) ->
  {ok, State, Data}.

callback_mode() ->
  [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

%% @doc
%% authenticate/3
%% This is the first state of the connection. It is responsible for
%% authenticating the connection at the node level.
%% TODO: Implement authentication. Authentication should be done
%% by querying the ontology and excpect a succeed result from the proved goal
%% @end

-spec authenticate(enter | info, any(), state()) ->
                    {keep_state, state()} | {next_state, atom(), state()} | {stop, any(), state()}.
authenticate(enter, _, #state{ref = Ref, transport = Transport} = State) ->
  {ok, Socket} = ranch:handshake(Ref, 500),
  {ok, {Host, _Port}} = Transport:peername(Socket),

  ok = Transport:setopts(Socket, [{active, once}]),
  %% Perform any required state initialization here.
  %% TODO: Fx literal port number
  {keep_state,
   State#state{socket = Socket, origin_node = #node_entry{host = Host, port = 2304}}};
authenticate(info,
             {tcp, _Ref, BinData},
             #state{origin_node = #node_entry{} = OriginNode,
                    my_node = #node_entry{node_id = MyNodeId}} =
               State)
  when is_binary(BinData) andalso MyNodeId =/= undefined ->
  %% ASN.1 decoding instead of binary_to_term
  case bbsvx_asn1_codec:decode_fast(BinData) of
    error ->
      logger:error("Failed to decode binary data"),
      {stop, normal, State};
    #header_connect{node_id = MyNodeId} ->
      ?'log-warning'("~p Connection to self   ~p", [?MODULE, MyNodeId]),
      %% Connecting to self
      ConnectAck = #header_connect_ack{node_id = MyNodeId,
                                     result = connection_to_self},
      case bbsvx_asn1_codec:encode_fast(ConnectAck) of
        error ->
          {stop, normal, State};
        EncodedAck ->
          ranch_tcp:send(State#state.socket, EncodedAck),
          {stop, normal, State}
      end;
    #header_connect{node_id = IncomingNodeId, namespace = NameSpace} ->
      ConnectAck = #header_connect_ack{node_id = State#state.my_node#node_entry.node_id,
                                     result = ok},
      case bbsvx_asn1_codec:encode_fast(ConnectAck) of
        error ->
          {stop, normal, State};
        EncodedAck ->
          ranch_tcp:send(State#state.socket, EncodedAck),
          ranch_tcp:setopts(State#state.socket, [{active, once}]),
          {next_state,
           wait_for_subscription,
           State#state{buffer = <<>>,
                       origin_node = OriginNode#node_entry{node_id = IncomingNodeId},
                       namespace = NameSpace}}
      end;
    _Other ->
      logger:error("Failed to decode authentication message"),
      {stop, normal, State}
  end;
%% catch all
authenticate(Type, Event, State) ->
  ?'log-warning'("~p Unmanaged event ~p", [?MODULE, {authenticate, {Type, Event}}]),
  {keep_state, State}.

%% @doc
%% wait_for_subscription/3
%% This state is responsible for waiting for the subscription message.
%% Upon the subscription message, it will be decided if the connection is
%% a join, register or forward subscription.
%% Lock is checked at this stage.
%% @end
wait_for_subscription(enter, _, State) ->
  {keep_state, State};
wait_for_subscription(info,
                      {tcp, _Ref, BinData},
                      #state{namespace = NameSpace,
                             origin_node = OriginNode,
                             socket = Socket,
                             buffer = Buffer,
                             transport = Transport} =
                        State) ->
  ConcatBuffer = <<Buffer/binary, BinData/binary>>,
  %% ASN.1 decoding instead of binary_to_term
  case bbsvx_asn1_codec:decode_fast(ConcatBuffer) of
    error ->
      %% Keep buffering for incomplete message
      {keep_state, State#state{buffer = ConcatBuffer}};
    #header_register{ulid = Ulid, lock = Lock} ->
      %% Register this arc. If collision, this process will crash
      %% with the incoming connection on ther side. At least
      %% it keeps arcs consistent.
      gproc:reg({n, l, {arc, in, Ulid}}, Lock),

      %% Notify spray agent to add to inview
      arc_event(NameSpace,
                Ulid,
                #evt_arc_connected_in{ulid = Ulid,
                                      lock = Lock,
                                      source = OriginNode,
                                      spread = {true, Lock}}),
      %% Acknledge the registration and activate socket
      %% TODO : Fix leader initialisation, it should be requested
      %% from the ontology
      RegisterAck = #header_register_ack{result = ok,
                                       leader = OriginNode#node_entry.node_id,
                                       current_index = 0},
      case bbsvx_asn1_codec:encode_fast(RegisterAck) of
        error ->
          {stop, normal, State};
        EncodedAck ->
          Transport:send(Socket, EncodedAck),
          Transport:setopts(State#state.socket, [{active, true}]),
          {next_state, connected, State#state{my_ulid = Ulid, buffer = <<>>}}
      end;
    #header_forward_join{ulid = Ulid, lock = Lock} ->
      %% TOO: There is no security here. Lock should be checked against the
      %% registration lock as an exemple.
      %% There shouldn't be any arc registered for this ulid, here, as, like in register,
      %% a new arc is created.
      gproc:reg({n, l, {arc, in, Ulid}}, Lock),
      %% Notify spray agent to add this new arc to inview
      arc_event(NameSpace,
                Ulid,
                #evt_arc_connected_in{ulid = Ulid,
                                      lock = Lock,
                                      source = OriginNode}),
      %% Acknledge the registration and activate socket
      %% TODO: type seems unused
      ForwardJoinAck = #header_forward_join_ack{result = ok, type = forward_join},
      case bbsvx_asn1_codec:encode_fast(ForwardJoinAck) of
        error ->
          {stop, normal, State};
        EncodedAck ->
          Transport:send(Socket, EncodedAck),
          Transport:setopts(State#state.socket, [{active, true}]),
          {next_state,
           connected,
           State#state{my_ulid = Ulid,
                       lock = Lock,
                       buffer = <<>>}}
      end;
    #header_join{type = mirror = Type,
                 ulid = Ulid,
                 options = Options,
                 current_lock = CurrentLock,
                 new_lock = NewLock} ->
      ?'log-info'("~p Mirror connection ~p   current lock ~p", [?MODULE, Ulid, CurrentLock]),
      Key = {arc, '_', '_'},
      GProcKey = {'_', '_', Key},
      MatchHead = {GProcKey, '_', '_'},
      Guard = [],
      Result = ['$$'],
      GG = gproc:select([{MatchHead, Guard, Result}]),
      ?'log-info'("GG: ~p", [GG]),
      case gproc:lookup_value({n, l, {arc, out, Ulid}}) of
        {gproc_error, Error} ->
          ?'log-alert'("~p No arc found for ulid ~p", [?MODULE, Ulid]),
          JoinAck = #header_join_ack{result = {error, Error},
                                   type = Type,
                                   options = Options},
          case bbsvx_asn1_codec:encode_fast(JoinAck) of
            error ->
              {stop, normal, State};
            EncodedAck ->
              Transport:send(Socket, EncodedAck),
              {stop, normal, State}
          end;
        CurrentLock ->
          ?'log-info'("~p Locks match ~p", [?MODULE, CurrentLock]),
          %% Change change the connection attributed to ulid to this one
          OtherConnectionPid = gproc:where({n, l, {arc, out, Ulid}}),
          gproc:unreg_other({n, l, {arc, out, Ulid}}, OtherConnectionPid),
          gproc:reg({n, l, {arc, in, Ulid}}, NewLock),
          %% Stop the previous connection
          gen_statem:stop(OtherConnectionPid),
          arc_event(NameSpace,
                    Ulid,
                    #evt_arc_connected_in{ulid = Ulid,
                                          lock = NewLock,
                                          source = OriginNode}),
          %% Notify other side we accepted the connection
          JoinAck = #header_join_ack{result = ok,
                                   type = Type,
                                   options = Options},
          case bbsvx_asn1_codec:encode_fast(JoinAck) of
            error ->
              {stop, normal, State};
            EncodedAck ->
              Transport:send(Socket, EncodedAck),
              Transport:setopts(Socket, [{active, true}]),
              {next_state,
               connected,
               State#state{my_ulid = Ulid,
                           lock = NewLock,
                           buffer = <<>>}}
          end;
        Else ->
          ?'log-warning'("~p Locks don't match incoming arc lock ~p    stored lock : ~p",
                         [?MODULE, CurrentLock, Else]),
          JoinAck = #header_join_ack{result = {error, lock_mismatch},
                                   type = Type,
                                   options = Options},
          case bbsvx_asn1_codec:encode_fast(JoinAck) of
            error ->
              {stop, normal, State};
            EncodedAck ->
              Transport:send(Socket, EncodedAck),
              {stop, normal, State}
          end
      end;
    #header_join{type = normal = Type,
                 ulid = Ulid,
                 current_lock = CurrentLock,
                 new_lock = NewLock,
                 options = Options} ->
      Key = {arc, '_', '_'},
      GProcKey = {'_', '_', Key},
      MatchHead = {GProcKey, '_', '_'},
      Guard = [],
      Result = ['$$'],
      GG = gproc:select([{MatchHead, Guard, Result}]),
      ?'log-info'("GG: ~p", [GG]),
      ?'log-info'("~p Normal connection ~p   current lock ~p", [?MODULE, Ulid, CurrentLock]),
      %% This is a swapped connection, so we shoud already have a
      %% server connection undr this arc ulid.
      case gproc:lookup_value({n, l, {arc, in, Ulid}}) of
        {gproc_error, Error} ->
          ?'log-alert'("~p No arc found for ulid ~p", [?MODULE, Ulid]),
          JoinAck = #header_join_ack{result = {error, Error},
                                   type = Type,
                                   options = Options},
          case bbsvx_asn1_codec:encode_fast(JoinAck) of
            error ->
              {stop, normal, State};
            EncodedAck ->
              Transport:send(Socket, EncodedAck),
              {stop, normal, State}
          end;
        CurrentLock ->
          ?'log-info'("~p Locks match ~p", [?MODULE, CurrentLock]),
          %% Change change the connection attributed to ulid to this one
          Key = {arc, '_', '_'},
          GProcKey = {'_', '_', Key},
          MatchHead = {GProcKey, '_', '_'},
          Guard = [],
          Result = ['$$'],
          GP = gproc:select([{MatchHead, Guard, Result}]),
          ?'log-info'("GP: ~p", [GP]),
          OtherConnectionPid = gproc:where({n, l, {arc, in, Ulid}}),
          gproc:unreg_other({n, l, {arc, in, Ulid}}, OtherConnectionPid),
          gproc:reg({n, l, {arc, in, Ulid}}, NewLock),
          %% Notify other side we accepted the connection
          JoinAck = #header_join_ack{result = ok,
                                   type = Type,
                                   options = Options},
          case bbsvx_asn1_codec:encode_fast(JoinAck) of
            error ->
              {stop, normal, State};
            EncodedAck ->
              Transport:send(Socket, EncodedAck),

              arc_event(NameSpace,
                        Ulid,
                        #evt_arc_connected_in{ulid = Ulid,
                                              lock = NewLock,
                                              source = OriginNode}),

              %% Stop the previous connection
              gen_statem:stop(OtherConnectionPid),
              Transport:setopts(Socket, [{active, true}]),
              {next_state,
               connected,
               State#state{my_ulid = Ulid,
                           lock = NewLock,
                           buffer = <<>>}}
          end;
        Else ->
          ?'log-warning'("~p Locks don't match ~p    incoming lock : ~p",
                         [?MODULE, CurrentLock, Else]),
          JoinAck = #header_join_ack{result = {error, lock_mismatch},
                                   type = Type,
                                   options = Options},
          case bbsvx_asn1_codec:encode_fast(JoinAck) of
            error ->
              {stop, normal, State};
            EncodedAck ->
              Transport:send(Socket, EncodedAck),
              {stop, normal, State}
          end
      end
  end;
%% Cathc all
wait_for_subscription(Type, Data, State) ->
  ?'log-warning'("~p Unamaneged event ~p", [?MODULE, {Type, Data}]),
  {keep_state, State}.

connected(enter,
          _,
          #state{namespace = NameSpace,
                 my_ulid = MyUlid,
                 lock = Lock,
                 my_node = MyNode,
                 origin_node = OriginNode} =
            State) ->
  gproc:reg({p, l, {inview, NameSpace}},
            #arc{age = 0,
                 ulid = MyUlid,
                 target = MyNode,
                 lock = Lock,
                 source = OriginNode}),

  prometheus_gauge:inc(<<"bbsvx_spray_inview_size">>, [NameSpace]),

  {keep_state, State};
connected(info, {tcp, _Ref, BinData}, #state{buffer = Buffer} = State) ->
  parse_packet(<<Buffer/binary, BinData/binary>>, keep_state, State);
connected(info, #incoming_event{event = #peer_connect_to_sample{} = Msg}, State) ->
  ?'log-info'("~p sending peer connect to sample to  ~p",
              [?MODULE, State#state.origin_node]),
  %% ASN.1 encoding instead of term_to_binary
  case bbsvx_asn1_codec:encode_fast(Msg) of
    error -> 
      {keep_state, State};
    EncodedMsg ->
      ranch_tcp:send(State#state.socket, EncodedMsg),
      {keep_state, State}
  end;
connected(info, #incoming_event{event = #header_register_ack{} = Header}, State) ->
  ?'log-info'("~p sending register ack to  ~p    header : ~p",
              [?MODULE, State#state.origin_node, Header]),
  %% ASN.1 encoding instead of term_to_binary
  case bbsvx_asn1_codec:encode_fast(Header) of
    error -> 
      {keep_state, State};
    EncodedMsg ->
      ranch_tcp:send(State#state.socket, EncodedMsg),
      {keep_state, State}
  end;
connected({call, From}, {accept_join, #header_join_ack{} = Header}, State) ->
  ?'log-info'("~p sending join ack to  ~p", [?MODULE, State#state.origin_node]),
  %% ASN.1 encoding instead of term_to_binary
  case bbsvx_asn1_codec:encode_fast(Header) of
    error -> 
      gen_statem:reply(From, {error, encode_failed}),
      {keep_state, State};
    EncodedMsg ->
      ranch_tcp:send(State#state.socket, EncodedMsg),
      gen_statem:reply(From, ok),
      {keep_state, State}
  end;
connected({call, From},
          {close, Reason},
          #state{} = State) ->
  ?'log-info'("~p closing connection from  ~p to us. Reason : ~p",
              [?MODULE, State#state.origin_node, Reason]),
  gen_statem:reply(From, ok),
  {stop, normal, State};
connected(info,
          #incoming_event{event = #exchange_out{proposed_sample = ProposedSample}},
          #state{} = State) ->
  ?'log-info'("~p sending exchange out to  ~p", [?MODULE, State#state.origin_node]),
  %% ASN.1 encoding instead of term_to_binary
  ExchangeOut = #exchange_out{proposed_sample = ProposedSample},
  case bbsvx_asn1_codec:encode_fast(ExchangeOut) of
    error -> 
      {keep_state, State};
    EncodedMsg ->
      ranch_tcp:send(State#state.socket, EncodedMsg),
      {keep_state, State}
  end;
connected(info, {reject, Reason}, #state{namespace = NameSpace} = State) ->
  ?'log-info'("~p sending exchange cancelled to  ~p", [?MODULE, State#state.origin_node]),
  %% ASN.1 encoding instead of term_to_binary
  ExchangeCancelled = #exchange_cancelled{namespace = NameSpace, reason = Reason},
  case bbsvx_asn1_codec:encode_fast(ExchangeCancelled) of
    error -> 
      ?'log-info'("~p Exchange cancelled encoding failed", [?MODULE]),
      {keep_state, State};
    EncodedMsg ->
      Result = ranch_tcp:send(State#state.socket, EncodedMsg),
      ?'log-info'("~p Exchange cancelled sent ~p", [?MODULE, Result]),
      {keep_state, State}
  end;
connected(cast, {send_history, #ontology_history{} = History}, State) ->
  ?'log-info'("~p sending history to  ~p", [?MODULE, State#state.origin_node]),
  %% ASN.1 encoding instead of term_to_binary
  case bbsvx_asn1_codec:encode_fast(History) of
    error -> 
      {keep_state, State};
    EncodedMsg ->
      ranch_tcp:send(State#state.socket, EncodedMsg),
      {keep_state, State}
  end;
connected(info, {send, Data}, State) ->
  %% ASN.1 encoding instead of term_to_binary
  case bbsvx_asn1_codec:encode_fast(Data) of
    error -> 
      {keep_state, State};
    EncodedMsg ->
      ranch_tcp:send(State#state.socket, EncodedMsg),
      {keep_state, State}
  end;
connected(info,
          {tcp_closed, _Ref},
          #state{namespace = NameSpace, my_ulid = MyUlid} = State) ->
  ?'log-info'("Namespace : ~p ; Node :~p Connection in from ~p closed...",
              [NameSpace, MyUlid, State#state.origin_node]),
  {stop, normal, State};
connected(info, {terminate, Reason}, State) ->
  ?'log-info'("~p Terminating connection from ~p   Reason ~p",
              [?MODULE, State#state.origin_node, Reason]),
  {stop, Reason, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

parse_packet(<<>>, Action, State) ->
  {Action, State#state{buffer = <<>>}};
parse_packet(Buffer,
             Action,
             #state{namespace = NameSpace,
                    my_ulid = MyUlid,
                    origin_node =
                      #node_entry{host = Host,
                                  port = Port,
                                  node_id = NodeId}} =
               State) ->
  %% ASN.1 decoding instead of binary_to_term
  case bbsvx_asn1_codec:decode_fast(Buffer) of
    error ->
      %% Incomplete or invalid data, buffer it
      {keep_state, State#state{buffer = Buffer}};
    #transaction{} = Transacion ->
      bbsvx_transaction_pipeline:receive_transaction(Transacion),
      %% For simplicity, assume we consumed all data
      %% In production, need to handle partial messages
      {Action, State#state{buffer = <<>>}};
    #ontology_history_request{namespace = NameSpace} = Event ->
      gproc:send({n, l, {bbsvx_actor_ontology, NameSpace}},
                 Event#ontology_history_request{requester = MyUlid}),
      {Action, State#state{buffer = <<>>}};
    #exchange_in{} = Msg ->
      arc_event(NameSpace, MyUlid, Msg),
      {Action, State#state{buffer = <<>>}};
    #change_lock{new_lock = NewLock} ->
      %% TODO: Update the lock at the connection level
      parse_packet(<<>>, Action, State#state{lock = NewLock});
    #exchange_cancelled{} = Event ->
      arc_event(NameSpace, MyUlid, Event),
      {Action, State#state{buffer = <<>>}};
    #exchange_accept{} = Event ->
      arc_event(NameSpace, MyUlid, Event),
      {Action, State#state{buffer = <<>>}};
    #open_forward_join{} = Event ->
      arc_event(NameSpace, MyUlid, Event),
      {Action, State#state{buffer = <<>>}};
    #epto_message{payload = Payload} ->
      gproc:send({p, l, {epto_event, NameSpace}}, {incoming_event, Payload}),
      {Action, State#state{buffer = <<>>}};
    #leader_election_info{} = Event ->
      gproc:send({p, l, {leader_election, NameSpace}}, {incoming_event, Event}),
      {Action, State#state{buffer = <<>>}};
    #node_quitting{reason = Reason} = Event ->
      ?'log-notice'("~p Event received ~p", [?MODULE, Event]),
      arc_event(NameSpace,
                MyUlid,
                #evt_node_quitted{direction = in,
                                  node_id = NodeId,
                                  host = Host,
                                  port = Port,
                                  reason = Reason}),

      {stop, Reason, State};
    Event ->
      ?'log-warn'("~p Event received ~p", [?MODULE, Event]),
      {Action, State#state{buffer = <<>>}}
  end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

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
                             direction = in,
                             origin_arc = MyUlid}).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
  ?assertEqual(true, true).

-endif.
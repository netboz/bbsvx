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

terminate(Reason, _CurrentState, State) ->
  ?'log-info'("~p Terminating conenction in...~p   Reason ~p", [?MODULE, State, Reason]),
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
  %% Perform authentication
  Decoded =
    try binary_to_term(BinData, [safe, used]) of
      {DecodedTerm, Index} when is_number(Index) ->
        <<_:Index/binary, Rest/binary>> = BinData,
        {ok, DecodedTerm, Rest}
    catch
      _:_ ->
        logger:error("Failed to decode binary data: ~p", [BinData]),
        {error, "Failed to decode binary data"}
    end,
  case Decoded of
    {ok, #header_connect{node_id = MyNodeId}, _} ->
      %% Connecting to self
      ranch_tcp:send(State#state.socket,
                     term_to_binary(#header_connect_ack{node_id = MyNodeId,
                                                        result = connection_to_self})),
      {stop, normal, State};
    {ok, #header_connect{node_id = IncomingNodeId} = Header, NewBuffer} ->
      ranch_tcp:send(State#state.socket,
                     term_to_binary(#header_connect_ack{node_id =
                                                          State#state.my_node#node_entry.node_id,
                                                        result = ok})),
      ranch_tcp:setopts(State#state.socket, [{active, once}]),
      {next_state,
       wait_for_subscription,
       State#state{buffer = NewBuffer,
                   origin_node = OriginNode#node_entry{node_id = IncomingNodeId},
                   namespace = Header#header_connect.namespace}};
    {error, Reason} ->
      logger:error("Failed to decode binary data: ~p", [Reason]),
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
                      #state{namespace = Namespace,
                             origin_node = OriginNode,
                             socket = Socket,
                             buffer = Buffer,
                             transport = Transport} =
                        State) ->
  ConcatBuffer = <<Buffer/binary, BinData/binary>>,
  Decoded =
    try binary_to_term(ConcatBuffer, [safe, used]) of
      {DecodedTerm, Index} when is_integer(Index) ->
        <<_:Index/binary, Rest/binary>> = ConcatBuffer,
        {ok, DecodedTerm, Rest}
    catch
      _:_ ->
        logger:error("Failed to decode binary data: ~p", [BinData]),
        {error, "Failed to decode binary data"}
    end,
  case Decoded of
    {ok, #header_register{ulid = Ulid, lock = Lock}, NewBuffer} ->
      %% Register this arc. If collision, this process will crash
      %% with the incoming connection on ther side. At least
      %% it keeps arcs consistent.
      gproc:reg({n, l, {arc, in, Ulid}}, Lock),

      %% Notify spray agent to add to inview
      arc_event(Namespace,
                Ulid,
                #evt_arc_connected_in{ulid = Ulid,
                                      lock = Lock,
                                      source = OriginNode,
                                      spread = {true, Lock}}),
      %% Acknledge the registration and activate socket
      %% TODO : Fix leader initialisation, it should be requested
      %% from the ontology
      Transport:send(Socket,
                     term_to_binary(#header_register_ack{result = ok,
                                                         leader = OriginNode#node_entry.node_id,
                                                         current_index = 0})),
      Transport:setopts(State#state.socket, [{active, true}]),
      {next_state, connected, State#state{my_ulid = Ulid, buffer = NewBuffer}};
    {ok, #header_forward_join{ulid = Ulid, lock = Lock}, NewBuffer} ->
      %% TOO: There is no security here. Lock should be checked against the
      %% registration lock as an exemple.
      %% There shouldn't be any arc registered for this ulid, here, as, like in register,
      %% a new arc is created.
      gproc:reg({n, l, {arc, in, Ulid}}, Lock),
      %% Notify spray agent to add this new arc to inview
      arc_event(Namespace,
                Ulid,
                #evt_arc_connected_in{ulid = Ulid,
                                      lock = Lock,
                                      source = OriginNode}),
      %% Acknledge the registration and activate socket
      %% TODO: type seems unused
      Transport:send(Socket,
                     term_to_binary(#header_forward_join_ack{result = ok, type = forward_join})),
      Transport:setopts(State#state.socket, [{active, true}]),
      {next_state,
       connected,
       State#state{my_ulid = Ulid,
                   lock = Lock,
                   buffer = NewBuffer}};
    {ok,
     #header_join{type = mirror = Type,
                  ulid = Ulid,
                  options = Options,
                  current_lock = CurrentLock,
                  new_lock = NewLock},
     NewBuffer} ->
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
          Transport:send(Socket,
                         term_to_binary(#header_join_ack{result = {error, Error},
                                                         type = Type,
                                                         options = Options})),
          {stop, normal, State};
        CurrentLock ->
          ?'log-info'("~p Locks match ~p", [?MODULE, CurrentLock]),
          %% Change change the connection attributed to ulid to this one
          OtherConnectionPid = gproc:where({n, l, {arc, out, Ulid}}),
          gproc:unreg_other({n, l, {arc, out, Ulid}}, OtherConnectionPid),
          gproc:reg({n, l, {arc, in, Ulid}}, NewLock),
          %% Stop the previous connection
          gen_statem:stop(OtherConnectionPid),
          arc_event(Namespace,
                    Ulid,
                    #evt_arc_connected_in{ulid = Ulid,
                                          lock = NewLock,
                                          source = OriginNode}),
          %% Notify other side we accepted the connection
          Transport:send(Socket,
                         term_to_binary(#header_join_ack{result = ok,
                                                         type = Type,
                                                         options = Options})),
          Transport:setopts(Socket, [{active, true}]),
          {next_state, connected, State#state{my_ulid = Ulid, buffer = NewBuffer}};
        Else ->
          ?'log-warning'("~p Locks don't match incoming arc lock ~p    stored lock : ~p",
                         [?MODULE, CurrentLock, Else]),
          Transport:send(Socket,
                         term_to_binary(#header_join_ack{result = {error, lock_mismatch},
                                                         type = Type,
                                                         options = Options})),
          {stop, normal, State}
      end;
    {ok,
     #header_join{type = normal = Type,
                  ulid = Ulid,
                  current_lock = CurrentLock,
                  new_lock = NewLock,
                  options = Options},
     NewBuffer} ->
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
          Transport:send(Socket,
                         term_to_binary(#header_join_ack{result = {error, Error},
                                                         type = Type,
                                                         options = Options})),
          {stop, normal, State};
        CurrentLock ->
          ?'log-info'("~p Locks match ~p", [?MODULE, CurrentLock]),
          %% Change change the connection attributed to ulid to this one
          Key = {arc, '_', '_'},
          GProcKey = {'_', '_', Key},
          MatchHead = {GProcKey, '_', '_'},
          Guard = [],
          Result = ['$$'],
          GG = gproc:select([{MatchHead, Guard, Result}]),
          ?'log-info'("GG: ~p", [GG]),
          OtherConnectionPid = gproc:where({n, l, {arc, in, Ulid}}),
          gproc:unreg_other({n, l, {arc, in, Ulid}}, OtherConnectionPid),
          gproc:reg({n, l, {arc, in, Ulid}}, NewLock),
          %% Stop the previous connection
          gen_statem:stop(OtherConnectionPid),
          %% Notifiy spray agent to change origin of this node
          arc_event(Namespace,
                    Ulid,
                    #evt_arc_swapped_in{ulid = Ulid,
                                        newlock = NewLock,
                                        new_source = OriginNode}),
          %% Notify other side we accepted the connection
          Transport:send(Socket,
                         term_to_binary(#header_join_ack{result = ok,
                                                         type = Type,
                                                         options = Options})),
          Transport:setopts(Socket, [{active, true}]),
          {next_state, connected, State#state{my_ulid = Ulid, buffer = NewBuffer}};
        Else ->
          ?'log-warning'("~p Locks don't match ~p    incoming lock : ~p",
                         [?MODULE, CurrentLock, Else]),
          Transport:send(Socket,
                         term_to_binary(#header_join_ack{result = {error, lock_mismatch},
                                                         type = Type,
                                                         options = Options})),
          {stop, normal, State}
      end
  end;
%% Cathc all
wait_for_subscription(Type, Data, State) ->
  ?'log-warning'("~p Unamaneged event ~p", [?MODULE, {Type, Data}]),
  {keep_state, State}.

connected(info, #incoming_event{event = #peer_connect_to_sample{} = Msg}, State) ->
  ?'log-info'("~p sending peer connect to sample to  ~p",
              [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket, term_to_binary(Msg)),
  {keep_state, State};
connected(info, #incoming_event{event = #header_register_ack{} = Header}, State) ->
  ?'log-info'("~p sending register ack to  ~p    header : ~p",
              [?MODULE, State#state.origin_node, Header]),
  ranch_tcp:send(State#state.socket, term_to_binary(Header)),
  {keep_state, State};
connected({call, From}, {accept_join, #header_join_ack{} = Header}, State) ->
  ?'log-info'("~p sending join ack to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket, term_to_binary(Header)),
  gen_statem:reply(From, ok),
  {keep_state, State};
connected({call, From},
          {close, Reason},
          #state{namespace = Namespace, my_ulid = MyUlid} = State) ->
  ?'log-info'("~p closing connection from  ~p to us. Reason : ~p",
              [?MODULE, State#state.origin_node, Reason]),
  gen_statem:reply(From, ok),
  arc_event(Namespace, MyUlid, #evt_arc_disconnected{direction = in, ulid = MyUlid}),

  {stop, normal, State};
connected(enter, _, State) ->
  {keep_state, State};
connected(info,
          #incoming_event{event = #exchange_out{proposed_sample = ProposedSample}},
          #state{} = State) ->
  ?'log-info'("~p sending exchange out to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket,
                 term_to_binary(#exchange_out{proposed_sample = ProposedSample})),
  {keep_state, State};
connected(info,
          #incoming_event{event = {reject, Reason}},
          #state{namespace = Namespace} = State) ->
  ?'log-info'("~p sending exchange cancelled to  ~p", [?MODULE, State#state.origin_node]),
  Result =
    ranch_tcp:send(State#state.socket,
                   term_to_binary(#exchange_cancelled{namespace = Namespace, reason = Reason})),
  ?'log-info'("~p Exchange cancelled sent ~p", [?MODULE, Result]),
  {keep_state, State};
connected(cast, {send_history, #ontology_history{} = History}, State) ->
  ?'log-info'("~p sending history to  ~p", [?MODULE, State#state.origin_node]),
  ranch_tcp:send(State#state.socket, term_to_binary(History)),
  {keep_state, State};
connected(info, {tcp, _Ref, BinData}, #state{buffer = Buffer} = State) ->
  parse_packet(<<Buffer/binary, BinData/binary>>, keep_state, State);
connected(info,
          {tcp_closed, _Ref},
          #state{namespace = Namespace, my_ulid = MyUlid} = State) ->
  ?'log-info'("~p Connection in closed...~p", [?MODULE, State#state.origin_node]),
  arc_event(Namespace, MyUlid, #evt_arc_disconnected{direction = in, ulid = MyUlid}),
  {stop, normal, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

parse_packet(<<>>, Action, State) ->
  {Action, State#state{buffer = <<>>}};
parse_packet(Buffer, Action, #state{namespace = Namespace, my_ulid = MyUlid} = State) ->
  Decoded =
    try binary_to_term(Buffer, [used]) of
      {DecodedEvent, NbBytesUsed} when is_number(NbBytesUsed) ->
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
                 Event#ontology_history_request{requester = Requester#node_entry{}}),
      parse_packet(BinLeft, Action, State);
    {complete, #exchange_in{} = Msg, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      arc_event(Namespace, MyUlid, Msg),
      parse_packet(BinLeft, Action, State);
    {complete, #change_lock{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      arc_event(Namespace, MyUlid, Event),
      %% Update the lock at the connection level
      parse_packet(BinLeft, Action, State#state{lock = Event#change_lock.new_lock});
    {complete, #exchange_cancelled{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      arc_event(Namespace, MyUlid, Event),
      parse_packet(BinLeft, Action, State);
    {complete, #exchange_accept{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      arc_event(Namespace, MyUlid, Event),
      parse_packet(BinLeft, Action, State);
    {complete, #peer_connect_to_sample{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      arc_event(Namespace, MyUlid, Event),
      parse_packet(BinLeft, Action, State);
    {complete, #open_forward_join{} = Event, Index} ->
      <<_:Index/binary, BinLeft/binary>> = Buffer,
      arc_event(Namespace, MyUlid, Event),
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

%%-----------------------------------------------------------------------------
%% @doc
%% ontology_arc_event/3
%% Send an event related to arcs events on this namespace
%% @end
%% ----------------------------------------------------------------------------
-spec arc_event(binary(), binary(), term()) -> ok.
arc_event(Namespace, MyUlid, Event) ->
  gproc:send({p, l, {spray_exchange, Namespace}},
             #incoming_event{event = Event, origin_arc = MyUlid}).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
  ?assertEqual(true, true).

-endif.

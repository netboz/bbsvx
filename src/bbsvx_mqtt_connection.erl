%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_mqtt_connection).

-author("yan").

-behaviour(gen_statem).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-record(message, {nameSpace :: binary(), payload :: binary(), qos :: integer()}).

%% External API
-export([start_link/3, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3, handle_event/4]).
%% State transitions
-export([waiting_for_id/3, connected/3]).
%% Hooks
-export([msg_handler/2, disconnected/1]).

-record(state, {connection :: pid(), my_id :: binary(), host :: {binary(), integer()}}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(MyId :: binary(), Host :: binary(), Port :: integer()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(MyId, Host, Port) ->
    gen_statem:start({via, gproc, {n, l, {Host, Port}}}, ?MODULE, [MyId, Host, Port], []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([MyId, Host, Port]) ->
    logger:info("BBSVX mqtt connection : Starting mqtt connection to ~p:~p    ~p", [Host, Port, MyId]),
    Me = self(),
    case emqtt:start_link([{host, Host},
                           {port, Port},
                           {clientid, MyId},
                           {proto_ver, v5},
                           {owner, Me},
                           {msg_handler,
                            #{disconnected => fun disconnected/1,
                              publish => {?MODULE, msg_handler, [Me]}}}])
    of
        {ok, Pid} ->
            case emqtt:connect(Pid) of
                {ok, _Props} ->
                    logger:info("Connected to ~p:~p", [Host, Port]),
                    emqtt:subscribe(Pid, #{}, [{<<"welcome">>, [{nl, true}]}]),
                    {ok,
                     waiting_for_id,
                     #state{connection = Pid,
                            my_id = MyId,
                            host = {Host, Port}}, 3000};
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    state_functions.

%%%=============================================================================
%%% State transitions
%%%=============================================================================

waiting_for_id(cast, {incoming_mqtt_message, _, _, _, _, <<"welcome">>, NodeId}, #state{host = {Host, Port}, my_id = NodeId } =  State) ->
    logger:info("BBSVX mqtt connection : Connecting to self ~p   ~p", [{Host, Port}, NodeId]),
    gproc:send({p, l, {Host, Port}}, {connection_to_self, State#state.host, NodeId}),
    {stop, normal, State};
waiting_for_id(cast, {incoming_mqtt_message, _, _, _, _, <<"welcome">>, NodeId}, #state{host = {Host, Port} } =  State) ->
    logger:info("BBSVX mqtt connection : Received contact ~p node ID  ~p", [{Host, Port}, NodeId]),
    gproc:reg({n, l, NodeId}, self()),
    gproc:send({p, l, {Host, Port}}, {connection_ready, State#state.host, NodeId}),
    {next_state, connected, State#state{my_id = NodeId}};
waiting_for_id(timeout, _, #state{host = Host} = State) ->
    gproc:send({p, l, Host}, {node_subscription_timeout, State#state.host}),
    {stop, normal, State}.


%%-----------------------------------------------------------------------------
%% @doc
%% Connected state enter
%% @end
%%-----------------------------------------------------------------------------
connected(enter, _From, State) ->
    logger:info("BBSVX mqtt connection : Connected to ~p", [State#state.host]),
    gproc:reg({n, l, State#state.my_id}),
    {next_state, connected, State};

%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to subscribe to a topic.
%% @end
%%-----------------------------------------------------------------------------
connected({call, From}, {subscribe, Topic, QoS}, State) ->
    logger:info("BBSVX mqtt connection : Subscribing to ~p", [Topic]),
    case emqtt:subscribe(State#state.connection, #{}, [{Topic,[{nl, true}]}]) of
        {ok, Props, _} ->
            {keep_state, State, [{reply, From, {ok, Props}}]};
        {error, Reason} ->
            logger:error("Failed to subscribe to ~p: ~p", [Topic, Reason]),
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;

%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to get target node id
%% @end
%%-----------------------------------------------------------------------------
connected({call, From}, get_id, State) ->
    {keep_state, State, [{reply, From, State#state.my_id}]};            


%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to publish a message to a topic.
%% @end

connected({call, From}, {publish, _NodeId, #message{nameSpace = Namespace, payload = Payload}}, State) ->
    case emqtt:publish(State#state.connection, Namespace, #{}, term_to_binary(Payload), []) of
        ok ->
            {keep_state, State, [{reply, From, ok}]};
        {error, Reason} ->
            logger:error("BBSVX mqtt connection : Failed to publish to ~p: ~p", [Namespace, Reason]),
            {keep_state, State, [{reply, From, {error, Reason}}]}            
    end;
    
%%-----------------------------------------------------------------------------
%% @doc
%% Return subscribed topics for this connection
%% @end
%%-----------------------------------------------------------------------------
connected({call, From}, get_susbscriptions, State) ->
    Result = emqtt:subscriptions(State#state.connection),
    {reply, From, {ok, Result}, State};


%%-----------------------------------------------------------------------------
%% @doc
%% Handle incoming mqtt messages
%% @end
connected(cast, {incoming_mqtt_message, _, _, _, _, Topic, Payload}, State) ->
    logger:info("BBSVX mqtt connection : Incoming mqtt message ~p ~p ~p", [State#state.my_id, Topic, Payload]),
    process_incoming_message(binary:split(Topic, <<"/">>, [global]), Payload, State),
    {keep_state, State};
%%-----------------------------------------------------------------------------
%% @doc
%% Catch all
%% @end
connected(Type, Message, State) ->
    logger:info("BBSVX mqtt connection : Unmanaged message in connected state  ~p ~p ~p", [Type, Message, State]),
    {keep_state, State}.

%%-----------------------------------------------------------------------------
%% @doc
%% Handle events common to all states.
%% @end
%%-----------------------------------------------------------------------------

handle_event(Type, Event, State, Data) ->
    %% Ignore all other events
    logger:warning("bbsvx_mqtt_connection ignoring event ~p", [{Type, Event, State, Data}]),
    {keep_state, Data}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================


%%----------------------------------------------------------------------------- 
%% @doc
%% Process incoming messages
%% @end
%% -----------------------------------------------------------------------------

-spec process_incoming_message([binary()], binary(), #state{}) -> #state{}.
process_incoming_message([<<"ontologies">>, <<"contact">>, Namespace, NodeId], {connection_accepted, Namespace, TargetNodeId, {TargetHost, TargetPort}}, #state{my_id = TargetNodeId} = State) ->
    logger:info("bbsvx mqtt connection : Contact request accepted from : ~p ~p ~p", [Namespace, TargetNodeId, {TargetHost, TargetPort}]),
    gproc:send({p, l, NodeId}, {connection_accepted, Namespace, TargetNodeId, {TargetHost, TargetPort}}),
    State;
%% Process forwarded subscription requests
process_incoming_message([<<"ontologies">>, <<"contact">>, Namespace, NodeId], {forwarded_subscription, NodeId, {Host, Port}}, #state{my_id = MyId} = State) ->
    logger:info("bbsvx mqtt connection : Got contact request : ~p ~p ~p", [Namespace, NodeId, {Host, Port}]),
    gproc:send({p, l, MyId}, {forwarded_subscription, NodeId, {Host, Port}}),
    State;
process_incoming_message(Onto, Payload, State) ->
    logger:warning("bbsvx mqtt connection : Got unmanaged message : ~p ~p", [Onto, Payload]),
    State.


%%%-----------------------------------------------------------------------------
%%% @doc
%%% msg_handler/2
%%% Function called by emqtt when a message is received.
%%% It forwards the message to the process that registered the handler.
%%% @end

-spec msg_handler(mqtt:msg(), pid()) -> pid().
msg_handler(Msg, Pid) ->
    logger:info("MQTT Msg Handler ~p to ~p", [Msg, Pid]),
    gen_statem:cast(Pid,
                    {incoming_mqtt_message,
                     maps:get(qos, Msg),
                     maps:get(dup, Msg),
                     maps:get(retain, Msg),
                     maps:get(packet_id, Msg),
                     maps:get(topic, Msg),
                     binary_to_term(maps:get(payload, Msg))}).

disconnected(Data) ->
    logger:info("DISCONNECTED ~p", [Data]).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

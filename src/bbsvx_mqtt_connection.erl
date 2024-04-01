%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_mqtt_connection).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_common_types.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/2, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3, handle_event/4]).
%% State transitions
-export([waiting_for_id/3, connected/3]).
%% Hooks
-export([msg_handler/2, disconnected/2]).

-export([get_subscriptions/1, get_target_node/1, subscribe/2, unsubscribe/2, get_mqtt_subscriptions/1]).

-record(state,
        {connection :: pid(),
         subscriptions = [] :: [binary()],
         my_id :: binary(),
         target_node :: node_entry()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(MyNode :: node_entry(), TargetNode :: node_entry()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(#node_entry{} = MyNode,
           #node_entry{host = TargetHost, port = TargetPort} = TargetNode) ->
    logger:info("BBSVX mqtt connection : Starting"),
    gen_statem:start({via, gproc, {n, l, {?MODULE, TargetHost, TargetPort}}},
                     ?MODULE,
                     [MyNode, TargetNode],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%% ----------------------------------------------------------------------------
%% @doc
%% Subscribe to a topic
%% @end
-spec subscribe(NodeId :: binary(), Topic :: binary()) -> ok | {error, any()}.
subscribe(NodeId, Topic) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, NodeId}}}, {subscribe, Topic, []}).


%% ----------------------------------------------------------------------------
%% @doc
%% Unsubscribe from a topic
%% @end
%% ----------------------------------------------------------------------------
-spec unsubscribe(NodeId :: binary(), Topic :: binary()) -> ok | {error, any()}.
unsubscribe(NodeId, Topic) ->
    gproc:send({n, l, {?MODULE, NodeId}}, {unsubscribe, Topic}).


%% ----------------------------------------------------------------------------
%% @doc
%% Get the subscriptions of the connection
%% @end
%% ----------------------------------------------------------------------------
-spec get_subscriptions(node_entry() | binary()) -> [binary()].
get_subscriptions(#node_entry{host = Host, port = Port}) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Host, Port}}}, get_susbscriptions);
get_subscriptions(#node_entry{node_id = NodeId}) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, NodeId}}}, get_susbscriptions);
get_subscriptions(NodeId) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, NodeId}}}, get_susbscriptions).

    
%% ----------------------------------------------------------------------------
%% @doc
%% get mqtt subscriptions
%% @end
%% ----------------------------------------------------------------------------
-spec get_mqtt_subscriptions(node_entry() | binary()) -> [binary()].
get_mqtt_subscriptions(#node_entry{host = Host, port = Port}) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Host, Port}}}, get_mqtt_susbscriptions);
get_mqtt_subscriptions(#node_entry{node_id = NodeId}) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, NodeId}}}, get_mqtt_susbscriptions);
get_mqtt_subscriptions(NodeId) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, NodeId}}}, get_mqtt_susbscriptions).

%% ----------------------------------------------------------------------------
%% @doc
%% Get the target node of the connection
%% @end
%% ----------------------------------------------------------------------------
-spec get_target_node(NodeId :: binary()) -> node_entry().

get_target_node(#node_entry{host = Host, port = Port}) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, Host, Port}}}, get_target_node);
get_target_node(NodeId) ->
    gen_statem:call({via, gproc, {n, l, {?MODULE, NodeId}}}, get_target_node).


%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([#node_entry{node_id = MyId} = MyNode,
      #node_entry{host = TargetHost, port = TargetPort} = TargetNode]) ->
    logger:info("BBSVX mqtt connection at ~p: openning mqtt connection to ~p",
                [MyNode, TargetNode]),

    Me = self(),
    case emqtt:start_link([{host, TargetHost},
                           {port, TargetPort},
                           {clientid, MyId},
                           {proto_ver, v5},
                           {keepalive, 0},
                           {owner, Me},
                           {msg_handler,
                            #{disconnected => {?MODULE, disconnected, [{TargetHost, TargetPort}]},
                              publish => {?MODULE, msg_handler, [Me]}}}])
    of
        {ok, Pid} ->
            case emqtt:connect(Pid) of
                {ok, _Props} ->
                    logger:info("MQTT connection : Connected to ~p:~p", [TargetHost, TargetPort]),
                    %%gproc:send({p, l, {?MODULE, TargetHost, TargetPort}},
                    %%           {connected, {TargetHost, TargetPort}}),
                    emqtt:subscribe(Pid, #{}, [{<<"welcome">>, [{nl, true}]}]),
                    {ok,
                     waiting_for_id,
                     #state{connection = Pid,
                            my_id = MyId,
                            target_node = TargetNode},
                     3000};
                {error, Reason} ->
                    logger:error("MQTT connection : Failed to connect to ~p:~p: ~p",
                                 [TargetHost, TargetPort, Reason]),
                    gproc:send({p, l, {mqtt_connection, TargetHost, TargetPort}},
                               {connection_failed, Reason, {TargetHost, TargetPort}}),
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

waiting_for_id(cast,
               {incoming_mqtt_message, _, _, _, _, <<"welcome">>, NodeId},
               #state{target_node = #node_entry{host = TargetHost, port = TargetPort}, my_id = NodeId} = State) ->
    logger:warning("BBSVX mqtt connection : Connecting to self ~p   ~p",
                   [{TargetHost, TargetPort}, NodeId]),
    gproc:send({p, l, {?MODULE, TargetHost, TargetPort}},
               {connection_to_self,
                #node_entry{host = TargetHost,
                            port = TargetPort,
                            node_id = NodeId}}),
    {stop, normal, State};
waiting_for_id(cast,
               {incoming_mqtt_message, _, _, _, _, <<"welcome">>, TargetNodeId},
               #state{target_node = #node_entry{host = TargetHost, port = TargetPort} = TargetNode } = State) ->
    logger:info("BBSVX mqtt connection : Connection to node  ~p accepted",
                [{TargetNode, TargetNodeId}]),
    %% Unsubscribe from welcome topic
    emqtt:unsubscribe(State#state.connection, #{}, <<"welcome">>),
    gproc:reg({n, l, {?MODULE, TargetNodeId}}, {TargetHost, TargetPort}),
    gproc:send({p, l, {?MODULE, TargetHost, TargetPort}},
               {connection_ready,
                #node_entry{host = TargetHost,
                            port = TargetPort,
                            node_id = TargetNodeId}}),
    {next_state, connected, State#state{target_node = TargetNode#node_entry{node_id = TargetNodeId}}};
waiting_for_id({call, From}, get_target_id, State) ->
    {keep_state, State, [{reply, From, undefined}]};
waiting_for_id(timeout,
               _,
               #state{target_node = #node_entry{host = TargetHost, port = TargetPort} = TargetNode} = State) ->
    gproc:send({p, l, {?MODULE, TargetHost, TargetPort}},
               {node_subscription_timeout, TargetNode}),
    {stop, normal, State}.

%%-----------------------------------------------------------------------------
%% @doc
%% Connected state enter
%% @end
%%-----------------------------------------------------------------------------
connected(enter, _From, State) ->
    logger:info("BBSVX mqtt connection : Connected to ~p",
                [{State#state.target_node}]),
    {next_state, connected, State};
%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to subscribe to a topic.
%% @end
%%-----------------------------------------------------------------------------
connected({call, From},
          {subscribe, Topic, _Options},
          #state{subscriptions = Subscriptions} = State) ->
    logger:info("BBSVX mqtt connection : Subscribing to topic ~p   subscriptions ~p",
                [Topic, Subscriptions]),
    
    case lists:member(Topic, Subscriptions) of
        true ->
            logger:info("BBSVX mqtt connection : Already subscribed to ~p, not subscribing again. Subscriptions :~p",
                        [Topic, Subscriptions]),
            {keep_state, State#state{subscriptions = [Topic | Subscriptions]}, [{reply, From, ok}]};
        false ->
            
            case emqtt:subscribe(State#state.connection, #{}, [{Topic, [{nl, true}]}]) of
                {ok, Props, _} ->
                    logger:info("BBSVX mqtt connection : Not already subsribed to ~p, subscribing",
                                [Topic]),
                    {keep_state,
                     State#state{subscriptions = [Topic | Subscriptions]},
                     [{reply, From, {ok, Props}}]};
                {error, Reason} ->
                    logger:error("Failed to subscribe to ~p: ~p", [Topic, Reason]),
                    {keep_state, State, [{reply, From, {error, Reason}}]}
            end
    end;
%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to unsubscribe from a topic.
%% @end
%%-----------------------------------------------------------------------------
connected(info, {unsubscribe, Topic}, #state{} = State) ->
    logger:info("BBSVX mqtt connection : Unsubscribing from topic ~p  Subscriptions :~p",
                [Topic, State#state.subscriptions]),
    NewSubscriptions = lists:delete(Topic, State#state.subscriptions),
    %% Check if we still have a subscription to this topic
    case lists:member(Topic, NewSubscriptions) of
        true ->
            {keep_state, State#state{subscriptions = NewSubscriptions}};
        false ->
            case emqtt:unsubscribe(State#state.connection, #{}, Topic) of
                {ok, _Props, _} ->
                    {keep_state, State#state{subscriptions = NewSubscriptions}, []};
                {error, Reason} ->
                    logger:error("BBSVX mqtt connection : Failed to unsubscribe from ~p: ~p",
                                 [Topic, Reason]),
                    %% TODO: Check logic here. Should we keep the subscription in the state?
                    {keep_state, State, []}
            end
    end;
%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to get subscribed topics
%% @end
%%-----------------------------------------------------------------------------
connected({call, From}, get_susbscriptions, State) ->
    Result = State#state.subscriptions,
    {keep_state, State, [{reply, From, {ok, Result}}]};
%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to get subscribed topics from MQTT connection process
%% @end
%%-----------------------------------------------------------------------------
connected({call, From}, get_mqtt_susbscriptions, State) ->
    Result = emqtt:subscriptions(State#state.connection),
    {keep_state, State, [{reply, From, {ok, Result}}]};
%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to get target node
%% @end
%% -----------------------------------------------------------------------------
connected({call, From}, get_target_node, State) ->
    {keep_state, State, [{reply, From, {ok, State#state.target_node}}]};
%% @doc
%% Manage requests to get target node id
%% @end
%%-----------------------------------------------------------------------------
connected({call, From}, get_target_id, State) ->
    {keep_state, State, [{reply, From, State#state.target_node#node_entry.node_id}]};
%%-----------------------------------------------------------------------------
%% @doc
%% Manage requests to publish a message to a topic.
%% @end
connected({call, From}, {publish, Namespace, Payload}, State) ->
    case emqtt:publish(State#state.connection, Namespace, #{}, term_to_binary(Payload), []) of
        ok ->
            {keep_state, State, [{reply, From, ok}]};
        {error, Reason} ->
            logger:error("BBSVX mqtt connection : Failed to publish to ~p: ~p",
                         [Namespace, Reason]),
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%%-----------------------------------------------------------------------------
%% @doc
%% Handle incoming mqtt messages
%% @end
connected(cast, {incoming_mqtt_message, _, _, _, _, Topic, Payload}, State) ->
    logger:info("BBSVX mqtt connection : Incoming mqtt message ~p ~p ~p",
                [State#state.my_id, Topic, Payload]),
    process_incoming_message(binary:split(Topic, <<"/">>, [global]), Payload, State),
    {keep_state, State};
%%-----------------------------------------------------------------------------
%% @doc
%% Catch all
%% @end
connected(Type, Message, State) ->
    logger:info("BBSVX mqtt connection : Unmanaged message in connected state  ~p ~p ~p",
                [Type, Message, State]),
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
process_incoming_message([<<"ontologies">>, <<"in">>, Namespace, MyNodeId],
                         {connection_accepted,
                          Namespace,
                          #node_entry{host = TargetHost,
                                      port = TargetPort,
                                      node_id = TargetNodeId} =
                              TargetNode,
                          NetworkSize, Leader},
                         #state{my_id = MyNodeId} = State) ->
    logger:info("bbsvx mqtt connection : Contact request accepted from : ~p ~p ~p",
                [Namespace, TargetNodeId, {TargetHost, TargetPort}]),
    gproc:send({p, l, {?MODULE, TargetNodeId, Namespace}},
               {connection_accepted, Namespace, TargetNode, NetworkSize, Leader}),
    State;
%% Process forwarded subscription requests
% process_incoming_message([<<"ontologies">>, <<"in">>, Namespace, SenderNodeId], {forwarded_subscription, SubscriberNodeId, {Host, Port}}, #state{my_id = MyId} = State) ->
%     logger:info("bbsvx mqtt connection ~p : Got forwarded subscription request from : ~p    for  ~p", [MyId, SenderNodeId, {Namespace, SubscriberNodeId, {Host, Port}}]),
%     gproc:send({p, l, {ontology, Namespace}}, {forwarded_subscription, SubscriberNodeId, {Host, Port}}),
%     State;
%% Process inview_join_accepted acknoledgements
process_incoming_message([<<"ontologies">>, <<"in">>, Namespace, MyNodeId],
                         {inview_join_accepted,
                          Namespace,
                          #node_entry{node_id = TargetNodeId} =
                              TargetNode},
                         #state{my_id = MyNodeId, target_node = #node_entry{node_id = TargetNodeId}} = State) ->
    gproc:send({p, l, {?MODULE, TargetNodeId, Namespace}},
               {inview_join_accepted, Namespace, TargetNode}),
    State;
%% manage exchange out reception of messages
process_incoming_message([<<"ontologies">>, <<"in">>, Namespace, _MyId],
                         {partial_view_exchange_out, Namespace, SenderNode, SamplePartial},
                         #state{} = State) ->
    gproc:send({p, l, {?MODULE, State#state.target_node#node_entry.node_id, Namespace}},
               {partial_view_exchange_out, Namespace, SenderNode, SamplePartial}),
    State;
%% manage exchange out reception of messages
process_incoming_message([<<"ontologies">>, <<"in">>, Namespace, _MyNodeId],
                         {empty_inview, Node},
                         #state{} = State) ->
    gproc:send({p, l, {ontology, Namespace}}, {empty_inview, Node}),
    State;
process_incoming_message(Onto, Payload, State) ->
    logger:warning("bbsvx mqtt connection : Got unmanaged message : ~p ~p   myID : ~p",
                   [Onto, Payload, State#state.my_id]),
    State.

%%%-----------------------------------------------------------------------------
%%% @doc
%%% msg_handler/2
%%% Function called by emqtt when a message is received.
%%% It forwards the message to the process that registered the handler.
%%% @end

-spec msg_handler(mqtt:msg(), pid()) -> ok.
msg_handler(Msg, Pid) ->
    gen_statem:cast(Pid,
                    {incoming_mqtt_message,
                     maps:get(qos, Msg),
                     maps:get(dup, Msg),
                     maps:get(retain, Msg),
                     maps:get(packet_id, Msg),
                     maps:get(topic, Msg),
                     binary_to_term(maps:get(payload, Msg))}).

disconnected(Reason, {TargetHost, TargetPort}) ->
    logger:warning("DISCONNECTED ~p", [{Reason, {TargetHost, TargetPort}}]),
    gproc:send({p, l, {mqtt_connection, TargetHost, TargetPort}},
               {connection_failed, Reason, {TargetHost, TargetPort}}).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

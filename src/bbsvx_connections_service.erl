%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_connections_service).

-author("yan").

-behaviour(gen_server).

-include_lib("ejabberd/include/mqtt.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/1, start_link/2, connect_node/2, publish/2, join/2, leave/2,
            my_host_port/0,
         incoming_contact_request/3]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([handle_sm_register_connection_hook/3, handle_mqtt_publish_hook/2,
         handle_mqtt_subscribe_hook/4, handle_mqtt_unsubscribe_hook/2]).

-define(SERVER, ?MODULE).
-define(MAX_UINT32, 4294967295).

%% This record holds a connection to a mqtt broker
-record(connection,
        {id :: integer(),
         pid :: pid(),
         ip :: inet:ip_address(),
         port :: inet:port_number(),
         props :: term(),
         last_seen :: integer()}).
%% This record describe a message as it is published to a mqtt broker
-record(message, {nameSpace :: binary(), payload :: binary(), qos :: integer()}).
%% Loop state
-record(state, {connection_table :: reference(), node_id = undefined, host, port}).

%%%=============================================================================
%%% API
%%%=============================================================================

start_link([Host, Port]) ->
    start_link(Host, Port).

-spec start_link(Host :: nonempty_list() | [nonempty_list()], Port :: integer()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Host, Port) ->
    gen_server:start_link({via, gproc, {n, l, ?SERVER}}, ?MODULE, [Host, Port], []).



%%-----------------------------------------------------------------------------
%% @doc
%% Return the host/port of this node
%% @end
%% -----------------------------------------------------------------------------
-spec my_host_port() -> {Host :: binary(), Port :: integer()}.
my_host_port() ->
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {error, not_started};
        Pid ->
            gen_server:call(Pid, my_host_port)
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% connect_node(Host, Port) -> {ok, NewId} | {error, Reason}.
%% Check if we already have an mqtt connection for this node.
%% If yes returns its id, otherwise creates a new connection  via emqtt
%% and return Id.
%% @end
%%-----------------------------------------------------------------------------

connect_node(Host, Port) ->
    logger:info("bbsvx_connections_service:connect_node/2 called with Host: "
                "~p, Port: ~p",
                [Host, Port]),
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {reply, {error, not_started}};
        Pid ->
            gen_server:call(Pid, {connect, Host, Port})
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% join(NodeId, NameSpace) -> ok | {error, Reason}.
%% Join a mqtt broker on the topic taken from the message nameSpace
%% @end
%%-----------------------------------------------------------------------------
-spec join(binary(), binary()) -> ok | {error, Reason :: any()}.
join(NodeId, NameSpace) ->
    logger:info("bbsvx_connections_service:join/2 called with target NodeId: ~p, "
                "NameSpace: ~p",
                [NodeId, NameSpace]),
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {reply, {error, not_started}};
        Pid ->
            gen_server:call(Pid, {join, NodeId, NameSpace})
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% leave(NodeId, NameSpace) -> ok | {error, Reason}.
%% Leave a mqtt broker on the topic taken from the message nameSpace
%% @end
%% -----------------------------------------------------------------------------

-spec leave(binary(), binary()) -> ok | {error, Reason :: any()}.
leave(NodeId, NameSpace) ->
    logger:info("bbsvx_connections_service:leave/2 called with NodeId: "
                "~p, NameSpace: ~p",
                [NodeId, NameSpace]),
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {reply, {error, not_started}};
        Pid ->
            gen_server:call(Pid, {leave, NodeId, NameSpace})
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% send(NodeId, Message) -> ok | {error, Reason}.
%% Send a message to a mqtt broker on the topic taken from the message nameSpace
%% @end
%%-----------------------------------------------------------------------------
-spec publish(term(), #message{}) -> ok | {error, Reason :: any()}.
publish(NodeId, #message{} = Message) ->
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {reply, {error, not_started}};
        Pid ->
            gen_server:call(Pid, {publish, NodeId, Message})
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% incoming_contact_request(NodeId, {Host, Port}, Namespace) -> ok | {error, Reason}.
%% A node request to join an ontology namespace
%% @end

-spec incoming_contact_request(binary(),
                               {inet:ip_address(), inet:port_number()},
                               binary()) ->
                                  ok | {error, Reason :: any()}.
incoming_contact_request(NodeId, {Host, Port}, Namespace) ->
    logger:info("bbsvx_connections_service:incoming_contact_request/3 called "
                "with NodeId: ~p, {Host, Port}: ~p, Namespace: ~p",
                [NodeId, {Host, Port}, Namespace]),
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {reply, {error, not_started}};
        Pid ->
            gen_server:call(Pid, {incoming_contact_request, NodeId, {Host, Port}, Namespace})
    end.

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Host, Port]) ->
    %% Publish my id to the welcome topic
    MyId = bbsvx_crypto_service:my_id(),
    mod_mqtt:publish({MyId, <<"localhost">>, <<"bob3>>">>},
                     #publish{topic = <<"welcome">>,
                              payload = term_to_binary(MyId),
                              retain = true},
                     ?MAX_UINT32),
    ejabberd_hooks:add(sm_register_connection_hook,
                       ?MODULE,
                       handle_sm_register_connection_hook,
                       50),
    ejabberd_hooks:add(mqtt_publish, ?MODULE, handle_mqtt_publish_hook, 50),
    ejabberd_hooks:add(mqtt_subscribe, ?MODULE, handle_mqtt_subscribe_hook, 50),
    ejabberd_hooks:add(mqtt_unsubscribe, ?MODULE, handle_mqtt_subscribe_hook, 50),

    ConnTable = ets:new(connection_table, [set, private, {keypos, 2}]),
    
    {ok,
     #state{connection_table = ConnTable,
            node_id = MyId,
            host = Host,
            port = Port}}.


%% Handle request to get host port
handle_call(my_host_port, _From, #state{host = Host, port = Port} = State) ->
    {reply, {ok, {Host, Port}}, State};

%% Manage connections to new nodes
%% Local connections are prevented
handle_call({connect, Host, Port}, _From, #state{host = Host, port = Port} = State) ->
    logger:info("bbsvx_connections_service: Preventing connection to self :"
                "~p, From: ~p, State: ~p",
                [{connect, Host, Port}, _From, State]),
    {reply, {error, connection_to_self}, State};
handle_call({connect, Host, Port}, From, State) ->
    logger:info("bbsvx_connections_service connecting with request: ~p, From: "
                "~p, State: ~p",
                [{connect, Host, Port}, From, State]),
    MyId = bbsvx_crypto_service:my_id(),
    case gproc:where({n, l, {Host, Port}}) of
        undefined ->
            bbsvx_mqtt_connection:start_link(MyId, Host, Port),
            {reply, {ok, connecting}, State};
        Pid ->
            NodeId = gen_statem:call(Pid, get_id),
            logger:info("bbsvx_connections_service: Got nde Id NodeId: ~p",
                        [NodeId]),
            {reply, {ok, NodeId}, State}
    end;
%% Manage request to join ontology namespace/topic
handle_call({join, NodeId, Namespace}, _From, State) ->
    logger:info("bbsvx_connections_service handle call join called with Request: ~p, From: ~p, State: ~p",
                [{join, NodeId, Namespace}, _From, State]),
    case gproc:where({n, l, NodeId}) of
        undefined ->
            {reply, {error, not_connected}, State};
        Pid ->
            logger:info("calling connection"),
            {reply, gen_statem:call(Pid, {subscribe, Namespace, 0}), State}
    end;
%% Manage request to leave ontology namespace/topic
handle_call({leave, NodeId, Namespace}, _From, State) ->
    gen_statem:call({n, l, NodeId}, {leave, Namespace}),
    logger:info("bbsvx_connections_service : Leave called with Request: ~p, From: "
                "~p, State: ~p",
                [{leave, Namespace}, _From, State]),
    Reply = ok,
    {reply, Reply, State};
%% Manage request to send a message to a node
handle_call({publish, NodeId, #message{} = Message}, _From, State) ->
    logger:info("bbsvx_connections_service : Send called with Request: ~p, From: "
                "~p, State: ~p",
                [{send, NodeId, Message}, _From, State]),
    case gproc:where({n, l, NodeId}) of
        undefined ->
            logger:warning("bbsvx_connections_service : Publishing to not connected Node ~p",
                           [NodeId]),
            {reply, {error, not_connected}, State};
        Pid ->
            {reply, gen_statem:call(Pid, {publish, NodeId, Message}), State}
    end;
%% Manage incoming contact request
%% TODO: check if the user is already in the contact list
%% ignore connections to self
handle_call({incoming_contact_request, NodeId, {Host, Port}, Namespace}, _From, State)
    when NodeId == State#state.node_id ->
    logger:info("bbsvx_connections_service : Ignoring connection request from self "
                "Incoming: ~p, Me : ~p, State: ~p",
                [NodeId, State#state.node_id, State]),

    mod_mqtt:publish({State#state.node_id, <<"localhost">>, <<"bob3>>">>},
                     #publish{topic =
                                  iolist_to_binary([<<"ontologies/contact/">>,
                                                    Namespace,
                                                    "/",
                                                    NodeId]),
                              payload =
                                  term_to_binary({connection_to_self,
                                                  Namespace,
                                                  NodeId,
                                                  {Host, Port}}),
                              retain = false},
                     ?MAX_UINT32),
    {reply, ok, State};
handle_call({incoming_contact_request, NodeId, {Host, Port}, Namespace}, _From, #state{node_id = MyNodeId, host = MyHost, port = MyPort} = State) ->
    logger:info("bbsvx_connections_service incoming_contact_request called with "
                "Request: ~p, From: ~p, State: ~p",
                [{incoming_contact_request, NodeId, {Host, Port}, Namespace}, _From, State]),
    R = mod_mqtt:publish({State#state.node_id, <<"localhost">>, <<"bob3>>">>},
                         #publish{topic =
                                      iolist_to_binary([<<"ontologies/contact/">>,
                                                        Namespace,
                                                        "/",
                                                        NodeId]),
                                  payload =
                                      term_to_binary({connection_accepted,
                                                      Namespace,
                                                      MyNodeId,
                                                      {MyHost, MyPort}}),
                                  retain = false},
                         ?MAX_UINT32),
    gproc:send({n, l, {scamp_agent, Namespace}}, {contact_request, NodeId, {Host, Port}}),
    logger:info("Publish result: ~p", [R]),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    logger:info("bbsvx_connections_service:handle_call/3 called with Request: "
                "~p, From: ~p, State: ~p",
                [_Request, _From, State]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% Ejabberd Hooks
handle_sm_register_connection_hook(Sid, Jid, Info) ->
    logger:info("---->_mqtt_ejd_mod:handle_sm_register_connection_hook/3 called "
                "with Sid: ~p, Jid: ~p, Info: ~p",
                [Sid, Jid, Info]),
    ok.

handle_mqtt_publish_hook(Usr, Pkt) ->
    logger:info("-----> _mod:handle_mqtt_publish_hook/2 called with Usr: "
                "~p, Pkt: ~p",
                [Usr, Pkt]),
    ok.

%% Manage contact requests
handle_mqtt_subscribe_hook(Usr, <<"welcome">>, _SubOpts, _Id) ->
    logger:info("-------> Contact request from ~p", [Usr]),
    ok;
handle_mqtt_subscribe_hook(Usr, TopicFilter, SubOpts, Id) ->
    logger:info("----->_mod:handle_mqtt_subscribe_hook/4 called with "
                "Usr: ~p, TopicFilter: ~p, SubOpts: ~p, Id: ~p",
                [Usr, TopicFilter, SubOpts, Id]),
    ok.

handle_mqtt_unsubscribe_hook(Usr, Topic) ->
    logger:info("---->_mod:handle_mqtt_unsubscribe_hook/2 called with "
                "Usr: ~p, Topic: ~p",
                [Usr, Topic]),
    ok.

normalize_topic_list([], Acc) ->
    logger:info("normalize_topic_list : ~p", [Acc]),
    Acc;
normalize_topic_list([El | Others], <<"">>) ->
    normalize_topic_list(Others, El);
normalize_topic_list([El | Others], Acc) ->
    normalize_topic_list(Others, <<Acc/binary, "/", El/binary>>).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

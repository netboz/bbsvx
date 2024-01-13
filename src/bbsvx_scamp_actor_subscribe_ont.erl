%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_scamp_actor_subscribe_ont).

-author("yan").

-behaviour(gen_statem).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/5]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([connecting/3, subscribing/3, handle_event/3]).

-record(state,
        {namespace :: binary(),
        my_host :: binary(),
        my_port :: integer(),
         host :: binary(),
         port :: integer(),
         target_node_id :: binary(),
         my_node_id :: binary(),
         parent :: pid()}).
-record(message, {nameSpace :: binary(), payload :: binary(), qos :: integer()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(),
                 Host :: binary(),
                 Port :: integer(),
                 Parent :: pid(),
                 MyNodeId :: binary()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, Host, Port, Parent, MyNodeId) ->
    gen_statem:start(?MODULE, [Namespace, Host, Port, Parent, MyNodeId], []).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, Host, Port, Parent, MyNodeId]) ->
    logger:info("Actor ~p initialising connection to contact node : ~p", [self(), {Host, Port, Namespace}]),
    {ok, {MyHost, MyPort}} = bbsvx_connections_service:my_host_port(),
    {ok,
     connecting,
     #state{host = Host,
            namespace = Namespace,
            port = Port,
            my_node_id = MyNodeId,
            my_host = MyHost,
            my_port = MyPort,
            parent = Parent}}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

connecting(enter,
           _From,
           #state{host = Host,
                  port = Port,
                  parent = Parent,
                  namespace = Namespace} =
               State) ->
    logger:info("Actor ~p connecting to ~p", [self(), {Host, Port, Namespace}]),
    case bbsvx_connections_service:connect_node(Host, Port) of
        {ok, connecting} ->
            gproc:reg({p, l, {Host, Port}}, self()),
            {keep_state, State, 3000};
        {ok, NodeId} ->
            gproc:reg({p, l, {Host, Port}}, self()),
            %% We are connected to the contact node
            %% we are now subscribing to the ontology namespace
            %% in a new state
            Me = self(),
            Me ! {connection_ready, {Host, Port}, NodeId},
            {keep_state, State#state{target_node_id = NodeId}, 3000};
        {error, Reason} ->
            logger:error("Actor ~p : Error connecting to contact node ~p:~p, Reason: ~p",
                         [self(), Host, Port, Reason]),
            gen_statem:cast(Parent, {error, {Reason, {Host, Port, Namespace}}}),
            {stop, normal, State}
    end;
connecting(info,
           {connection_to_self, {Host, Port}, _NodeId},
           #state{parent = Parent, namespace = Namespace} = State) ->
    logger:error("Actor ~p : Connectng to self ~p", [self(), {Host, Port}]),
    gen_statem:cast(Parent, {error, {connection_to_self, {Host, Port, Namespace}}}),
    {stop, normal, State};
connecting(info,
           {connection_ready, {Host, Port}, NodeId},
           #state{host = Host, port = Port} = State) ->
    logger:info("Actor ~p connected to ~p", [self(), {Host, Port, NodeId}]),
    gproc:unreg({p, l, {Host, Port}}),
    gproc:reg({p, l, NodeId}, self()),
    {next_state, subscribing, State#state{target_node_id = NodeId}, 3000};
connecting(info,
           {node_subscription_timeout, {Host, Port}},
           #state{parent = Parent} = State) ->
    logger:error("Actor ~p : Timeout subscribing to node welcome topic ~p",
                 [self(), {Host, Port}]),
    gen_statem:cast(Parent, {error, {subscription_timeout, {Host, Port}}}),
    {stop, normal, State};
connecting(timeout,
           _,
           #state{parent = Parent,
                  host = Host,
                  port = Port,
                  namespace = Namespace} =
               State) ->
    logger:error("Actor ~p : Timeout connecting to contact node ~p:~p, Reason: ~p",
                 [self(), Host, Port, timeout]),
    gen_statem:cast(Parent, {error, {connection_time_out, {Host, Port, Namespace}}}),
    {stop, normal, State}.

subscribing(enter,
            _From,
            #state{host = Host,
                   port = Port,
                   namespace = Namespace,
                   target_node_id = TargetNodeId,
                   my_node_id = MyNodeId,
                   parent = Parent} =
                State) ->
    logger:info("Actor ~p subscribing to ~p", [self(), {Host, Port, Namespace}]),
    SubscriptionPath =
        iolist_to_binary([<<"ontologies/contact/">>, Namespace, "/", MyNodeId]),
    logger:info("SubscriptionPath: ~p", [SubscriptionPath]),
    case bbsvx_connections_service:join(TargetNodeId, SubscriptionPath) of
        {ok, _} ->
            bbsvx_connections_service:publish(TargetNodeId,
                                              #message{payload =
                                                           {join,
                                                            MyNodeId,
                                                            {State#state.my_host, State#state.my_port}},
                                                       nameSpace = SubscriptionPath,
                                                       qos = 0}),
            {keep_state, State, 3000};
        {error, Reason} ->
            logger:error("Actor ~p : Error subscribing to ontology namespace ~p, Reason: ~p",
                         [self(), Namespace, Reason]),
            gen_statem:cast(Parent,
                            {error,
                             {namespace_subscription_failled,
                              {Host, Port, TargetNodeId, Namespace}}}),
            {stop, normal, State}
    end;
subscribing(timeout,
            _,
            #state{namespace = Namespace,
                   parent = Parent,
                   host = Host,
                   port = Port,
                   target_node_id = TargetNodeId} =
                State) ->
    logger:error("Actor ~p : Timeout subscribing to ontology namespace ~p",
                 [self(), Namespace]),
    gen_statem:cast(Parent,
                    {error,
                     {namespace_subscription_timeout, {Host, Port, TargetNodeId, Namespace}}}),
    {stop, normal, State};
subscribing(info, {connection_accepted, Namespace, NodeId, {Host, Port}}, State) ->
    logger:info("Actor ~p has been accepted to  ~p by ~p",
                [self(), Namespace, {Host, Port, NodeId}]),
    gen_statem:cast(State#state.parent, {subscribed, State#state.namespace, NodeId}),
    {stop, normal, State};
subscribing(Type, Event, State) ->
    logger:info("Actor ~p : subscribing called with Type: ~p, Event: ~p",
                [self(), Type, Event]),
    {keep_state, State}.

%%-----------------------------------------------------------------------------
%% @doc
%% Handle events common to all states.
%% @end
%%-----------------------------------------------------------------------------

handle_event(Type, Data, State) ->
    logger:info("Scamp connection actor handle_event called with Data: ~p", [{Type, Data}]),
    %% Ignore all other events
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

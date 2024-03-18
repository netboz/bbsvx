%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray_join).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_common_types.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/4, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([connecting/3, subscribing/3]).

-record(state,
        {namespace :: binary(),
         type :: contact | join_inview,
         my_node :: node_entry(),
         target_node :: node_entry(),
         connection_pid}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Type :: contact | join_inview,
                 Namespace :: binary(),
                 MyNode :: node_entry(),
                 TargetNode :: node_entry()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Type, Namespace, MyNode, TargetNode) ->
    gen_statem:start({via, gproc, {n, l, {?MODULE, TargetNode}}},
                     ?MODULE,
                     [Type, Namespace, MyNode, TargetNode],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Type,
      Namespace,
      MyNode,
      #node_entry{host = TargetHost, port = TargetPort, node_id = TargetNodeId} = TargetNode]) ->
    %% Look if there is already an openned connection to the target node
    case gproc:where({n, l, {bbsvx_mqtt_connection, TargetNodeId}}) of
        undefined ->
            logger:info("~p : No connection to ~p", [?MODULE, TargetNode]),
            %% No connection, subscribe to connection events and open it
            gproc:reg({p,
                       l,
                       {bbsvx_mqtt_connection,
                        TargetHost,
                        TargetPort}}),
            case supervisor:start_child(bbsvx_sup_mqtt_connections, [MyNode, TargetNode]) of
                {ok, ConnectionPid} ->
                    {ok,
                     connecting,
                     #state{connection_pid = ConnectionPid,
                            type = Type,
                            namespace = Namespace,
                            my_node = MyNode,
                            target_node = TargetNode}};
                {error, Reason} ->
                    logger:warning("~p : Could not start connection to ~p : ~p",
                                   [?MODULE, TargetNode, Reason]),
                    {stop, Reason}
            end;
        ConnectionPid ->
            logger:info("~p : Connection to ~p already openned", [?MODULE, TargetNode]),
            %% Connection already openned
            %%
            gproc:reg({p, l, {bbsvx_mqtt_connection, TargetNodeId, Namespace}}),
            {ok,
             subscribing,
             #state{type = Type,
                    namespace = Namespace,
                    my_node = MyNode,
                    target_node = TargetNode,
                    connection_pid = ConnectionPid}}
    end.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
connecting(enter, _, State) ->
    logger:info("~p : Connecting to ~p", [?MODULE, State#state.target_node]),
    keep_state_and_data;
%% Manage connection to self
connecting(info,
           {connection_to_self, TargetNode},
           #state{namespace = Namespace} = State) ->
    logger:warning("~p : Connection to self ~p", [?MODULE, TargetNode]),
    gproc:send({p, l, {ontology, Namespace}}, {connection_to_self, TargetNode}),

    {stop, normal, State};
connecting(info,
           {connection_ready,
            #node_entry{host = TargetHost,
                        port = TargetPort,
                        node_id = TargetNodeId} =
                TargetNode},
           #state{namespace = Namespace, target_node = #node_entry{host = TargetHost, port = TargetPort}} = State) ->
    logger:info("~p : Connection to ~p ready", [?MODULE, TargetNode]),

    gproc:reg({p, l, {bbsvx_mqtt_connection, TargetNodeId, Namespace}}),
    {next_state,
     subscribing,
     State#state{target_node =
                     #node_entry{host = TargetHost,
                                 port = TargetPort,
                                 node_id = TargetNodeId}}}.

subscribing(enter,
            _,
            #state{type = contact,
                   connection_pid = ConnectionPid,
                   namespace = Namespace,
                   my_node = #node_entry{node_id = MyNodeId}} =
                State) ->
    %% Compute the topic to connect to from Namespace
    InviewNamespace = <<"ontologies/in/", Namespace/binary, "/", MyNodeId/binary>>,
    %%% Ask the connection to subscribe to the topic natching ontology namespace
    %% We request to connection to subscribe to the inview namespace
    logger:info("~p : Conection pid ~p", [?MODULE, ConnectionPid]),
    gen_statem:call(ConnectionPid, {subscribe, InviewNamespace, []}),
    %% We send the contact request to the target node
    logger:info("~p : Sending contact request to ~p", [?MODULE, State#state.target_node]),
    gen_statem:call(State#state.connection_pid,
                    {publish, InviewNamespace, {subscribe, State#state.my_node}}),
    keep_state_and_data;
subscribing(enter,
            _,
            #state{type = join_inview,
                   connection_pid = ConnectionPid,
                   namespace = Namespace,
                   my_node = #node_entry{node_id = MyNodeId}} =
                State) ->
    %% Compute the topic to subscribe to from Namespace
    InviewNamespace = <<"ontologies/in/", Namespace/binary, "/", MyNodeId/binary>>,
    %%% Ask the connection to subscribe to the topic natching ontology namespace
    %% We request to connection to subscribe to the inview namespace
    gen_statem:call(ConnectionPid, {subscribe, InviewNamespace, []}),
    %% We send the inview join request to the target node
    logger:info("~p : Sending subscribe request to ~p", [?MODULE, State#state.target_node]),
    gen_statem:call(State#state.connection_pid,
                    {publish, InviewNamespace, {inview_join_request, State#state.my_node}}),
    keep_state_and_data;
%% Contact request accepted
subscribing(info, {connection_accepted, Namespace, TargetNode, _NetworkSize}, State) ->
    logger:info("~p : connected to ~p", [?MODULE, {State#state.target_node, Namespace}]),
    %% As contact node automatically adds us to its inview, we can now
    %% add it to our outview
    gproc:send({p, l, {ontology, Namespace}}, {add_to_view, outview, TargetNode}),
    {stop, normal, State};
%% Subscribe requuest accepted
subscribing(info, {inview_join_accepted, Namespace, TargetNode}, State) ->
    logger:info("~p : Subscribed to ~p", [?MODULE, {State#state.target_node, Namespace}]),
    %% As contact node automatically adds us to its inview, we can now
    %% add it to our outview
    gproc:send({p, l, {ontology, Namespace}}, {add_to_view, outview, TargetNode}),
    {stop, normal, State}.

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

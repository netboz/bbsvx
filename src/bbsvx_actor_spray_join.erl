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
-include("bbsvx_tcp_messages.hrl").
%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/4, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([connecting/3, subscribing/3, increase_inview/3]).

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

init([Type, Namespace, MyNode, TargetNode]) ->
    {ok,
     connecting,
     #state{type = Type,
            namespace = Namespace,
            my_node = MyNode,
            target_node = TargetNode,
            connection_pid = undefined}}.

terminate(_Reason, _State, _Data) ->
    logger:info("Terminating ~p", [?MODULE]),
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
connecting(enter,
           _,
           #state{type = Type,
                  namespace = Namespace,
                  my_node = MyNode,
                  target_node =
                      #node_entry{node_id = TargetNodeId,
                                  host = TargetHost,
                                  port = TargetPort} =
                          TargetNode} =
               State) ->
    case TargetNodeId of
        undefined ->
            logger:warning("~p : First connection to ~p", [?MODULE, TargetNode]),
            gproc:reg({p, l, {bbsvx_tcp_connection, Namespace, TargetHost, TargetPort}}),
            {ok, ConnectionPid} =
                supervisor:start_child(bbsvx_sup_tcp_connections,
                                       [Type, Namespace, MyNode, TargetNode]),
            {keep_state, State#state{connection_pid = ConnectionPid}};
        _ ->
            case gproc:where({n, l, {bbsvx_tcp_connection, Namespace, TargetNodeId}}) of
                undefined ->
                    logger:info("~p : Connecting to nodeId ~p but found no connection to it",
                                   [?MODULE, TargetNode]),
                    gproc:reg({p, l, {bbsvx_tcp_connection, Namespace, TargetHost, TargetPort}}),

                    {ok, ConnectionPid} =
                        supervisor:start_child(bbsvx_sup_tcp_connections,
                                               [Type, Namespace, MyNode, TargetNode]),
                    {keep_state, State#state{connection_pid = ConnectionPid}};
                ConnPid ->
                    logger:info("~p : Connection to ~p already openned",
                                [?MODULE, {TargetNode, Namespace}]),
                    %% Connection already openned
                    gen_statem:cast(self(), increase_inview),
                    {keep_state, State#state{connection_pid = ConnPid}}
            end
    end;
connecting(info, {connection_error, Namespace, Reason}, State) ->
    logger:warning("~p : Connection to ~p failed : ~p",
                   [?MODULE, {State#state.target_node, Namespace}, Reason]),
    {stop, normal, State};
connecting(info, {connection_refused, Namespace, Reason}, State) ->
    logger:warning("~p : Connection to ~p refused : ~p",
                   [?MODULE, {State#state.target_node, Namespace}, Reason]),
    {stop, normal, State};
connecting(info,
           {connected, Namespace, TargetNodeId},
           #state{namespace = Namespace, target_node = #node_entry{} = TargetNode} = State) ->
    logger:info("~p : Connected to ~p namespace ~p  TargetnodeID ~p",
                [?MODULE, Namespace, State#state.target_node, TargetNodeId]),
    gproc:reg({p, l, {bbsvx_tcp_connection, Namespace, TargetNodeId}}),
    {next_state,
     subscribing,
     State#state{target_node = TargetNode#node_entry{node_id = TargetNodeId}},
     1000};
connecting(timeout, _, State) ->
    logger:warning("~p : Connection to ~p timed out", [?MODULE, State#state.target_node]),
    {stop, normal, State}.

subscribing(enter, _, _) ->
    keep_state_and_data;
subscribing(info,
            {contacted, Namespace},
            #state{namespace = Namespace,
                   target_node = TargetNode,
                   type = contact} =
                State) ->
    logger:info("~p : Contacted ~p", [?MODULE, State#state.target_node]),
    gproc:send({p, l, {ontology, Namespace}}, {add_to_view, outview, TargetNode}),
    {stop, normal, State};
subscribing(info,
            {inview_joined, Namespace},
            #state{namespace = Namespace,
                   target_node = TargetNode,
                   type = join_inview} =
                State) ->
    logger:info("~p : Joined ~p", [?MODULE, State#state.target_node]),
    gproc:send({p, l, {ontology, Namespace}}, {add_to_view, outview, TargetNode}),
    {stop, normal, State};
subscribing(timeout, _, State) ->
    logger:warning("~p : Subscription to ~p timed out", [?MODULE, State#state.target_node]),
    {stop, normal, State}.

increase_inview(enter, _, _State) ->
    keep_state_and_data;
increase_inview(info, {incoming_event, Namespace, #increase_inview_ack{target_node = TargetNode}}, State) ->
    logger:info("~p : Increased view ~p   ~p", [?MODULE, TargetNode, Namespace]),
    gproc:send({p, l, {ontology, Namespace}}, {add_to_view, outview, TargetNode}),
    {stop, normal, State};
increase_inview(timeout, _, State) ->
    logger:warning("~p : Increase inview to ~p timed out", [?MODULE, State#state.target_node]),
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

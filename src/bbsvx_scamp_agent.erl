%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_scamp_agent).

-author("yan").

-behaviour(gen_statem).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/2, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3, handle_event/3]).

-record(state,
        {in_view :: [binary()],
         partial_view :: [{binary(), number()}],
         namespace :: binary(),
         estimated_size :: integer(),
         c :: integer(),
         my_id :: binary(),
         k :: integer(),
         ttl :: integer(),
         contact_nodes :: [term()],
         current_contact_node :: term()}).
-record(message, {nameSpace :: binary(), payload :: binary(), qos :: integer()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), ContactNodes :: list()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, ContactNodes) ->
    gen_statem:start({via, gproc, {n, l, {scamp_agent, Namespace}}},
                     ?MODULE,
                     [Namespace, ContactNodes],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, [ContactNode|ContactNodes]]) ->
    logger:info("Scamp Agent ~p :  Starting.", [Namespace]),
    MyId = bbsvx_crypto_service:my_id(),
    
    %% To catch exit signals from actors
    process_flag(trap_exit, true),

    #{ip := Host, port := Port} = ContactNode,
    
    spawn_actor(bbsvx_scamp_actor_subscribe_ont, start_link, [Namespace, Host, Port, self(), MyId]),

    State =
        #state{in_view = [],
               partial_view = [],
               namespace = Namespace,
               c = 1,
               my_id = MyId,
               k = 0,
               ttl = 0,
               estimated_size = 1,
               current_contact_node = {Host, Port},
               contact_nodes = ContactNodes ++ [ContactNode]},

    {ok, running, State}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================

running(enter, _From, _State) ->
    keep_state_and_data;
running(cast,
              {subscribed, Namespace, NodeId},
              #state{current_contact_node = {Host, Port}, namespace = Namespace} = State) ->
    %% The actor signals it sucessfully connected and subscribed to topic
    logger:info("Scamp Agent ~p : Contact node ~p accepted subscription",
                [Namespace, {Host, Port, NodeId, Namespace}]),
    {next_state,
     running,
     State#state{current_contact_node = undefined, partial_view = []}};
%% Manage case where we have no more contacts
running(cast, no_more_contact, #state{contact_nodes = []} = State) ->
    logger:info("Scamp Agent ~p : No more contact nodes", [State#state.namespace]),
    {next_state, running, State};

%% Manage connection to self
running(cast, {connection_to_self, {Host, Port, _Namespace}}, State) ->
    logger:error("Scamp Agent ~p: Connecting to self ~p",
                 [State#state.namespace, {Host, Port}]),
    {repeat_state,
     State#state{contact_nodes =
                     lists:delete(#{ip => Host, port => Port}, State#state.contact_nodes)}};
%% Manage general errors
running(cast, {error, Reason}, State) ->
    logger:error("Scamp Agent ~p: Error connecting to contact node ~p",
                 [State#state.namespace, Reason]),
    {repeat_state, State};
%% We receive contact request from a node and partial view is empty
%% we keep the contact request.
running(info,
        {contact_request, NodeId, {Host, Port}},
        #state{namespace = Namespace, partial_view = [], my_id = MyId} = State) ->
    logger:info("Scamp Agent ~p : Running state, Empty parttial view, initial contact_request from ~p",
                [Namespace, {Host, Port, NodeId}]),
    %% Spawn actor to connect to the inview of the node using actor add node partial view
    spawn_actor(bbsvx_scamp_actor_add_node_partial_view,
                start_link,
                [Namespace, Host, Port, NodeId, self(), MyId]),        
    {keep_state, State#state{}};
running(info,
        {contact_request, NodeId, {Host, Port}},
        #state{namespace = Namespace, partial_view = PartialView} = State) ->
    logger:info("Scamp Agent ~p : Running state, initial contact_request from ~p",
                [Namespace, {Host, Port, NodeId}]),
    %% Forward subscriptions to all nodes of the view
    lists:foreach(fun({NId, _}) ->
                     bbsvx_connections_service:publish(NId,
                                                       #message{payload =
                                                                    {forwarded_subscription,
                                                                     NodeId,
                                                                     {Host, Port}},
                                                                nameSpace = Namespace,
                                                                qos = 0})
                  end,
                  PartialView),
    %% Then C Additonnal copies of the subscription are sent
    %% to random nodes in the partial view
    FinalPartialView = lists:foldl(fun(_, Acc) ->
                   {TargetNodeId, NewPartialView} = get_weigthed_random_node(Acc),
                   bbsvx_connections_service:publish(TargetNodeId,
                                                     #message{payload =
                                                                  {forwarded_subscription,
                                                                  NodeId,
                                                                   {Host, Port}},
                                                              nameSpace = Namespace,
                                                              qos = 0}),
                   NewPartialView
                end,
                PartialView,
                lists:seq(1, State#state.c)),
    {keep_state, State#state{partial_view = FinalPartialView}};
%% Partial view is empty : we keep the subscription
running(info,
        {forwarded_subscription, NodeId, {Host, Port}},
        #state{namespace = Namespace, partial_view = []} = State) ->
    logger:info("Scamp Agent ~p : Running state, Received forwarded_subscription from ~p",
                [Namespace, {Host, Port, NodeId}]),

    {keep_state, State#state{partial_view = [{NodeId, 50}]}};
%% Counter is 0 and partial view is not empty : we keep the subscription and update the partial view
%% with the new node, initializing its weigth to mean of the weigth of the other nodes in partial view
running(info,
        {forwarded_subscription, NodeId, {Host, Port}},
        #state{namespace = Namespace, partial_view = PartialView} = State) ->
    logger:info("Scamp Agent ~p : Running state, Received forwarded_subscription from ~p",
                [Namespace, {Host, Port, NodeId}]),

    %% Keep node with probability proportional to partial view length
    %% and update weigths
    %% else forward subscription to random node in partial view
    %% and update weigths
    case math:floor(rand:uniform() * (length(PartialView) + 1)) of
        0 ->
            NewPartialView = insert_node_id(NodeId, PartialView),
            {keep_state, State#state{partial_view = NewPartialView}};
        _ ->
            {ForwardTarget, NewPartialView} = get_weigthed_random_node(PartialView),
            bbsvx_connections_service:publish(ForwardTarget,
                                              #message{payload =
                                                           {forwarded_subscription,
                                                            NodeId,
                                                            {Host, Port}},
                                                       nameSpace = Namespace,
                                                       qos = 0}),
            {keep_state, State#state{partial_view = NewPartialView}}
    end;
%% Manage this agent being accepted to inview from other node
%% i.e: target node is now part of our partial view
running(info, {add_partial_view, Namespace, NodeId}, #state{namespace = Namespace} =  State) ->
    logger:info("Scamp Agent ~p : Running state, add_partial_view from ~p",
                [State#state.namespace, NodeId]),
    {keep_state, State#state{partial_view = [{NodeId, 50}]}};
running(EventType, EventContent, Data) ->
    logger:info("Scamp Agent ~p : Unmanaged event in running state Event: ~p",
                [Data#state.namespace, {EventType, EventContent}]),
    {keep_state, Data}.

%%-----------------------------------------------------------------------------
%% @doc
%% Handle events common to all states.
%% @end
%%-----------------------------------------------------------------------------

handle_event(_, _, Data) ->
    logger:info("Scamp Agent ~p : handle_event called with Data: ~p",
                [Data#state.namespace, Data]),
    %% Ignore all other events
    {keep_state, Data}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%-----------------------------------------------------------------------------
%% @doc
%% spawn_actor/2
%% An Actor is a process working with the fsm to do some work and them trigger
%% FSM state change.
%% @end
%%-----------------------------------------------------------------------------

spawn_actor(Mod, Func, Params) ->
    spawn(Mod, Func, Params).

%%-----------------------------------------------------------------------------
%% @doc
%% get_weigthed_random_sample/1
%% Get a random node from list of nodes with probability proportional to their
%% weigth.
%% @end

get_weigthed_random_node(WeithedListOfNodes) ->
    WeigthSum = lists:foldl(fun({_, Weigth}, Acc) -> Acc + Weigth end, 0, WeithedListOfNodes),
    Index = rand:uniform(WeigthSum),
    get_weigthed_random_node(WeithedListOfNodes, {Index, []}, 0).

get_weigthed_random_node([{NodeId, Weigth} | OtherNodes], {Index, CheckedNodeList}, Acc)
    when Index < Acc + Weigth ->
    {NodeId, CheckedNodeList ++ [{NodeId, Weigth + 10}] ++ OtherNodes};
get_weigthed_random_node([{_, Weigth} = Node | Rest], {Index, CheckedNodeList}, Acc) ->
    get_weigthed_random_node(Rest, {Index, CheckedNodeList ++ [Node]}, Acc + Weigth).

%% Insert a new node id into a view, initializing its weigth to mean of the
%% weigth of the other nodes in view
insert_node_id(NodeId, View) ->
    MeanWeigth =
        round(lists:foldl(fun({_, Weigth}, Acc) -> Acc + Weigth end, 0, View) / length(View)),
    View ++ [{NodeId, MeanWeigth}].

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

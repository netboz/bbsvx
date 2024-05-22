%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% This state machine, willl be used to exchange views between nodes.
%%% It receives the sample of the view, and will try to connect to the
%%% contained nodes. If connection succeeds, it will deregister the node
%%% It will wait for the connection to be established, and then it will send the
%%% view to the spray agent.
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray_view_exchanger).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_tcp_messages.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/3, start_link/5, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([responding/3, wait_exchange_out/3, wait_for_exchange_end/3,
         wait_for_exchange_end_responding/3, responding_disconnect/3, initiator_disconnect/3]).
-export([get_random_sample/1, get_big_random_sample/1, get_oldest_node/1]).

-define(EXCHANGE_OUT_TIMEOUT, 3000).

-record(state,
        {namespace :: binary(),
         to_leave = [] :: [node_entry()],
         origin_node :: node_entry() | undefined, %% Used only in responder
         target_node :: node_entry() | undefined, %% Used only in initiator
         proposed_sample :: [node_entry()] | undefined,
         my_node :: node_entry() | undefined,
         partial_view = [] :: [node_entry()],
         kept_nodes = [] :: [node_entry()],
         outview_size = 0 :: non_neg_integer(),
         parent_pid :: pid() | undefined}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(ActorType :: initiator, NameSpace :: binary(), MyNode :: node_entry()) ->
                    {ok, pid()} | {error, Reason :: any()}.
start_link(initiator, Namespace, MyNode) ->
    gen_statem:start({via, gproc, {n, l, {?MODULE, Namespace}}},
                     ?MODULE,
                     [initiator, Namespace, MyNode],
                     []).

-spec start_link(ActorType :: responder,
                 NameSpace :: binary(),
                 MyNode :: node_entry(),
                 OriginNode :: node_entry(),
                 ProposedSample :: [node_entry()]) ->
                    {ok, pid()} | {error, Reason :: any()}.
start_link(responder, Namespace, MyNode, OriginNode, ProposedSample) ->
    gen_statem:start({via, gproc, {n, l, {?MODULE, Namespace}}},
                     ?MODULE,
                     [responder, Namespace, MyNode, OriginNode, ProposedSample],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([initiator, Namespace, MyNode]) ->
    State =
        #state{namespace = Namespace,
               my_node = MyNode,
               parent_pid = self()},
    logger:info("Starting view exchanger initiator for ~p", [MyNode]),
    %% Register to events from mqtt connection
    gproc:reg({p, l, {spray_exchange, Namespace}}),
    {ok, wait_exchange_out, State, ?EXCHANGE_OUT_TIMEOUT};
init([responder, Namespace, MyNode, OriginNode, ProposedSample]) ->
    logger:info("Starting view exchanger responder for ~p", [MyNode]),
    %% Register to events from mqtt connection
    gproc:reg({p, l, {spray_exchange, Namespace}}),
    {ok,
     responding,
     #state{namespace = Namespace,
            my_node = MyNode,
            origin_node = OriginNode,
            proposed_sample = ProposedSample,
            parent_pid = self()}}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
-spec wait_exchange_out(gen_statem:event_type(), term(), state()) ->
    gen_statem:state_return().
wait_exchange_out(enter, _, #state{namespace = Namespace} = State) ->
    {ok, PartialView} =
        gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, State#state.namespace}}},
                        get_outview),

    OutviewSize = length(PartialView),
    logger:info("Actor exchanger: Entering wait_exchange_out with partial view ~p",
                [PartialView]),

    %% Get Id of oldest node
    #node_entry{node_id = OldestNodeId, pid = OldestNodePid} =
        OldestNode = get_oldest_node(PartialView),
    %% Partialview without oldest node
    {_, _, PartialViewWithoutOldest} =
        lists:keytake(OldestNodePid, #node_entry.pid, PartialView),
    %% Get sample from partial view without oldest
    {Sample, KeptNodes} = get_random_sample(PartialViewWithoutOldest),

    %% Replace all other occurence of oldest node with our node
    ReplacedSample =
        lists:map(fun (#node_entry{node_id = Nid}) when Nid == OldestNodeId ->
                          State#state.my_node;
                      (Node) ->
                          Node
                  end,
                  Sample),

    %% Finally Add our node to the sample to get the final sample to be sent.
    %% As we removed one oldest node entry, adding ourselves keeps the sample size constant
    FinalSample = [State#state.my_node | ReplacedSample],
    logger:info("Actor exchanger : Final sample ~p", [FinalSample]),

    %% Send exchange proposition to oldest node
    bbsvx_client_connection:send(OldestNode#node_entry.pid,
                                 #exchange_in{namespace = Namespace,
                                              origin_node = State#state.my_node,
                                              proposed_sample = FinalSample}),

    logger:info("Actor exchanger ~p : Running state, Sent partial view exchange "
                "in to ~p   sample : ~p",
                [State#state.namespace, OldestNode, FinalSample]),
    {keep_state,
     State#state{partial_view = PartialView,
                 kept_nodes = KeptNodes,
                 target_node = OldestNode,
                 outview_size = OutviewSize,
                 to_leave = Sample ++ [OldestNode]},
     ?EXCHANGE_OUT_TIMEOUT};
%% Receive exchange cancel from oldest node
wait_exchange_out(info,
                  {incoming_event, #exchange_cancelled{namespace = Namespace, reason = Reason}},
                  State) ->
    logger:info("Actor exchanger ~p : wait_exchange_out, Got exchange cancelled "
                " wth reason ~p from ~p",
                [Namespace, Reason, State#state.target_node]),
    bbsvx_actor_spray_view:reinit_age(Namespace, State#state.target_node#node_entry.pid),
    {stop, normal, State};
%% Receive exchange out in wait_exchange_out
wait_exchange_out(info,
                  {incoming_event, #exchange_out{namespace = Namespace, proposed_sample = []}},
                  #state{outview_size = 1} = State) ->
    logger:info("Actor exchanger ~p : wait_exchange_out, empty proposal single "
                "outview ~p",
                [Namespace, State#state.target_node]),
    bbsvx_client_connection:send(State#state.target_node#node_entry.pid,
                                 #exchange_cancelled{namespace = Namespace,
                                                     reason = empty_proposal_empty_outview}),
    bbsvx_actor_spray_view:reinit_age(Namespace, State#state.target_node#node_entry.pid),

    {stop, normal, State};
wait_exchange_out(info,
                  {incoming_event,
                   #exchange_out{namespace = Namespace,
                                 origin_node = OriginNode,
                                 proposed_sample = IncomingSample}},
                  #state{my_node = MyNode} = State) ->
    logger:info("Actor exchanger ~p : wait_exchange_out, Got partial view exchange "
                "out from ~p",
                [Namespace, OriginNode]),
    %% Replace all occurence of our node by the origin node in the incoming sample
    ReplacedIncomingSample =
        lists:map(fun (#node_entry{node_id = Nid})
                          when Nid == State#state.my_node#node_entry.node_id ->
                          OriginNode;
                      (Node) ->
                          Node
                  end,
                  IncomingSample),

    %% Register to future connection events
    %%Register to events from client connections on this namespace
    gproc:reg({p, l, {bbsvx_client_connection, Namespace}}),

    %% Connect to ReplacementIncomingSample nodes
    open_connections(Namespace, MyNode, ReplacedIncomingSample),

    %% Send exchange accept to oldest node
    bbsvx_client_connection:send(State#state.target_node#node_entry.pid, #exchange_accept{}),
    case ReplacedIncomingSample of
        [] ->
            %% We don't need to connect to any node, go straight to exchange end
            {next_state,
             initiator_disconnect,
             State#state{proposed_sample = ReplacedIncomingSample},
             500};
        _ ->
            {next_state,
             wait_for_exchange_end,
             State#state{proposed_sample = ReplacedIncomingSample},
             500}
    end;
wait_exchange_out(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : wait_exchange_out, timed out",
                   [State#state.namespace]),

    prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_initiator_echange_timeout_">>,
                                                            binary:replace(State#state.namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))),
    {stop, normal, State}.

responding(enter,
           _,
           #state{namespace = Namespace,
                  my_node = MyNode,
                  origin_node = OriginNode} =
               State) ->
    logger:info("Actor exchanger ~p : Entering responding state", [Namespace]),

    %% Get partial view from the spray view agent
    {ok, Outview} =
        gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}}, get_outview),

    {MySample, KeptNodes} = get_big_random_sample(Outview),

    %% Replace all occurences of origin node in our sample by our node entry
    ReplacedMySample =
        lists:map(fun (#node_entry{node_id = NodeId})
                          when NodeId == OriginNode#node_entry.node_id ->
                          MyNode;
                      (Node) ->
                          Node
                  end,
                  MySample),

    %% Send our sample to the origin node
    logger:info("Actor exchanger ~p : responding state, Sent partial view exchange "
                "out to ~p   sample : ~p",
                [Namespace, OriginNode#node_entry.node_id, ReplacedMySample]),

    bbsvx_server_connection:accept_exchange(OriginNode#node_entry.pid, ReplacedMySample),

    {keep_state,
     State#state{to_leave = MySample, kept_nodes = KeptNodes},
     ?EXCHANGE_OUT_TIMEOUT};
responding(info,
           {incoming_event, #exchange_accept{}},
           #state{my_node = MyNode, namespace = Namespace} = State) ->
    logger:info("Actor exchanger ~p : responding state, Got exchange accept", [Namespace]),

    %%Register to events from client connections on this namespace
    gproc:reg({p, l, {bbsvx_client_connection, Namespace}}),

    % We start by connecting to proposed sample
    open_connections(Namespace, MyNode, State#state.proposed_sample),

    %% Send exchange end to other side
    bbsvx_server_connection:exchange_end(State#state.origin_node#node_entry.pid),
    case State#state.proposed_sample of
        [] ->
            %% We don't need to connect to any node, go straight to exchange end
            {next_state, responding_disconnect, State, 500};
        _ ->
            {next_state, wait_for_exchange_end_responding, State, 500}
    end;
responding(info,
           {incoming_event, #exchange_cancelled{namespace = Namespace, reason = Reason}},
           State) ->
    logger:info("Actor exchanger ~p : responding state, Got exchange cancelled "
                " wth reason ~p",
                [Namespace, Reason]),
    {stop, normal, State};
responding(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : responding state, timed out",
                   [State#state.namespace]),
    {stop, normal, State}.

wait_for_exchange_end(enter, _, #state{to_leave = []} = State) ->
    logger:info("Actor exchanger ~p : Entering wait_for_exchange_end with no "
                "node to leave, terminating",
                [State#state.namespace]),
    {stop, normal, State};
wait_for_exchange_end(enter, _, State) ->
    {keep_state, State};
wait_for_exchange_end(info,
                      {connected, _Namespace, RequesterNode, {outview, _}},
                      State) ->
    logger:info("Actor exchanger ~p : wait_for_exchange_end, Got connected event "
                "from ~p",
                [State#state.namespace, RequesterNode]),
    {next_state, initiator_disconnect, State, 500};
%% We received exchange end before we are connected to the proposed sample
%% so risk of empty outview. We postpone the event and stay in this state until we are connected
wait_for_exchange_end(info,
                      {incoming_event, #exchange_end{}},
                      #state{namespace = Namespace} = State) ->
    logger:info("Actor exchanger ~p : wait_for_exchange_end, Got exchange end "
                "before connected, postponing, to connect : ~p",
                [Namespace, State#state.proposed_sample]),
    {next_state, wait_for_exchange_end, State, [postpone]};
wait_for_exchange_end(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : wait_for_exchange_end, timed out",
                   [State#state.namespace]),
    {stop, normal, State};
%% Catch all
wait_for_exchange_end(_, _, State) ->
    logger:warning("Actor exchanger ~p : wait_for_exchange_end, unmanaged call",
                   [State#state.namespace]),
    {keep_state, State}.

initiator_disconnect(enter, _, State) ->
    {keep_state, State};
initiator_disconnect(info,
                     {incoming_event, #exchange_end{}},
                     #state{namespace = Namespace} = State) ->
    %% Disconnect from the nodes to leave
    logger:info("Actor exchanger ~p : initiator_disconnect, Disconnect from "
                "nodes to leave ~p",
                [Namespace, State#state.to_leave]),
    bbsvx_client_connection:send(State#state.target_node#node_entry.pid, #exchange_end{}),
    %% Finally start closing the connections
    close_connections(State#state.to_leave),
    {stop, normal, State};
initiator_disconnect(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : initiator_disconnect, timed out",
                   [State#state.namespace]),
    {stop, normal, State};
%% Catch all
initiator_disconnect(Type, Event, State) ->
    logger:warning("Actor exchanger ~p : initiator_disconnect, unmanaged call ~p:~p",
                   [State#state.namespace, Type, Event]),
    {keep_state, State}.

wait_for_exchange_end_responding(enter, _, #state{proposed_sample = []} = State) ->
    logger:info("Actor exchanger ~p : Entering wait_for_exchange_end_responding "
                "with empty proposed sample, terminating",
                [State#state.namespace]),
    {stop, normal, State};
wait_for_exchange_end_responding(enter, _, #state{to_leave = []} = State) ->
    logger:info("Actor exchanger ~p : Entering wait_for_exchange_end_responding "
                "with no node to leave, terminating",
                [State#state.namespace]),
    {stop, normal, State};
wait_for_exchange_end_responding(enter, _, State) ->
    {keep_state, State};
wait_for_exchange_end_responding(info,
                                 {connected, _Namespace, RequesterNode, {outview, _}},
                                 State) ->
    logger:info("Actor exchanger ~p : wait_for_exchange_end_responding, Got "
                "connected event from ~p",
                [State#state.namespace, RequesterNode]),
    {next_state, responding_disconnect, State, 500};
wait_for_exchange_end_responding(info,
                                 {incoming_event, #exchange_end{}},
                                 #state{namespace = Namespace} = State) ->
    logger:info("Actor exchanger ~p : wait_for_exchange_end_responding, Got "
                "exchange end before connected, postponing",
                [Namespace]),
    {keep_state, State, [{postpone, true}]};
wait_for_exchange_end_responding(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : wait_for_exchange_end_responding, timed "
                   "out",
                   [State#state.namespace]),
    {stop, normal, State};
%% Catch all
wait_for_exchange_end_responding(_, _, State) ->
    logger:warning("Actor exchanger ~p : wait_for_exchange_end_responding, unmanaged "
                   "call",
                   [State#state.namespace]),
    {keep_state, State}.

responding_disconnect(enter, _, State) ->
    {keep_state, State};
responding_disconnect(info,
                      {incoming_event, #exchange_end{}},
                      #state{namespace = Namespace} = State) ->
    %% Disconnect from the nodes to leave
    logger:info("Actor exchanger ~p : wait_for_exchange_end_responding, Disconnect "
                "from nodes to leave ~p",
                [Namespace, State#state.to_leave]),
    lists:foreach(fun(Node) ->
                     %% Notify leaving node of the removal
                     gen_statem:call(Node#node_entry.pid, {disconnect, exchange})
                  end,
                  State#state.to_leave),
    {stop, normal, State};
responding_disconnect(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : responding_disconnect, timed out",
                   [State#state.namespace]),
    {stop, normal, State};
%% Catch all
responding_disconnect(_, _, State) ->
    logger:warning("Actor exchanger ~p : responding_disconnect, unmanaged call",
                   [State#state.namespace]),
    {keep_state, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
-spec open_connections(binary(), node_entry(), [node_entry()]) -> ok.
open_connections(Namespace, MyNode, TargetNodes) ->
lists:foreach(fun(Node) ->
    supervisor:start_child(bbsvx_sup_client_connections,
                           [join, Namespace, MyNode, Node])
 end,
 TargetNodes).

 -spec close_connections([node_entry()]) -> ok.
 close_connections(TargetNodes) ->
    lists:foreach(fun(Node) ->
        %% Notify leaving node of the removal
        gen_statem:call(Node#node_entry.pid, {disconnect, exchange})
     end,
     TargetNodes).

%%-----------------------------------------------------------------------------
%% @doc
%% get_randm_sample/2
%% Get a random sample of nodes from a list of nodes.
%% returns the sample and the rest of the list
%% @end
%% ----------------------------------------------------------------------------

get_random_sample([]) ->
    {[], []};
get_random_sample([_] = View) ->
    {[], View};
get_random_sample(View) ->
    %% Shuffle the view
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- View])],
    %% split the view in two
    {_Sample, _Rest} = lists:split(length(View) div 2 - 1, Shuffled).

%% get_big_random_sample/1
%% Like get_random_sample/1 but doesn't substract 1 when halving view size
get_big_random_sample([]) ->
    {[], []};
get_big_random_sample([_] = View) ->
    {[], View};
get_big_random_sample(View) ->
    %% Shuffle the view
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- View])],
    %% split the view in two
    {_Sample, _Rest} = lists:split(length(View) div 2, Shuffled).

%%-----------------------------------------------------------------------------
%% @doc
%% get_oldest_node/1
%% Get the oldest node in a view
%% @end
%% ----------------------------------------------------------------------------
get_oldest_node([Node]) ->
    Node;
get_oldest_node(Nodes) ->
    Sorted = lists:keysort(#node_entry.age, Nodes),
    lists:last(Sorted).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

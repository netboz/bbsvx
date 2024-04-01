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

-include("bbsvx_common_types.hrl").

-include_lib("ejabberd/include/mqtt.hrl").

-include("otel_tracer.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/3, start_link/5, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([responding/3, wait_exchange_out/3]).
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
         parent_pid :: pid() | undefined}).

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
    State = #state{namespace = Namespace, my_node = MyNode},
    logger:info("Starting view exchanger initiator for ~p", [MyNode]),
    {ok, wait_exchange_out, State, ?EXCHANGE_OUT_TIMEOUT};
init([responder, Namespace, MyNode, OriginNode, ProposedSample]) ->
    logger:info("Starting view exchanger responder for ~p", [MyNode]),
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
responding(enter,
           _,
           #state{namespace = Namespace,
                  my_node = MyNode,
                  origin_node = OriginNode} =
               State) ->
    logger:info("Actor exchanger ~p : Entering responding state", [Namespace]),

    %% Get partial view from the spray view agent
    SprayPid = gproc:where({n, l, {bbsvx_actor_spray_view, Namespace}}),
    {ok, Outview} = gen_statem:call(SprayPid, get_outview),
    logger:info("Actor exchanger ~p : responding state, Got outview ~p",
                [Namespace, Outview]),
    {MySample, KeptNodes} = get_big_random_sample(Outview),
    logger:info("Actor exchanger ~p : responding state, My sample ~p, Kept nodes ~p",
                [Namespace, MySample, KeptNodes]),
    %% Replace all occurences of origin node in our sample by our node entry
    ReplacedMySample =
        lists:map(fun (#node_entry{node_id = Nid}) when Nid == OriginNode#node_entry.node_id ->
                          MyNode;
                      (Node) ->
                          Node
                  end,
                  MySample),
    logger:info("Actor exchanger ~p : responding state, Replaced my sample ~p",
                [Namespace, ReplacedMySample]),
    %% Send our ReplacedSample to the origin node
    OriginNodeNamespace =
        iolist_to_binary([<<"ontologies/in/">>, Namespace, "/", OriginNode#node_entry.node_id]),
    %% Send our sample to the origin node
    logger:info("Actor exchanger ~p : responding state, Sent partial view exchange out to ~p   sample : ~p",
                [Namespace, OriginNode#node_entry.node_id, ReplacedMySample]),
    mod_mqtt:publish({MyNode, <<"localhost">>, <<"bob3>>">>},
                     #publish{topic = OriginNodeNamespace,
                              payload =
                                  term_to_binary({partial_view_exchange_out,
                                                  Namespace,
                                                  MyNode,
                                                  ReplacedMySample}),
                              retain = false},
                     ?MAX_UINT32),

    %% Connect to the nodes in the proposed sample
    logger:info("Actor exchanger ~p : responding state, Connect to nodes in proposed sample ~p",
                [Namespace, State#state.proposed_sample]),
    lists:foreach(fun(Node) ->
                     bbsvx_actor_spray_join:start_link(join_inview,
                                                       State#state.namespace,
                                                       State#state.my_node,
                                                       Node)
                  end,
                  State#state.proposed_sample),
    %% Disconnect from the nodes to leave
    logger:info("Actor exchanger ~p : responding state, Disconnect from nodes to leave ~p",
                [Namespace, MySample]),

    lists:foreach(fun(Node) ->
                     %% Remove node from outview
                     gproc:send({p, l, {ontology, State#state.namespace}},
                                {remove_from_view, outview, Node})
                  end,
                  MySample),

    {stop, normal, State}.

wait_exchange_out(enter, _, #state{} = State) ->
    {ok, PartialView} =
        gen_statem:call(
            gproc:where({n, l, {bbsvx_actor_spray_view, State#state.namespace}}), get_outview),

    logger:info("Actor exchanger: Entering wait_exchange_out with partial view ~p",
                [PartialView]),

    %% Get Id of oldest node
    #node_entry{node_id = OldestNodeId} = OldestNode = get_oldest_node(PartialView),
    logger:info("Actor Exchanger : Oldest node ~p", [OldestNode]),
    %% Partialview without oldest node
    {_, _, PartialViewWithoutOldest} =
        lists:keytake(OldestNode#node_entry.node_id, #node_entry.node_id, PartialView),
    logger:info("Actor exchanger : Partial view without oldest ~p",
                [PartialViewWithoutOldest]),
    %% Get sample from partial view without oldest
    {Sample, KeptNodes} = get_random_sample(PartialViewWithoutOldest),
    logger:info("Actor exchanger : Sample ~p, Keptnodes ~p", [Sample, KeptNodes]),

    %% Replace all other occurence of oldest node with our node
    ReplacedSample =
        lists:map(fun (#node_entry{node_id = Nid}) when Nid == OldestNodeId ->
                          State#state.my_node;
                      (Node) ->
                          Node
                  end,
                  Sample),
    logger:info("Actor exchanger : Replaced oldest with our node, new sample ~p",
                [ReplacedSample]),

    %% Finally Add our node to the sample to get the final sample to be sent.
    %% As we removed one oldest node entry, adding ourselves keeps the sample size constant
    FinalSample = [State#state.my_node | ReplacedSample],
    logger:info("Actor exchanger : Final sample ~p", [FinalSample]),

    %% Send exchange proposition to oldest node
    %% Send the sample to exchange to the oldest node using connection service
    %% InViewNameSpace =
    InViewNameSpace =
        iolist_to_binary([<<"ontologies/in/">>,
                          State#state.namespace,
                          "/",
                          State#state.my_node#node_entry.node_id]),

    %% Register to events from mqtt connection
    gproc:reg({p, l, {bbsvx_mqtt_connection, OldestNodeId, State#state.namespace}}),

    ConPid = gproc:where({n, l, {bbsvx_mqtt_connection, OldestNodeId}}),
    gen_statem:call(ConPid,
                    {publish,
                     InViewNameSpace,
                     {partial_view_exchange_in,
                      State#state.namespace,
                      State#state.my_node,
                      FinalSample}}),
    logger:info("Actor exchanger ~p : Running state, Sent partial view exchange in to ~p   sample : ~p",
                [State#state.namespace, OldestNode, FinalSample]),
    {keep_state,
     State#state{partial_view = PartialView,
                 kept_nodes = KeptNodes,
                 target_node = OldestNode,
                 to_leave = Sample ++ [OldestNode]},
     ?EXCHANGE_OUT_TIMEOUT};
%% Receive exchange out in wait_exchange_out
wait_exchange_out(info,
                  {partial_view_exchange_out,
                   _Namespace,
                   #node_entry{node_id = TargetNodeId} = _OriginNode,
                   IncomingSample},
                  State) ->
    logger:info("Actor exchanger ~p : wait_exchange_out, Got partial view exchange out from ~p",
                [State#state.namespace, TargetNodeId]),
    %% Replace all occurence of our node by the origin node in the incoming sample
    ReplacedIncomingSample =
        lists:map(fun (#node_entry{node_id = Nid})
                          when Nid == State#state.my_node#node_entry.node_id ->
                          #node_entry{node_id = TargetNodeId};
                      (Node) ->
                          Node
                  end,
                  IncomingSample),

    %% Connect to ReplacementIncomingSample nodes
    logger:info("Actor exchanger ~p : wait_exchange_out, Connect to nodes in incoming sample ~p",
                [State#state.namespace, ReplacedIncomingSample]),
    lists:foreach(fun(Node) ->
                     R = bbsvx_actor_spray_join:start_link(join_inview,
                                                           State#state.namespace,
                                                           State#state.my_node,
                                                           Node),
                     logger:info("Actor exchanger ~p : wait for exchange out starting join actor ~p",
                                 [State#state.namespace, R])
                  end,
                  ReplacedIncomingSample),
    %% Disconnect from the nodes to leave
    logger:info("Actor exchanger ~p : wait_exchange_out, Disconnect from nodes to leave ~p",
                [State#state.namespace, State#state.to_leave]),

    lists:foreach(fun(Node) ->
                     %% Remove node from outview
                     gproc:send({p, l, {ontology, State#state.namespace}},
                                {remove_from_view, outview, Node})
                  end,
                  State#state.to_leave),
    {stop, normal, State};
wait_exchange_out(timeout, _, State) ->
    logger:warning("Actor exchanger ~p : wait_exchange_out, timed out",
                   [State#state.namespace]),

    ?set_attribute(target_node, print(State#state.target_node)),
    prometheus_counter:inc(binary_to_atom(iolist_to_binary([<<"spray_initiator_echange_timeout_">>,
                                                            binary:replace(State#state.namespace,
                                                                           <<":">>,
                                                                           <<"_">>)]))),
    {stop, normal, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

print(Term) ->
    iolist_to_binary([lists:flatten(
                          io_lib:format("~p", [Term]))]).

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
    {_Sample, _Rest} = lists:split((length(View) div 2) - 1, Shuffled).

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

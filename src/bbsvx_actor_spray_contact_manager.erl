%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray_contact_manager).

-author("yan").

-behaviour(gen_statem).

-include("bbsvx_common_types.hrl").

-include_lib("ejabberd/include/mqtt.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).
-define(MAX_UINT32, 4294967295).

%% External API
-export([start_link/3, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([acking/3]).

-record(state,
        {namespace :: binary(), my_node :: node_entry(), candidate_node :: node_entry()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(),
                 MyNode :: node_entry(),
                 CandidateNode :: node_entry()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(_Namespace,
           #node_entry{node_id = MyNodeId,
                       port = MyPort,
                       host = MyHost},
           #node_entry{host = Host,
                       port = Port,
                       node_id = NodeId})
    when NodeId == MyNodeId orelse (Host == MyHost) and (Port == MyPort) ->
    {error, connection_to_self};
start_link(Namespace, MyNode, CandidateNode) ->
    logger:info("Starting contact manager for ~p", [CandidateNode]),
    gen_statem:start({via,
                      gproc,
                      {n, l, {?MODULE, Namespace, CandidateNode#node_entry.node_id}}},
                     ?MODULE,
                     [Namespace, MyNode, CandidateNode],
                     []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([Namespace, MyNode, CandidateNode]) ->
    logger:info("Initializing contact manager for ~p", [CandidateNode]),
    {ok,
     acking,
     #state{candidate_node = CandidateNode,
            my_node = MyNode,
            namespace = Namespace}}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [state_functions, state_enter].

%%%=============================================================================
%%% State transitions
%%%=============================================================================
acking(enter, _, #state{namespace = Namespace} = State) ->
    logger:info("contact agent: acking contact request from ~p",
                [State#state.candidate_node]),
    RequesterInviewNamespace =
        iolist_to_binary([<<"ontologies/in/">>,
                          Namespace,
                          "/",
                          State#state.candidate_node#node_entry.node_id]),
    MyId = State#state.my_node#node_entry.node_id,
    %% Get current leader
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    %% Acknowledge the contact request
    mod_mqtt:publish({MyId, <<"localhost">>, <<"bob3>>">>},
                     #publish{topic = RequesterInviewNamespace,
                              payload =
                                  term_to_binary({connection_accepted,
                                                  Namespace,
                                                  State#state.my_node,
                                                  0, Leader}),
                              retain = false},
                     ?MAX_UINT32),
    SprayPid = gproc:where({n, l, {bbsvx_actor_spray_view, Namespace}}),

    {ok, InView} = gen_statem:call(SprayPid, get_inview),

    %% As we accepted the contactrequest, we can add the requester to our inview
    gproc:send({p, l, {ontology, Namespace}},
               {add_to_view, inview, State#state.candidate_node}),

    %% Target topic
    TargetTopic = iolist_to_binary([<<"ontologies/in/">>, Namespace, "/", MyId]),
    %% Get Partial view from spray agent
    {ok, Outview} = gen_statem:call({via, gproc, {n, l, {bbsvx_actor_spray_view, Namespace}}}, get_outview),

    case {InView, Outview} of
        {[], []} ->
            %% Our outview is empty, we subscribe to the candidate node
            bbsvx_actor_spray_join:start_link(join_inview, Namespace, State#state.my_node, State#state.candidate_node);
            
        _ ->
            %% Forward subscriptions to all nodes of the view
            lists:foreach(fun(#node_entry{node_id = NId}) ->
                             gen_statem:call({via, gproc, {n, l, {bbsvx_mqtt_connection, NId}}},
                                             {publish,
                                              TargetTopic,
                                              {forwarded_subscription,
                                               Namespace,
                                               State#state.candidate_node}})
                          end,
                          Outview)
    end,

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

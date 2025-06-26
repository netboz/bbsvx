%%%-----------------------------------------------------------------------------
%%% @doc
%%% Prometheus metrics reporter for P2P network graph visualization.
%%% Listens to spray exchange events and updates edge metrics for Grafana Node Graph.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_metrics_graph_reporter).

-author("yan").

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-behaviour(gen_statem).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/0, stop/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3]).

-record(state, {my_id :: binary(), 
                my_host :: binary(),
                my_port :: integer(),
                connections = #{} :: #{binary() => {binary(), binary()}}}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> gen_statem:start_ret().
start_link() ->
    gen_statem:start({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([]) ->
    MyId = bbsvx_crypto_service:my_id(),
    %% Get my host and port for node metadata
    {ok, {Host, Port}} = bbsvx_network_service:my_host_port(),
    HostBin = list_to_binary(inet:ntoa(Host)),
    %% Register to spray exchange events for bbsvx:root namespace
    gproc:reg({p, l, {spray_exchange, <<"bbsvx:root">>}}),
    ?'log-info'("Starting metrics graph reporter with id: ~p, host: ~p, port: ~p", [MyId, HostBin, Port]),
    %% Register this node immediately
    ShortId = binary:part(MyId, 0, 5),
    prometheus_gauge:set(<<"bbsvx_spray_node_active">>,
                         [MyId, <<"bbsvx:root">>, ShortId, HostBin, Port],
                         1),
    {ok, running, #state{my_id = MyId, my_host = HostBin, my_port = Port, connections = #{}}}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    state_functions.

%%%=============================================================================
%%% State transitions
%%%=============================================================================

%% Handle outgoing arc connected event
running(info,
        #incoming_event{event =
                            #evt_arc_connected_out{ulid = Ulid,
                                                   target = #node_entry{node_id = TargetNodeId, host = TargetHost, port = TargetPort}}},
        State) ->
    %% Set edge as active (value = 1)
    prometheus_gauge:set(<<"bbsvx_spray_edge_active">>,
                         [State#state.my_id, TargetNodeId, <<"bbsvx:root">>, <<"out">>],
                         1),
    %% Set my node as active (already done in init, but ensure it's there)
    MyShortId = binary:part(State#state.my_id, 0, 5),
    prometheus_gauge:set(<<"bbsvx_spray_node_active">>,
                         [State#state.my_id, <<"bbsvx:root">>, MyShortId, State#state.my_host, State#state.my_port],
                         1),
    %% Set target node as active with its info
    TargetShortId = binary:part(TargetNodeId, 0, 5),
    TargetHostBin = case TargetHost of
        local -> <<"local">>;
        _ when is_tuple(TargetHost) -> list_to_binary(inet:ntoa(TargetHost));
        _ when is_binary(TargetHost) -> TargetHost;
        _ -> <<"unknown">>
    end,
    prometheus_gauge:set(<<"bbsvx_spray_node_active">>,
                         [TargetNodeId, <<"bbsvx:root">>, TargetShortId, TargetHostBin, TargetPort],
                         1),
    %% Set edge info for Node Graph
    prometheus_gauge:set(<<"bbsvx_spray_edge_info">>,
                         [Ulid, State#state.my_id, TargetNodeId, <<"bbsvx:root">>],
                         1),
    %% Track this connection for potential disconnection
    NewConnections = maps:put(Ulid, {State#state.my_id, TargetNodeId}, State#state.connections),
    {next_state, running, State#state{connections = NewConnections}};

%% Handle incoming arc connected event  
running(info,
        #incoming_event{event =
                            #evt_arc_connected_in{ulid = Ulid,
                                                  source = #node_entry{node_id = SourceNodeId, host = SourceHost, port = SourcePort}}},
        State) ->
    %% Set edge as active (value = 1)
    prometheus_gauge:set(<<"bbsvx_spray_edge_active">>,
                         [SourceNodeId, State#state.my_id, <<"bbsvx:root">>, <<"in">>],
                         1),
    %% Set my node as active (already done in init, but ensure it's there)
    MyShortId = binary:part(State#state.my_id, 0, 5),
    prometheus_gauge:set(<<"bbsvx_spray_node_active">>,
                         [State#state.my_id, <<"bbsvx:root">>, MyShortId, State#state.my_host, State#state.my_port],
                         1),
    %% Set source node as active with its info
    SourceShortId = binary:part(SourceNodeId, 0, 5),
    SourceHostBin = case SourceHost of
        local -> <<"local">>;
        _ when is_tuple(SourceHost) -> list_to_binary(inet:ntoa(SourceHost));
        _ when is_binary(SourceHost) -> SourceHost;
        _ -> <<"unknown">>
    end,
    prometheus_gauge:set(<<"bbsvx_spray_node_active">>,
                         [SourceNodeId, <<"bbsvx:root">>, SourceShortId, SourceHostBin, SourcePort],
                         1),
    %% Set edge info for Node Graph (reverse direction since this is incoming)
    prometheus_gauge:set(<<"bbsvx_spray_edge_info">>,
                         [Ulid, SourceNodeId, State#state.my_id, <<"bbsvx:root">>],
                         1),
    %% Track this connection for potential disconnection
    NewConnections = maps:put(Ulid, {SourceNodeId, State#state.my_id}, State#state.connections),
    {next_state, running, State#state{connections = NewConnections}};

%% Handle arc disconnected events
running(info,
        #incoming_event{event = #evt_arc_disconnected{ulid = Ulid, direction = Direction}},
        State) ->
    case maps:get(Ulid, State#state.connections, undefined) of
        {SourceNodeId, TargetNodeId} ->
            %% Remove edge metrics
            prometheus_gauge:set(<<"bbsvx_spray_edge_active">>,
                                 [SourceNodeId, TargetNodeId, <<"bbsvx:root">>, 
                                  case Direction of in -> <<"in">>; out -> <<"out">> end],
                                 0),
            prometheus_gauge:set(<<"bbsvx_spray_edge_info">>,
                                 [Ulid, SourceNodeId, TargetNodeId, <<"bbsvx:root">>],
                                 0),
            %% Remove from tracked connections
            NewConnections = maps:remove(Ulid, State#state.connections),
            ?'log-info'("Arc disconnected: ulid=~p, direction=~p, removed edge ~p -> ~p", 
                        [Ulid, Direction, SourceNodeId, TargetNodeId]),
            {next_state, running, State#state{connections = NewConnections}};
        undefined ->
            ?'log-info'("Arc disconnected: ulid=~p, direction=~p (connection not tracked)", 
                        [Ulid, Direction]),
            {next_state, running, State}
    end;

%% Handle node start events
running(info,
        #incoming_event{event =
                            {node_started,
                             _Namespace,
                             #node_entry{node_id = NodeId}}},
        State) ->
    ?'log-info'("Node started: ~p", [NodeId]),
    %% Node start doesn't directly create edges, just log for now
    {next_state, running, State};

%% Handle node stop events  
running(info,
        #incoming_event{event =
                            {node_stopped,
                             _Namespace,
                             #node_entry{node_id = NodeId}}},
        State) ->
    ?'log-info'("Node stopped: ~p", [NodeId]),
    %% When a node stops, we could clean up all its edges, but they should
    %% already be cleaned up by disconnection events
    {next_state, running, State};

%% Catch all other events
running(_Type, _Msg, State) ->
    {next_state, running, State}.

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
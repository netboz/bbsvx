%%%-----------------------------------------------------------------------------
%%% SPRAY Protocol Actor - Peer-to-Peer Overlay Network Management
%%% @author yan
%%%-----------------------------------------------------------------------------

-module(bbsvx_actor_spray).

-moduledoc """
Gen State Machine implementation of the SPRAY protocol for distributed peer sampling.

The SPRAY protocol maintains a random overlay network topology through periodic
view exchanges between nodes. This module implements the full SPRAY lifecycle including
connection management, arc aging, and exchange protocols.

## Key Responsibilities

- **View Management**: Maintains inview (incoming) and outview (outgoing) connections
- **Exchange Protocol**: Coordinates view exchanges with peers to maintain network topology
- **Arc Lifecycle**: Manages arc creation, aging, mirroring, and removal
- **Broadcast Support**: Provides primitives for EPTO and other protocols to broadcast messages

## Protocol Flow

1. Nodes maintain partial views of the network (in/out connections called "arcs")
2. Periodic timer triggers exchange with random peer from outview
3. Nodes swap partial view samples to maintain connectivity
4. Arc aging ensures fresh connections are preferred over stale ones

Author: yan
""".

-behaviour(gen_statem).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

-define(EXCHANGE_INTERVAL, 4000).
%% Jitter to desynchronize exchanges across nodes (50% of interval)
-define(EXCHANGE_JITTER, (?EXCHANGE_INTERVAL div 8)).
-define(WAIT_EXCHANGE_OUT_TIMEOUT, ?EXCHANGE_INTERVAL div 5).
-define(WAIT_EXCHANGE_ACCEPT_TIMEOUT, ?EXCHANGE_INTERVAL div 5).
-define(EXCHANGE_END_TIMEOUT, ?EXCHANGE_INTERVAL - round(?EXCHANGE_INTERVAL / 10)).

%% External API
-export([
    start_link/1, start_link/2,
    stop/0,
    broadcast/2,
    broadcast_unique/2,
    get_n_unique_random/2,
    broadcast_unique_random_subset/3,
    get_inview/1,
    get_all_inview/1,
    get_all_outview/1,
    get_views/1
]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([handle_event/4]).
%% spray timer handler
-export([trigger_exchange/1]).
%-export([iddle/3]).

-record(state,
    %%in_view = [] :: [arc()],
    {
        %%out_view = [] :: [arc()],
        spray_timer :: pid(),
        current_exchange_peer :: arc() | undefined,
        exchange_direction :: in | out | undefined,
        proposed_sample :: [exchange_entry()],
        incoming_sample :: [exchange_entry()],
        contact_nodes = [] :: [node_entry()],
        namespace :: binary(),
        my_node :: node_entry()
    }
).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================
-spec start_link(NameSpace :: binary()) -> gen_statem:start_ret().
start_link(NameSpace) ->
    start_link(NameSpace, []).

-spec start_link(NameSpace :: binary(), Options :: list()) -> gen_statem:start_ret().
start_link(NameSpace, Options) ->
    gen_statem:start_link(
        {via, gproc, {n, l, {?MODULE, NameSpace}}},
        ?MODULE,
        [NameSpace, Options],
        []
    ).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([NameSpace, Options]) ->
    %%process_flag(trap_exit, true),
    ?'log-info'("spray Agent ~p : Starting state with Options ~p", [NameSpace, Options]),
    %% Get our node id
    MyNodeId = bbsvx_crypto_service:my_id(),
    %% Get our host and port
    {ok, {Host, Port}} = bbsvx_network_service:my_host_port(),
    MyNode =
        #node_entry{
            node_id = MyNodeId,
            host = Host,
            port = Port
        },

    %% Register to events for this ontolgy namespace
    gproc:reg({p, l, {spray_exchange, NameSpace}}),

    ContactNodes =
        case maps:get(boot, Options, []) of
            root ->
                [];
            _ ->
                maps:get(contact_nodes, Options, [])
        end,

    %% STart spray time timer
    MyPid = self(),

    SprayTimer = spawn_link(?MODULE, trigger_exchange, [MyPid]),

    %% TODO: Reove next
    Data =
        #{
            action => <<"add">>,
            node_id => MyNodeId,
            metadata =>
                #{
                    host => format_host(Host),
                    port => Port,
                    namespace => NameSpace,
                    node_id => MyNodeId
                }
        },
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    %% TODO: move next to another place
    httpc:request(
        post,
        {"http://graph-visualizer:3400/nodes", [], "application/json", Json},
        [],
        []
    ),

    %Me = self(),
    %SprayTimer = erlang:start_timer(?EXCHANGE_INTERVAL, Me, spray_time),
    {ok, disconnected, #state{
        namespace = NameSpace,
        spray_timer = SprayTimer,
        proposed_sample = [],
        incoming_sample = [],
        contact_nodes = ContactNodes,
        my_node = MyNode
    }}.

terminate(
    Reason,
    _CurrentState,
    #state{namespace = NameSpace, my_node = #node_entry{node_id = MyNodeId}}
) ->
    ?'log-info'("spray Agent ~p : Terminating. Reason :~p", [MyNodeId, Reason]),
    % Normal termination
    % We need to terminate our in and out connections
    % First we get the outview, and keep a single arc per target node
    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
    OutArcs =
        lists:usort(
            fun(
                {#arc{target = #node_entry{node_id = NodeId1}}, _},
                {#arc{target = #node_entry{node_id = NodeId2}}, _}
            ) ->
                NodeId1 < NodeId2
            end,
            OutView
        ),

        %% TODO : this can maybe be optiomized as the second parameter from get_available_arcs is the pid of the connection
    lists:foreach(
        fun({#arc{ulid = Ulid}, _}) -> terminate_connection(NameSpace, Ulid, out, Reason) end,
        OutArcs
    ),
    ?'log-info'("2", []),
    InView = bbsvx_arc_registry:get_available_arcs(NameSpace, in),
    InArcs =
        lists:usort(
            fun(
                {#arc{source = #node_entry{node_id = NodeId1}}, _},
                {#arc{source = #node_entry{node_id = NodeId2}}, _}
            ) ->
                NodeId1 < NodeId2
            end,
            InView
        ),
    ?'log-info'("3", []),
    lists:foreach(
        fun({#arc{ulid = Ulid}, _}) -> terminate_connection(NameSpace, Ulid, in, Reason) end,
        InArcs
    ),
    ?'log-info'("4", []),
    Data = #{action => <<"remove">>, node_id => MyNodeId},
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    httpc:request(
        post,
        {"http://graph-visualizer:3400/nodes", [], "application/json", Json},
        [],
        []
    ),
    Reason.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    [handle_event_function, state_enter].

%%%%%%%%%%%%%%%%%%%%%%% Disconnected state %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Entering diconnected state from initialization
handle_event(
    enter,
    disconnected,
    disconnected,
    #state{
        namespace = NameSpace,
        my_node = MyNode,
        contact_nodes = ContactNodes
    } =
        State
) ->
    gen_statem:call(
        {via, gproc, {n, l, {bbsvx_epto_disord_component, NameSpace}}},
        empty_inview
    ),

    ?'log-info'("spray Agent ~p : Entering initial disconnected state", [NameSpace]),

    %% We connect to a contact node
    %%  Try to register to the ontology node mesh
    register_namespace(NameSpace, MyNode, ContactNodes),
    {keep_state, State};
handle_event(enter, _, disconnected, #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : Entering disconnected state", [NameSpace]),
    prometheus_gauge:inc(<<"bbsvx_spray_inview_depleted">>, [NameSpace]),
    {keep_state, State};
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #evt_arc_connected_out{}},
    disconnected,
    StateData
) ->
    %% TODO ask other side to connect to us
    {next_state, empty_inview, StateData};
handle_event(
    info,
    #incoming_event{
        origin_arc = Ulid,
        event =
            #evt_arc_connected_in{
                source = Source,
                lock = Lock,
                connection_type = register
            }
    },
    disconnected,
    #state{namespace = NameSpace, my_node = MyNode} = StateData
) ->
                    ?'log-info'("spray Agent ~p : disconnected state, New incoming arc : ~p connecting to origin", [NameSpace, Source]),

        %% Send current_index to newly connected peer for registration
    case bbsvx_actor_ontology:get_current_index(NameSpace) of
        {ok, CurrentIndex} ->
            Arc =
                #arc{
                    ulid = Ulid,
                    lock = Lock,
                    source = Source,
                    target = MyNode,
                    age = 0
                },
            ?'log-info'(
                "spray Agent ~p : Sending registration info to peer ~p "
                "(current_index=~p)",
                [NameSpace, Source, CurrentIndex]
            ),
            send(
                NameSpace,
                Ulid,
                in,
                #registered{
                    registered_arc = Arc,
                    current_index = CurrentIndex,
                    leader = <<>>
                }),
                %% Then connect to him
         open_connection(NameSpace, MyNode, Source, []);
        Error ->
            ?'log-warning'(
                "spray Agent ~p : Failed to get current_index for registration: ~p",
                [NameSpace, Error]
            )
    end,
    
    {next_state, empty_outview, StateData};

handle_event(
    info,
    #incoming_event{
        event =
            #evt_arc_connected_in{
                source = Source,
                connection_type = forward_join
            }
    },
    disconnected,
    #state{namespace = NameSpace} = StateData
) ->
    %% New forward join connecting to us. Atm even if we have an empty outview ( as we are disconnected ), we don't connect back to the origin of the forward join
                    ?'log-info'("spray Agent ~p : disconnected state, New incoming forward join, ignoring. Origin : ~p", [NameSpace, Source]),
    
    {next_state, empty_outview, StateData};

handle_event(
    info,
    #incoming_event{
        event =
            #evt_arc_connected_in{
                source = Source,
                connection_type = mirror
            }
    },
    disconnected,
    #state{namespace = NameSpace} = StateData
) ->
    %% Not sure how we could mirror an arc while being disconnected
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, New incoming mirrored arc from ~p received, ignoring",
        [NameSpace, Source]
    ),
    
    {next_state, empty_outview, StateData};

handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_disconnected{ulid = Ulid, direction = Direction}
    },
    disconnected,
    #state{namespace = NameSpace}
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, arc disconnected ~p direction ~p received, ignoring",
        [NameSpace, Ulid, Direction]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #evt_arc_swapped_in{}},
    disconnected,
    _StateData
) ->
    %% Arc swap notification - Not sure how we could get this in disconnected state
    %% Log a warning and ignore it.
    ?'log-warning'(
        "spray Agent ~p : disconnected state, arc swapped in received, ignoring",
        [_Ulid]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #open_forward_join{}
    } = Event,
    disconnected,
    #state{namespace = NameSpace}
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, forward_join ~p received, ignoring",
        [NameSpace, Event]
    ),
    keep_state_and_data;
handle_event(
    info,
    spray_time,
    disconnected,
    #state{namespace = NameSpace}
) ->
    ?'log-info'(
        "spray Agent ~p : disconnected state, spray time received, ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = OriginUlid,
        event = #exchange_in{}
    },
    disconnected,
    #state{
        namespace = NameSpace,
        current_exchange_peer = undefined
    }
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it

    ?'log-warning'(
        "spray Agent ~p : disconnected state, exchange in received from arc ~p, "
        "Ignoring",
        [NameSpace, OriginUlid]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #exchange_out{}
    },
    disconnected,
    #state{namespace = NameSpace}
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, exchange out received, "
        "Ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{event = #exchange_accept{}},
    disconnected,
    #state{
        namespace = NameSpace,
        current_exchange_peer = CurrentExchangePeer,
        incoming_sample = IncomingSample,
        proposed_sample = ProposedSample
    }
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, exchange accept received, "
        "Ignoring. CurrentExchangePeer: ~p, IncomingSample: ~p, ProposedSample: ~p",
        [NameSpace, CurrentExchangePeer, IncomingSample, ProposedSample]
    ),
    keep_state_and_data;
handle_event(
    info,
    #evt_end_exchange{exchanged_ulids = EndedExchangeUlids},
    disconnected,
    #state{namespace = NameSpace, current_exchange_peer = CurrentExchangePeer}
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, end exchange received for arcs ~p, "
        "Ignoring. CurrentExchangePeer: ~p",
        [NameSpace, EndedExchangeUlids, CurrentExchangePeer]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #exchange_cancelled{reason = Reason}
    },
    disconnected,
    #state{namespace = NameSpace}
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, exchange cancelled received with reason ~p, "
        "Ignoring",
        [NameSpace, Reason]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_node_quitted{
                node_id = NodeId,
                reason = Reason,
                direction = Direction
            }
    },
    disconnected,
    #state{namespace = NameSpace}
) ->
    %% This should not happen, as we are disconnected already
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : disconnected state, node quitted ~p with reason "
        "~p  direction ~p received, ignoring",
        [NameSpace, NodeId, Reason, Direction]
    ),
    keep_state_and_data;

%%%%%%%%%%%%%%%%%%%%%%% Empty outview state %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_event(enter, disconnected, empty_outview, #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : promoting to Empty outview state", [NameSpace]),
    {keep_state, State};
handle_event(enter, _, empty_outview, #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : downgrrading to Empty outview state", [NameSpace]),
    prometheus_gauge:inc(<<"bbsvx_spray_outview_depleted">>, [NameSpace]),
    {keep_state, State};
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #evt_arc_connected_out{}},
    empty_outview,
    #state{namespace = NameSpace} = StateData
) ->
    prometheus_gauge:dec(<<"bbsvx_spray_outview_depleted">>, [NameSpace]),

    {next_state, connected, StateData};

handle_event(
    info,
    #incoming_event{
        origin_arc = Ulid,
        event =
            #evt_arc_connected_in{
                source = Source,
                lock = Lock,
                spread = Spread,
                connection_type = register
            }
    },
    empty_outview,
    #state{namespace = NameSpace, my_node = MyNode}
) ->
    ?'log-info'("spray Agent ~p : empty_outview state, New incoming arc : ~p", [NameSpace, Source]),

    %% Send current_index to newly connected peer for registration
    case bbsvx_actor_ontology:get_current_index(NameSpace) of
        {ok, CurrentIndex} ->
            Arc =
                #arc{
                    ulid = Ulid,
                    lock = Lock,
                    source = Source,
                    target = MyNode,
                    age = 0
                },
            ?'log-info'(
                "spray Agent ~p : Sending registration info to peer ~p "
                "(current_index=~p)",
                [NameSpace, Source, CurrentIndex]
            ),
            send(
                NameSpace,
                Ulid,
                in,
                #registered{
                    registered_arc = Arc,
                    current_index = CurrentIndex,
                    leader = <<>>
                }
            ),
            %% Then connect to him
            open_connection(NameSpace, MyNode, Source, []);
        Error ->
            ?'log-warning'(
                "spray Agent ~p : Failed to get current_index for registration: ~p",
                [NameSpace, Error]
            )
    end,
    keep_state_and_data;

handle_event(
    info,
    #incoming_event{
        event = 
            #evt_arc_connected_in{
                source = Source,
                connection_type = forward_join
            }
    },
    empty_outview,
    #state{namespace = NameSpace, my_node = MyNode}
) ->
    %% Please note this could only happen if we register to a node and got disconnected from him before we
    %% received his forward join. In this case we accept the forward join and connect to him, but log a warning.
    
    ?'log-warning'("spray Agent ~p : empty_outview state, New incoming forward join from ~p", [NameSpace, Source]),

    %% Open connection to subscriber node
    open_connection(NameSpace, MyNode, Source, []),
    keep_state_and_data;

handle_event(
    info,
    #incoming_event{
        event = 
            #evt_arc_connected_in{
                source = Source,
                connection_type = mirror
            }
    },
    empty_outview,
    #state{namespace = NameSpace, my_node = MyNode}
) ->
    %% Not sure how we could mirror an arc while having an empty outview. Maybe when unexpected disconnection occured
    %% mirror, means one of our outview arc was swapped for this new inview arc.
    ?'log-warning'(
        "spray Agent ~p : empty_outview state, New incoming mirrored arc from ~p received",
        [NameSpace, Source]
    ),
    keep_state_and_data;



handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_disconnected{ulid = Ulid, direction = out}
    },
    empty_outview,
    #state{namespace = NameSpace}
) ->
    %% This should not happen, as outview is already empty
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : empty_outview state, Arc Out disconnected :~p, ignoring",
        [NameSpace, Ulid]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_disconnected{ulid = Ulid, direction = in}
    },
    empty_outview,
    #state{namespace = NameSpace} = State
) ->
    %% Request inview, disconnected arc should already be removed from registry
    CurrentInview = bbsvx_arc_registry:get_available_arcs(NameSpace, in),
    case CurrentInview of
        [] ->
            ?'log-warning'(
                "spray Agent ~p : Arc In disconnected :~p, empty inview",
                [State#state.namespace, Ulid]
            ),
            prometheus_gauge:inc(<<"bbsvx_spray_inview_depleted">>, [NameSpace]),
            {next_state, disconnected, State};
        _ ->
            %% TODO: Check if we need to spread to neighbors to refill outview
            {keep_state, State}
    end;

handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #evt_arc_swapped_in{}},
    empty_outview,
    _StateData
) ->
    %% Arc swap notification - no action needed, connection is already updated
    keep_state_and_data;
%% Recieved forward join in empty outview
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #open_forward_join{subscriber_node = SubscriberNode}
    } = Event,
    empty_outview,
    #state{namespace = NameSpace, my_node = MyNode}
) ->
    ?'log-info'(
        "spray Agent ~p : empty_outview state, forward_join ~p received",
        [NameSpace, Event]
    ),
    %% Open connection to subscriber node
    open_connection(NameSpace, MyNode, SubscriberNode, []),
    keep_state_and_data;
%% Ignore spray time in empty outview
%% We can't proceed to exchange in this state
handle_event(
    info,
    spray_time,
    empty_outview,
    State
) ->
    ?'log-info'(
        "spray Agent ~p : empty_outview state, spray time received, ignoring",
        [State#state.namespace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_in{}},
    empty_outview,
    #state{namespace = NameSpace} = State
) ->
    %% TODO please note that exchange may be accepted theoretically if inview is not empty
    %% but for now we just cancel it
    ?'log-warning'(
        "spray Agent ~p : empty_outview state, exchange in received, "
        "cancelling",
        [NameSpace]
    ),
    send_reject(NameSpace, in, _Ulid, exchange_in_in_empty_outview),
    prometheus_counter:inc(
        <<"spray_exchange_rejected">>,
        [State#state.namespace, exchange_in_in_empty_outview]
    ),
    {keep_state, State};
%% Exchange out received in empty outview
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_out{}},
    empty_outview,
    #state{namespace = NameSpace}
) ->
    %% Manage exchange out in empty outview, I don't think this could happen.
    %% if an exchange was started, it means we had at least one arc in outview,
    %% not in exchanging state. We just ignore the message and log a warning.
    ?'log-warning'(
        "spray Agent ~p : empty_outview state, exchange out received, "
        "ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_accept{}},
    empty_outview,
    #state{namespace = NameSpace}
) ->
    %% Manage exchange accept in empty outview. This could happen if exchange was accepted in
    %% exchange in, but we curretly refuse exchanges in empty outview.
    %% We just ignore the message and log a warning.
    ?'log-warning'(
        "spray Agent ~p : empty_outview state, exchange accept received, "
        "ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
%% Reception of end exchange in empty outview, we restore the arcs to available
handle_event(
    info,
    #evt_end_exchange{exchanged_ulids = EndedExchangeUlids},
    empty_outview,
    #state{namespace = Namespace} = State
) ->
    ?'log-info'(
        "spray Agent ~p : End exchange in empty outview, checking arcs still present: ~p",
        [Namespace, EndedExchangeUlids]
    ),

    %% For each arc in exchanged ulids: if arc is still in exchanging state,
    %% then the exchange failed and we need to change lock and mark back as available
    %% If at least one arc was restored, we can move back to connected state

    %% Update all arcs in EndedExchangeUlids to available when present. If one is restored,
    %% we move back to connected state.
    RestoredArc =
        lists:any(
            fun(Ulid) ->
                case bbsvx_arc_registry:get_arc(Namespace, out, Ulid) of
                    {ok, {#arc{status = exchanging, lock = Lock}, Pid}} ->
                        ?'log-info'(
                            "Arc ~p still in exchanging state, changing lock and marking available",
                            [Ulid]
                        ),
                        %% Arc is still present and in exchanging state - exchange failed
                        %% Change lock and mark as available again
                        NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),

                        Pid ! {send, #change_lock{current_lock = Lock, new_lock = NewLock}},
                        bbsvx_arc_registry:update_status(Namespace, out, Ulid, available),
                        true;
                    {ok, {#arc{status = OtherStatus}, _Pid}} ->
                        ?'log-warning'("Arc ~p in unexpected status ~p during end_exchange", [
                            Ulid, OtherStatus
                        ]),
                        false;
                    {error, not_found} ->
                        ?'log-info'("Arc ~p not found (already exchanged/disconnected)", [Ulid]),
                        false
                end
            end,
            EndedExchangeUlids
        ),
    case RestoredArc of
        true ->
            {next_state, connected, State};
        false ->
            keep_state_and_data
    end;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_cancelled{reason = Reason}},
    empty_outview,
    #state{namespace = NameSpace}
) ->
    %% Same remark as above, as long as we refuse these exchange, this should not happen
    %% We just log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : empty_outview state, exchange cancelled received with reason ~p, "
        "ignoring",
        [NameSpace, Reason]
    ),
    keep_state_and_data;
%% Node quitted in empty outview
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_node_quitted{
                node_id = NodeId,
                reason = Reason,
                direction = Direction
            } =
                Evt
    },
    empty_outview,
    State
) ->
    ?'log-warning'(
        "spray Agent ~p : empty outview state, node quitted ~p with reason "
        "~p  direction ~p",
        [State#state.namespace, NodeId, Reason, Direction]
    ),

    %% Get only available arcs (not currently being exchanged)
    OutViewAvailable = bbsvx_arc_registry:get_available_arcs(State#state.namespace, out),
    InView = get_inview(State#state.namespace),

    ?'log-info'("Start manage quitted node ~p", [OutViewAvailable]),
    manage_quitted_node(OutViewAvailable, InView, Evt, State);
%%%%%%%%%%%%%%%%%%%%%%% Empty InView state %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_event(enter, disconnected, empty_inview, #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : Entering Empty inview state", [NameSpace]),

    gen_statem:call(
        {via, gproc, {n, l, {bbsvx_epto_disord_component, NameSpace}}},
        empty_inview
    ),
    {keep_state, State};
handle_event(enter, _, empty_inview, #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : Entering Empty inview state", [NameSpace]),
    prometheus_gauge:inc(<<"bbsvx_spray_inview_depleted">>, [NameSpace]),

    gen_statem:call(
        {via, gproc, {n, l, {bbsvx_epto_disord_component, NameSpace}}},
        empty_inview
    ),
    {keep_state, State};
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #evt_arc_connected_out{}},
    empty_inview,
    _
) ->
    %% TODO: maybe ask other side to connect to us
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = Ulid,
        event =
            #evt_arc_connected_in{
                source = Source,
                lock = Lock,
                connection_type = register
            }
    },
    empty_inview,
    #state{namespace = NameSpace, my_node = MyNode} = StateData
) ->
    prometheus_gauge:dec(<<"bbsvx_spray_inview_depleted">>, [NameSpace]),
    %% Check if we have at least one node in outview. If yes, trigger forward join to nodes in outview
    %% if not connect to incoming node.
    case bbsvx_actor_ontology:get_current_index(NameSpace) of
        {ok, CurrentIndex} ->
            Arc =
                #arc{
                    ulid = Ulid,
                    lock = Lock,
                    source = Source,
                    target = MyNode,
                    age = 0
                },
            ?'log-info'(
                "spray Agent ~p : Sending registration info to peer ~p "
                "(current_index=~p)",
                [NameSpace, Source, CurrentIndex]
            ),
            send(
                NameSpace,
                Ulid,
                in,
                #registered{
                    registered_arc = Arc,
                    current_index = CurrentIndex,
                    leader = <<>>
                }
            ),

                    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
                    %% Outview shouldn't be empty but in case of, we just log it and connect to the source only
                    case OutView of
                        [] ->
                            ?'log-warning'(
                                "spray Agent ~p : Running state, New arc in, but empty outview, no spread",
                                [NameSpace]
                            ),
                            open_connection(NameSpace, MyNode, Source, []);
                        _ ->
                            ?'log-info'(
                                "spray Agent ~p : Running state, New arc in, spreading to ~p neighbours",
                                [NameSpace, length(OutView)]
                            ),
                            %% Broadcast forward subscription to all nodes in the outview
                            lists:foreach(
                                fun({_, Pid}) ->
                                    Pid ! {send, #open_forward_join{lock = Lock, subscriber_node = Source}}
                                end,
                                OutView
                            )
                    end;

        Error ->
            ?'log-warning'(
                "spray Agent ~p : Failed to get current_index for registration: ~p",
                [NameSpace, Error]
            )
    end,
    {next_state, connected, StateData};

handle_event(
    info, #incoming_event{
        event = 
            #evt_arc_connected_in{
                source = Source,
                connection_type = forward_join
            }
    },
    empty_inview,
    #state{namespace = NameSpace} = StateData
) ->
    %% New forward joing to us, we just move to connected state 
    ?'log-info'("spray Agent ~p : empty_inview state, New incoming forward join from ~p", [NameSpace, Source]),
    {next_state, connected, StateData};

handle_event(
    info,
    #incoming_event{
        event = 
            #evt_arc_connected_in{
                source = Source,
                connection_type = mirror
            }
    },
    empty_inview,
    #state{namespace = NameSpace} = StateData
) ->
    %% get outview arcs
    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
    %% If outview is empty, log a notice and move to empty outview state
    %% if not move to connected state
    case OutView of
        [] ->
            ?'log-notice'(
                "spray Agent ~p : empty_inview state, New incoming mirrored arc from ~p, made empty outview, moving to empty_outview",
                [NameSpace, Source]
            ),
            {next_state, empty_outview, StateData};
        _ ->
            ?'log-info'(
                "spray Agent ~p : empty_inview state, New incoming mirrored arc from ~p",
                [NameSpace, Source]
            ),
            {next_state, connected, StateData}
    end;


handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_arc_disconnected{ulid = DisconnectedUlid, direction = out}
    },
    empty_inview,
    #state{namespace = NameSpace} = State
) ->
    OutView = bbsvx_arc_registry:get_available_arcs(State#state.namespace, out),
    case OutView of
        [] ->
            ?'log-warning'(
                "spray Agent ~p : empty inview state, Arc Out disconnected :~p, going to disconnected",
                [State#state.namespace, DisconnectedUlid]
            ),
            prometheus_gauge:inc(<<"bbsvx_spray_outview_depleted">>, [NameSpace]),
            {next_state, disconnected, State};
        _ ->
            keep_state_and_data
    end;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_disconnected{ulid = DisconnectedUlid, direction = in}
    },
    empty_inview,
    #state{namespace = Namespace}
) ->
    %% This should not happen, as inview is already empty
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : empty inview state, Arc In disconnected :~p, ignoring",
        [Namespace, DisconnectedUlid]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_swapped_in{}
    },
    empty_inview,
    _StateData
) ->
    %% Arc swap notification - no action needed, connection is already updated
    keep_state_and_data;
%% forward join received in empty inview
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #open_forward_join{}
    } = Event,
    empty_inview,
    #state{namespace = NameSpace}
) ->
    %% This should not happen as inview is empty
    %% Log a warning and ignore it
    ?'log-warning'(
        "spray Agent ~p : empty inview state, forward_join ~p received, ignoring",
        [NameSpace, Event]
    ),
    keep_state_and_data;
%% Manage reception of spray time while in empty inview
%% This wouldn't help to proceed to the exchange, so we just ignore it
handle_event(
    info,
    spray_time,
    empty_inview,
    State
) ->
    ?'log-info'(
        "spray Agent ~p : empty_inview state, spray time received, ignoring",
        [State#state.namespace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_in{}},
    empty_inview,
    #state{namespace = NameSpace}
) ->
    %% Manage exchange in in empty inview, as inview is empty, this
    %% can't happen. Ignore it
    ?'log-warning'(
        "spray Agent ~p : empty_inview state, exchange in received, "
        "ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_out{}},
    empty_inview,
    #state{namespace = NameSpace}
) ->
    %% Manage exchange out in empty inview, as inview is empty, this
    %% can't happen. Ignore it
    ?'log-warning'(
        "spray Agent ~p : empty_inview state, exchange out received, "
        "ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_accept{}},
    empty_inview,
    #state{namespace = NameSpace}
) ->
    %% Manage exchange accept in empty inview, as inview is empty, this
    %% can't happen. Ignore it
    ?'log-warning'(
        "spray Agent ~p : empty_inview state, exchange accept received, "
        "ignoring",
        [NameSpace]
    ),
    keep_state_and_data;
%% Manage reception of end exchange in empty inview, we restore the arcs to available.
%% As it is our inview that is empty, whatever the number of restored arcs, we stay in empty inview.

handle_event(
    info,
    #evt_end_exchange{exchanged_ulids = EndedExchangeUlids},
    empty_inview,
    #state{namespace = NameSpace} = State
) ->
    ?'log-info'(
        "spray Agent ~p : End exchange in empty inview, checking arcs still present: ~p",
        [NameSpace, EndedExchangeUlids]
    ),

    %% For each arc in exchanged ulids: if arc is still in exchanging state,
    %% then the exchange failed and we need to change lock and mark back as available
    lists:foreach(
        fun(Ulid) ->
            case bbsvx_arc_registry:get_arc(NameSpace, out, Ulid) of
                {ok, {#arc{status = exchanging, lock = Lock}, Pid}} ->
                    ?'log-info'(
                        "Arc ~p still in exchanging state, changing lock and marking available", [
                            Ulid
                        ]
                    ),
                    %% Arc is still present and in exchanging state - exchange failed
                    %% Change lock and mark as available again
                    NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),

                    Pid ! {send, #change_lock{current_lock = Lock, new_lock = NewLock}},
                    bbsvx_arc_registry:update_status(NameSpace, out, Ulid, available);
                {ok, {#arc{status = OtherStatus}, _Pid}} ->
                    ?'log-warning'("Arc ~p in unexpected status ~p during end_exchange", [
                        Ulid, OtherStatus
                    ]);
                {error, not_found} ->
                    ?'log-info'("Arc ~p not found (already exchanged/disconnected)", [Ulid])
            end
        end,
        EndedExchangeUlids
    ),

    {keep_state, State};
%% Manage reception of exchange cancelled, not sure how this could happen in empty inview
%% but we handle it anyway
%% We restore arcs to available
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #exchange_cancelled{reason = Reason}},
    empty_inview,
    #state{namespace = NameSpace, proposed_sample = ProposedSample} = State
) ->
    ?'log-warning'(
        "spray Agent ~p : empty_inview state, exchange cancelled :~p",
        [NameSpace, Reason]
    ),
    prometheus_counter:inc(<<"bbsvx_spray_exchange_cancelled">>, [NameSpace, Reason]),
    %% Check if we need to restore arcs to available
    lists:foreach(
        fun(#exchange_entry{ulid = ArcUlid}) ->
            case bbsvx_arc_registry:get_arc(NameSpace, out, ArcUlid) of
                {ok, {#arc{status = exchanging, lock = Lock}, Pid}} ->
                    ?'log-info'(
                        "Arc ~p still in exchanging state, changing lock and marking available", [
                            ArcUlid
                        ]
                    ),
                    %% Arc is still present and in exchanging state - exchange failed
                    %% Change lock and mark as available again
                    NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),

                    Pid ! {send, #change_lock{current_lock = Lock, new_lock = NewLock}},
                    bbsvx_arc_registry:update_status(NameSpace, out, ArcUlid, available);
                {ok, {#arc{status = OtherStatus}, _Pid}} ->
                    ?'log-warning'("Arc ~p in unexpected status ~p during exchange_cancelled", [
                        ArcUlid, OtherStatus
                    ]);
                {error, not_found} ->
                    ?'log-info'("Arc ~p not found (already exchanged/disconnected)", [ArcUlid])
            end
        end,
        ProposedSample
    ),
    {keep_state, State#state{
        current_exchange_peer = undefined,
        proposed_sample = [],
        incoming_sample = [],
        exchange_direction = undefined
    }};
%% Node quitted in empty inview
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_node_quitted{
                node_id = NodeId,
                reason = Reason,
                direction = Direction
            } =
                Evt
    },
    empty_inview,
    State
) ->
    ?'log-warning'(
        "spray Agent ~p : empty inview state, node quitted ~p with reason "
        "~p  direction ~p",
        [State#state.namespace, NodeId, Reason, Direction]
    ),
    %% Get only available arcs (not currently being exchanged)
    OutViewAvailable = bbsvx_arc_registry:get_available_arcs(State#state.namespace, out),
    InView = get_inview(State#state.namespace),
    ?'log-info'("Start manage quitted node ~p", [OutViewAvailable]),
    manage_quitted_node(OutViewAvailable, InView, Evt, State);
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Connected state %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_event(enter, _, connected, #state{namespace = NameSpace} = State) ->
    ?'log-info'("spray Agent ~p : Entering connected state", [NameSpace]),
    {keep_state, State};
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_connected_out{target = TargetNode}
    },
    connected,
    #state{namespace = NameSpace} = StateData
) ->
    ?'log-info'("spray Agent ~p : Arc connected out : ~p", [NameSpace, TargetNode]),
    {next_state, connected, StateData};


handle_event(
    info,
    #incoming_event{
        origin_arc = Ulid,
        event =
            #evt_arc_connected_in{
                source = Source,
                lock = Lock,
                connection_type = register
            }
    },
    connected,
    #state{namespace = NameSpace, my_node = MyNode} = StateData
) ->
    ?'log-info'("spray Agent ~p : New incoming arc : ~p", [NameSpace, Source]),

    case bbsvx_actor_ontology:get_current_index(NameSpace) of
        {ok, CurrentIndex} ->
            Arc =
                #arc{
                    ulid = Ulid,
                    lock = Lock,
                    source = Source,
                    target = MyNode,
                    age = 0
                },
            ?'log-info'(
                "spray Agent ~p : Sending registration info to peer ~p "
                "(current_index=~p)",
                [NameSpace, Source, CurrentIndex]
            ),
            send(
                NameSpace,
                Ulid,
                in,
                #registered{
                    registered_arc = Arc,
                    current_index = CurrentIndex,
                    leader = <<>>
                }
            ),

                    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
                    case OutView of
                        [] ->
                            ?'log-warning'(
                                "spray Agent ~p : Running state, New arc in, but empty outview, conneting to it",
                                [NameSpace]
                            ),
                            open_connection(NameSpace, MyNode, Source, []);
                        _ ->
                            ?'log-info'(
                                "spray Agent ~p : Running state, New arc in, spreading to ~p neighbours",
                                [NameSpace, length(OutView)]
                            ),
                            %% Broadcast forward subscription to all nodes in the outview
                            lists:foreach(
                                fun({_, Pid}) ->
                                    Pid ! {send, #open_forward_join{lock = Lock, subscriber_node = Source}}
                                end,
                                OutView
                            )
                    end;
  
        Error ->
            ?'log-warning'(
                "spray Agent ~p : Failed to get current_index for registration: ~p",
                [NameSpace, Error]
            )
    end,
    {next_state, connected, StateData};


handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_arc_connected_in{
                source = Source,
                connection_type = forward_join
            }
    },
    connected,
    #state{namespace = NameSpace} = State
) ->
    ?'log-info'(
        "spray Agent ~p : connected state, New incoming forward join from ~p",
        [NameSpace, Source]
    ),
    {next_state, connected, State};


handle_event(info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_arc_connected_in{
                source = Source,
                connection_type = mirror
            }
    },
    connected,
    #state{namespace = NameSpace, my_node = MyNode}
) ->
    %% Check if we have at least one node in outview.
    %% If outview is empty, log a notice and move to empty outview state
    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
    case OutView of
        [] ->
            ?'log-notice'(
                "spray Agent ~p : connected state, New incoming mirrored arc from ~p, made empty outview, moving to empty_outview",
                [NameSpace, Source]
            ),
            {next_state, empty_outview, #state{namespace = NameSpace, my_node = MyNode}};
        _ ->
            ?'log-info'(
                "spray Agent ~p : connected state, New incoming mirrored arc from ~p",
                [NameSpace, Source]
            ),
            {next_state, connected, #state{namespace = NameSpace, my_node = MyNode}}
    end; 


handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_arc_disconnected{ulid = DisconnectedUlid, direction = out}
    },
    connected,
    #state{namespace = NameSpace} = State
) ->
    case bbsvx_arc_registry:get_available_arcs(NameSpace, out) of
        [] ->
            ?'log-warning'(
                "spray Agent ~p : Arc Out disconnected :~p, empty outview",
                [State#state.namespace, DisconnectedUlid]
            ),

            {next_state, empty_outview, State};
        _ ->
            keep_state_and_data
    end;
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #evt_arc_disconnected{ulid = Ulid, direction = in}
    },
    connected,
    #state{namespace = NameSpace} = State
) ->
    case bbsvx_arc_registry:get_available_arcs(NameSpace, in) of
        [] ->
            ?'log-warning'(
                "spray Agent ~p : Arc In disconnected :~p, empty inview",
                [State#state.namespace, Ulid]
            ),

            {next_state, empty_inview, State};
        _ ->
            keep_state_and_data
    end;
handle_event(
    info,
    #incoming_event{origin_arc = _Ulid, event = #evt_arc_swapped_in{}},
    connected,
    _StateData
) ->
    %% Arc swap notification - no action needed, connection is already updated
    keep_state_and_data;
%% Manage forward join request
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event = #open_forward_join{subscriber_node = SubscriberNode}
    } = Event,
    CurrentState,
    #state{namespace = NameSpace, my_node = MyNode}
) ->
    ?'log-info'(
        "DIAGNOSTIC: spray Agent ~p in state ~p received forward_join: ~p",
        [NameSpace, CurrentState, Event]
    ),
    case CurrentState of
        connected ->
            %% Openning forwarded join request from registration of SubscriberNode
            ?'log-info'("DIAGNOSTIC: Opening connection to subscriber ~p", [SubscriberNode]),
            open_connection(NameSpace, MyNode, SubscriberNode, []),
            keep_state_and_data;
        empty_outview ->
            %% Openning forwarded join request from registration of SubscriberNode
            ?'log-info'("DIAGNOSTIC: (empty_outview) Opening connection to subscriber ~p", [
                SubscriberNode
            ]),
            open_connection(NameSpace, MyNode, SubscriberNode, []),
            keep_state_and_data;
        _Other ->
            ?'log-warning'("DIAGNOSTIC: Ignoring forward_join in state ~p", [CurrentState]),
            keep_state_and_data
    end;
handle_event(
    info,
    spray_time,
    connected,
    #state{
        namespace = NameSpace,
        my_node = MyNode,
        current_exchange_peer = undefined
    } =
        State
) ->
    ?'log-info'("spray Agent ~p : Running state, spray time", [NameSpace]),

    %% increase age of outview via arc_registry
    %% TODO: optimize by having a bulk age update function in arc_registry
    OutViewAll = bbsvx_arc_registry:get_all_arcs(NameSpace, out),
    lists:foreach(
        fun({#arc{ulid = Ulid}, _}) -> bbsvx_arc_registry:update_age(NameSpace, out, Ulid) end,
        OutViewAll
    ),

    %% Get only available arcs (not currently being exchanged)
    OutViewAvailable = bbsvx_arc_registry:get_available_arcs(NameSpace, out),

    case length(OutViewAvailable) of
        L when L < 2 ->
            ?'log-info'(
                "spray Agent ~p : Running state, Not enough arcs for exchange (~p), skipping",
                [State#state.namespace, L]
            ),

            {keep_state, State#state{}};
        _ ->
            %% Log arc ages for debugging
            ArcAges = [Arc#arc.age || {Arc, _} <- OutViewAvailable],
            ?'log-info'(
                "spray Agent ~p : Starting exchange, Candidate ages: ~p",
                [NameSpace, ArcAges]
            ),

            %% Get oldest arc
            {#arc{ulid = Ulid, age = SelectedAge} = OldestArc, OldestArcPid} = get_oldest_arc(
                OutViewAvailable
            ),

            ?'log-info'(
                "Actor exchanger ~p : Doing exchange with node ~p  on arc ~p (age ~p)",
                [NameSpace, OldestArc#arc.target, OldestArc#arc.ulid, SelectedAge]
            ),

            %% Reset age of selected arc immediately to rotate selection for next round
            reset_age(NameSpace, Ulid),
            ?'log-info'("spray Agent ~p : Reset age for arc ~p", [NameSpace, Ulid]),

            %% Partialview without oldest Arc - extract just arcs for keytake
            OutViewArcsOnly = [Arc || {Arc, _} <- OutViewAvailable],
            {_, _, PartialViewWithoutOldest} =
                lists:keytake(Ulid, #arc.ulid, OutViewArcsOnly),

            %% Get sample from out view without oldest
            {Sample, _KeptArcs} = get_random_sample(PartialViewWithoutOldest),

            %% reAdd oldest node
            SamplePlusOldest = [OldestArc | Sample],
            %% Replace all occurences of oldest node in samplePlusOldest
            %% by our node, to avoid target doing loops
            FinalSample =
                lists:map(
                    fun
                        (#arc{target = #node_entry{node_id = TargetNodeId}} = Arc) when
                            TargetNodeId == OldestArc#arc.target#node_entry.node_id
                        ->
                            Arc#arc{target = MyNode};
                        (Arc) ->
                            Arc
                    end,
                    SamplePlusOldest
                ),
            ?'log-info'("Actor exchanger : unmodified sample sent ~p", [FinalSample]),

            %% Prepare Proposed sample as list of exchange_entry
            ProposedSample =
                [
                    #exchange_entry{
                        ulid = Arc#arc.ulid,
                        lock = Arc#arc.lock,
                        target = Arc#arc.target
                    }
                 || Arc <- FinalSample
                ],

            %% Mark all proposed arcs as 'exchanging' in registry to prevent re-selection
            lists:foreach(
                fun(#exchange_entry{ulid = ArcUlid}) ->
                    bbsvx_arc_registry:update_status(NameSpace, out, ArcUlid, exchanging)
                end,
                ProposedSample
            ),

            %% Send exchange in proposition to oldest node
            OldestArcPid ! {send, #exchange_in{proposed_sample = ProposedSample}},

            ?'log-info'(
                "Actor exchanger ~p : Running state, Sent partial view exchange "
                "in to ~p   sample : ~p",
                [State#state.namespace, OldestArc#arc.target, ProposedSample]
            ),

            {next_state, connected,
                State#state{
                    current_exchange_peer = OldestArc,
                    exchange_direction = out,
                    proposed_sample = ProposedSample
                },
                ?WAIT_EXCHANGE_OUT_TIMEOUT}
    end;
handle_event(
    info,
    spray_time,
    connected,
    #state{current_exchange_peer = CurrentExchangePeer} = State
) when
    CurrentExchangePeer =/= undefined
->
    ?'log-info'(
        "spray Agent ~p : Running state, spray time while exchanging, "
        "ignoring exchange",
        [State#state.namespace]
    ),

    keep_state_and_data;


handle_event(
    info,
    #incoming_event{
        origin_arc = OriginUlid,
        event = #exchange_in{proposed_sample = IncomingSample}
    },
    connected,
    #state{
        namespace = NameSpace,
        current_exchange_peer = undefined,
        my_node = MyNode
    } =
        State
) ->
    %% First, security check: verify the exchange comes from a node in our inview
    InViewArcs = bbsvx_arc_registry:get_available_arcs(NameSpace, in),
    InViewArcsOnly = [Arc || {Arc, _} <- InViewArcs],

    case lists:keyfind(OriginUlid, #arc.ulid, InViewArcsOnly) of
        false ->
            %% Exchange from unknown node - reject for security
            ?'log-warning'(
                "spray Agent ~p : Running state, exchange in from unknown node ~p, rejecting",
                [NameSpace, OriginUlid]
            ),
            send_reject(NameSpace, in, OriginUlid, exchange_in_unknown_node),
            prometheus_counter:inc(
                <<"spray_exchange_rejected">>,
                [NameSpace, exchange_in_unknown_node]
            ),
            {keep_state, State};
        #arc{source = SourceNode} = ExchangeArc ->
            ?'log-info'(
                "spray Agent ~p : Running state, exchange in received from ~p, inview size=~p",
                [NameSpace, OriginUlid, length(InViewArcs)]
            ),

            %% Count how many entries in the sample have target == initiator (SourceNode)
            %% These entries will trigger mirror operations during swap_connections,
            %% converting our inview arcs to outview arcs
            MirrorCount = length([
                Entry || #exchange_entry{target = #node_entry{node_id = TargetNodeId}} = Entry
                    <- IncomingSample,
                    TargetNodeId == SourceNode#node_entry.node_id
            ]),

            %% Check if exchange would leave us with empty inview
            %% We lose MirrorCount inview arcs during the exchange
            WouldBeEmptyInview = (length(InViewArcs) - MirrorCount) =< 0,

            case WouldBeEmptyInview of
                true ->
                    %% Exchange would empty our inview - reject it
                    ?'log-info'(
                        "spray Agent ~p : Running state, exchange in from ~p would "
                        "empty inview (inview=~p, mirrors=~p), rejecting",
                        [NameSpace, OriginUlid, length(InViewArcs), MirrorCount]
                    ),
                    send_reject(NameSpace, in, OriginUlid, exchange_in_empty_inview),
                    prometheus_counter:inc(
                        <<"spray_exchange_rejected">>,
                        [NameSpace, exchange_in_empty_inview]
                    ),
                    {keep_state, State#state{
                        current_exchange_peer = undefined,
                        exchange_direction = undefined,
                        proposed_sample = [],
                        incoming_sample = []
                    }};
                false ->
                    ?'log-info'(
                        "Actor exchanger ~p : starting exchange proposed by arc ~p ~n "
                        "Incoming sample : ~p",
                        [NameSpace, OriginUlid, IncomingSample]
                    ),
                    ?'log-info'(
                        "spray Agent ~p : Arc ~p    Matching node ~p",
                        [NameSpace, OriginUlid, SourceNode]
                    ),
                    %% Get only available arcs (not currently being exchanged)
                    OutViewAvailable = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
                    OutViewArcsOnly = [Arc || {Arc, _} <- OutViewAvailable],

                    {MySample, _KeptArcs} = get_big_random_sample(OutViewArcsOnly),

                    %% Change every occurence of target node in the sample by our node
                    %% to avoid loops
                    MySampleWithoutTarget =
                        lists:map(
                            fun
                                (#arc{target = #node_entry{node_id = TargetNodeId}} = Arc) when
                                    TargetNodeId == SourceNode#node_entry.node_id
                                ->
                                    Arc#arc{target = MyNode};
                                (Arc) ->
                                    Arc
                            end,
                            MySample
                        ),

                    %% Turn sample into exchange_entry
                    MySampleEntry =
                        [
                            #exchange_entry{
                                ulid = Arc#arc.ulid,
                                lock = Arc#arc.lock,
                                target = Arc#arc.target
                            }
                         || Arc <- MySampleWithoutTarget
                        ],

                    %% Send our sample to the origin node
                    ?'log-info'(
                        "Actor exchanger ~p : responding state, Sent partial view exchange "
                        "out to ~p   sample : ~p",
                        [NameSpace, OriginUlid, MySampleEntry]
                    ),

                    %% Mark all proposed arcs as 'exchanging' in registry to prevent re-selection
                    lists:foreach(
                        fun(#exchange_entry{ulid = ArcUlid}) ->
                            bbsvx_arc_registry:update_status(NameSpace, out, ArcUlid, exchanging)
                        end,
                        MySampleEntry
                    ),

                    %% Send exchange out to origin node
                    send(NameSpace, OriginUlid, in, #exchange_out{proposed_sample = MySampleEntry}),

                    {next_state, connected,
                        State#state{
                            proposed_sample = MySampleEntry,
                            incoming_sample = IncomingSample,
                            exchange_direction = in,
                            current_exchange_peer = ExchangeArc
                        },
                        ?WAIT_EXCHANGE_ACCEPT_TIMEOUT}
            end
    end;
handle_event(
    info,
    #incoming_event{origin_arc = OriginUlid, event = #exchange_in{}},
    connected,
    #state{current_exchange_peer = CurrentExchangePeer} = State
) when
    CurrentExchangePeer =/= undefined
->
    ?'log-info'(
        "spray Agent ~p : Running state, exchange in received while "
        "exchanging with ~p",
        [State#state.namespace, CurrentExchangePeer#arc.target]
    ),
    send_reject(State#state.namespace, in, OriginUlid, exchange_in_busy),
    prometheus_counter:inc(
        <<"spray_exchange_rejected">>,
        [State#state.namespace, exchange_in_busy]
    ),
    {keep_state, State};
handle_event(
    info,
    #incoming_event{
        event = #exchange_out{proposed_sample = IncomingSample},
        origin_arc = ArcUlid
    },
    connected,
    #state{
        namespace = NameSpace,
        my_node = #node_entry{node_id = MyNodeId} = MyNode,
        proposed_sample = ProposedSample,
        current_exchange_peer = CurrentExchangePeerArc
    } =
        State
) when
    CurrentExchangePeerArc =/= undefined
->
    ?'log-info'(
        "Actor exchanger ~p : Got partial view exchange out from ~p~nProposed "
        "sample ~p",
        [NameSpace, CurrentExchangePeerArc, IncomingSample]
    ),
    %% Remove occurrences of MyNode from incoming sample
    %% (connections with wrong locks will fail anyway)
    IncomingSampleWithoutMyNode =
        lists:filter(
            fun
                (#exchange_entry{target = #node_entry{node_id = TargetNodeId}}) when
                    TargetNodeId == MyNodeId
                ->
                    false;
                (_Entry) ->
                    true
            end,
            IncomingSample
        ),

    %% Get only available arcs (not currently being exchanged)
    OutViewAvailable = bbsvx_arc_registry:get_available_arcs(NameSpace, out),

    %% Check if exchange would leave us with empty outview
    %% We need to check: current available outview + incoming sample (without our node)
    WouldBeEmptyOutview = (OutViewAvailable == []) andalso (IncomingSampleWithoutMyNode == []),

    case WouldBeEmptyOutview of
        true ->
            %% Exchange would leave us with empty outview - cancel it
            ?'log-info'(
                "spray Agent ~p : connected state, exchange would cause empty outview, cancelling",
                [NameSpace]
            ),
            send(NameSpace, ArcUlid, out, #exchange_cancelled{
                reason = exchange_out_cause_empty_outview,
                namespace = NameSpace
            }),
            prometheus_counter:inc(
                <<"bbsvx_spray_exchange_cancelled">>,
                [NameSpace, exchange_out_cause_empty_outview]
            ),

            %% Mark proposed arcs back as available since exchange was cancelled
            lists:foreach(
                fun(#exchange_entry{ulid = Ulid}) ->
                    bbsvx_arc_registry:update_status(NameSpace, out, Ulid, available)
                end,
                ProposedSample
            ),

            {next_state, connected, State#state{
                current_exchange_peer = undefined,
                exchange_direction = undefined,
                proposed_sample = [],
                incoming_sample = []
            }};
        false ->
            ?'log-info'("spray Agent ~p : connected state, proceeding to exchange", [NameSpace]),

            Me = self(),
            %% Program removal of arcs from nodes to leave after timeout
            erlang:send_after(
                ?EXCHANGE_END_TIMEOUT,
                Me,
                #evt_end_exchange{
                    exchanged_ulids =
                        lists:map(
                            fun(#exchange_entry{ulid = Ulid}) ->
                                Ulid
                            end,
                            ProposedSample
                        )
                }
            ),
            %% Send exchange accept to oldest node
            send(NameSpace, ArcUlid, out, #exchange_accept{}),
            ?'log-info'("Connecting to incoming sample ~p", [IncomingSample]),

            %% start connecting to the proposed sample
            swap_connections(
                NameSpace,
                MyNode,
                CurrentExchangePeerArc#arc.target,
                IncomingSampleWithoutMyNode
            ),
            {next_state, connected, State#state{
                current_exchange_peer = undefined,
                proposed_sample = [],
                exchange_direction = undefined,
                incoming_sample = []
            }}
    end;
handle_event(
    info,
    #incoming_event{event = #exchange_accept{}},
    connected,
    #state{
        namespace = NameSpace,
        my_node = MyNode,
        current_exchange_peer = CurrentExchangePeer,
        incoming_sample = IncomingSample,
        proposed_sample = ProposedSample
    } =
        State
) when
    CurrentExchangePeer =/= undefined
->
    ?'log-info'(
        "spray Agent ~p : Exchange accepted, nodes to leave : ~p    "
        "~nNodes to join : ~p    exchange peer : ~p",
        [NameSpace, ProposedSample, IncomingSample, CurrentExchangePeer]
    ),

    swap_connections(NameSpace, MyNode, CurrentExchangePeer#arc.source, IncomingSample),
    Me = self(),
    %% Program removal of arcs from nodes to leave after timeout
    erlang:send_after(
        ?EXCHANGE_END_TIMEOUT,
        Me,
        #evt_end_exchange{
            exchanged_ulids =
                lists:map(
                    fun(#exchange_entry{ulid = Ulid}) -> Ulid end,
                    ProposedSample
                )
        }
    ),

    {next_state, connected, State#state{
        current_exchange_peer = undefined,
        exchange_direction = undefined,
        proposed_sample = [],
        incoming_sample = []
    }};
handle_event(
    info,
    #evt_end_exchange{exchanged_ulids = EndedExchangeUlids},
    connected,
    #state{namespace = NameSpace} = State
) ->
    ?'log-info'(
        "spray Agent ~p : End exchange, checking arcs still present: ~p",
        [NameSpace, EndedExchangeUlids]
    ),

    %% For each arc in exchanged ulids: if arc is still in exchanging state,
    %% then the exchange failed and we need to change lock and mark back as available
    %% Note: We use EndedExchangeUlids from the message, not ProposedSample from state,
    %% because state.proposed_sample is cleared by the exchange_accept handler before this fires
    lists:foreach(
        fun(Ulid) ->
            case bbsvx_arc_registry:get_arc(NameSpace, out, Ulid) of
                {ok, {#arc{status = exchanging, lock = Lock}, Pid}} ->
                    ?'log-info'(
                        "Arc ~p still in exchanging state, changing lock and marking available", [
                            Ulid
                        ]
                    ),
                    %% Arc is still present and in exchanging state - exchange failed
                    %% Change lock and mark as available again
                    NewLock = bbsvx_client_connection:get_lock(?LOCK_SIZE),
                    Pid ! {send, #change_lock{current_lock = Lock, new_lock = NewLock}},
                    bbsvx_arc_registry:update_status(NameSpace, out, Ulid, available);
                {ok, {#arc{status = OtherStatus}, _Pid}} ->
                    ?'log-warning'("Arc ~p in unexpected status ~p during end_exchange", [
                        Ulid, OtherStatus
                    ]);
                {error, not_found} ->
                    ?'log-info'("Arc ~p not found (already exchanged/disconnected)", [Ulid])
            end
        end,
        EndedExchangeUlids
    ),

    {keep_state, State};
handle_event(
    info,
    #incoming_event{event = #exchange_cancelled{reason = Reason}},
    connected,
    #state{
        namespace = NameSpace,
        current_exchange_peer = #arc{ulid = _PeerUlid},
        exchange_direction = out,
        proposed_sample = ProposedSample
    } =
        State
) ->
    ?'log-info'(
        "spray Agent ~p connced state : exchange cancelled out : ~p",
        [NameSpace, Reason]
    ),
    %% Note: Age was already reset when arc was selected for exchange
    prometheus_counter:inc(
        <<"bbsvx_spray_exchange_cancelled">>,
        [NameSpace, Reason]
    ),

    %% Mark proposed arcs back as available since exchange was cancelled
    lists:foreach(
        fun(#exchange_entry{ulid = Ulid}) ->
            bbsvx_arc_registry:update_status(NameSpace, out, Ulid, available)
        end,
        ProposedSample
    ),

    {next_state, connected, State#state{
        current_exchange_peer = undefined,
        exchange_direction = undefined,
        proposed_sample = [],
        incoming_sample = []
    }};
%%Manage node quitted
handle_event(
    info,
    #incoming_event{
        origin_arc = _Ulid,
        event =
            #evt_node_quitted{
                node_id = NodeId,
                reason = Reason,
                direction = Direction
            } =
                Evt
    },
    connected,
    State
) ->
    ?'log-warning'(
        "spray Agent ~p : Running state, node quitted ~p with reason "
        "~p  direction ~p",
        [State#state.namespace, NodeId, Reason, Direction]
    ),

    %% Get only available arcs (not currently being exchanged)
    OutViewAvailable = bbsvx_arc_registry:get_available_arcs(State#state.namespace, out),
    InView = get_inview(State#state.namespace),

    ?'log-info'("Start manage quitted node ~p", [OutViewAvailable]),
    manage_quitted_node(OutViewAvailable, InView, Evt, State);
%% Catch all
handle_event(Type, Msg, StateName, StateData) ->
    ?'log-warning'(
        "spray Agent ~p :State:~p Received unhandled message ~p ~p~n "
        "Statedata : ~p",
        [StateData#state.namespace, StateName, Type, Msg, StateData]
    ),
    keep_state_and_data.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-doc """
Initiate proposed connections received from an exchange.

Creates new outgoing connections to nodes provided in the incoming sample from
an exchange peer, handling mirroring and normal swaps as appropriate.
""".
-spec swap_connections(binary(), node_entry(), node_entry(), [exchange_entry()]) -> ok.
swap_connections(
    NameSpace,
    MyNode,
    #node_entry{node_id = ExchangePeerNodeId},
    IncomingSample
) ->
    ?'log-info'(
        "spray Agent ~p : Swapping connections with ~p",
        [NameSpace, ExchangePeerNodeId]
    ),
    lists:foreach(
        fun
            (
                #exchange_entry{target = #node_entry{node_id = TargetNodeId}} =
                    ExchangeEntry
            ) when
                TargetNodeId == ExchangePeerNodeId
            ->
                ?'log-info'(
                    "spray Agent ~p : mirror Swapping arc ~p to ~p",
                    [NameSpace, ExchangeEntry#exchange_entry.ulid, TargetNodeId]
                ),
                swap_connection(NameSpace, MyNode, mirror, ExchangeEntry);
            (ExchangeEntry) ->
                ?'log-info'(
                    "spray Agent ~p : normal Swapping arc ~p to ~p",
                    [
                        NameSpace,
                        ExchangeEntry#exchange_entry.ulid,
                        ExchangeEntry#exchange_entry.target#node_entry.node_id
                    ]
                ),
                swap_connection(NameSpace, MyNode, normal, ExchangeEntry)
        end,
        IncomingSample
    ).

%%-----------------------------------------------------------------------------
%% @doc
%% swap_connection/4
%% Initiate a connection proposed during and exchange.
%% The target node we are connecting to, when connected, will disconnected
%% the connection with same ulid
%% @end
%% ----------------------------------------------------------------------------

-spec swap_connection(
    NameSpace :: binary(),
    MyNode :: node_entry(),
    Type :: mirror | normal,
    ExchangeEntry :: exchange_entry()
) ->
    supervisor:startchild_ret().
swap_connection(
    NameSpace,
    MyNode,
    Type,
    #exchange_entry{
        target = TargetNode,
        ulid = Ulid,
        lock = Lock
    }
) ->
    supervisor:start_child(
        bbsvx_sup_client_connections,
        [join, NameSpace, MyNode, TargetNode, Ulid, Lock, Type, []]
    ).

%%-----------------------------------------------------------------------------
%% @doc
%% open_connection/4
%% Open a connection in case of a forard join request
%% TODO: This function is badly named, it should be renamed to reflect the fact
%% this is a forward join request
%% @end
%% ----------------------------------------------------------------------------

-spec open_connection(
    NameSpace :: binary(),
    MyNode :: node_entry(),
    TargetNode :: node_entry(),
    Options :: list()
) ->
    supervisor:startchild_ret().
open_connection(NameSpace, MyNode, TargetNode, Options) ->
    supervisor:start_child(
        bbsvx_sup_client_connections,
        [forward_join, NameSpace, MyNode, TargetNode, Options]
    ).

%%-----------------------------------------------------------------------------
%% @doc
%% terminate_connection/3
%% Terminate a connection identified by Ulid, using direction Direction and
%% reason Reason.
%% @end
%% ----------------------------------------------------------------------------
-spec terminate_connection(
    NameSpace :: binary(), Ulid :: binary(), Direction :: in | out, Reason :: atom()
) ->
    ok.
terminate_connection(NameSpace, Ulid, Direction, Reason) ->
    %% Signal we are closing the connection
    %% to the other side
    send(NameSpace, Ulid, Direction, #node_quitting{reason = Reason}),
    bbsvx_arc_registry:send(NameSpace, Direction, Ulid, {terminate, Reason}).

%%-----------------------------------------------------------------------------
%% @doc
%% send/4
%% Send a message over an arc
%% @end

-spec send(NameSpace :: binary(), Ulid :: binary(), Direction :: in | out, Payload :: term()) -> ok.
send(NameSpace, Ulid, Direction, Payload) ->
    ?'log-info'("DIAGNOSTIC: Sending ~p to arc {~p, ~p}", [Payload, Direction, Ulid]),
    case bbsvx_arc_registry:send(NameSpace, Direction, Ulid, Payload) of
        ok ->
            ?'log-info'("spray Agent : Message sent ~p ~p ~p", [Ulid, Direction, Payload]);
        {error, not_found} ->
            ?'log-warning'(
                "spray Agent : Failed to send message to arc ~p ~p - "
                "arc already disconnected or not registered. Payload: ~p",
                [Direction, Ulid, Payload]
            )
    end,
    ok.

%%-----------------------------------------------------------------------------
%% @doc
%% send_reject/4
%% Send a reject message directly to an arc connection process.
%% This bypasses bbsvx_arc_registry:send/4 which wraps messages in {send, ...},
%% allowing the server_connection's {reject, Reason} handler to match correctly.
%% @end
%% ----------------------------------------------------------------------------

-spec send_reject(NameSpace :: binary(), Direction :: in | out, Ulid :: binary(), Reason :: atom()) ->
    ok.
send_reject(NameSpace, Direction, Ulid, Reason) ->
    case bbsvx_arc_registry:get_arc(NameSpace, Direction, Ulid) of
        {ok, {_Arc, Pid}} ->
            Pid ! {reject, Reason},
            ok;
        {error, not_found} ->
            ?'log-warning'(
                "spray Agent : Failed to send reject to arc ~p ~p - "
                "arc not found. Reason: ~p",
                [Direction, Ulid, Reason]
            ),
            ok
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% register_to_node/3
%% Register to a node. This is to be called when contacting a node to request
%% to join the namespace.
%% @end
%% ----------------------------------------------------------------------------

-spec register_to_node(binary(), node_entry(), node_entry()) ->
    supervisor:startchild_ret().
register_to_node(NameSpace, MyNode, ContactNode) ->
    supervisor:start_child(
        bbsvx_sup_client_connections,
        [
            register,
            NameSpace,
            MyNode,
            ContactNode#node_entry{host = ContactNode#node_entry.host},
            []
        ]
    ).

%%-----------------------------------------------------------------------------
%% @doc
%% register_namespace/3
%% Join namespace by sending register requests to the lists of nodes
%% Return list of nodes that failed to start registering, empty list if all
%% nodes succeeded to connection bootup
%% @end
%% ----------------------------------------------------------------------------

-spec register_namespace(binary(), node_entry(), [node_entry()]) ->
    [{node_entry(), any()}].
register_namespace(NameSpace, MyNode, ContactNodes) ->
    ?'log-info'("spray Agent ~p : Registering to nodes ~p", [NameSpace, ContactNodes]),
    lists:foldl(
        fun(Node, FailedNodes) ->
            ?'log-debug'("Registering to node ~p", [Node]),
            case register_to_node(NameSpace, MyNode, Node) of
                {ok, _} -> FailedNodes;
                {error, Reason} -> [{Node, Reason} | FailedNodes];
                ignore -> FailedNodes
            end
        end,
        [],
        ContactNodes
    ).

-spec manage_quitted_node([{arc(), pid()}], [{arc(), pid()}], term(), state()) ->
    gen_statem:state_function_result().
manage_quitted_node(
    FilteredOutView,
    InView,
    #evt_node_quitted{reason = Reason, node_id = TargetNodeId} = Evt,
    #state{namespace = NameSpace} = State
) when
    TargetNodeId =/= undefined
->
    ?'log-info'(
        "spray Agent ~p : Running state, quitted node ~p with reason ~p",
        [NameSpace, TargetNodeId, Reason]
    ),
    %% Remove target_nde from outview and count number of time it appears
    {CountRemovedOut, FutureOutView} = filter_and_count(TargetNodeId, FilteredOutView),

    ?'log-info'("11", []),
    %% Remove target_node from inview
    {CountRemovedIn, FutureInView} = filter_and_count(TargetNodeId, InView),

    react_quitted_node(
        FutureOutView,
        CountRemovedOut,
        FutureInView,
        CountRemovedIn,
        Evt,
        State
    );
%% catch all
manage_quitted_node(FilteredOutView, InView, Evt, State) ->
    ?'log-warning'(
        "spray Agent ~p : Running state, quitted node, unhandled case "
        "Outview ~p  Inview ~p  Event ~p ~n State ~p",
        [State#state.namespace, FilteredOutView, InView, Evt, State]
    ),
    {keep_state, State}.

%% Will leave us without connectection, we neeed to reregister
-spec react_quitted_node([{arc(), pid()}], integer(), [{arc(), pid()}], integer(), term(), state()) ->
    gen_statem:state_function_result().
react_quitted_node(
    [],
    _,
    [],
    _,
    #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
    #state{
        namespace = NameSpace,
        my_node = MyNode,
        contact_nodes = ContactNodes
    } =
        State
) ->
    ?'log-info'(
        "Node ~p quitted with reason ~p, Reacting to isolation by re-registering",
        [QuittedNodeId, Reason]
    ),
    %% Select random node from contact nodes and re-register
    %% TODO: What if node that quitted is the only node in contact nodes
    RandomNode =
        lists:nth(
            rand:uniform(length(ContactNodes)), ContactNodes
        ),

    supervisor:start_child(
        bbsvx_sup_client_connections,
        [register, NameSpace, MyNode, RandomNode, []]
    ),
    ?'log-info'("13", []),
    {keep_state, State};
%% Manage empty outview
react_quitted_node(
    [],
    _,
    FilteredInView,
    _,
    #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
    #state{namespace = NameSpace, my_node = MyNode} = State
) ->
    ?'log-info'(
        "Node ~p quitted with reason ~p, empty outview, joining node "
        "in inview",
        [QuittedNodeId, Reason]
    ),
    %% get random node from InView
    {#arc{source = TargetNode}, _} =
        lists:nth(
            rand:uniform(length(FilteredInView)), FilteredInView
        ),

    supervisor:start_child(
        bbsvx_sup_client_connections,
        [forward_join, NameSpace, MyNode, TargetNode, []]
    ),
    {keep_state, State};
%% Manage empty inview
react_quitted_node(
    FilteredOutView,
    _,
    [],
    _,
    #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
    #state{namespace = NameSpace, my_node = MyNode} = State
) ->
    ?'log-info'(
        "Node ~p quitted with reason ~p, ack node in outview to foin me",
        [QuittedNodeId, Reason]
    ),
    %% get random node from Outview and ask it to connect to us
    {#arc{ulid = DestUlid}, _} =
        lists:nth(
            rand:uniform(length(FilteredOutView)), FilteredOutView
        ),
    %%TODO: For now we do it as forward join but we should create a dedicated pro
    %% to handle this case
    send(NameSpace, DestUlid, out, #open_forward_join{
        lock = <<"Depleted">>, subscriber_node = MyNode
    }),
    {keep_state, State};
%% Manage normal case
react_quitted_node(
    FilteredOutView,
    CountRemovedOut,
    _FilteredInView,
    _CountRemovedIn,
    #evt_node_quitted{node_id = QuittedNodeId, reason = Reason},
    #state{namespace = NameSpace, my_node = MyNode} = State
) ->
    ?'log-info'(
        "Node ~p quitted with reason ~p, Recreating connections. FilteredOutV"
        "iew ~p  count ~p",
        [QuittedNodeId, Reason, FilteredOutView, CountRemovedOut]
    ),
    case CountRemovedOut > 1 of
        true ->
            lists:foreach(
                fun(IndexL) ->
                    Rand = rand:uniform(),
                    ?'log-info'(
                        "spray Agent : Rand is ~p   gap is ~p",
                        [Rand, 1 / (CountRemovedOut + IndexL - 1)]
                    ),

                    case Rand of
                        X when X > 1 / (CountRemovedOut + IndexL - 1) ->
                            %% Select a random arc
                            {RandomArc, _} =
                                lists:nth(
                                    rand:uniform(length(FilteredOutView)),
                                    FilteredOutView
                                ),
                            supervisor:start_child(
                                bbsvx_sup_client_connections,
                                [
                                    forward_join,
                                    NameSpace,
                                    MyNode,
                                    RandomArc#arc.target,
                                    []
                                ]
                            );
                        _ ->
                            ok
                    end
                end,
                lists:seq(1, CountRemovedOut - 1)
            );
        false ->
            ok
    end,
    {keep_state, State};
%% catch all
react_quitted_node(
    FilteredOutView,
    CountRemovedOut,
    FilteredInView,
    CountRemovedIn,
    Evt,
    State
) ->
    ?'log-info'(
        "spray Agent ~p : Running state, quitted node, unhandled case "
        "Outview ~p  RemovedOutCount : ~p InView ~p RemovedInCount ~p "
        "~n Event ~p ~n State ~p",
        [
            State#state.namespace,
            FilteredOutView,
            CountRemovedOut,
            FilteredInView,
            CountRemovedIn,
            Evt,
            State
        ]
    ),
    {keep_state, State}.

%%-----------------------------------------------------------------------------
%% @doc
%% reset_age/2
%% Reset the age of a node
%% @end
%% ----------------------------------------------------------------------------

-spec reset_age(NameSpace :: binary(), Ulid :: binary()) -> ok.
reset_age(NameSpace, Ulid) ->
    bbsvx_arc_registry:reset_age(NameSpace, out, Ulid),
    ok.

%%-----------------------------------------------------------------------------
%% @doc
%% get_oldest_arc/1
%% Get the oldest arc in a view
%% @end
%% ----------------------------------------------------------------------------

-spec get_oldest_arc([{arc(), pid()}]) -> {arc(), pid()}.
get_oldest_arc([ArcPid]) ->
    ArcPid;
get_oldest_arc(ArcsPids) ->
    %% Sort by arc age ascending - need custom sort for tuples
    Sorted = lists:sort(fun({Arc1, _}, {Arc2, _}) -> Arc1#arc.age =< Arc2#arc.age end, ArcsPids),
    %% Get maximum age
    {LastArc, _} = lists:last(Sorted),
    MaxAge = LastArc#arc.age,
    %% Get all arcs with maximum age
    OldestArcs = [{Arc, Pid} || {Arc, Pid} <- Sorted, Arc#arc.age == MaxAge],
    %% If multiple arcs have same age, pick one randomly
    case OldestArcs of
        [SingleArcPid] -> SingleArcPid;
        Multiple -> lists:nth(rand:uniform(length(Multiple)), Multiple)
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% trigger_exchange/1
%% Triggered by timer to start an exchange
%% @end
%% ----------------------------------------------------------------------------

-spec trigger_exchange(pid()) -> supervisor:startchild_ret().
trigger_exchange(SprayPid) ->
    timer:sleep(?EXCHANGE_INTERVAL + rand:uniform(?EXCHANGE_JITTER)),
    SprayPid ! spray_time,
    trigger_exchange(SprayPid).

%%-----------------------------------------------------------------------------
%% @doc
%% get_big_random_sample/1
%% Like get_random_sample/1 but doesn't substract 1 when halving view size.
%% Used to select nodes to exchange when acting as exchange target
%% @end
%% ----------------------------------------------------------------------------

-spec get_big_random_sample([arc()]) -> {[arc()], [arc()]}.
get_big_random_sample([]) ->
    {[], []};
get_big_random_sample([Arc] = _View) ->
    {[Arc], []};
get_big_random_sample(View) ->
    %% Shuffle the view
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- View])],
    %% split the view in two
    {_Sample, _Rest} = lists:split(length(View) div 2, Shuffled).

%%-----------------------------------------------------------------------------
%% @doc
%% get_randm_sample/2
%% Get a random sample of nodes from a list of nodes.
%% returns the sample and the rest of the list.
%% Used to select nodes to exchange when acting as exchange initiator.
%% @end
%% ----------------------------------------------------------------------------
-spec get_random_sample([arc()]) -> {[arc()], [arc()]}.
get_random_sample([]) ->
    {[], []};
get_random_sample([_] = View) ->
    {[], View};
get_random_sample(View) ->
    %% Shuffle the view
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- View])],
    %% Calculate sample size: ⌊length/2⌋ - 1, but at least 1 if view has 2+ arcs
    %% The -1 accounts for the initiator losing the arc to the exchange peer
    %% But we need at least 1 arc to make the exchange useful for discovery
    RawSize = length(View) div 2 - 1,
    SampleSize =
        case length(View) of
            L when L >= 2 -> max(1, RawSize);
            _ -> RawSize
        end,
    %% split the view
    {_Sample, _Rest} = lists:split(SampleSize, Shuffled).

-doc """
Send payload to all connections in the outview.

Broadcasts the given payload to every connection process in the outview.
This is used for general message dissemination across the overlay network.

Returns: `ok`
""".
-spec broadcast(NameSpace :: binary(), Payload :: term()) -> ok.
broadcast(NameSpace, Payload) ->
    lists:foreach(fun({_, Pid}) -> Pid ! {send, Payload} end, bbsvx_arc_registry:get_available_arcs(NameSpace, out)).

-doc """
Send payload to all unique connections in the outview.

Gets all available arcs from the outview and sends the payload to each unique connection
process. This ensures each peer receives the message exactly once, used by EPTO for
transaction dissemination.

Returns: `ok`
""".
-spec broadcast_unique(NameSpace :: binary(), Payload :: term()) -> ok.
broadcast_unique(NameSpace, Payload) ->
    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
    lists:foreach(fun({_, Pid}) -> Pid ! {send, Payload} end, OutView).

-doc """
Send payload to a random subset of the view.

Selects N random unique arcs from the outview and broadcasts the payload to them.
Useful for probabilistic broadcast protocols that don't require full fanout.

Returns: `{ok, Count}` where Count is the number of nodes the payload was sent to
""".
-spec broadcast_unique_random_subset(
    NameSpace :: binary(),
    Payload :: term(),
    N :: integer()
) ->
    {ok, integer()}.
broadcast_unique_random_subset(NameSpace, Payload, N) ->
    RandomSubset = get_n_unique_random(NameSpace, N),
    lists:foreach(fun({#arc{ulid = Ulid}, _Pid}) -> send(NameSpace, Ulid, out, Payload) end, RandomSubset),
    {ok, length(RandomSubset)}.

-doc """
Get N unique random arcs from the outview or from a list.

When called with a binary namespace, retrieves available arcs from the outview and
returns N random selections. When called with a list, returns N random elements.

Returns: List of arcs or list elements
""".
-spec get_n_unique_random(binary(), N :: integer()) -> [arc()];
                         (list({term, Pid}), N :: integer()) -> [{term, Pid}].
get_n_unique_random(NameSpace, N) when is_binary(NameSpace) ->
    OutView = bbsvx_arc_registry:get_available_arcs(NameSpace, out),
    get_n_unique_random(OutView, N);
get_n_unique_random(List, N) ->
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- List])],
    lists:sublist(Shuffled, N).

-doc """
Get the inview of a namespace.

**IMPORTANT**: Uses `get_all_arcs` to count ALL arcs for "empty inview" checks,
not just available ones (an arc being exchanged is still a connection).

Returns: List of all incoming arcs
""".
-spec get_inview(binary()) -> [arc()].
get_inview(NameSpace) ->
    %% For empty check, we need ALL arcs - an arc in exchanging status is still there
    [Arc || {Arc, _} <- bbsvx_arc_registry:get_all_arcs(NameSpace, in)].

-doc """
Get ALL outview arcs (for visualization/debugging).

Returns all arcs regardless of status, used for visualization and debugging purposes.

Returns: List of all outgoing arcs
""".
-spec get_all_outview(binary()) -> [arc()].
get_all_outview(NameSpace) ->
    %% Get ALL arcs regardless of status for visualization
    [Arc || {Arc, _} <- bbsvx_arc_registry:get_all_arcs(NameSpace, out)].

-doc """
Get ALL inview arcs (for visualization/debugging).

Returns all arcs regardless of status, used for visualization and debugging purposes.

Returns: List of all incoming arcs
""".
-spec get_all_inview(binary()) -> [arc()].
get_all_inview(NameSpace) ->
    %% Get ALL arcs regardless of status for visualization
    [Arc || {Arc, _} <- bbsvx_arc_registry:get_all_arcs(NameSpace, in)].

-doc """
Get the combined views of a namespace (inview and outview).

Returns the union of inview and outview arcs, sorted. Only includes arcs with
`available` status.

Returns: Sorted list of all available arcs
""".
get_views(NameSpace) ->
    InView = [Arc || {Arc, _} <- bbsvx_arc_registry:get_available_arcs(NameSpace, in)],
    OutView = [Arc || {Arc, _} <- bbsvx_arc_registry:get_available_arcs(NameSpace, out)],
    lists:sort(InView ++ OutView).

format_host(Host) when is_binary(Host) ->
    Host;
format_host(Host) when is_list(Host) ->
    list_to_binary(Host);
format_host({A, B, C, D}) ->
    list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])).

-doc """
Filter out the target node from the sample and count removals.

Removes all arcs targeting the specified node ID from the sample and returns
the count of how many were removed along with the filtered sample.

Returns: `{Count, FilteredSample}` where Count is the number of arcs removed
""".
-spec filter_and_count(TargetNodeId :: binary(), [{arc(), pid()}]) -> {integer(), [{arc(), pid()}]}.
filter_and_count(TargetNodeId, Sample) ->
    lists:foldr(
        fun({#arc{target = #node_entry{node_id = NodeId}} = Arc, Pid}, {Count, NewSample}) ->
            case NodeId of
                TargetNodeId -> {Count + 1, NewSample};
                _ -> {Count, [{Arc, Pid} | NewSample]}
            end
        end,
        {0, []},
        Sample
    ).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

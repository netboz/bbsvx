%%%-----------------------------------------------------------------------------
%%% Gen State Machine built from template.
%%% @author yan
%%%-----------------------------------------------------------------------------

-module(bbsvx_arc_reporter_graph_visualizer).

-author("yan").

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-behaviour(gen_statem).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

-define(SERVER, ?MODULE).

%% External API
-export([start_link/0, stop/0, example_action/0]).
%% Gen State Machine Callbacks
-export([init/1, code_change/4, callback_mode/0, terminate/3]).
%% State transitions
-export([running/3]).
-export([do/1]).

-record(state, {my_id :: binary()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> gen_statem:start_ret().
start_link() ->
    gen_statem:start({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?SERVER).

-spec example_action() -> term().
example_action() ->
    gen_statem:call(?SERVER, example_action).

%%%=============================================================================
%%% Gen State Machine Callbacks
%%%=============================================================================

init([]) ->
    MyId = bbsvx_crypto_service:my_id(),
    gproc:reg({p, l, {spray_exchange, <<"bbsvx:root">>}}),
    ?'log-info'("Starting graph visualizer arc reporter with id: ~p", [MyId]),
    %% Get my host port
    {ok, {Host, _Port}} = bbsvx_network_service:my_host_port(),
    inets:start(),
    R = inets:start(
        httpd,
        [
            {port, 7080},
            {server_name, "simple_server"},
            {modules, [?MODULE]},
            {document_root, "/tmp"},
            % Not used in our custom handler
            {server_root, "/tmp"},
            {bind_address, Host}
        ]
    ),
    ?'log-info'("httpd started with result: ~p", [R]),
    {ok, running, #state{my_id = MyId}}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

callback_mode() ->
    state_functions.

%%%=============================================================================
%%% State transitions
%%%=============================================================================

running(
    info,
    #incoming_event{
        event =
            #evt_arc_connected_in{
                ulid = Ulid,
                source = #node_entry{node_id = NodeId}
            }
    },
    State
) ->
    %% Ensure both nodes exist in graph
    create_node_if_needed(NodeId),
    create_node_if_needed(State#state.my_id),

    Data =
        #{
            action => <<"add">>,
            ulid => Ulid,
            from => NodeId,
            to => State#state.my_id
        },
    Json = jiffy:encode(Data),
    ?'log-info'("Adding incoming arc: ~p -> ~p (ulid: ~p)", [NodeId, State#state.my_id, Ulid]),
    httpc:request(
        post,
        {"http://graph-visualizer:3400/edges/add", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
%% Handle outgoing arc connections
running(
    info,
    #incoming_event{
        event =
            #evt_arc_connected_out{
                ulid = Ulid,
                target = #node_entry{node_id = TargetNodeId}
            }
    },
    State
) ->
    %% Ensure both nodes exist in graph
    create_node_if_needed(State#state.my_id),
    create_node_if_needed(TargetNodeId),

    Data =
        #{
            action => <<"add">>,
            ulid => Ulid,
            from => State#state.my_id,
            to => TargetNodeId
        },
    Json = jiffy:encode(Data),
    ?'log-info'("Adding outgoing arc: ~p -> ~p (ulid: ~p)", [State#state.my_id, TargetNodeId, Ulid]),
    httpc:request(
        post,
        {"http://graph-visualizer:3400/edges/add", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
running(
    info,
    #incoming_event{
        event = #evt_arc_disconnected{
            ulid = Ulid, direction = in, origin_node = OriginNode, reason = Reason
        }
    },
    State
) ->
    %% Handle incoming arc disconnection - edge was FROM origin_node TO us
    Data =
        #{
            action => <<"remove">>,
            from => OriginNode#node_entry.node_id,
            ulid => Ulid,
            reason => normalize_reason(Reason)
        },
    Json = jiffy:encode(Data),
    ?'log-info'("Removing incoming arc: ~p -> ~p (ulid: ~p, reason: ~p)", [
        OriginNode#node_entry.node_id, State#state.my_id, Ulid, Reason
    ]),
    httpc:request(
        post,
        {"http://graph-visualizer:3400/edges/remove", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
running(
    info,
    #incoming_event{
        event = #evt_arc_disconnected{
            ulid = Ulid, direction = out, origin_node = OriginNode, reason = Reason
        }
    },
    State
) ->
    %% Handle outgoing arc disconnection - edge was FROM us TO origin_node
    Data =
        #{
            action => <<"remove">>,
            from => State#state.my_id,
            ulid => Ulid,
            reason => normalize_reason(Reason)
        },
    Json = jiffy:encode(Data),
    ?'log-info'("Removing outgoing arc: ~p -> ~p (ulid: ~p, reason: ~p)", [
        State#state.my_id, OriginNode#node_entry.node_id, Ulid, Reason
    ]),

    httpc:request(
        post,
        {"http://graph-visualizer:3400/edges/remove", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
%% manage node start
running(
    info,
    #incoming_event{
        event =
            {node_started, Namespace, #node_entry{
                node_id = NodeId,
                host = Host,
                port = Port
            }}
    },
    State
) ->
    %% Prepare body as json :
    %% {
    %   "action": "add",
    %   "node_id": "node12345",
    %   "metadata": {
    %     "host": Host,
    %    "port": Port,
    %   "namespace": Namespace,
    %  "node_id": NodeId
    %   }
    % }
    Data =
        #{
            action => <<"add">>,
            node_id => NodeId,
            metadata =>
                #{
                    host => Host,
                    port => Port,
                    namespace => Namespace,
                    node_id => NodeId
                }
        },
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    httpc:request(
        post,
        {"http://graph-visualizer:3400/nodes/add", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
running(
    info,
    #incoming_event{
        event =
            #evt_arc_swapped_in{
                ulid = Ulid,
                previous_source = PrevSource,
                new_source = NewSource,
                destination = Destination
            }
    },
    State
) ->
    %% Prepare body as json :
    %% {
    %% "action": "swap",
    %% "ulid": "unique-edge-id",
    %% "prevous_source": NodeId,
    %% "new_source": NodeId,
    %% "destination": NodeId
    %% }
    Data =
        #{
            action => <<"swap">>,
            ulid => Ulid,
            previous_source => PrevSource#node_entry.node_id,
            new_source => NewSource#node_entry.node_id,
            destination => Destination#node_entry.node_id
        },
    %% Encode Data to json
    Json = jiffy:encode(Data),

    %% Post json data to http://graph-visualizer/api/edges
    httpc:request(
        post,
        {"http://graph-visualizer:3400/edges/swap", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
running(
    info,
    #incoming_event{
        event =
            {node_stopped, Namespace, #node_entry{
                node_id = NodeId,
                host = Host,
                port = Port
            }}
    },
    State
) ->
    %% Prepare body as json :
    %% {
    %   "action": "add",
    %   "node_id": "node12345",
    %   "metadata": {
    %     "host": Host,
    %    "port": Port,
    %   "namespace": Namespace,
    %  "node_id": NodeId
    %   }
    % }
    Data =
        #{
            action => <<"add">>,
            node_id => NodeId,
            metadata =>
                #{
                    host => Host,
                    port => Port,
                    namespace => Namespace,
                    node_id => NodeId
                }
        },
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    httpc:request(
        post,
        {"http://graph-visualizer:3400/nodes/add", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
%% Handle node quitted events
running(
    info,
    #incoming_event{
        event = #evt_node_quitted{
            node_id = NodeId,
            host = Host,
            port = Port,
            reason = Reason
        }
    },
    State
) ->
    ?'log-info'("Node quitted: ~p (~p:~p) reason: ~p", [NodeId, Host, Port, Reason]),
    Data =
        #{
            action => <<"remove">>,
            node_id => NodeId,
            reason => normalize_reason(Reason)
        },
    Json = jiffy:encode(Data),
    httpc:request(
        post,
        {"http://graph-visualizer:3400/nodes", [], "application/json", Json},
        [],
        []
    ),
    {next_state, running, State};
%% Handle any other arc events we might have missed
running(
    info,
    #incoming_event{event = Event} = IncomingEvent,
    State
) ->
    {next_state, running, State};
%% Catch all - log unhandled events
running(Type, Event, State) ->
    ?'log-debug'("Unhandled event type ~p: ~p", [Type, Event]),
    {next_state, running, State}.

%%%=============================================================================
%%% Termination REST handler
%%% This is a simple REST handler that will either stop a node ( spray agent )
%%% or a connectioon ( in or out ) between two nodes, upon patssed json payload
%%% =============================================================================

do(Req) ->
    ?'log-info'("Received request: ~p", [Req]),
    case get_method(Req) of
        options ->
            % Handle preflight OPTIONS request
            handle_cors_preflight(Req);
        put ->
            handle_put(Req);
        _ ->
            {405, [], "Method Not Allowed"}
    end.

% Handle PUT requests
handle_put(_Req) ->
    % Process the PUT request body and respond
    {200, cors_headers(), <<"PUT request received">>}.

% Handle OPTIONS requests for preflight
handle_cors_preflight(_Req) ->
    %% Console log
    {204, cors_headers(), <<>>}.

% Utility function to determine the request method
get_method(Req) ->
    proplists:get_value(method, Req).

% Define CORS headers
cors_headers() ->
    % Allow all origins, or specify one
    [
        {"Access-Control-Allow-Origin", "*"},
        {"Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"},
        {"Access-Control-Allow-Headers", "Content-Type, Authorization"}
    ].

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% Convert any Erlang term to a JSON-safe binary string
normalize_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
normalize_reason(Reason) when is_binary(Reason) ->
    Reason;
normalize_reason(Reason) ->
    %% Convert complex terms (tuples, lists, etc.) to binary
    list_to_binary(io_lib:format("~p", [Reason])).

%% Create a node in the graph if it doesn't exist
create_node_if_needed(NodeId) when NodeId =/= undefined ->
    Data =
        #{
            action => <<"add">>,
            node_id => NodeId,
            metadata =>
                #{
                    node_id => NodeId,
                    auto_created => true
                }
        },
    Json = jiffy:encode(Data),
    httpc:request(
        post,
        {"http://graph-visualizer:3400/nodes", [], "application/json", Json},
        [],
        []
    );
create_node_if_needed(_) ->
    ok.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

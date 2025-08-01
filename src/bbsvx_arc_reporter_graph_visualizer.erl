%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
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
    Data =
        #{
            action => <<"add">>,
            ulid => Ulid,
            from => NodeId,
            to => State#state.my_id
        },
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %%?'log-info'("add edge post data: ~p", [Data]),
    %% Post json data to http://graph-visualizer/api/edges
    httpc:request(
        post,
        {"http://graph-visualizer:3400/edges/add", [], "application/json", Json},
        [],
        []
    ),
    %%?'log-info'("add edge response: ~p", [R]),
    {next_state, running, State};
running(
    info,
    #incoming_event{event = #evt_arc_disconnected{ulid = Ulid, direction = in}},
    State
) ->
    %% Handle incoming arc disconnection
    Data =
        #{
            action => <<"remove">>,
            from => State#state.my_id,
            ulid => Ulid
        },
    Json = jiffy:encode(Data),
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
        event = #evt_arc_disconnected{ulid = Ulid, direction = out, origin_node = OriginNode}
    },
    State
) ->
    %% Handle outgoing arc disconnection
    Data =
        #{
            action => <<"remove">>,
            from => OriginNode#node_entry.node_id,
            ulid => Ulid
        },
    Json = jiffy:encode(Data),
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
%% Catch all
running(_Type, _Msg, State) ->
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

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

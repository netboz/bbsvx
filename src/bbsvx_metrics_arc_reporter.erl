%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen State Machine built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_metrics_arc_reporter).

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

-record(state, {my_id :: binary()}).

-define(DELAY, 1000).

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

running(info,
        #incoming_event{event =
                            #evt_arc_connected_out{ulid = Ulid,
                                                   target = #node_entry{node_id = NodeId}}},
        State) ->
    %% Get outview and inview
    %% Build body as json :
    % {
    %     "action": "add",
    %     "ulid": "01GZCZXT82A01AXY71T5X3KG4Z",
    %     "from": "node1",
    %     "to": "node2"
    %   }
    Data =
        #{action => <<"add">>,
          ulid => Ulid,
          from => State#state.my_id,
          to => NodeId},
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %%?'log-info'("add edge post data: ~p", [Data]),
    %% Post json data to http://graph-visualizer/api/edges
    R = httpc:request(post,
                      {"http://graph-visualizer:3400/edges/add", [], "application/json", Json},
                      [],
                      []),
    %%?'log-info'("add edge response: ~p", [R]),
    {next_state, running, State};
running(info,
        #incoming_event{event = #evt_arc_disconnected{ulid = Ulid, direction = out}},
        State) ->
    %% Prepare body as json :
    %% {
    %% "action": "remove",
    %%  "from": "node1",
    %%  "ulid": "unique-edge-id"
    %%
    %% }
    Data =
        #{action => <<"remove">>,
          from => State#state.my_id,
          ulid => Ulid},
    %?'log-info'("remove edge post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/api/edges
    R = httpc:request(post,
                      {"http://graph-visualizer:3400/edges/remove", [], "application/json", Json},
                      [],
                      []),
    %?'log-info'("remove edge response: ~p", [R]),
    {next_state, running, State};
%% manage node start
running(info,
        #incoming_event{event =
                            {node_started,
                             Namespace,
                             #node_entry{node_id = NodeId,
                                         host = Host,
                                         port = Port}}},
        State) ->
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
        #{action => <<"add">>,
          node_id => NodeId,
          metadata =>
              #{host => Host,
                port => Port,
                namespace => Namespace,
                node_id => NodeId}},
    %?'log-info'("add node post data: ~p", [Data]),
    %% Encode Data to json
    Json = jiffy:encode(Data),
    %% Post json data to http://graph-visualizer/nodes
    R = httpc:request(post,
                      {"http://graph-visualizer:3400/nodes/add", [], "application/json", Json},
                      [],
                      []),
    {next_state, running, State};
%% Catch all
running(Type, Msg, State) ->
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

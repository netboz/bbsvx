%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_network_service).

-author("yan").

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").
-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/1, start_link/2, my_host_port/0]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([]).

-define(SERVER, ?MODULE).

%% Loop state
-record(state, {node_id = undefined, host, port}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

start_link([Host, Port]) ->
    start_link(Host, Port).

-spec start_link(Host :: nonempty_list() | [nonempty_list()], Port :: integer()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Host, Port) ->
    gen_server:start_link({via, gproc, {n, l, ?SERVER}}, ?MODULE, [Host, Port], []).

%%-----------------------------------------------------------------------------
%% @doc
%% Return the host/port of this node
%% @end
%% -----------------------------------------------------------------------------
-spec my_host_port() ->
                      {ok, {Host :: binary(), Port :: integer()}} | {error, not_started}.
my_host_port() ->
    case gproc:where({n, l, ?SERVER}) of
        undefined ->
            {error, not_started};
        Pid ->
            gen_server:call(Pid, my_host_port)
    end.

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Host, Port]) ->
    %% Publish my id to the welcome topic
    MyId = bbsvx_crypto_service:my_id(),
    {ok, _} =
        ranch:start_listener(bbsvx_spray_service,
                             ranch_tcp,
                             #{socket_opts => [{port, 2304}], max_connections => infinity},
                             bbsvx_server_connection,
                             [#node_entry{node_id = MyId,
                                          host = Host,
                                          port = Port}]),

    {ok,
     #state{node_id = MyId,
            host = Host,
            port = Port}}.

%% Handle request to get host port
-spec handle_call(Event :: term(), _From :: gen_server:from(), State :: state()) ->
                     term().
handle_call(my_host_port, _From, #state{host = Host, port = Port} = State) ->
    {reply, {ok, {Host, Port}}, State};
%% Manage connections to new nodes
%% Local connections are prevented
handle_call(Request, From, State) ->
   ?'log-warning'("Unmanaged handle_call/3 called with Request: "
                "~p, From: ~p, State: ~p",
                [Request, From, State]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

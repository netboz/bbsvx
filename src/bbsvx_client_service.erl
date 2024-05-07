%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_client_service).

-author("yan").

-behaviour(gen_server).

-include("bbsvx_common_types.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/1, start_link/2, my_host_port/0, register_connection/5,
         unregister_connection/5]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([]).

-define(SERVER, ?MODULE).

%% Loop state
-record(state,
        {connection_table :: atom() | term(),
         node_id = undefined,
         host,
         port,
         subscriptions :: term}).

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

-spec register_connection(Namespace :: binary(),
                          NodeId :: binary(),
                          Host :: binary(),
                          Port :: integer(),
                          Pid :: pid()) ->
                             ok | {error, atom()}.
register_connection(Namespace, NodeId, Host, Port, Pid) ->
    %% record the connection into ets table
    ets:insert(connection_table,
               #connection{node_id = NodeId,
                           host = Host,
                           namespace = Namespace,
                           port = Port,
                           pid = Pid}),

    ok.

unregister_connection(Namespace, NodeId, Host, Port, Pid) ->
    ets:delete(connection_table,
               #connection{node_id = NodeId,
                           host = Host,
                           namespace = Namespace,
                           port = Port,
                           pid = Pid}),
    ok.

broadcast(Nodes, Payload) ->
    %% Get all connections for this namespace
    Conns = ets:match(connection_table, #connection{namespace = Namespace}),
    lists:foreach(fun(#connection{pid = Pid}) ->
                         gen_server:cast(Pid, {broadcast, Payload})
                  end,
                  Conns).
%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Host, Port]) ->
    %% Publish my id to the welcome topic
    MyId = bbsvx_crypto_service:my_id(),
    logger:info("bbsvx_connections_service: My id is ~p", [MyId]),

    ConnTable = ets:new(connection_table, [bag, named_table, public, {keypos, 2}]),

    {ok,
     #state{connection_table = ConnTable,
            node_id = MyId,
            host = Host,
            port = Port,
            subscriptions = dict:new()}}.

%% Handle request to get host port
handle_call(my_host_port, _From, #state{host = Host, port = Port} = State) ->
    {reply, {ok, {Host, Port}}, State};
%% Manage connections to new nodes
%% Local connections are prevented
handle_call(_Request, _From, State) ->
    logger:info("bbsvx_connections_service:handle_call/3 called with Request: "
                "~p, From: ~p, State: ~p",
                [_Request, _From, State]),
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

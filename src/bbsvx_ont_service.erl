%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_service).

-author("yan").

-behaviour(gen_server).

-include("bbsvx.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/0, new_ontology/1, get_ontology/1, delete_ontology/1, new_goal/2,
         store_goal/1, get_goal/1, connect_ontology/1, disconnect_ontology/1, string_to_eterm/1,
         binary_to_table_name/1, table_exists/1]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(INDEX_LOAD_TIMEOUT, 30000).

%% Loop state
-record(state, {my_id :: binary()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Start the ontology service
%%% @returns {ok, Pid} if the service was started successfully, {error, Reason} otherwise
%%% @end

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Create a new ontology
%%% @param Ontology the ontology to create
%%% @returns ok if the ontology was created successfully, {error, Reason} otherwise
%%% @end

-spec new_ontology(ontology()) -> ok | {error, atom()}.
new_ontology(Namespace) ->
    gen_server:call(?SERVER, {new_ontology, Namespace, []}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get an ontology
%%% @param Namespace the namespace of the ontology to get
%%% @returns {ok, Ontology} if the ontology was found, {error, Reason} otherwise
%%% @end

-spec get_ontology(binary()) -> {ok, ontology()} | {error, atom()}.
get_ontology(Namespace) ->
    gen_server:call(?SERVER, {get_ontology, Namespace}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Delete an ontology
%%% @param Namespace the namespace of the ontology to delete
%%% @returns ok if the ontology was deleted successfully, {error, Reason} otherwise
%%% @end
%%%
-spec delete_ontology(Namespace :: binary()) -> ok | {error, atom()}.
delete_ontology(Namespace) ->
    gen_server:call(?SERVER, {delete_ontology, Namespace}).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Connect an ontology to the network
%%% @param Namespace the namespace of the ontology to connect
%%% @returns ok if the ontology was connected successfully, {error, Reason} otherwise
%%% @end

-spec connect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
connect_ontology(Namespace) ->
    gen_server:call(?SERVER, {connect_ontology, Namespace}).

-spec disconnect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Disconnect an ontology from the network
%%% @param Namespace the namespace of the ontology to disconnect
%%% @returns ok if the ontology was disconnected successfully, {error, Reason} otherwise
%%% @end
disconnect_ontology(Namespace) ->
    gen_server:call(?SERVER, {disconnect_ontology, Namespace}).

-spec store_goal(goal()) -> ok | {error, atom()}.
store_goal(Goal) ->
    gen_server:call(?SERVER, {store_goal, Goal}).

get_goal(GoalId) ->
    gen_server:call(?SERVER, {get_goal, GoalId}).

new_goal(Namespace, Predicate) ->
    gen_server:cast(?SERVER, {new_goal, Namespace, Predicate}).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([]) ->
    logger:info("Onto service : starting ontology service"),
    case have_index_table() of
        true ->
            logger:info("Onto service : waiting for index table ~p", [?INDEX_TABLE]),
            case mnesia:wait_for_tables([?INDEX_TABLE], ?INDEX_LOAD_TIMEOUT) of
                {timeout, _} ->
                    logger:error("Onto service : index table ~p load timeout", [?INDEX_TABLE]),
                    {error, index_table_timeout};
                _ ->
                    logger:info("Onto service : index table ~p loaded", [?INDEX_TABLE]),
                    MyId = bbsvx_crypto_service:my_id(),

                    {ok, #state{my_id = MyId}}
            end;
        false ->
            %% First time we start
            case mnesia:create_table(?INDEX_TABLE, [{attributes, record_info(fields, ontology)}]) of
                {atomic, ok} ->
                    MyId = bbsvx_crypto_service:my_id(),

                    case bbsvx_transaction:root_exits() of
                        true ->
                            ok;
                        false ->
                            bbsvx_transaction:new_root_ontology(),
                            %% Retrieve my host port
                            {ok, {MyHost, MyPort}} = bbsvx_network_service:my_host_port(),
                            ContactNodes =
                                [#node_entry{host = MyHost,
                                             port = MyPort,
                                             node_id = MyId}],
                            OntEntry =
                                #ontology{namespace = <<"bbsvx:root">>,
                                          version = <<"0.0.1">>,
                                          type = shared,
                                          contact_nodes = ContactNodes},
                            mnesia:activity(transaction, fun() -> mnesia:write(OntEntry) end)
                    end,
                    supervisor:start_child(bbsvx_sup_shared_ontologies, [<<"bbsvx:root">>, #{}]),
                    {ok, #state{my_id = MyId}};
                {aborted, {error, Reason}} ->
                    logger:info("Onto service : failed to create index table ~p", [Reason]),
                    {error, Reason}
            end
    end.

-spec handle_call(any(), gen_server:from(), state()) -> {reply, any(), state()}.
handle_call({new_ontology,
             #ontology{namespace = Namespace,
                       type = Type,
                       contact_nodes = ContactNodes},
             _Options},
            _From,
            State) ->
    logger:info("Contact nodes ~p", [ContactNodes]),
    case mnesia:dirty_read(?INDEX_TABLE, Namespace) of
        [] ->
            CN = case ContactNodes of
                     [] ->
                         [#node_entry{host = <<"bbsvx_bbsvx_root_1">>, port = 1883}];
                     _ ->
                         ContactNodes
                 end,
            Ont = #ontology{namespace = Namespace,
                            contact_nodes = CN,
                            version = <<"0.0.1">>,
                            type = Type,
                            last_update = erlang:system_time(microsecond)},
            logger:info("Onto service : creating ontology ~p", [Ont]),
            case mnesia:create_table(binary_to_table_name(Namespace),
                                     [{attributes, record_info(fields, goal)}])
            of
                {atomic, ok} ->
                    logger:info("Onto service : created table ~p", [binary_to_atom(Namespace)]),
                    FinalOnt =
                        case Type of
                            shared ->
                                logger:info("Onto service : shared ontology type", []),
                                %% Ask ontologies supervisor to start an ontology supervisor
                                %% which will start the needed agents
                                supervisor:start_child(bbsvx_sup_shared_ontologies,
                                                       [Namespace, #{contact_nodes => CN}]),

                                Ont#ontology{type = shared};
                            local ->
                                logger:info("Onto service : local ontology type", []),
                                Ont#ontology{type = local}
                        end,
                    logger:info("Final Ont ~p", [FinalOnt]),
                    ok = mnesia:activity(transaction, fun() -> mnesia:write(FinalOnt) end),

                    %logger:info("Onto service : created table ~p", [TabCreateResult]),
                    {reply, ok, State};
                {aborted, {already_exists, _}} ->
                    logger:info("Onto service : table ~p already exists",
                                [binary_to_atom(Namespace)]),
                    logger:info("Onto service : created table ~p", [binary_to_atom(Namespace)]),
                    FinalOnt =
                        case Type of
                            shared ->
                                %% Start shared ontology agents
                                logger:info("Onto service : ging to start shared ontology agents",
                                            []),
                                {ok, _} =
                                    supervisor:start_child(bbsvx_sup_shared_ontologies,
                                                           [Namespace, #{contact_nodes => CN}]),

                                Ont#ontology{type = shared};
                            local ->
                                logger:info("Onto service : local ontology type", []),
                                Ont#ontology{type = local}
                        end,
                    logger:info("Final Ont ~p", [FinalOnt]),
                    ok = mnesia:activity(transaction, fun() -> mnesia:write(FinalOnt) end),

                    %logger:info("Onto service : created table ~p", [TabCreateResult]),
                    {reply, ok, State};
                {aborted, {error, Reason}} ->
                    logger:error("Onto service : failed to create table ~p with reason : ~p",
                                 [binary_to_atom(Namespace), Reason]),
                    {reply, {error, Reason}, State};
                Else ->
                    logger:error("Onto service : unanaged create table ~p result with reason "
                                 ": ~p",
                                 [binary_to_atom(Namespace), Else]),
                    {reply, {error, Else}, State}
            end;
        _ ->
            {reply, {error, already_exists}, State}
    end;
handle_call({get_ontology, Namespace}, _From, State) ->
    logger:info("Index dump ~p", [mnesia:dirty_all_keys(ontology)]),
    Ont = mnesia:dirty_read(?INDEX_TABLE, Namespace),
    logger:info("Onto service : ontology ~p", [Ont]),
    case Ont of
        [] ->
            {reply, {error, not_found}, State};
        [Ontology] ->
            {reply, {ok, Ontology}, State}
    end;
%% Connect the ontology to the network
handle_call({connect_ontology, Namespace}, _From, State) ->
    %% Start the shared ontology agents
    FUpdateOnt =
        fun() ->
           case mnesia:wread({?INDEX_TABLE, Namespace}) of
               [] ->
                   logger:info("Onto service : ontology ~p not found", [Namespace]),
                   {error, not_found};
               [#ontology{type = shared}] ->
                   logger:info("Onto service : ontology ~p already connected", [Namespace]),
                   {error, already_connected};
               [Ont] ->
                   %% Start shared ontology agents
                   %% @TODO: check contact nodes below if it have unexpected value
                   supervisor:start_child(bbsvx_sup_shared_ontologies,
                                          [Namespace,
                                           #{contact_nodes => Ont#ontology.contact_nodes}]),
                   mnesia:write(Ont#ontology{type = shared})
           end
        end,
    mnesia:activity(transaction, FUpdateOnt),
    {reply, ok, State};
%% Disconnect the ontology from the network
handle_call({disconnect_ontology, Namespace}, _From, State) ->
    %% Stop the shared ontology agents
    FDisconnectOnt =
        fun() ->
           case mnesia:wread({?INDEX_TABLE, Namespace}) of
               [] ->
                   logger:info("Onto service : ontology ~p not found", [Namespace]),
                   {error, not_found};
               [#ontology{type = local}] ->
                   logger:info("Onto service : ontology ~p already disconnected", [Namespace]),
                   {error, already_disconnected};
               _ ->
                   case gproc:where({n, l, {bbsvx_sup_shared_ontology, Namespace}}) of
                       undefined ->
                           logger:error("Onto service : shared ontology sup not found", []);
                       Pid -> supervisor:terminate_child(bbsvx_sup_shared_ontologies, Pid)
                   end,
                   jobs:delete_queue({Namespace}),
                   [Ont] = mnesia:wread({?INDEX_TABLE, Namespace}),
                   mnesia:write(Ont#ontology{type = local})
           end
        end,
    mnesia:activity(transaction, FDisconnectOnt),
    {reply, ok, State};
handle_call({delete_ontology, Namespace}, _From, State) ->
    TabDeleteResult =
        case mnesia:dirty_read({?INDEX_TABLE, Namespace}) of
            [#ontology{type = shared}] ->
                supervisor:terminate_child(bbsvx_sup_spray_view_agents, Namespace),
                case mnesia:delete_table(binary_to_atom(Namespace)) of
                    {atomic, ok} ->
                        FunDel = fun() -> mnesia:delete({?INDEX_TABLE, Namespace}) end,
                        mnesia:activity(transaction, FunDel);
                    Else ->
                        {error, Else}
                end;
            [#ontology{type = _}] ->
                case mnesia:delete_table(binary_to_atom(Namespace)) of
                    {atomic, ok} ->
                        FunDel = fun() -> mnesia:delete({?INDEX_TABLE, Namespace}) end,
                        mnesia:activity(transaction, FunDel);
                    Else ->
                        {error, Else}
                end;
            [] ->
                {error, not_found}
        end,
    logger:info("Onto service : deleted table ~p", [TabDeleteResult]),
    {reply, TabDeleteResult, State};
handle_call({store_goal, Goal}, _From, State) ->
    %% Insert the goal into the database or perform any necessary operations
    logger:info("Onto service : storing goal ~p", [Goal]),
    F = fun() -> mnesia:write(Goal) end,
    mnesia:activity(transaction, F),
    {reply, ok, State};
%% REtrieve goal from the database
handle_call({get_goal, GoalId}, _From, State) ->
    Res = mnesia:dirty_read(GoalId),
    {reply, {ok, Res}, State};
handle_call(Request, _From, LoopState) ->
    logger:info("Onto service : received unknown call request ~p", [Request]),
    Reply = ok,
    {reply, Reply, LoopState}.

handle_cast({new_goal, Namespace, Predicate}, State) when is_list(Predicate) ->
    %% @TODO: Get right value for leader
    {ok, CurrentLeader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    case string_to_eterm(Predicate) of
        {ok, Eterm} ->
            Timestamp = erlang:system_time(microsecond),
            Goal =
                #goal{id = uuid:uuid4(),
                      namespace = Namespace,
                      source_id = State#state.my_id,
                      leader = CurrentLeader,
                      timestamp = Timestamp,
                      payload = Eterm},
            Transaction = #transaction{payload = Goal, ts_created = Timestamp},
            bbsvx_epto_service:broadcast(Namespace, Transaction),
            {noreply, State};
        {error, Reason} ->
            logger:error("Onto service : failed to parse goal ~p with reason ~p",
                         [Predicate, Reason]),
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

have_index_table() ->
    TableName = ?INDEX_TABLE,
    Tablelist = mnesia:system_info(tables),
    lists:member(TableName, Tablelist).

table_exists(Namespace) ->
    TableName = binary_to_table_name(Namespace),
    Tablelist = mnesia:system_info(tables),
    lists:member(TableName, Tablelist).

binary_to_table_name(Namespace) ->
    Replaced = binary:replace(Namespace, <<":">>, <<"_">>),
    binary_to_atom(Replaced).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc
%%% Convert a string to an prolog eterm
%%%
%%% @param String the string to convert
%%% @returns {ok, Eterm} if the string was successfully converted, {error, Reason} otherwise
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
string_to_eterm(String) when is_binary(String) ->
    string_to_eterm(binary_to_list(String));
string_to_eterm(String) ->
    logger:info("Parsing string ~p", [String]),
    %% We add a space at the end of the string to parse because of a probable error in prolog parser
    %% A list is returned in case of error to avoid eterm confusion if we return {error, Error}
    case erlog_scan:tokens([], String ++ " ", 1) of
        {done, {ok, Tokk, _}, _} ->
            case erlog_parse:term(Tokk) of
                {ok, Eterms} ->
                    Eterms;
                Other1 ->
                    [error, Other1]
            end;
        Other ->
            [error, Other]
    end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.

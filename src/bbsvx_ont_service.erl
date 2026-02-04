%%%-----------------------------------------------------------------------------
%%% BBSvx Ontology Service
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_service).

-moduledoc "BBSvx Ontology Service\n\n"
"Gen Server for managing ontology instances and Prolog knowledge base operations.\n\n"
"Provides API for ontology creation, querying, goal storage, and distributed connections.".

-author("yan").

-behaviour(gen_server).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([
    start_link/0,
    create_ontology/1,
    create_ontology/2,
    get_ontology/1,
    delete_ontology/1,
    prove/2,
    store_goal/1,
    get_goal/1,
    connect_ontology/1,
    connect_ontology/2,
    reconnect_ontology/1,
    disconnect_ontology/1,
    get_connection_status/1,
    retry_connection/1,
    binary_to_table_name/1,
    table_exists/1,
    is_contact_node/2
]).
%% Callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(INDEX_LOAD_TIMEOUT, 30000).

%% Loop state
-record(state, {my_id :: binary()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() -> gen_statem:start_ret().
%% Start the ontology service

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


-spec create_ontology(Namespace :: binary()) -> ok | {error, atom()}.
create_ontology(Namespace) when is_binary(Namespace) ->
    create_ontology(Namespace, #{}).

-spec create_ontology(Namespace :: binary(), map()) -> ok | {error, atom()}.
create_ontology(Namespace, Options) when is_binary(Namespace) ->
    gen_server:call(?SERVER, {create_ontology, Namespace, Options}).


-spec connect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
connect_ontology(Namespace) ->
    connect_ontology(Namespace, #{}).

-spec connect_ontology(Namespace :: binary(), map()) -> ok | {error, atom()}.
connect_ontology(Namespace, Options) ->
    gen_server:call(?SERVER, {connect_ontology, Namespace, Options}).


-spec reconnect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
reconnect_ontology(Namespace) ->
    gen_server:call(?SERVER, {reconnect_ontology, Namespace}).


%% Get an ontology by namespace

-spec get_ontology(binary()) -> {ok, ontology()} | {error, atom()}.
get_ontology(Namespace) ->
    gen_server:call(?SERVER, {get_ontology, Namespace}).

%% Delete an ontology by namespace
-spec delete_ontology(Namespace :: binary()) -> ok | {error, atom()}.
delete_ontology(Namespace) ->
    gen_server:call(?SERVER, {delete_ontology, Namespace}).

-spec disconnect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
disconnect_ontology(Namespace) ->
    gen_server:call(?SERVER, {disconnect_ontology, Namespace}).

-spec get_connection_status(Namespace :: binary()) -> {ok, connection_status()} | {error, term()}.
get_connection_status(Namespace) ->
    case gproc:where({n, l, {bbsvx_actor_ontology, Namespace}}) of
        undefined ->
            {error, ontology_not_found};
        Pid ->
            gen_statem:call(Pid, get_connection_status)
    end.

-spec retry_connection(Namespace :: binary()) -> ok | {error, term()}.
retry_connection(Namespace) ->
    case gproc:where({n, l, {bbsvx_actor_ontology, Namespace}}) of
        undefined ->
            {error, ontology_not_found};
        Pid ->
            Pid ! retry_connection,
            ok
    end.

-spec store_goal(goal()) -> ok | {error, atom()}.
store_goal(Goal) ->
    gen_server:call(?SERVER, {store_goal, Goal}).

get_goal(GoalId) ->
    gen_server:call(?SERVER, {get_goal, GoalId}).

prove(Namespace, Predicate) ->
    gen_server:call(?SERVER, {prove, Namespace, Predicate}).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([]) ->
    MyId = bbsvx_crypto_service:my_id(),
    case create_index_table() of
        {aborted, {already_exists, ?INDEX_TABLE}} ->
            %% Index Table alreay exists, this is not a first start.
            ?'log-info'("Onto service reading index table ~p", [?INDEX_TABLE]),
            case mnesia:wait_for_tables([?INDEX_TABLE], ?INDEX_LOAD_TIMEOUT) of
                {timeout, _} ->
                    logger:error("Onto service : index table ~p load timeout", [?INDEX_TABLE]),
                    {error, index_table_timeout};
                _ ->
                    ?'log-info'("Booting indexed ontologies", []),
                    boot_indexed_ontologies(),
                    {ok, #state{my_id = MyId}}
            end;
        {atomic, ok} ->
            %% This is the first time we start, so we need to either create root ontology, either
            %% join an existing network.
            %% Atm default behavior is to create root ontology but later on default will be to join an existing network,
            %% once the root mesh is stable enough.

            case application:get_env(bbsvx, boot, root) of
                root ->
                    ?'log-info'("Onto service : boot type : root", []),
                    Namespace = <<"bbsvx:root">>,
                    case create_transaction_table(Namespace) of
                        ok ->
                            Ont = #ontology{
                                namespace = Namespace,
                                contact_nodes = [],
                                version = <<"0.0.1">>,
                                type = shared,
                                last_update = erlang:system_time(microsecond)
                            },
                            case index_new_ontology(Ont) of
                                ok ->
                                    case activate_ontology(Namespace, #{boot => create}) of
                                        {ok, _Pid} ->
                                            ?'log-info'("Onto service : activated root ontology, building genesis transaction", []),
                                            %% Build and submit genesis transaction with root ontology predicates
                                            case bbsvx_transaction:build_root_genesis_transaction([
                                                {extenal_predicates, [bbsvx_ont_root]},
                                                {static_ontology, [{file, bbsvx, <<"bbsvx_root.pl">>}]}
                                            ]) of
                                                {ok, GenesisTx} ->
                                                    ?'log-info'("Submitting genesis transaction to root ontology for validation", []),
                                                    %% Send to validate stage (not accept, as genesis shouldn't be broadcast)
                                                    bbsvx_actor_ontology:receive_transaction(GenesisTx),
                                                    {ok, #state{my_id = MyId}};
                                                {error, GenesisReason} ->
                                                    ?'log-error'(
                                                        "Failed to build genesis transaction: ~p",
                                                        [GenesisReason]
                                                    ),
                                                    {stop, GenesisReason}
                                            end;
                                        {error, Reason} ->
                                            ?'log-error'(
                                                "Onto service : failed to create root ontology network with reason ~p",
                                                [Reason]
                                            ),
                                            {stop, Reason}
                                    end;
                                {error, Reason} ->
                                    ?'log-error'(
                                        "Failed to index new ontology ~p at boot with reason : ~p", [Ont, Reason]),
                                    {stop, Reason}
                             end;
                        {error, Reason} ->
                            ?'log-error'("Failed to create transaction table ~p", [Reason]),
                            {stop, Reason}
                    end;
                {join, ContactNodes} when is_list(ContactNodes) ->
                    case validate_contact_nodes(ContactNodes) of
                        {[], InvalidNodes} ->
                            ?'log-error'(
                                "Onto service : no valid contact nodes provided, cannot join network, invalid format ~p",
                                [InvalidNodes]
                            ),
                            {stop, no_valid_contact_nodes};
                        {ContactNodesEntries, InvalidNodes} ->
                            case InvalidNodes of
                                [] ->
                                    ok;
                                _ ->
                                    ?'log-warning'(
                                        "Onto service : some contact nodes have invalid format ~p, ignoring them",
                                        [InvalidNodes]
                                    )
                            end,
                            Namespace = <<"bbsvx:root">>,
                            case create_transaction_table(Namespace) of
                                ok ->
                                    OntEntry = #ontology{
                                        namespace = Namespace,
                                        version = <<"0.0.1">>,
                                        type = shared,
                                        contact_nodes = ContactNodesEntries
                                    },
                                    case index_new_ontology(OntEntry) of
                                        ok ->
                                            case activate_ontology(Namespace, #{
                                                contact_nodes => ContactNodesEntries,
                                                boot => connect
                                            }) of
                                                {ok, _} ->
                                                    ?'log-info'("Onto service : joined existing ontology network", []),
                                                    {ok, #state{my_id = MyId}};
                                                {error, Reason} ->
                                                    ?'log-error'(
                                                        "Onto service : failed to join existing ontology network with reason ~p",
                                                        [Reason]
                                                    ),
                                                    {stop, Reason}
                                            end;
                                        {error, Reason} ->
                                            ?'log-error'(
                                                "Failed to index new ontology ~p at boot with reason : ~p", [OntEntry, Reason]),
                                            {stop, Reason}
                                    end;
                                {error, Reason} ->
                                    ?'log-error'("Failed to create transaction table for ~p: ~p", [Namespace, Reason]),
                                    {stop, Reason}
                            end;
                        {error, Reason} ->
                            ?'log-error'("Invalid contact nodes format ~p", [Reason]),
                            {stop, Reason}
                    end
            end
    end.

handle_call(
    {create_ontology,
        Namespace,
        Options},
    _From,
    State
) ->
    %% Start by checking if we have this ontology registered into index
    case get_ontology_from_index(Namespace) of
        {error, not_found} ->
            %% No, we can continue into ontology creation

            %% Extract type from options, default to local for backward compatibility with tests
            Type = maps:get(type, Options, shared),

            Ont = #ontology{
                namespace = Namespace,
                contact_nodes = [],
                version = <<"0.0.1">>,
                type = Type,
                last_update = erlang:system_time(microsecond)
            },
            case create_transaction_table(Namespace) of
                ok ->
                    case index_new_ontology(Ont) of
                        ok ->
                            case activate_ontology(Namespace, #{boot => create}) of
                                {ok, _Pid} ->
                                    ?'log-info'("Ontology ~p activated, building genesis transaction", [Namespace]),
                                    %% Build and submit genesis transaction for the new ontology
                                    case bbsvx_transaction:build_genesis_transaction(Namespace, Options) of
                                        {ok, GenesisTx} ->
                                            ?'log-info'("Submitting genesis transaction to ontology ~p", [Namespace]),
                                            bbsvx_actor_ontology:receive_transaction(GenesisTx),
                                            {reply, ok, State};
                                        {error, GenesisReason} ->
                                            ?'log-error'("Failed to build genesis transaction for ~p: ~p",
                                                        [Namespace, GenesisReason]),
                                            {reply, {error, GenesisReason}, State}
                                    end;
                                {error, ActivationReason} ->
                                    ?'log-error'("Failed to activate ontology ~p: ~p", [Namespace, ActivationReason]),
                                    {reply, {error, ActivationReason}, State}
                            end;
                        {error, Reason} ->
                            ?'log-error'(
                                "Failed to index new ontology ~p at boot with reason : ~p", [
                                    Ont, Reason
                                ]
                            ),
                            {reply, {error, Reason}, State}
                    end;
                {error, Reason} ->
                    ?'log-error'("Failed to create transaction table ~p", [Reason]),
                    {reply, {error, Reason}, State}
            end;
        _ ->
            {reply, {error, already_exists}, State}
    end;

%% Connect to an existing ontology network for the first time.
handle_call({connect_ontology, Namespace, #{contact_nodes := ContactNodes} = Options}, _From, State) ->
     %% Start by checking if we have this ontology registered into index
    case get_ontology_from_index(Namespace) of
        {error, not_found} ->
            %% No, we can continue into ontology creation
            case validate_contact_nodes(ContactNodes) of
                {[], InvalidNodes} ->
                    ?'log-error'(
                        "Onto service : no valid contact nodes provided, cannot join network, invalid format ~p",
                        [InvalidNodes]
                    ),
                    {reply, {error, no_valid_contact_nodes}, State};
                {ContactNodesEntries, InvalidNodes} ->
                    case InvalidNodes of
                        [] ->
                            ok;
                        _ ->
                            ?'log-warning'(
                                "Onto service : some contact nodes have invalid format ~p, ignoring them",
                                [InvalidNodes]
                            )
                    end,
                    Ont = #ontology{
                        namespace = Namespace,
                        contact_nodes = ContactNodesEntries,
                        version = <<"0.0.1">>,
                        type = shared,
                        last_update = erlang:system_time(microsecond)
                    },
                    case create_transaction_table(Namespace) of
                        ok ->
                            case index_new_ontology(Ont) of
                                ok ->
                                    ActivationResult = activate_ontology(Namespace, #{
                                        contact_nodes => ContactNodesEntries,
                                        boot => connect
                                    }),
                                    {reply, ActivationResult, State};
                                {error, Reason} ->
                                    ?'log-error'(
                                        "Failed to index new ontology ~p at boot with reason : ~p", [
                                            Ont, Reason
                                        ]
                                    ),
                                    {reply, {error, Reason}, State}
                            end;
                        {error, Reason} ->
                            ?'log-error'("Failed to create transaction table ~p", [Reason]),
                            {reply, {error, Reason}, State}
                    end        
            end;
        _ ->
            {reply, {error, already_exists}, State}
    end;
            

%% Reconnect an already connected ontology
handle_call({reconnect_ontology, Namespace}, _From, State) ->
            case get_ontology_from_index(Namespace) of
                {error, Reason} ->
                    ?'log-error'("Onto service : ontology ~p not found", [Namespace]),
                    {reply, {error, Reason}, State};
                {ok, #ontology{contact_nodes = ContactNodes} = Ont} ->
                    %% Start shared ontology agents
                    %% TODO: check contact nodes below if it have unexpected value
                    ActivationResult = activate_ontology(Namespace, #{
                            contact_nodes => ContactNodes,
                            boot => reconnect
                        }),
                    {reply, ActivationResult, State}
            end;

%% Disconnect the ontology from the network
handle_call({disconnect_ontology, Namespace}, _From, State) ->
    %% Stop the shared ontology agents
    FDisconnectOnt =
        fun() ->
            case get_ontology_from_index(Namespace) of
                {error, not_found} ->
                    ?'log-error'("Onto service : ontology ~p not found", [Namespace]),
                    {error, not_found};
                {ok, #ontology{type = local}} ->
                    ?'log-warning'("Onto service : ontology ~p already disconnected", [Namespace]),
                    {error, already_disconnected};
                {ok, #ontology{} = Ont} ->
                    case deactivate_ontology(Namespace) of
                        ok ->
                            mnesia:write(Ont#ontology{type = local});
                        {error, Reason} ->
                            ?'log-error'("Onto service : failed to deactivate ontology ~p", [Reason])
                    end
            end
        end,
    DisconnectResult = mnesia:activity(transaction, FDisconnectOnt),
    {reply, DisconnectResult, State};


handle_call({prove, Namespace, Predicate}, _From, State) when
    is_binary(Predicate) andalso is_binary(Namespace) ->
    ?'log-info'("Onto service : proving goal ~p", [Predicate]),
    case bbsvx_transaction:string_to_eterm(Predicate) of
        {error, Reason} ->
            logger:error(
                "Onto service : failed to parse goal ~p with reason ~p",
                [Predicate, Reason]
            ),
            {reply, {error, Reason}, State};
        Eterm ->
            Timestamp = erlang:system_time(microsecond),
            Goal =
                #goal{
                    id = ulid:generate(),
                    namespace = Namespace,
                    source_id = State#state.my_id,
                    timestamp = Timestamp,
                    payload = Eterm
                },
            %% TODO: It is a goal that should be broadcasted not a transaction
            Transaction =
                #transaction{
                    namespace = Namespace,
                    payload = Goal,
                    current_address = <<"-1">>,
                    signature = <<"TODO">>,
                    source_ontology_id = <<"TODO">>,
                    ts_processed = 0,
                    prev_address = <<"-1">>,
                    prev_hash = <<"-1">>,
                    leader = undefined,
                    type = goal,
                    ts_created = Timestamp
                },
            bbsvx_epto_service:broadcast(Namespace, Transaction),
            {reply, {ok, Goal#goal.id}, State}
    end;
handle_call({get_ontology, Namespace}, _From, State) ->
    {reply, get_ontology_from_index(Namespace), State};

handle_call({delete_ontology, Namespace}, _From, State) when is_binary(Namespace) ->
    TabDeleteResult =
        case get_ontology_from_index(Namespace) of
            {ok, #ontology{}} ->
                %% Stop the ontology services supervisor if running
                case deactivate_ontology(Namespace) of
                    ok -> ok;
                    {error, _} -> ok  %% Ignore if already stopped
                end,
                %% Delete the transaction table
                case mnesia:delete_table(binary_to_atom(Namespace)) of
                    {atomic, ok} ->
                        FunDel = fun() -> mnesia:delete({?INDEX_TABLE, Namespace}) end,
                        mnesia:activity(transaction, FunDel);
                    {aborted, {no_exists, _}} ->
                        %% Table doesn't exist, just delete from index
                        FunDel = fun() -> mnesia:delete({?INDEX_TABLE, Namespace}) end,
                        mnesia:activity(transaction, FunDel);
                    Else ->
                        {error, Else}
                end;
            {error, not_found} ->
                {error, not_found}
        end,
    ?'log-info'("Onto service : deleted ontology ~p result: ~p", [Namespace, TabDeleteResult]),
    {reply, TabDeleteResult, State};
handle_call({store_goal, #goal{} = Goal}, _From, State) ->
    %% Insert the goal into the database or perform any necessary operations
    ?'log-info'("Onto service : storing goal ~p", [Goal]),
    F = fun() -> mnesia:write(Goal) end,
    mnesia:activity(transaction, F),
    {reply, ok, State};
%% RRetrieve goal from the database
handle_call({get_goal, Namespace, GoalId}, _From, #state{} = State) when
    is_binary(GoalId) andalso is_binary(Namespace)
->
    Res = mnesia:dirty_read({binary_to_atom(Namespace), GoalId}),
    {reply, {ok, Res}, State};
handle_call(Request, _From, LoopState) ->
    ?'log-warning'("Onto service : received unknown call request ~p", [Request]),
    
    {reply, ok, LoopState}.

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

-spec validate_contact_nodes(ContactNodes :: list()) -> {list(#node_entry{}), list(term())}.
validate_contact_nodes(ContactNodes) when is_list(ContactNodes) ->
    {ValidNodes, InvalidNodes} = 
                                lists:splitwith(
                                    fun
                                        ({Host, Port}) when is_list(Host), is_integer(Port) -> true;
                                        ({Host, Port}) when is_binary(Host), is_integer(Port) -> true;
                                        (_) -> false
                                    end, ContactNodes),
    FormattedValidNodes = lists:map(
        fun
            ({Host, Port}) when is_list(Host) -> 
                #node_entry{host = list_to_binary(Host), port = Port};
            ({Host, Port}) when is_binary(Host) -> 
                #node_entry{host = Host, port = Port}
        end, ValidNodes),
    {FormattedValidNodes, InvalidNodes}.

                                   


-spec get_ontology_from_index(Namespace :: binary()) -> {ok, ontology()} | {error, not_found}.
get_ontology_from_index(Namespace) ->
    case mnesia:dirty_read({?INDEX_TABLE, Namespace}) of
        [Ontology] ->
            {ok, Ontology};
        [] ->
            {error, not_found}
    end.

-spec create_root_transaction_table() -> ok | {error, Reason :: atom()}.
create_root_transaction_table() ->
    create_transaction_table(<<"bbsvx:root">>).

-spec create_transaction_table(NameSpace :: binary()) -> ok | {error, Reason :: atom()}.
create_transaction_table(NameSpace) ->
    case bbsvx_transaction:create_transaction_table(NameSpace) of
        ok ->
            ?'log-info'("Onto service : created transaction table ~p", [NameSpace]),
            ok;
        {error, Reason} ->
            ?'log-error'("Onto service : failed to create transaction table ~p", [Reason]),
            {error, Reason}
    end.

-spec index_new_ontology(ontology()) -> ok | {error, Reason :: term()}.
index_new_ontology(#ontology{} = Ontology) ->
    try
        mnesia:activity(transaction, fun() -> mnesia:write(Ontology) end),
        ok
    catch
        exit:{aborted, Reason} ->
            {error, Reason};
        Error:Reason ->
            {error, {Error, Reason}}
    end.

-spec create_index_table() -> {atomic, ok} | {aborted, term()}.
create_index_table() ->
    mnesia:create_table(
        ?INDEX_TABLE,
        [{attributes, record_info(fields, ontology)}, {disc_copies, [node()]}]
    ).

-spec activate_ontology(Namespace :: binary(), Options :: map()) ->
    supervisor:startchild_ret().
activate_ontology(Namespace, Options) ->
    supervisor:start_child(bbsvx_sup_actors_ontologies, [Namespace, Options]).

-spec deactivate_ontology(Namespace :: binary()) -> ok | {error, Reason :: atom()}.
deactivate_ontology(Namespace) ->
    %% For simple_one_for_one supervisors, we need the child PID to terminate
    %% Look up the ontology actor via gproc
    case gproc:where({n, l, {bbsvx_actor_ontology, Namespace}}) of
        undefined ->
            %% Actor not running, nothing to deactivate
            {error, not_running};
        Pid when is_pid(Pid) ->
            %% Terminate the child process
            supervisor:terminate_child(bbsvx_sup_actors_ontologies, Pid)
    end.

-spec update_ontology(NewOntology :: ontology()) -> ok | {error, Reason :: term()}.
update_ontology(NewOntology) ->
    case mnesia:activity(transaction, fun() -> mnesia:write(NewOntology) end) of
        {atomic, _} ->
            ok;
        {aborted, Reason} ->
            {error, Reason}
    end.

boot_indexed_ontologies() ->
    FirstKey = mnesia:dirty_first(?INDEX_TABLE),
    do_boot_ontologies(FirstKey).

do_boot_ontologies('$end_of_table') ->
    ok;
do_boot_ontologies(Key) ->
    ?'log-info'("Booting ontology : ~p", [Key]),
    [Ont] = mnesia:dirty_read({?INDEX_TABLE, Key}),
    ?'log-info'("stored ont desc : ~p", [Ont]),

    case Ont#ontology.type of
        shared ->
            supervisor:start_child(
                bbsvx_sup_actors_ontologies,
                [
                    Ont#ontology.namespace,
                    #{contact_nodes => Ont#ontology.contact_nodes, boot => reconnect}
                ]
            );
        local ->
            ok
    end,
    NextKey = mnesia:dirty_next(?INDEX_TABLE, Key),
    do_boot_ontologies(NextKey).

is_contact_node(NodeId, ContactNodes) ->
    lists:member(NodeId, [N#node_entry.node_id || N <- ContactNodes]).

table_exists(Namespace) ->
    TableName = binary_to_table_name(Namespace),
    Tablelist = mnesia:system_info(tables),
    check_is_in_table_list(TableName, Tablelist).

check_is_in_table_list(TableName, Tablelist) when is_list(Tablelist) ->
    lists:member(TableName, Tablelist).

parse_contact_nodes(ContactNodesStr) ->
    Nodes = string:tokens(ContactNodesStr, ","),
    lists:map(fun parse_single_node/1, Nodes).

parse_single_node(NodeStr) ->
    CleanNode = string:strip(NodeStr),
    case string:tokens(CleanNode, ":") of
        [Host, Port] ->
            #node_entry{host = list_to_binary(Host), port = list_to_integer(Port)};
        [Host] ->
            #node_entry{host = list_to_binary(Host), port = 2304};
        _ ->
            #node_entry{host = <<"localhost">>, port = 2304}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Convert a binary namespace to a table name
-spec binary_to_table_name(binary()) -> atom().
binary_to_table_name(Namespace) ->
    Replaced = binary:replace(Namespace, <<":">>, <<"_">>),
    binary_to_atom(Replaced).

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.

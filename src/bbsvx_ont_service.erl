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
    new_ontology/1,
    get_ontology/1,
    delete_ontology/1,
    prove/2,
    store_goal/1,
    get_goal/1,
    connect_ontology/1,
    disconnect_ontology/1,
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

%% Create a new ontology

-spec new_ontology(ontology()) -> ok | {error, atom()}.
new_ontology(#ontology{namespace = Namespace, contact_nodes = ContactNodes} = Ontology) ->
    gen_server:call(?SERVER, {new_ontology, Ontology}).

%% Get an ontology by namespace

-spec get_ontology(binary()) -> {ok, ontology()} | {error, atom()}.
get_ontology(Namespace) ->
    gen_server:call(?SERVER, {get_ontology, Namespace}).

%% Delete an ontology by namespace
-spec delete_ontology(Namespace :: binary()) -> ok | {error, atom()}.
delete_ontology(Namespace) ->
    gen_server:call(?SERVER, {delete_ontology, Namespace}).

%%%-----------------------------------------------------------------------------
%% Connect an ontology to the network

-spec connect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
connect_ontology(Namespace) ->
    gen_server:call(?SERVER, {connect_ontology, Namespace}).

-spec disconnect_ontology(Namespace :: binary()) -> ok | {error, atom()}.
%%%-----------------------------------------------------------------------------
%% Disconnect an ontology from the network
disconnect_ontology(Namespace) ->
    gen_server:call(?SERVER, {disconnect_ontology, Namespace}).

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
                    MyId = bbsvx_crypto_service:my_id(),
                    boot_indexed_ontologies(),
                    {ok, #state{my_id = MyId}}
            end;
        {atomic, ok} ->
            %% This is the first time we start, so we need to either create root ontology, either
            %% join an existing network

            BootMode = application:get_env(bbsvx, boot, root),
            ListOfContactNodes =
                case BootMode of
                    root ->
                        [];
                    {join, ContactNodesTuples} when is_list(ContactNodesTuples) ->
                        %% This node is asked to boot by joining already existing network
                        %% Convert from [{Host, Port}, ...] to [#node_entry{}, ...]
                        lists:map(
                            fun({Host, Port}) when  Host andalso is_integer(Port) ->
                                #node_entry{
                                    host = list_to_binary(Host),
                                    port = Port
                                }
                            end,
                            ContactNodesTuples
                        );
                    Other ->
                        logger:error("Invalid boot mode: ~p", [Other]),
                        {stop, {invalid_boot_mode, Other}}
                end,

            logger:info("Onto service : contact nodes ~p", [ListOfContactNodes]),
            OntEntry = #ontology{
                namespace = <<"bbsvx:root">>,
                version = <<"0.0.1">>,
                type = shared,
                contact_nodes = ListOfContactNodes
            },
            %% register new ontology into index table
            case index_new_ontology(OntEntry) of
                ok ->
                    %% Now start the shared ontology needed processes (bbsvx_actor_spay,
                    %% bbsvx_actor_ontology, bbsvx_epto_disord_component and bbsvx_actor_leader_manager)
                    case
                        activate_ontology(<<"bbsvx:root">>, #{
                            contact_nodes => ListOfContactNodes,
                            boot => BootMode
                        })
                    of
                        {ok, _} ->
                            ?'log-info'("Onto service : root ontology processes started", []),
                            %% TODO: nt sure we need to keep my_id()
                            case
                                bbsvx_transaction:build_root_genesis_transaction(
                                    [
                                        {static_ontology, [{file, bbsvx, "bbsvx_root.pl"}]},
                                        {extenal_ontology, [bbsvx_ont_root]}
                                    ]
                                )
                            of
                                {ok, GenesisTransaction} ->
                                    gproc:send(
                                        {n, l, {bbsvx_actor_ontology, <<"bbsvx:root">>}},
                                        GenesisTransaction
                                    ),
                                    MyId = bbsvx_crypto_service:my_id(),
                                    {ok, #state{my_id = MyId}};
                                {error, Reason} ->
                                    ?'log-error'(
                                        "Onto service : failed to create root genesis transaction, reason: ~p",
                                        [Reason]
                                    ),
                                    {stop, Reason}
                            end;
                        {error, Reason} ->
                            ?'log-error'(
                                "Onto service : failed to start root ontology processes, reason: ~p",
                                [Reason]
                            ),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    ?'log-error'("Onto service : failed to register ontology ~p, reason: ~p", [
                        OntEntry, Reason
                    ]),
                    {error, Reason}
            end
    end.

% create_process_root_genesis_transaction(Options) ->

%     %% Initialize root ontology
%     ?'log-info'("Onto service : initializing root ontology with ~p", [Options]),
%     %% Try to create index table
%     case
%         mnesia:create_table(
%             ?INDEX_TABLE,
%             [{attributes, record_info(fields, ontology)}, {disc_copies, [node()]}]
%         )
%     of
%         {aborted, {already_exists, ?INDEX_TABLE}} ->
%             %% Index table already exists, so this is not the first time we start
%             ?'log-info'("Onto service : waiting for index table ~p", [?INDEX_TABLE]),
%             case mnesia:wait_for_tables([?INDEX_TABLE], ?INDEX_LOAD_TIMEOUT) of
%                 {timeout, _} ->
%                     logger:error("Onto service : index table ~p load timeout", [?INDEX_TABLE]),
%                     {error, index_table_timeout};
%                 _ ->
%                     ?'log-info'("Onto service : index table ~p loaded", [?INDEX_TABLE]),
%                     MyId = bbsvx_crypto_service:my_id(),
%                     boot_indexed_ontologies(),
%                     {ok, #state{my_id = MyId}}
%             end;
%         {atomic, ok} ->
%             MyId = bbsvx_crypto_service:my_id(),
%             bbsvx_transaction:new_root_ontology(),
%             BootMode = application:get_env(bbsvx, boot, root),
%             case BootMode of
%                 root ->
%                     ?'log-info'("Onto service : boot type : root"),

%                     GenesisTransaction =
%                         #transaction{
%                             type = creation,
%                             index = 0,
%                             current_address = <<"0">>,
%                             prev_address = <<"-1">>,
%                             prev_hash = <<"0">>,
%                             signature =
%                                 %% TODO: Should be signature of ont owner
%                                 <<"">>,
%                             ts_created = erlang:system_time(),
%                             ts_processed = erlang:system_time(),
%                             source_ontology_id = <<"">>,
%                             leader = bbsvx_crypto_service:my_id(),
%                             status = processed,
%                             diff = [],
%                             namespace = <<"bbsvx:root">>,
%                             payload = []
%                         },
%                     bbsvx_transaction:record_transaction(GenesisTransaction),

%                     {ok, {MyHost, MyPort}} = bbsvx_network_service:my_host_port(),

%                     %% Format contact nodes
%                     ContactNodes = [#node_entry{host = MyHost, port = MyPort}],
%                     logger:info("Onto service : contact nodes ~p", [ContactNodes]),
%                     OntEntry =
%                         #ontology{
%                             namespace = <<"bbsvx:root">>,
%                             version = <<"0.0.1">>,
%                             type = shared,
%                             contact_nodes = ContactNodes
%                         },
%                     mnesia:activity(transaction, fun() -> mnesia:write(OntEntry) end),
%                     supervisor:start_child(
%                         bbsvx_sup_shared_ontologies,
%                         [
%                             <<"bbsvx:root">>,
%                             #{contact_nodes => ContactNodes, boot => root}
%                         ]
%                     ),

%                     {ok, #state{my_id = MyId}};
%                 {join, Host, Port} ->
%                     ?'log-info'("Onto service : boot type : joining node ~p ~p", [Host, Port]),
%                     ListOfContactNodes = [#node_entry{host = list_to_binary(Host), port = Port}],

%                     logger:info("Onto service : contact nodes ~p", [ListOfContactNodes]),
%                     OntEntry =
%                         #ontology{
%                             namespace = <<"bbsvx:root">>,
%                             version = <<"0.0.1">>,
%                             type = shared,
%                             contact_nodes = ListOfContactNodes
%                         },
%                     mnesia:activity(transaction, fun() -> mnesia:write(OntEntry) end),
%                     supervisor:start_child(
%                         bbsvx_sup_shared_ontologies,
%                         [
%                             <<"bbsvx:root">>,
%                             #{contact_nodes => ListOfContactNodes, boot => join}
%                         ]
%                     ),

%                     {ok, #state{my_id = MyId}};
%                 join ->
%                     %% Join mode without specific contact node (restart case)
%                     ?'log-info'("Onto service : boot type : join (restart)"),
%                     ContactNodes = application:get_env(bbsvx, contact_nodes, "none"),
%                     ListOfContactNodes =
%                         case ContactNodes of
%                             "none" ->
%                                 [#node_entry{host = <<"localhost">>, port = 2304}];
%                             _ ->
%                                 %% Parse contact nodes string
%                                 parse_contact_nodes(ContactNodes)
%                         end,

%                     logger:info("Onto service : contact nodes ~p", [ListOfContactNodes]),
%                     OntEntry =
%                         #ontology{
%                             namespace = <<"bbsvx:root">>,
%                             version = <<"0.0.1">>,
%                             type = shared,
%                             contact_nodes = ListOfContactNodes
%                         },
%                     mnesia:activity(transaction, fun() -> mnesia:write(OntEntry) end),
%                     supervisor:start_child(
%                         bbsvx_sup_shared_ontologies,
%                         [
%                             <<"bbsvx:root">>,
%                             #{contact_nodes => ListOfContactNodes, boot => join}
%                         ]
%                     ),

%                     {ok, #state{my_id = MyId}};
%                 Else ->
%                     ?'log-warning'("Onto service : unmanaged boot type ~p", [Else]),
%                     {stop, {error, invalid_boot_type}}
%             end;
%         {aborted, {error, Reason}} ->
%             logger:error("Onto service : failed to create index table ~p", [Reason]),
%             {stop, Reason}
%     end.

handle_call(
    {new_ontology,
        #ontology{
            namespace = Namespace,
            type = Type,
            contact_nodes = ContactNodes
        },
        _Options},
    _From,
    State
) ->
    %% Start by checking if we have this ontology registered into index
    case get_ontology_from_index(Namespace) of
        {error, not_found} ->
            %% No, we can continue into ontology creation
            CN =
                case ContactNodes of
                    [] ->
                        [#node_entry{host = <<"bbsvx_bbsvx_root_1">>, port = 1883}];
                    _ ->
                        ContactNodes
                end,
            Ont = #ontology{
                namespace = Namespace,
                contact_nodes = CN,
                version = <<"0.0.1">>,
                type = Type,
                last_update = erlang:system_time(microsecond)
            },
            case create_transaction_table(Namespace) of
                ok ->
                    case index_new_ontology(Ont) of
                        ok ->
                            ?'log-info'("Onto service : indexed new ontology ~p", [Ont]),
                            case Type of
                                shared ->
                                    ActivationResult = activate_ontology(Namespace, #{
                                        contact_nodes => CN,
                                        boot => join
                                    }),
                                    {reply, ActivationResult, State};
                                local ->
                                    {reply, ok, State}
                            end;
                        {error, Reason} ->
                            ?'log-error'(
                                "Onto service : failed to index new ontology ~p with reason : ~p", [
                                    Ont, Reason
                                ]
                            ),
                            {reply, {error, Reason}, State}
                    end;
                {error, Reason} ->
                    ?'log-error'("Onto service : failed to create transaction table ~p", [Reason]),
                    {reply, {error, Reason}, State}
            end;
        _ ->
            {reply, {error, already_exists}, State}
    end;
handle_call({prove, Namespace, Predicate}, _From, State) when
    is_binary(Predicate) andalso is_binary(Namespace)
->
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
%% Connect the ontology to the network
handle_call({connect_ontology, Namespace}, _From, State) ->
    %% Start the shared ontology agents
    FUpdateOnt =
        fun() ->
            case get_ontology_from_index(Namespace) of
                {error, not_found} ->
                    ?'log-error'("Onto service : ontology ~p not found", [Namespace]),
                    {error, not_found};
                {ok, #ontology{type = shared}} ->
                    ?'log-notice'("Onto service : ontology ~p already connected", [Namespace]),
                    {error, already_connected};
                {ok, #ontology{type = shared, contact_nodes = ContactNodes} = Ont} ->
                    %% Start shared ontology agents
                    %% TODO: check contact nodes below if it have unexpected value
                    case
                        activate_ontology(Namespace, #{
                            contact_nodes => ContactNodes,
                            boot => join
                        })
                    of
                        ok ->
                            update_ontology(Ont#ontology{type = shared});
                        {error, Reason} ->
                            ?'log-error'(
                                "Onto service : failed to start shared ontology agents ~p", [Reason]
                            ),
                            {error, Reason}
                    end
            end
        end,
    ConnectResult = mnesia:activity(transaction, FUpdateOnt),
    {reply, ConnectResult, State};
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
handle_call({delete_ontology, Namespace}, _From, State) when is_binary(Namespace) ->
    TabDeleteResult =
        case get_ontology_from_index(Namespace) of
            {ok, #ontology{type = shared}} ->
                supervisor:terminate_child(bbsvx_sup_spray_view_agents, Namespace),
                case mnesia:delete_table(binary_to_atom(Namespace)) of
                    {atomic, ok} ->
                        FunDel = fun() -> mnesia:delete({?INDEX_TABLE, Namespace}) end,
                        mnesia:activity(transaction, FunDel);
                    Else ->
                        {error, Else}
                end;
            {ok, #ontology{type = _}} ->
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
    ?'log-info'("Onto service : deleted table ~p", [TabDeleteResult]),
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
    Reply = ok,
    {reply, Reply, LoopState}.

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
    supervisor:start_child(bbsvx_sup_shared_ontologies, [Namespace, Options]).

-spec deactivate_ontology(Namespace :: binary()) -> ok | {error, Reason :: atom()}.
deactivate_ontology(Namespace) ->
    supervisor:terminate_child(bbsvx_sup_shared_ontologies, [Namespace]).

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
                bbsvx_sup_shared_ontologies,
                [
                    Ont#ontology.namespace,
                    #{contact_nodes => Ont#ontology.contact_nodes, boot => join}
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

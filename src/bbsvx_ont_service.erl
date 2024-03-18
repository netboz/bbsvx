%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_ont_service).

-author("yan").

-behaviour(gen_server).

-include("bbsvx_common_types.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/0, new_ontology/1, store_goal/1, get_goal/1, prove_goal/1]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(INDEX_TABLE, ontologies_index).
-define(INDEX_LOAD_TIMEOUT, 30000).

%% Loop state
-record(state, {}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link() ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec new_ontology(ontology()) -> ok | {error, atom()}.
new_ontology(Ontology) ->
    gen_server:call(?SERVER, {new_ontology, Ontology, []}).

-spec store_goal(goal()) -> ok | {error, atom()}.
store_goal(Goal) ->
    gen_server:call(?SERVER, {store_goal, Goal}).

get_goal(GoalId) ->
    gen_server:call(?SERVER, {get_goal, GoalId}).

prove_goal(Goal) ->
    gen_server:call(?SERVER, {prove_goal, Goal}).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([]) ->
    logger:info("Onto service : starting ontology service"),
    Tablelist = mnesia:system_info(tables),
    logger:info("Table list ~p", [Tablelist]),
    IndexTableExists = lists:member(?INDEX_TABLE, Tablelist),
    case IndexTableExists of
        true ->
            case mnesia:wait_for_tables(?INDEX_TABLE, ?INDEX_LOAD_TIMEOUT) of
                {timeout, _} ->
                    {error, index_table_timeout};
                _ ->
                    {ok, #state{}}
            end;
        false ->
            case mnesia:create_table(?INDEX_TABLE,
                                     [{attributes, record_info(fields, ontology)},
                                      {disc_copies, [node()]}])
            of
                {atomic, ok} ->
                    {ok, #state{}};
                {atomic, {error, Reason}} ->
                    {error, Reason}
            end
    end.

handle_call({new_ontology, #ontology{namespace = Namespace}, _Options}, _From, State) ->
    Reply = ok,
    FunCreateOntoTable =
        fun() ->
           case mnesia:create_table(binary_to_atom(Namespace),
                                    [{attributes, record_info(fields, goal)},
                                     {disc_copies, [node()]}])
           of
               {atomic, ok} ->
                   %% Insert ontology into the index table
                   mnesia:write(#ontology{namespace = Namespace,
                                          version = "0.0.1",
                                          last_update = erlang:system_time(microsecond)});
               _ ->
                   ok
           end
        end,
    TabCreateResult = mnesia:activity(transaction, FunCreateOntoTable),
    logger:info("Onto service : created table ~p", [TabCreateResult]),
    %% For testing purposes, we are starting the shared ontology agents now
    supervisor:start_child(bbsvx_sup_spray_view_agents,
                           [Namespace,
                            [{contact_nodes,
                              [#node_entry{host = <<"bbsvx_bbsvx_root_1">>, port = 1883}]}]]),
    
    %% Start leader election agent
    supervisor:start_child(bbsvx_sup,
                           #{id => bbsvx_actor_leader_manager,
                             start => {bbsvx_actor_leader_manager, start_link, [Namespace, 8, 50, 100, 200]}, %%Namespace, Diameter, DeltaC, DeltaE, DeltaD
                             restart => permanent,
                             shutdown => brutal_kill,
                             type => worker,
                             modules => [bbsvx_actor_leader_manager]}),
    {reply, Reply, State};
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
handle_call({prove_goal, Goal}, _From, State) ->
    %% Check ontology exists
    %%
    %% Prove the goal
    logger:info("Onto service : proving goal ~p", [Goal]),
    {reply, ok, State};
handle_call(_Request, _From, LoopState) ->
    logger:info("Onto service : received unknown call request ~p", [_Request]),
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

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

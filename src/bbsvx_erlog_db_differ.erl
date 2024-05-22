%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% This mod is an erlog mod storage.
%%% More precisely, when creating the knowledge base db ( new/1 ), it takes
%%% as input usual DB identifier, plus the name of another erlog db mod.
%%% Thismodule is then acting as a proxy for the other db mod, and logs all
%%% operations that are modifying the db.
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_erlog_db_differ).

-author("yan").

-behaviour(gen_server).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/1]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
%% Erlog DB api
-export([new/1]).
-export([add_built_in/2, add_compiled_proc/4, asserta_clause/4, assertz_clause/4]).
-export([retract_clause/3, abolish_clauses/2]).
-export([get_procedure/2, get_procedure_type/2]).
-export([get_interpreted_functors/1]).

%% State
-record(state,
        {asserta :: [term()],
         assertz :: [term()],
         retract :: [term()],
         abolish :: [term()],
         op_fifo :: [term()]}).
-record(db_differ, {goal_id :: binary(), outmod :: atom(), outmoddb :: term()}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(GoalId :: binary()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(GoalId) ->
    gen_server:start_link({via, gproc, {n, l, {differ, GoalId}}}, ?MODULE, [], []).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([]) ->
    {ok, #state{}}.

%% Manager assertA storage into state
handle_call({asserta, Functor, Head, Body}, _From, #state{op_fifo = OpFifo} = State) ->
    {reply, ok, State#state{op_fifo = OpFifo ++ [{asserta, Functor, Head, Body}]}};
%% Manager assertZ storage into state
handle_call({assertz, Functor, Head, Body}, _From, #state{op_fifo = OpFifo} = State) ->
    {reply, ok, State#state{op_fifo = OpFifo ++ [{assertz, Functor, Head, Body}]}};
%% Manager retract storage into state
handle_call({retract, Functor, Tag}, _From, #state{op_fifo = OpFifo} = State) ->
    {reply, ok, State#state{op_fifo = OpFifo ++ [{retract, Functor, Tag}]}};
%% Manager abolish storage into state
handle_call({abolish, Functor}, _From, #state{op_fifo = OpFifo} = State) ->
    {reply, ok, State#state{op_fifo = OpFifo ++ [{abolish, Functor}]}};
%% Answer request to get all stored procedures
handle_call(get_procedures, _From, State) ->
    {reply, {ok, {State#state.asserta, State#state.assertz}}, State};
%% Manage reception of message :{get_procedure_type, Functor}
handle_call({get_procedure_type, Functor}, _From, State) ->
    %% Check if we have a record for this functor
    Clauses = State#state.asserta ++ State#state.assertz,
    case lists:keyfind(Functor, 1, Clauses) of
        {Functor, _, _} ->
            {reply, interpreted, State};
        false ->
            {reply, undefined, State}
    end;
handle_call(Request, _From, State) ->
    logger:info("erlog_db_differ : unmatched call : ~p", [Request]),
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, LoopState) ->
    {noreply, LoopState}.

handle_info(_Info, LoopState) ->
    {noreply, LoopState}.

terminate(_Reason, _LoopState) ->
    ok.

code_change(_OldVsn, LoopState, _Extra) ->
    {ok, LoopState}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% Erlog DB API

%% new(InitArgs) -> Db.

new({GoalId, OutMod}) ->
    start_link(GoalId),
    OutModDb = OutMod:new(GoalId),
    #db_differ{goal_id = GoalId,
               outmod = OutMod,
               outmoddb = OutModDb}.

%% add_built_in(Db, Functor) -> NewDb.
%%  Add Functor as a built-in in the database.

add_built_in(#db_differ{outmod = OutMod, outmoddb = Outmoddb} = Db, Functor) ->
    NewOutDb = OutMod:add_built_in(Outmoddb, Functor),
    Db#db_differ{outmoddb = NewOutDb}.

%% add_compiled_proc(Db, Functor, Module, Function) -> {ok,NewDb} | error.
%%  Add functor as a compiled procedure with code in M:F in the
%%  database. Check that it is not a built-in, if so return error.

add_compiled_proc(#db_differ{outmod = OutMod, outmoddb = Outmoddb} = Db, Functor, M, F) ->
    {ok, NewOutDb} = OutMod:add_compiled_proc(Outmoddb, Functor, M, F),
    {ok, Db#db_differ{outmoddb = NewOutDb}}.

%% asserta_clause(Db, Functor, Head, Body) -> {ok,NewDb} | error.
%% assertz_clause(Db, Functor, Head, Body) -> {ok,NewDb} | error.
%%  We DON'T check format and just put it straight into the database.

asserta_clause(#db_differ{outmod = OutMod,
                          outmoddb = Outmoddb,
                          goal_id = GoalId} =
                   Db,
               Functor,
               Head,
               Body) ->
    %% Record this asserta operation
    gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, {asserta, Functor, Head, Body}),
    %% Call outmod to do the real work
    {ok, NewOutDb} = OutMod:asserta_clause(Outmoddb, Functor, Head, Body),
    {ok, Db#db_differ{outmoddb = NewOutDb}}.

assertz_clause(#db_differ{outmod = OutMod,
                          outmoddb = Outmoddb,
                          goal_id = GoalId} =
                   Db,
               Functor,
               Head,
               Body) ->
    %% Record this assertz operation
    gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, {assertz, Functor, Head, Body}),
    %% Call outmod to do the real work
    {ok, NewOutDb} = OutMod:assertz_clause(Outmoddb, Functor, Head, Body),
    {ok, Db#db_differ{outmoddb = NewOutDb}}.

%% retract_clause(Db, Functor, ClauseTag) -> {ok,NewDb} | error.
%%  Retract (remove) the clause with tag ClauseTag from the list of
%%  clauses of Functor.

retract_clause(#db_differ{outmod = OutMod,
                          outmoddb = Outmoddb,
                          goal_id = GoalId} =
                   Db,
               Functor,
               Tag) ->
    %% Record this retract operation
    gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, {retract, Functor, Tag}),
    %% Call outmod to do the real work
    {ok, NewOutDb} = OutMod:retract_clause(Outmoddb, Functor, Tag),
    {ok, Db#db_differ{outmoddb = NewOutDb}}.

%% abolish_clauses(Db, Functor) -> NewDatabase.

abolish_clauses(#db_differ{outmod = OutMod,
                           outmoddb = Outmoddb,
                           goal_id = GoalId} =
                    Db,
                Functor) ->
    %% Record this abolish operation
    gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, {abolish, Functor}),
    %% Call outmod to do the real work
    NewOutDb = OutMod:abolish_clauses(Outmoddb, Functor),
    Db#db_differ{outmoddb = NewOutDb}.

%% get_procedure(Db, Functor) ->
%%        built_in | {code,{Mod,Func}} | {clauses,[Clause]} | undefined.
%% Return the procedure type and data for a functor.

get_procedure(#db_differ{outmod = OutMod,
                         outmoddb = OutmoDb,
                         goal_id = GoalId},
              Functor) ->
    %% Call genserver to get the added procedures ( only assert_a clauses )
    {ok, {ClausesA, ClausesZ}} =
        gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, get_procedures),
    %% Get the procedures from ClausesA if there are some
    SelectedClausesA = lists:filter(fun({F, _, _}) -> F == Functor end, ClausesA),
    %% Get procedure from out mod
    OutModProcedures = OutMod:get_procedure(OutmoDb, Functor),
    %% Get procedures from clause Z
    SelectedClausesZ = lists:filter(fun({F, _, _}) -> F == Functor end, ClausesZ),
    %% If Outmod returned clauses, then we merge them with the ones from assert_a and assert_z
    case OutModProcedures of
        {clauses, Cs} ->
            {clauses, SelectedClausesA ++ Cs ++ SelectedClausesZ};
        Else ->
            Else
    end.

%% get_procedure_type(Db, Functor) ->
%%        built_in | compiled | interpreted | undefined.
%%  Return the procedure type for a functor.

get_procedure_type(#db_differ{outmod = OutMod,
                              outmoddb = Outmoddb,
                              goal_id = GoalId},
                   Functor) ->
    OutModProcedureType = OutMod:get_procedure_type(Outmoddb, Functor),
    case OutModProcedureType of
        built_in ->
            built_in;
        compiled ->
            compiled;
        interpreted ->
            interpreted;
        undefined ->
            %% Ask genserver if we have a record for this functor
            gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, {get_procedure_type, Functor})
    end.

%% get_interp_functors(Db) -> [Functor].

get_interpreted_functors(#db_differ{outmod = OutMod,
                                    outmoddb = Outmoddb,
                                    goal_id = GoalId}) ->
    OutInterpretedFunctors = OutMod:get_interpreted_functors(Outmoddb),
    case gen_server:call({via, gproc, {n, l, {differ, GoalId}}}, get_procedures) of
        {ok, {ClausesA, ClausesZ}} ->
            FunctorsA = lists:map(fun({F, _, _}) -> F end, ClausesA),
            FunctorsZ = lists:map(fun({F, _, _}) -> F end, ClausesZ),
            OutInterpretedFunctors ++ FunctorsA ++ FunctorsZ;
        _ ->
            OutInterpretedFunctors
    end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

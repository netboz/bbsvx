%%%-----------------------------------------------------------------------------
%%% @doc
%%% Gen Server built from template.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_transaction_pipeline).

-author("yan").

-behaviour(gen_server).

-include("bbsvx.hrl").

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([start_link/3, accept_transaction/1, accept_transaction_result/1]).
%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

%% Loop state
-record(state, {namespace :: binary()}).

-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(Namespace :: binary(), OntState :: ont_state(), Options :: map()) ->
                    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason :: any()}.
start_link(Namespace, OntState, Options) ->
    gen_server:start_link({via, gproc, {n, l, {?MODULE, Namespace}}},
                          ?MODULE,
                          [Namespace, OntState, Options],
                          []).

%%%=============================================================================
%%% @doc This function is the entry point to start processing a transaction.
%%% @spec accept_transaction(Transaction :: transaction()) -> ok.
%%% @end
%%%=============================================================================

-spec accept_transaction(transaction()) -> ok.
accept_transaction(#transaction{namespace = Namespace} = Transaction) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, Namespace}}},
                    {accept_transaction, Transaction}).

-spec accept_transaction_result(goal_result()) -> ok.
accept_transaction_result(#goal_result{namespace = Namespace} = GoalResult) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, Namespace}}},
                    {accept_transaction_result, GoalResult}).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

init([Namespace, OntState, _Options]) ->
    logger:info("Starting transaction pipeline for ~p", [Namespace]),
    ok = jobs:add_queue({stage_transaction_validate, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_process, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_postprocess, Namespace}, [passive]),

    ok = jobs:add_queue({stage_transaction_results, Namespace}, [passive]),

    spawn_link(fun() -> transaction_validate_stage(Namespace, OntState) end),
    spawn_link(fun() -> transaction_process_stage(Namespace, OntState) end),
    spawn_link(fun() -> transaction_postprocess_stage(Namespace, OntState) end),

    {ok, #state{namespace = Namespace}}.

handle_call({accept_transaction, Transaction},
            _From,
            #state{namespace = Namespace} = State) ->
    Reply = jobs:enqueue({stage_transaction_validate, Namespace}, Transaction),
    {reply, Reply, State};
handle_call({accept_transaction_result, GoalResult},
            _From,
            #state{namespace = Namespace} = State) ->
    Reply = jobs:enqueue({stage_transaction_results, Namespace}, GoalResult),
    {reply, Reply, State}.

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
-spec transaction_validate_stage(binary(), ont_state()) -> no_return().
transaction_validate_stage(Namespace, OntState) ->
    logger:info("Waiting for transaction ~p", [self()]),
    [{_, Transaction}] = jobs:dequeue({stage_transaction_validate, Namespace}, 1),
    logger:info("Received Transaction, validating ~p", [Transaction]),
    {AddressedTransaction, NewOntState} = transaction_validate(Transaction, OntState),
    jobs:enqueue({stage_transaction_process, Namespace}, AddressedTransaction),
    transaction_validate_stage(Namespace, NewOntState).

-spec transaction_process_stage(binary(), ont_state()) -> no_return().
transaction_process_stage(Namespace, OntState) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_process, Namespace}, 1),
    logger:info("Received Transaction, processing ~p", [Transaction]),
    process_transaction(Transaction, OntState),
    jobs:enqueue({stage_transaction_postprocess, Namespace}, Transaction),
    transaction_process_stage(Namespace, OntState).

-spec transaction_postprocess_stage(binary(), ont_state()) -> no_return().
transaction_postprocess_stage(Namespace, OntState) ->
    [{_, Transaction}] = jobs:dequeue({stage_transaction_postprocess, Namespace}, 1),
    logger:info("Received Transaction, postprocessing ~p", [Transaction]),
    transaction_postprocess_stage(Namespace, OntState).

%% Procesing functions
-spec transaction_validate(transaction(), ont_state()) -> {transaction(), ont_state()}.
transaction_validate(#transaction{} = Transaction,
                     #ont_state{current_address = CurrentAddress, next_address = NextAddress} =
                         OntState) ->
    {Transaction#transaction{current_address = NextAddress, prev_address = CurrentAddress},
     OntState}.

-spec process_transaction(transaction(), ont_state()) -> ont_state().
process_transaction(#transaction{type = creation,
                                 payload =
                                     #transaction_payload_init_ontology{namespace = Namespace,
                                                                        contact_nodes =
                                                                            _ContactNodes},
                                 namespace = Namespace} =
                        _Transaction,
                    _OntState) ->
    ok;
process_transaction(#transaction{type = goal,
                                 payload = #goal{} = Goal,
                                 namespace = Namespace} =
                        Transaction,
                    OntState) ->
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(Namespace),
    MyId = bbsvx_crypto_service:my_id(),
    case do_prove_goal(Goal, OntState, MyId == Leader) of
        {_FailOrSucceed, #ont_state{} = NewOntState} ->
            logger:info("Recording transaction ~p", [Transaction]),
            NewTransaction =
                Transaction#transaction{status = processed,
                                        ts_processed = erlang:system_time(),
                                        prev_address = Transaction#transaction.current_address,
                                        current_address = NewOntState#ont_state.current_address},
            bbsvx_transaction:record_transaction(NewTransaction),
            NewOntState;
        {error, Reason} ->
            logger:error("Error processing goal ~p: ~p", [Goal, Reason]),
            OntState
    end.

-spec do_prove_goal(goal(), ont_state(), boolean()) ->
                       {succeed, ont_state()} | {fail, ont_state()} | {error, any()}.
do_prove_goal(#goal{namespace = Namespace, payload = ReceivedPred} = Goal,
              #ont_state{namespace = Namespace, prolog_state = PrologState} = OntState,
              true) ->
    %% @TODO : Predicate validating should done in validation stage in a more robust way
    case bbsvx_ont_service:string_to_eterm(ReceivedPred) of
        {error, Reason} ->
            logger:error("Error parsing goal ~p: ~p", [ReceivedPred, Reason]),
            {error, Reason};
        Pred ->
            case erlog_int:prove_goal(Pred, PrologState) of
                {succeed, #est{db = #db{ref = #db_differ{op_fifo = OpFifo}}} = NewPrologState} ->
                    GoalResult =
                        %% @TODO : Add signature
                        #goal_result{namespace = Namespace,
                                     result = succeed,
                                     signature = <<>>,
                                     address = Goal#goal.id,
                                     diff = OpFifo},
                    bbsvx_epto_service:broadcast(Namespace, GoalResult),
                    {succeed, OntState#ont_state{prolog_state = NewPrologState}};
                {fail, NewPrologState} ->
                    %% @TODO : Add signature
                    GoalResult =
                        #goal_result{namespace = Namespace,
                                     result = fail,
                                     signature = <<>>,
                                     address = Goal#goal.id,
                                     diff = []},
                    bbsvx_epto_service:broadcast(Namespace, GoalResult),
                    {fail, OntState#ont_state{prolog_state = NewPrologState}};
                Other ->
                    logger:error("Unknown result from erlog_int:prove_goal ~p", [Other]),
                    %% @TODO : Add signature
                    GoalResult =
                        #goal_result{namespace = Namespace,
                                     result = error,
                                     signature = <<>>,
                                     address = Goal#goal.id,
                                     diff = []},
                    bbsvx_actor_spray_view:broadcast_unique(Namespace, GoalResult),
                    {error, Other}
            end
    end;
do_prove_goal(_Goal, #ont_state{prolog_state = PrologState} = OntState, false) ->
    [{_, GoalResult}] =
        jobs:dequeue({stage_transaction_results, OntState#ont_state.namespace}, 1),
    %% Get current leader
    %% @TODO: Store next two into state
    {ok, Leader} = bbsvx_actor_leader_manager:get_leader(OntState#ont_state.namespace),
    MyId = bbsvx_crypto_service:my_id(),
    case MyId == Leader of
        false ->
            case GoalResult of
                #goal_result{diff = GoalDiff, result = Result} ->
                    NewDb =
                        bbsvx_erlog_db_differ:apply_diff(GoalDiff,
                                                         OntState#ont_state.prolog_state#est.db),
                    {Result, OntState#ont_state{prolog_state = PrologState#est{db = NewDb}}};
                Else ->
                    logger:error("Unknown message ~p", [Else]),
                    OntState
            end;
        true ->
            OntState
    end.

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

example_test() ->
    ?assertEqual(true, true).

-endif.

-module(bbsvx_cowboy_websocket_handler).

-include_lib("logjam/include/logjam.hrl").
-include("bbsvx.hrl").
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).


init(Req, _Opts) ->
    {cowboy_websocket, Req, #{}, #{
        idle_timeout => infinity}}.

terminate(Reason, PartialReq, State) -> 
    ?'log-info'("Cowboy Handler : Terminating ~p", [Reason]),
    ok.

websocket_init(State) ->
    {ok, Ref} =
        gen_statem:call({via, gproc, {n, l, {bbsvx_actor_ontology, <<"bbsvx:root">>}}}, get_db_ref),
    ?'log-info'("Cowboy Handler : db Ref ~p", [Ref]),
    DumpedTable = ets:tab2list(Ref),
    ?'log-info'("Cowboy Handler : Dumped Table ~p", [DumpedTable]),
    JsonData = lists:map(fun state_entry_to_map/1, DumpedTable),
    ?'log-info'("Cowboy Handler : Json Data ~p", [JsonData]),
    Encoded = jiffy:encode(JsonData),
    ?'log-info'("Cowboy Handler : Encoded ~p", [Encoded]),
    self() ! {send, Encoded},
    gproc:reg({p, l, {diff, <<"bbsvx:root">>}}, self()),
    {ok, State}.

websocket_handle({text, Msg}, State) ->
    %% Handle incoming text message
    io:format("Received message: ~p~n", [Msg]),
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info( {send, Encoded}, State) ->
    {[{text, Encoded}], State};
websocket_info({transaction_processed, #transaction{diff = Diff}}, State) ->
    ?'log-info'("Cowboy Handler : Transaction Processed ~p", [Diff]),
    %%Diff is a list of diffs
    JsonData = lists:map(fun diff_to_json/1, Diff),
    ?'log-info'("Cowboy Handler : Diff Json Data ~p", [JsonData]),
    Encoded = jiffy:encode(JsonData),
    {[{text, Encoded}], State}.

state_entry_to_map({{Functor, Arity}, built_in}) ->
        #{functor => Functor,
          arity => Arity,
          type => built_in};
state_entry_to_map({{Functor, Arity}, clauses, NumberOfClauses, ListOfClauses}) ->
        #{functor => Functor,
          arity => Arity,
          type => clauses,
          number_of_clauses => NumberOfClauses,
          clauses => lists:map(fun clause_to_map/1, ListOfClauses)}.
    
clause_to_map({ClauseNum, Head, {_Bodies, false}}) ->
        [Functor | Params] = tuple_to_list(Head),
        JsonableParams = lists:map(fun param_to_json/1, Params),
        #{clause_num => ClauseNum,
          functor => Functor,
          arguments => JsonableParams}.
    
param_to_json({VarNum}) ->
        VarNumBin = integer_to_binary(VarNum),
        <<"Var_", VarNumBin/binary>>;
param_to_json(Value) ->
        Value.

diff_to_json({asserta, FunctorIn, Head, _Body} ) ->
    [Functor | Params] = tuple_to_list(Head),
    JsonableParams = lists:map(fun param_to_json/1, Params),
    {_, Arity} = FunctorIn,
    #{operation => asserta,
      arity  => Arity,
      head => #{arguments => JsonableParams, functor => Functor}};
diff_to_json({assertz, FunctorIn, Head, _Body} ) ->
    [Functor | Params] = tuple_to_list(Head),
    JsonableParams = lists:map(fun param_to_json/1, Params),
    {_, Arity} = FunctorIn,
    #{operation => assertz,
      arity  => Arity,
      head => #{arguments => JsonableParams, functor => Functor}};
diff_to_json({retract, FunctorIn, Tag} ) ->
    {_, Arity} = FunctorIn,
    {_, TagArity} = Tag,
    {Functor, _} = FunctorIn,
    #{operation => retract,
      arity  => Arity,
      tag_arity => TagArity,
      functor => Functor};
diff_to_json({abolish, FunctorIn} ) ->
    {_, Arity} = FunctorIn,
    {Functor, _} = FunctorIn,
    #{operation => abolish,
      arity  => Arity,
      functor => Functor}.
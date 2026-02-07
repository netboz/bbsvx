-module(bbsvx_cowboy_websocket_handler).

-include_lib("logjam/include/logjam.hrl").
-include("bbsvx.hrl").
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #{}, #{
        idle_timeout => infinity
    }}.

terminate(Reason, _PartialReq, _State) ->
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

websocket_info({send, Encoded}, State) ->
    {[{text, Encoded}], State};
websocket_info({transaction_processed, #transaction{diff = Diff, bindings = Bindings}}, State) ->
    ?'log-info'("Cowboy Handler : Transaction Processed ~p with bindings ~p", [Diff, Bindings]),
    %%Diff is a list of diffs
    DiffJsonData = lists:map(fun diff_to_json/1, Diff),
    ?'log-info'("Cowboy Handler : Diff Json Data ~p", [DiffJsonData]),

    %% Serialize bindings for JSON transmission
    BindingsJsonData = serialize_bindings(Bindings),
    ?'log-info'("Cowboy Handler : Bindings Json Data ~p", [BindingsJsonData]),

    %% Include both diffs and bindings in the response
    Response = #{
        diffs => DiffJsonData,
        bindings => BindingsJsonData
    },

    Encoded = jiffy:encode(Response),
    {[{text, Encoded}], State}.

state_entry_to_map({{Functor, Arity}, built_in}) ->
    #{
        functor => Functor,
        arity => Arity,
        type => built_in
    };
state_entry_to_map({{Functor, Arity}, code, {Module, Function}}) ->
    #{
        functor => Functor,
        arity => Arity,
        type => code,
        module => Module,
        function => Function
    };
state_entry_to_map({{Functor, Arity}, clauses, NumberOfClauses, ListOfClauses}) ->
    #{
        functor => Functor,
        arity => Arity,
        type => clauses,
        number_of_clauses => NumberOfClauses,
        clauses => lists:map(fun clause_to_map/1, ListOfClauses)
    }.

clause_to_map({ClauseNum, Head, {_Bodies, _HasCut}}) ->
    [Functor | Params] = tuple_to_list(Head),
    JsonableParams = param_list_to_json(Params),
    #{
        clause_num => ClauseNum,
        functor => Functor,
        arguments => JsonableParams
    }.

param_to_json({VarNum}) when is_integer(VarNum) ->
    VarNumBin = integer_to_binary(VarNum),
    <<"Var_", VarNumBin/binary>>;
param_to_json(Tuple) when is_tuple(Tuple) ->
    %% Handle complex nested structures (e.g., disconnect({0}))
    [Functor | Args] = tuple_to_list(Tuple),
    #{
        functor => Functor,
        args => param_list_to_json(Args)
    };
param_to_json(List) when is_list(List) ->
    param_list_to_json(List);
param_to_json(Value) ->
    Value.

%% Handle lists that may be improper (e.g., [H | T] patterns where T is a variable)
%% Prolog patterns like satisfy_prereq([Prereq | Rest]) are stored as [{0} | {1}]
%% which is an improper list (tail is a variable, not [] or another cons cell)
param_list_to_json([]) ->
    [];
param_list_to_json([H | T]) when is_list(T) ->
    [param_to_json(H) | param_list_to_json(T)];
param_list_to_json([H | T]) ->
    %% Improper list: T is not a list (e.g., a variable reference {1})
    #{
        type => cons,
        head => param_to_json(H),
        tail => param_to_json(T)
    }.

diff_to_json({asserta, FunctorIn, Head, _Body}) ->
    [Functor | Params] = tuple_to_list(Head),
    JsonableParams = param_list_to_json(Params),
    {_, Arity} = FunctorIn,
    #{
        operation => asserta,
        arity => Arity,
        head => #{arguments => JsonableParams, functor => Functor}
    };
diff_to_json({assertz, FunctorIn, Head, _Body}) ->
    [Functor | Params] = tuple_to_list(Head),
    JsonableParams = param_list_to_json(Params),
    {_, Arity} = FunctorIn,
    #{
        operation => assertz,
        arity => Arity,
        head => #{arguments => JsonableParams, functor => Functor}
    };
diff_to_json({retract, FunctorIn, Tag}) ->
    {_, Arity} = FunctorIn,
    {_, TagArity} = Tag,
    {Functor, _} = FunctorIn,
    #{
        operation => retract,
        arity => Arity,
        tag_arity => TagArity,
        functor => Functor
    };
diff_to_json({abolish, FunctorIn}) ->
    {_, Arity} = FunctorIn,
    {Functor, _} = FunctorIn,
    #{
        operation => abolish,
        arity => Arity,
        functor => Functor
    }.

%% Serialize Prolog bindings to JSON format
%% Bindings come from the Erlog state as a list of {VarName, Value} pairs
serialize_bindings([]) ->
    [];
serialize_bindings(Bindings) when is_list(Bindings) ->
    lists:map(fun serialize_binding/1, Bindings);
serialize_bindings(_) ->
    [].

%% Serialize a single binding pair
serialize_binding({VarName, Value}) when is_atom(VarName) ->
    #{
        variable => atom_to_binary(VarName),
        value => serialize_term(Value)
    };
serialize_binding({VarName, Value}) when is_binary(VarName) ->
    #{
        variable => VarName,
        value => serialize_term(Value)
    };
serialize_binding({VarName, Value}) when is_integer(VarName) ->
    %% Erlog uses integers for variable names internally
    VarNumBin = integer_to_binary(VarName),
    #{
        variable => <<"Var_", VarNumBin/binary>>,
        value => serialize_term(Value)
    };
serialize_binding(_Other) ->
    #{}.

%% Serialize Prolog terms to JSON-friendly format
serialize_term(Value) when is_atom(Value) ->
    atom_to_binary(Value);
serialize_term(Value) when is_binary(Value) ->
    Value;
serialize_term(Value) when is_integer(Value) ->
    Value;
serialize_term(Value) when is_float(Value) ->
    Value;
serialize_term({VarNum}) when is_integer(VarNum) ->
    %% Unbound variable
    VarNumBin = integer_to_binary(VarNum),
    <<"Var_", VarNumBin/binary>>;
serialize_term(Tuple) when is_tuple(Tuple) ->
    %% Complex term like foo(bar, baz)
    [Functor | Args] = tuple_to_list(Tuple),
    #{
        functor => serialize_term(Functor),
        args => lists:map(fun serialize_term/1, Args)
    };
serialize_term(List) when is_list(List) ->
    lists:map(fun serialize_term/1, List);
serialize_term(Value) ->
    %% Fallback for other types
    iolist_to_binary(io_lib:format("~p", [Value])).

%%%-----------------------------------------------------------------------------
%%% BBSvx Cowboy Ontology Handler
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_ontology).

-moduledoc "BBSvx Cowboy Ontology Handler\n\n"
"Cowboy REST handler for ontology operations.\n\n"
"Handles CREATE (PUT), DELETE, and GET operations for ontology resources via REST API.\n"
"Routes: PUT/DELETE/GET /ontologies/:namespace".

-author("yan").

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-export([
    init/2,
    allowed_methods/2,
    content_types_accepted/2,
    content_types_provided/2,
    delete_resource/2,
    delete_completed/2,
    resource_exists/2,
    malformed_request/2
]).
-export([provide_onto/2, accept_onto/2, accept_goal/2, options/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(Req0, State) ->
    Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req0),

    {cowboy_rest, Req1, State}.

options(Req, State) ->
    ?'log-info'("Options: ~p", [Req]),
    Resp =
        cowboy_req:reply(
            204,
            #{
                <<"Access-Control-Allow-Origin">> => <<"*">>,
                <<"Access-Control-Allow-Methods">> =>
                    <<"GET, POST, PUT, DELETE, OPTIONS">>,
                <<"Access-Control-Allow-Headers">> => <<"*">>
            },
            <<>>,
            Req
        ),
    {stop, Resp, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>, <<"HEAD">>, <<"OPTIONS">>], Req, State}.

malformed_request(#{path := <<"/ontologies/prove">>, method := <<"PUT">>} = Req, State) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        DBody = jiffy:decode(Body, [return_maps]),

        case DBody of
            #{<<"namespace">> := Namespace, <<"goal">> := Goal} ->
                {false, Req1, State#{namespace => Namespace, goal => Goal}};
            _ ->
                Req2 =
                    cowboy_req:set_resp_body(
                        jiffy:encode([#{error => <<"missing_namespace">>}]), Req1
                    ),
                {true, Req2, State}
        end
    catch
        A:B ->
            ?'log-warning'("Malformed request ~p:~p", [A, B]),
            Req3 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"invalid_json">>}]), Req
                ),
            {true, Req3, State}
    end;
malformed_request(
    #{path := <<"/ontologies/", _Namespace/binary>>, method := <<"PUT">>} =
        Req,
    State
) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        DBody = jiffy:decode(Body, [return_maps]),
        case maps:get(<<"namespace">>, DBody, undefined) of
            undefined ->
                Req2 =
                    cowboy_req:set_resp_body(
                        jiffy:encode([#{error => <<"missing_namespace">>}]), Req1
                    ),
                {true, Req2, State};
            _ ->
                {false, Req1, State#{body => DBody}}
        end
    catch
        A:B ->
            ?'log-warning'("Malformed request ~p:~p", [A, B]),
            Req3 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"invalid_json">>}]), Req
                ),
            {true, Req3, State}
    end;
malformed_request(
    #{path := <<"/ontologies/", _Namespace/binary>>, method := <<"GET">>} =
        Req,
    State
) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        DBody = jiffy:decode(Body, [return_maps]),
        case maps:get(<<"namespace">>, DBody, "bbsvx:root") of
            undefined ->
                ?'log-info'("Malformed request ~p:~p", [Req, State]),
                Req2 =
                    cowboy_req:set_resp_body(
                        jiffy:encode([#{error => <<"missing_namespace">>}]), Req1
                    ),
                {true, Req2, State};
            _ ->
                ?'log-info'("request accepted"),
                {false, Req1, State#{body => DBody}}
        end
    catch
        A:B ->
            ?'log-warning'("Malformed request ~p:~p", [A, B]),

            {false, Req, State#{body => #{"namespace" => "bbsvx:root"}}}
    end;
malformed_request(Req, State) ->
    ?'log-warning'("Malformed Request ~p", [Req]),
    {false, Req, State}.

resource_exists(
    #{path := <<"/ontologies/prove">>} = Req,
    #{namespace := Namespace} = State
) ->
    case bbsvx_ont_service:get_ontology(Namespace) of
        {ok, #ontology{}} ->
            {true, Req, State};
        _ ->
            Req1 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"namespace_mismatch">>}]), Req
                ),
            {false, Req1, State}
    end;
resource_exists(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    case bbsvx_ont_service:get_ontology(Namespace) of
        {ok, #ontology{} = Onto} ->
            {true, Req, maps:put(onto, Onto, State)};
        _ ->
            {false, Req, maps:put(onto, undefined, State)}
    end;
resource_exists(Req, State) ->
    {false, Req, State}.

last_modified(Req, #{onto := #ontology{last_update = LastUpdate}} = State) ->
    {LastUpdate, Req, State}.

delete_resource(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    bbsvx_ont_service:delete_ontology(Namespace),
    {true, Req, State}.

delete_completed(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    Tablelist = mnesia:system_info(tables),
    Result = lists:member(binary_to_atom(Namespace), Tablelist),
    {not Result, Req, State}.

content_types_provided(#{path := Path} = Req, State) ->
    Explo = explode_path(Path),
    ?'log-info'("Cowboy Handler : Content Types Provided Path : ~p", [Explo]),
    do_content_types_provided(Explo, Req, State).

do_content_types_provided([<<"ontologies">>, _Namespace], Req, State) ->
    ?'log-info'("Cowboy Handler : DOing Content Types Provided ~p", [Req]),
    {[{{<<"application">>, <<"json">>, []}, provide_onto}], Req, State}.

content_types_accepted(#{path := Path} = Req, State) ->
    Explo = explode_path(Path),
    do_content_types_accepted(Explo, Req, State).

do_content_types_accepted(
    [<<"ontologies">>, <<"prove">>],
    #{method := <<"PUT">>} = Req,
    State
) ->
    {[{{<<"application">>, <<"json">>, []}, accept_goal}], Req, State};
do_content_types_accepted(
    [<<"ontologies">>, _Namespace],
    #{method := <<"PUT">>} = Req,
    State
) ->
    {[{{<<"application">>, <<"json">>, []}, accept_onto}], Req, State}.

%%=============================================================================
%% Internal functions
%% ============================================================================
-spec explode_path(binary()) -> [binary()].
explode_path(Path) ->
    binary:split(Path, <<"/">>, [global, trim_all]).

provide_onto(Req, State) ->
    ?'log-info'("Cowboy Handler : Provide Onto ~p", [Req]),
    #ontology{namespace = Namespace} = maps:get(onto, State),
    {ok, Ref} =
        gen_statem:call({via, gproc, {n, l, {bbsvx_actor_ontology, Namespace}}}, get_db_ref),
    ?'log-info'("Cowboy Handler : db Ref ~p", [Ref]),
    DumpedTable = ets:tab2list(Ref),
    ?'log-info'("Cowboy Handler : Dumped Table ~p", [DumpedTable]),
    JsonData = lists:map(fun state_entry_to_map/1, DumpedTable),
    ?'log-info'("Cowboy Handler : Json Data ~p", [JsonData]),
    Encoded = jiffy:encode(JsonData),
    {Encoded, Req, State}.

accept_onto(Req0, #{onto := PreviousOntState, body := Body} = State) ->
    Namespace = cowboy_req:binding(namespace, Req0),

    Type =
        case maps:get(<<"type">>, Body, undefined) of
            undefined ->
                local;
            Value when Value == <<"local">> orelse Value == <<"shared">> ->
                binary_to_existing_atom(Value)
        end,
    case Body of
        #{<<"namespace">> := Namespace} when Type == local orelse Type == shared ->
            ProposedOnt =
                #ontology{
                    namespace = Namespace,
                    version = maps:get(<<"version">>, Body, <<"0.0.1">>),
                    contact_nodes =
                        [
                            #node_entry{host = Hst, port = Prt}
                         || #{<<"host">> := Hst, <<"port">> := Prt} <-
                                maps:get(<<"contact_nodes">>, Body, [])
                        ],
                    type = Type
                },
            case {ProposedOnt, PreviousOntState} of
                {#ontology{type = Type}, #ontology{type = Type}} ->
                    %% Identical REST request, return 3
                    %NewReq = cowboy_req:reply(304, Req1),
                    Req2 =
                        cowboy_req:set_resp_body(
                            jiffy:encode([#{info => <<"already_exists">>}]), Req0
                        ),

                    {true, Req2, State};
                {#ontology{}, undefined} ->
                    bbsvx_ont_service:create_ontology(Namespace, #{type => Type}),
                    {true, Req0, State};
                {
                    #ontology{type = shared} = ProposedOnt,
                    #ontology{type = local} = PreviousOntState
                } ->
                    bbsvx_ont_service:connect_ontology(Namespace),
                    {true, Req0, State};
                {
                    #ontology{type = local} = ProposedOnt,
                    #ontology{type = shared} = PreviousOntState
                } ->
                    bbsvx_ont_service:disconnect_ontology(Namespace),
                    {true, Req0, State}
            end;
        _ ->
            ?'log-error'("Cowboy Handler : Missing namespace in body ~p", [Body]),
            Req2 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"missing_namespace">>}]), Req0
                ),
            {false, Req2, State}
    end.

accept_goal(Req0, #{namespace := Namespace, goal := Payload} = State) ->
    ?'log-info'("Cowboy Handler : New goal ~p", [Req0]),

    %% Normalize goal: ensure it ends with ". " for Prolog parser
    NormalizedPayload = normalize_goal(Payload),

    try bbsvx_ont_service:prove(Namespace, NormalizedPayload) of
        {ok, Id} ->
            ?'log-info'("Cowboy Handler : Goal accepted ~p", [Id]),

            %% Wait a short time for the transaction to be processed and retrieve bindings
            %% This is optional - we could also add a separate endpoint to poll for results
            timer:sleep(100),

            %% Try to get the transaction result with bindings
            Response = case bbsvx_transaction:read_transaction(Namespace, Id) of
                #transaction{bindings = Bindings} when Bindings =/= [] ->
                    BindingsJson = serialize_bindings(Bindings),
                    [#{
                        status => <<"accepted">>,
                        <<"id">> => Id,
                        bindings => BindingsJson
                    }];
                _ ->
                    [#{status => <<"accepted">>, <<"id">> => Id}]
            end,

            Encoded = jiffy:encode(Response),
            ?'log-info'("Cowboy Handler : Encoded ~p", [Encoded]),
            Req1 = cowboy_req:set_resp_body(Encoded, Req0),
            {true, Req1, State};
        {error, Reason} when is_atom(Reason) ->
            Req1 = cowboy_req:set_resp_body(jiffy:encode([#{error => atom_to_binary(Reason)}]), Req0),
            {false, Req1, State};
        {error, Reason} ->
            ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
            Req1 = cowboy_req:set_resp_body(jiffy:encode([#{error => ReasonBin}]), Req0),
            {false, Req1, State}
    catch
        A:B ->
            ?'log-error'("Internal error ~p:~p", [A, B]),
            Req1 = cowboy_req:set_resp_body(jiffy:encode([#{error => <<"network_internal_error">>}]), Req0),
            {false, Req1, State}
    end.

%%-----------------------------------------------------------------------------
%% get_ulid/0
%% Return an unique identifier
%% ----------------------------------------------------------------------------
-spec get_ulid() -> binary().
get_ulid() ->
    UlidGen = persistent_term:get(ulid_gen),
    {NewGen, Ulid} = ulid:generate(UlidGen),
    persistent_term:put(ulid_gen, NewGen),
    Ulid.

state_entry_to_map({{Functor, Arity}, code, _Module}) ->
    #{
        functor => Functor,
        arity => Arity,
        type => code
    };
state_entry_to_map({{Functor, Arity}, built_in}) ->
    #{
        functor => Functor,
        arity => Arity,
        type => built_in
    };
state_entry_to_map({{Functor, Arity}, clauses, NumberOfClauses, ListOfClauses}) ->
    #{
        functor => Functor,
        arity => Arity,
        type => clauses,
        number_of_clauses => NumberOfClauses,
        clauses => lists:map(fun clause_to_map/1, ListOfClauses)
    }.

clause_to_map({ClauseNum, Head, {_Bodies, false}}) ->
    [Functor | Params] = tuple_to_list(Head),
    JsonableParams = lists:map(fun param_to_json/1, Params),
    #{
        clause_num => ClauseNum,
        functor => Functor,
        arguments => JsonableParams
    }.

param_to_json({VarNum}) ->
    VarNumBin = integer_to_binary(VarNum),
    <<"var_", VarNumBin/binary>>;
param_to_json(Value) ->
    serialize_term(Value).

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

%% Normalize a goal string to ensure it ends with ". " for Prolog parser
%% Handles: "goal" -> "goal. ", "goal." -> "goal. ", "goal. " -> "goal. "
normalize_goal(Goal) when is_binary(Goal) ->
    Trimmed = string:trim(Goal, trailing),
    case binary:last(Trimmed) of
        $. ->
            <<Trimmed/binary, " ">>;
        _ ->
            <<Trimmed/binary, ". ">>
    end;
normalize_goal(Goal) when is_list(Goal) ->
    normalize_goal(list_to_binary(Goal)).

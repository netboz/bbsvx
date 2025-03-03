%%%-----------------------------------------------------------------------------
%%% @doc
%%% Cowboy onologies handler
%%% This module handles the ontology requests from REST clients
%%% Path:
%%%  PUT        /ontologies/:namespace : Create an ontology
%%%  DELETE     /ontologies/:namespace : Delete an ontology
%%%  GET        /ontologies/:namespace : Get an ontology details
%%%
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_ontology).

-author("yan").

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-export([init/2, allowed_methods/2, content_types_accepted/2, content_types_provided/2,
         delete_resource/2, delete_completed/2, resource_exists/2, last_modified/2,
         malformed_request/2]).
-export([provide_onto/2, accept_onto/2, accept_goal/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(Req0, State) ->
    {cowboy_rest, Req0, State}.

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
                        jiffy:encode([#{error => <<"missing_namespace">>}]), Req1),
                {true, Req2, State}
        end
    catch
        A:B ->
            ?'log-warning'("Malformed request ~p:~p", [A, B]),
            Req3 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"invalid_json">>}]), Req),
            {true, Req3, State}
    end;
malformed_request(#{path := <<"/ontologies/", _Namespace/binary>>, method := <<"PUT">>} =
                      Req,
                  State) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        DBody = jiffy:decode(Body, [return_maps]),
        case maps:get(<<"namespace">>, DBody, undefined) of
            undefined ->
                Req2 =
                    cowboy_req:set_resp_body(
                        jiffy:encode([#{error => <<"missing_namespace">>}]), Req1),
                {true, Req2, State};
            _ ->
                {false, Req1, State#{body => DBody}}
        end
    catch
        A:B ->
            ?'log-warning'("Malformed request ~p:~p", [A, B]),
            Req3 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"invalid_json">>}]), Req),
            {true, Req3, State}
    end;
malformed_request(Req, State) ->
    ?'log-warning'("Malformed Request ~p", [Req]),
    {false, Req, State}.

resource_exists(#{path := <<"/ontologies/prove">>} = Req,
                #{namespace := Namespace} = State) ->
    case bbsvx_ont_service:get_ontology(Namespace) of
        {ok, #ontology{}} ->
            {true, Req, State};
        _ ->
            Req1 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"namespace_mismatch">>}]), Req),
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
    do_content_types_provided(Explo, Req, State).

do_content_types_provided([<<"ontologies">>, _Namespace], Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_onto}], Req, State}.

content_types_accepted(#{path := Path} = Req, State) ->
    Explo = explode_path(Path),
    do_content_types_accepted(Explo, Req, State).

do_content_types_accepted([<<"ontologies">>, <<"prove">>],
                          #{method := <<"PUT">>} = Req,
                          State) ->
    {[{{<<"application">>, <<"json">>, []}, accept_goal}], Req, State};
do_content_types_accepted([<<"ontologies">>, _Namespace],
                          #{method := <<"PUT">>} = Req,
                          State) ->
    {[{{<<"application">>, <<"json">>, []}, accept_onto}], Req, State}.

%%=============================================================================
%% Internal functions
%% ============================================================================
-spec explode_path(binary()) -> [binary()].
explode_path(Path) ->
    binary:split(Path, <<"/">>, [global, trim_all]).

provide_onto(Req, State) ->
    GoalId = cowboy_req:binding(goal_id, Req),
    Goal = bbsvx_ont_service:get_goal(GoalId),
    {jiffy:encode(Goal), Req, State}.

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
        #{<<"namespace">> := Namespace}  when Type == local orelse Type == shared ->
            ProposedOnt =
                #ontology{namespace = Namespace,
                          version = maps:get(<<"version">>, Body, <<"0.0.1">>),
                          contact_nodes =
                              [#node_entry{host = Hst, port = Prt}
                               || #{<<"host">> := Hst, <<"port">> := Prt}
                                      <- maps:get(<<"contact_nodes">>, Body, [])],
                          type = Type},
            case {ProposedOnt, PreviousOntState} of
                {#ontology{type = Type}, #ontology{type = Type}} ->
                    %% Identical REST request, return 3
                    %NewReq = cowboy_req:reply(304, Req1),
                    Req2 =
                        cowboy_req:set_resp_body(
                            jiffy:encode([#{info => <<"already_exists">>}]), Req0),

                    {true, Req2, State};
                {#ontology{}, undefined} ->
                    bbsvx_ont_service:new_ontology(ProposedOnt),
                    {true, Req0, State};
                {#ontology{type = shared} = ProposedOnt,
                 #ontology{type = local} = PreviousOntState} ->
                    bbsvx_ont_service:connect_ontology(Namespace),
                    {true, Req0, State};
                {#ontology{type = local} = ProposedOnt,
                 #ontology{type = shared} = PreviousOntState} ->
                    bbsvx_ont_service:disconnect_ontology(Namespace),
                    {true, Req0, State}
            end;
        _ ->
            ?'log-error'("Cowboy Handler : Missing namespace in body ~p", [Body]),
            Req2 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"missing_namespace">>}]), Req0),
            {false, Req2, State}
    end.

accept_goal(Req0, #{namespace := Namespace, goal := Payload} = State) ->
    ?'log-info'("Cowboy Handler : New goal ~p", [Req0]),

    try bbsvx_ont_service:prove(Namespace, Payload) of
        {ok, Id} ->
            Req1 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{status => <<"accepted">>, <<"id">> => Id}]), Req0),
            {true, Req1, State};
        {error, Reason} ->
            Req2 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => atom_to_binary(Reason)}]), Req0),
            {true, Req2, State}
    catch
        A:B ->
            ?'log-error'("Internal error ~p:~p", [A, B]),
            Req3 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"network_internal_error">>}]), Req0),
            {true, Req3, State}
    end.

%%-----------------------------------------------------------------------------
%% @doc
%% get_ulid/0
%% Return an unique identifier
%% @end
%% ----------------------------------------------------------------------------
-spec get_ulid() -> binary().
get_ulid() ->
    UlidGen = persistent_term:get(ulid_gen),
    {NewGen, Ulid} = ulid:generate(UlidGen),
    persistent_term:put(ulid_gen, NewGen),
    Ulid.

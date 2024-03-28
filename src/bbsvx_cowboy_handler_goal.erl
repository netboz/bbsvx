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

-module(bbsvx_cowboy_handler_goal).

-author("yan").

-include("bbsvx_common_types.hrl").

-export([init/2, allowed_methods/2, content_types_accepted/2, content_types_provided/2,
         delete_resource/2, delete_completed/2, resource_exists/2, last_modified/2]).
-export([provide_onto/2, accept_onto/2, accept_goal/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(Req0, State) ->
    {cowboy_rest, Req0, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>, <<"HEAD">>, <<"OPTIONS">>], Req, State}.

resource_exists(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    case bbsvx_ont_service:get_ontology(Namespace) of
        {ok, #ontology{} = Onto} ->
            logger:info("Ontology ~p exists ~p", [Namespace, Onto]),
            {true, Req, maps:put(onto, Onto, State)};
        _ ->
            logger:info("Ontology ~p does not exist", [Namespace]),
            {false, Req, maps:put(onto, undefined, State)}
    end;
resource_exists(Req, State) ->
    logger:info("Ontology ~p ressource exists catch all", [Req]),
    {false, Req, State}.

last_modified(Req, #{onto := #ontology{last_update = LastUpdate}} = State) ->
    logger:info("Last update ~p", [LastUpdate]),
    {LastUpdate, Req, State}.

delete_resource(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    bbsvx_ont_service:delete_ontology(binary_to_atom(Namespace)),
    {true, Req, State}.

delete_completed(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    Tablelist = mnesia:system_info(tables),
    logger:info("Table list ~p", [Tablelist]),
    logger:info("Ontology ~p", [binary_to_atom(Namespace)]),
    Result = lists:member(binary_to_atom(Namespace), Tablelist),
    logger:info("Ontology ~p exists ~p", [Namespace, Result]),
    {not Result, Req, State}.

content_types_provided(#{path := Path} = Req, State) ->
    Explo = binary:split(Path, <<"/">>, [global, trim_all]),
    do_content_types_provided(Explo, Req, State).

do_content_types_provided([<<"ontologies">>, _Namespace], Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_onto}], Req, State}.

content_types_accepted(#{path := Path} = Req, State) ->
    Explo = binary:split(Path, <<"/">>, [global, trim_all]),
    do_content_types_accepted(Explo, Req, State).

do_content_types_accepted([<<"ontologies">>, _Namespace, <<"prove">>],
                          #{method := <<"POST">>} = Req,
                          State) ->
    {[{{<<"application">>, <<"json">>, []}, accept_goal}], Req, State};
do_content_types_accepted([<<"ontologies">>, _Namespace],
                          #{method := <<"PUT">>} = Req,
                          State) ->
    {[{{<<"application">>, <<"json">>, []}, accept_onto}], Req, State}.

%%=============================================================================
%% Internal functions
%% ============================================================================

provide_onto(Req, State) ->
    logger:info("Processing get goal request ~p", [Req]),
    GoalId = cowboy_req:binding(goal_id, Req),
    Goal = bbsvx_ont_service:get_goal(GoalId),
    {jiffy:encode(Goal), Req, State}.

accept_onto(Req0, #{onto := PreviousOntState} = State) ->
    logger:info("Cowboy Handler : Accept Onto", []),

    Namespace = cowboy_req:binding(namespace, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    DBody = jiffy:decode(Body, [return_maps]),
    logger:info("DBody ~p", [DBody]),
    Type = case maps:get(<<"type">>, DBody, undefined) of
               undefined -> local;
               Value -> binary_to_existing_atom(Value)
           end,
    case DBody of
        #{<<"namespace">> := Namespace} ->
            ProposedOnt =
                #ontology{namespace = Namespace,
                          contact_nodes =
                              [#node_entry{host = Hst, port = Prt}
                               || #{<<"host">> := Hst, <<"port">> := Prt} <- maps:get(<<"contact_nodes">>, DBody, [])],
                          type = Type},
            case {ProposedOnt, PreviousOntState} of
                {#ontology{type = Type}, #ontology{type = Type}} ->
                    %% Identical REST request, return 3
                    %NewReq = cowboy_req:reply(304, Req1),
                    Req2 =
                        cowboy_req:set_resp_body(
                            jiffy:encode([#{info => <<"already_exists">>}]), Req1),

                    {true, Req2, State};
                {#ontology{}, undefined} ->
                    logger:info("Cowboy Handler : Creating New ontology ~p", [ProposedOnt]),
                    bbsvx_ont_service:new_ontology(ProposedOnt),
                    {true, Req1, State};
                {#ontology{type = shared} = ProposedOnt,
                 #ontology{type = local} = PreviousOntState} ->
                    logger:info("Cowboy Handler : connecting ~p", [ProposedOnt]),
                    bbsvx_ont_service:connect_ontology(Namespace),
                    {true, Req1, State};
                {#ontology{type = local} = ProposedOnt,
                 #ontology{type = shared} = PreviousOntState} ->
                    logger:info("Cowboy Handler : disconnecting ~p", [ProposedOnt]),
                    bbsvx_ont_service:disconnect_ontology(Namespace),
                    {true, Req1, State}
            end;
        _ ->
            logger:error("Cowboy Handler : Missing namespace in body ~p", [DBody]),
            Req2 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"missing_namespace">>}]), Req1),
            {false, Req2, State}
    end.

accept_goal(Req0, State) ->
    logger:info("Cowboy Handler : New goal ~p", [Req0]),

    Namespace = cowboy_req:binding(namespace, Req0),

    logger:info("Cowboy Handler : New goal for namespace ~p", [Namespace]),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"namespace">> := Namespace2, <<"payload">> := Payload} =
        jiffy:decode(Body, [return_maps]),
    Goal = #goal{namespace = Namespace, payload = Payload},
    logger:info("new_ontology namespace frm body ~p", [Namespace2]),
    bbsvx_ont_service:new_ontology(#ontology{namespace = Namespace}),
    {true, Req1, State}.

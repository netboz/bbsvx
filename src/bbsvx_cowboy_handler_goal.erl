%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_goal).

-author("yan").

-include("bbsvx_common_types.hrl").

-export([init/2, allowed_methods/2, content_types_accepted/2, content_types_provided/2,
         resource_exists/2]).
-export([provide_onto/2, accept_onto/2, accept_goal/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(Req0, State) ->
    {cowboy_rest, Req0, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"HEAD">>, <<"OPTIONS">>], Req, State}.

resource_exists(#{path := <<"/ontologies/", Namespace/binary>>} = Req, State) ->
    Tablelist = mnesia:system_info(tables),
    logger:info("Table list ~p", [Tablelist]),
    logger:info("Ontology ~p", [binary_to_atom(Namespace)]),
    Result = lists:member(binary_to_atom(Namespace), Tablelist),
    logger:info("Ontology ~p exists ~p", [Namespace, Result]),
    {Result, Req, State}.

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

provide_onto(Req, State) ->
    logger:info("Processing get goal request ~p", [Req]),
    GoalId = cowboy_req:binding(goal_id, Req),
    Goal = bbsvx_ont_service:get_goal(GoalId),
    {jiffy:encode(Goal), Req, State}.

accept_onto(Req0, State) ->
    logger:info("Cowboy Handler : New ontology ~p", [Req0]),

    Namespace = cowboy_req:binding(namespace, Req0),
    logger:info("Cowboy Handler : New ontology namespace ~p", [Namespace]),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"namespace">> := Namespace2} = jiffy:decode(Body, [return_maps]),
    logger:info("new_ontology namespace frm body ~p", [Namespace2]),
    bbsvx_ont_service:new_ontology(#ontology{namespace = Namespace}),
    {true, Req1, State}.

accept_goal(Req0, State) ->
    logger:info("Cowboy Handler : New goal ~p", [Req0]),

    Namespace = cowboy_req:binding(namespace, Req0),

    logger:info("Cowboy Handler : New goal for namespace ~p", [Namespace]),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"namespace">> := Namespace2, <<"payload">> := Payload} = jiffy:decode(Body, [return_maps]),
    Goal = #goal{namespace = Namespace, payload = Payload},
    logger:info("new_ontology namespace frm body ~p", [Namespace2]),
    bbsvx_ont_service:new_ontology(#ontology{namespace = Namespace}),
    {true, Req1, State}.

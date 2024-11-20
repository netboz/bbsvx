%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_rest_service_spray).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-export([init/2, allowed_methods/2, malformed_request/2, resource_exists/2,
         content_types_provided/2]).
-export([provide_outview/2, provide_inview/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(Req0, State) ->
    {cowboy_rest, Req0, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"HEAD">>, <<"POST">>, <<"OPTIONS">>], Req, State}.

malformed_request(Req, State) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        ?'log-info'("Body: ~p", [Body]),
        DBody = jiffy:decode(Body, [return_maps]),
        ?'log-info'("BBody: ~p", [DBody]),

        case DBody of
            #{<<"namespace">> := Namespace} ->
                {false, Req1, State#{namespace => Namespace}};
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
malformed_request(Req, State) ->
    ?'log-warning'("Malformed Request ~p", [Req]),
    Req1 =
        cowboy_req:set_resp_body(
            jiffy:encode([#{error => <<"invalid_json">>}]), Req),
    {true, Req1, State}.

resource_exists(Req, #{namespace := Namespace} = State) ->
    case bbsvx_ont_service:get_ontology(Namespace) of
        {ok, #ontology{} = Onto} ->
            {true, Req, State#{onto => Onto}};
        _ ->
            Req1 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"ontology_not_found">>}]), Req),
            {false, Req1, State}
    end.

content_types_provided(#{path := <<"/spray/inview">>} = Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_inview}], Req, State};
content_types_provided(#{path := <<"/spray/outview">>} = Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_outview}], Req, State};
content_types_provided(Req, State) ->
    ?'log-info'("Path: ~p", [Req]),
    ?'log-info'("State: ~p", [State]),
    Req2 =
        cowboy_req:set_resp_body(
            jiffy:encode([#{error => <<"missing_namespace">>}]), Req),
    {false, Req2, State}.

-spec get_view(atom(), binary()) -> {ok, [arc()]} | {error, binary()}.
get_view(Type, Namespace) when Type == get_inview orelse Type == get_outview ->
    %% Look for spray agent
    case gproc:where({n, l, {bbsvx_actor_spray, Namespace}}) of
        undefined ->
            ?'log-error'("No view actor on namespace ~p:", [Namespace]),
            {error, <<"no_actor_on_namespace_", Namespace/binary>>};
        Pid ->
            gen_statem:call(Pid, Type)
    end.

provide_outview(Req, #{namespace := Namespace} = State) ->
    ?'log-info'("provide_outview: ~p", [Namespace]),
    ?'log-info'("State: ~p", [State]),
    ?'log-info'("Req: ~p", [Req]),
    MyId = bbsvx_crypto_service:my_id(),
    case get_view(get_outview, Namespace) of
        {error, Reason} ->
            ?'log-error'("Error: ~p", [Reason]),
            {jiffy:encode([#{error => Reason}]), Req, State};
        {ok, View} ->
            ?'log-info'("Got View: ~p", [View]),
            {jiffy:encode(
                 lists:map(fun(#arc{ulid = Ulid,
                                    source = Source,
                                    target = Target,
                                    lock = Lock,
                                    age = Age}) ->
                              #{
                                my_id => MyId,
                                ulid => Ulid,
                                source => node_entry_to_map(Source),
                                target => node_entry_to_map(Target),
                                lock => Lock,
                                age => Age}
                           end,
                           View)),
             Req,
             State}
    end.

provide_inview(Req, #{namespace := Namespace} = State) ->
    ?'log-info'("provide_inview: ~p", [Namespace]),
    ?'log-info'("State: ~p", [State]),
    ?'log-info'("Req: ~p", [Req]),
    MyId = bbsvx_crypto_service:my_id(),
    case get_view(get_inview, Namespace) of
        {error, Reason} ->
            {jiffy:encode([#{error => Reason}]), Req, State};
        {ok, View} ->
            ?'log-info'("Got View: ~p", [View]),
            {jiffy:encode(
                 lists:map(fun(#arc{ulid = Ulid,
                                    source = Source,
                                    target = Target,
                                    lock = Lock,
                                    age = Age}) ->
                              #{
                                my_id => MyId,
                                ulid => Ulid,
                                source => node_entry_to_map(Source),
                                target => node_entry_to_map(Target),
                                lock => Lock,
                                age => Age}
                           end,
                           View)),
             Req,
             State}
    end.

format_host(Host) when is_binary(Host) ->
    Host;
format_host(Host) when is_list(Host) ->
    list_to_binary(Host);
format_host({A, B, C, D}) ->
    list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])).


%% Convert a node_entry to a map
-spec node_entry_to_map(node_entry()) -> map().
node_entry_to_map(#node_entry{node_id = NodeId, host = Host, port = Port}) ->
    #{node_id => NodeId, host => format_host(Host), port => Port}.
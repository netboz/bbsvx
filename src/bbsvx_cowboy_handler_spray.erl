%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_spray).

-include("bbsvx.hrl").

-include_lib("logjam/include/logjam.hrl").

-export([init/2, allowed_methods/2, malformed_request/2, resource_exists/2,
         content_types_provided/2, content_types_accepted/2, options/2]).
-export([provide_outview/2, provide_inview/2, stop_spray_agent/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(Req0, State) ->
    ?'log-info'("---->   Init", []),
    {cowboy_rest, Req0, State}.

options(Req, State) ->
    ?'log-info'("Options: ~p", [Req]),
    Resp =
        cowboy_req:reply(204,
                         #{<<"access-control-allow-origin">> => <<"*">>,
                           <<"access-control-allow-methods">> =>
                               <<"GET, POST, PUT, DELETE, OPTIONS">>,
                           <<"access-control-allow-headers">> => <<"*">>},
                         <<>>,
                         Req),
    {stop, Resp, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"OPTIONS">>, <<"DELETE">>], Req, State}.

malformed_request(Req, State) ->
    ?'log-info'("Malformed Request: ~p", [Req]),
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        ?'log-info'("Body: ~p", [Body]),
        ?'log-info'("Req: ~p", [Req]),

        DBody = jiffy:decode(Body, [return_maps]),
        ?'log-info'("BBody: ~p", [DBody]),

        case DBody of
            #{<<"namespace">> := Namespace} ->
                ?'log-info'("request ok : Namespace: ~p", [Namespace]),
                {false, Req1, State#{namespace => Namespace, body => DBody}};
            _ ->
                Req2 =
                    cowboy_req:set_resp_body(
                        jiffy:encode([#{error => <<"missing_namespace">>}]), Req1),
                {true, Req2, State}
        end
    catch
        A:B ->
            {false, Req, State#{namespace => <<"bbsvx:root">>}}
    end;
malformed_request(Req, State) ->
    {false, Req, State#{namespace => <<"bbsvx:root">>}}.

resource_exists(Req, #{namespace := Namespace} = State) ->
    ?'log-info'("Resource Exists: ~p", [Req]),
    case bbsvx_ont_service:get_ontology(Namespace) of
        {ok, #ontology{} = Onto} ->
            %% Add CORS header even on success, if you'd like
            Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req),
            {true, Req1, State#{onto => Onto}};
        _ ->
            %% Also add on error
            Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req),
            Req2 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"ontology_not_found">>}]), Req1),
            {false, Req2, State}
    end.

content_types_accepted(Req, State) ->
    ?'log-info'("Content Types Accepted: ~p", [Req]),
    {[{{<<"application">>, <<"json">>, []}, stop_spray_agent}], Req, State}.

content_types_provided(#{path := <<"/spray/inview">>} = Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_inview}], Req, State};
content_types_provided(#{path := <<"/spray/outview">>} = Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_outview}], Req, State};
content_types_provided(Req, State) ->
    ?'log-info'("Content Types Provided: ~p", [Req]),
    {[{{<<"application">>, <<"json">>, []}, stop_spray_agent}], Req, State}.

stop_spray_agent(Req, #{namespace := Namespace} = State) ->
    ?'log-info'("Stopping spray agent on namespace ~p", [Namespace]),
    Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req),
    case gproc:where({n, l, {bbsvx_actor_spray, Namespace}}) of
        undefined ->
            ?'log-error'("No spray agent on namespace ~p", [Namespace]),
            {jiffy:encode([#{result => ok}]), Req1, State};
        Pid ->
            ?'log-info'("Sending delete_node event to spray agent ~p", [Pid]),
            %% Send a delete_node event to the spray agent
            gen_statem:stop(Pid),
            ?'log-info'("Spray agent ~p stopped", [Pid]),
            Req2 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{result => <<"ok">>}]), Req1),
            {true, Req2, State}
    end.

-spec get_view(atom(), binary()) -> {ok, [arc()]} | {error, binary()}.
get_view(Type, Namespace) when Type == get_inview orelse Type == get_outview ->
    %% Look for spray agent
    case Type of
        get_inview ->
            InView = bbsvx_actor_spray:get_inview(Namespace),
            {ok, InView};
        get_outview ->
            OutView = bbsvx_actor_spray:get_outview(Namespace),
            {ok, OutView}
    end.

provide_outview(Req, #{namespace := Namespace} = State) ->
    MyId = bbsvx_crypto_service:my_id(),
    case get_view(get_outview, Namespace) of
        {error, Reason} ->
            ?'log-error'("Error: ~p", [Reason]),
            {jiffy:encode([#{error => Reason}]), Req, State};
        {ok, View} ->
            %% Add Access-Control-Allow-Origin header
            Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req),
            ?'log-info'("Got View: ~p", [View]),
            {jiffy:encode(
                 lists:map(fun(#arc{ulid = Ulid,
                                    source = Source,
                                    target = Target,
                                    lock = Lock,
                                    age = Age}) ->
                              #{my_id => MyId,
                                ulid => Ulid,
                                source => node_entry_to_map(Source),
                                target => node_entry_to_map(Target),
                                lock => Lock,
                                age => Age}
                           end,
                           View)),
             Req1,
             State}
    end.

provide_inview(Req, #{namespace := Namespace} = State) ->
    MyId = bbsvx_crypto_service:my_id(),
    case get_view(get_inview, Namespace) of
        {error, Reason} ->
            {jiffy:encode([#{error => Reason}]), Req, State};
        {ok, View} ->
            %% Add Access-Control-Allow-Origin header
            Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req),
            ?'log-info'("Got View: ~p", [View]),
            {jiffy:encode(
                 lists:map(fun(#arc{ulid = Ulid,
                                    source = Source,
                                    target = Target,
                                    lock = Lock,
                                    age = Age}) ->
                              #{my_id => MyId,
                                ulid => Ulid,
                                source => node_entry_to_map(Source),
                                target => node_entry_to_map(Target),
                                lock => Lock,
                                age => Age}
                           end,
                           View)),
             Req1,
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
node_entry_to_map(#node_entry{node_id = NodeId,
                              host = Host,
                              port = Port}) ->
    #{node_id => NodeId,
      host => format_host(Host),
      port => Port}.

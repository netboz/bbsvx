%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_node_service).

-author("yan").

-include("bbsvx_common_types.hrl").

-export([init/2]).
%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(#{method := <<"GET">>, path := <<"/subs/", ClientId/binary>>} = Req0, State) ->
    logger:info("Processing get subs request ~p", [Req0]),
    Conn = gproc:where({n, l, {bbsvx_mqtt_connection, ClientId}}),
    Result =
        case Conn of
            undefined ->
                logger:error("No connection found for ~p", [ClientId]),
                jiffy:encode([#{"error" => <<"No connection found">>}]);
            Pid ->
                {ok, Data} = gen_server:call(Pid, get_susbscriptions),
                jiffy:encode(Data)
        end,
    Req = cowboy_req:reply(200,
                           #{<<"content-type">> => <<"application/json">>},
                           Result,
                           Req0),
    {ok, Req, State};

init(#{method := <<"GET">>} = Req0, State) ->
    logger:info("Processing get view request ~p", [Req0]),
    Onto = cowboy_req:binding(namespace, Req0),
    Type = view_type_to_atom(cowboy_req:binding(view_type, Req0)),
    logger:info("Bindings ~p", [cowboy_req:bindings(Req0)]),
    %% Get my node id from crypto service
    MyId = bbsvx_crypto_service:my_id(),
    case get_view(Type, Onto) of
        undefined ->
            Req = cowboy_req:reply(404,
                                   #{<<"content-type">> => <<"text/plain">>},
                                   <<"Not Found">>,
                                   Req0),
            {ok, Req, State};
        {ok, View} ->
            logger:info("Got view : ~p", [View]),
            Result =
                case Type of
                    get_outview ->
                        jiffy:encode([#{id =>
                                            list_to_binary(uuid:to_string(
                                                               uuid:uuid4())),
                                        my_id => MyId,
                                        source => MyId,
                                        target => NodeId,
                                        host => list_to_binary(inet:ntoa(Host)),
                                        port => Port,
                                        age => Age}
                                      || #node_entry{host = Host,
                                                     port = Port,
                                                     node_id = NodeId,
                                                     age = Age}
                                             <- View]);
                    get_inview ->
                        jiffy:encode([#{id =>
                                            list_to_binary(uuid:to_string(
                                                               uuid:uuid4())),
                                        my_id => MyId,
                                        source => NodeId,
                                        target => MyId,
                                        host => list_to_binary(inet:ntoa(Host)),
                                        port => Port,
                                        age => Age}
                                      || #node_entry{host = Host,
                                                     port = Port,
                                                     node_id = NodeId,
                                                     age = Age}
                                             <- View])
                end,
            Req = cowboy_req:reply(200,
                                   #{<<"content-type">> => <<"application/json">>},
                                   Result,
                                   Req0),
            {ok, Req, State}
    end;

init(#{method := <<"POST">>, path := <<"/epto/post/", Namespace/binary>>} = Req0,
     State) ->
    logger:info("Processing post view request ~p", [Req0]),
    logger:info("Namespace ~p", [Namespace]),
    {ok, Body, _} = cowboy_req:read_body(Req0),
    Comp = gproc:where({n, l, {bbsvx_epto_dissemination_comp, <<"bbsvx:root">>}}),
    gen_server:call(Comp, {epto_broadcast, Body}),
    {ok, Req0, State};
init(Req0, State) ->
    logger:info("Processing unknown request ~p", [Req0]),
    Req = cowboy_req:reply(200,
                           #{<<"content-type">> => <<"text/plain">>},
                           <<"Hello Erlang!">>,
                           Req0),
    logger:info("Request ~p", [Req]),
    {ok, Req, State}.

get_view(undefined, _) ->
    undefined;
get_view(Type, Namespace) ->
    %% Look for spray agent
    case gproc:where({n, l, {bbsvx_actor_spray_view, Namespace}}) of
        undefined ->
            logger:error("No view actor found"),
            undefined;
        Pid ->
            gen_statem:call(Pid, Type)
    end.

view_type_to_atom(<<"in">>) ->
    get_inview;
view_type_to_atom(<<"out">>) ->
    get_outview;
view_type_to_atom(_Unk) ->
    undefined.

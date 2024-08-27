%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_node_service).

-author("yan").

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

-export([init/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

init(#{method := <<"GET">>, path := <<"/subs/", ClientId/binary>>} = Req0, State) ->
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
    Onto = cowboy_req:binding(namespace, Req0),
    Type = view_type_to_atom(cowboy_req:binding(view_type, Req0)),
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
            Result =
                case Type of
                    get_outview ->
                        jiffy:encode([#{id =>
                                            list_to_binary(uuid:to_string(
                                                               uuid:uuid4())),
                                        my_id => MyId,
                                        source => MyId,
                                        target => NodeId,
                                        host => Host,
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
                                        host => Host,
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

    {ok, Body, _} = cowboy_req:read_body(Req0),
    Comp = gproc:where({n, l, {bbsvx_epto_dissemination_comp, <<"bbsvx:root">>}}),
    gen_server:call(Comp, {epto_broadcast, Body}),
    {ok, Req0, State};
init(Req0, State) ->
    ?'log-warning'("Processing unknown request ~p", [Req0]),
    Req = cowboy_req:reply(200,
                           #{<<"content-type">> => <<"text/plain">>},
                           <<"Hello Erlang!">>,
                           Req0),
    {ok, Req, State}.

get_view(undefined, _) ->
    undefined;
get_view(Type, Namespace) ->
    %% Look for spray agent
    case gproc:where({n, l, {bbsvx_actor_spray_view, Namespace}}) of
        undefined ->
            ?'log-error'("No view actor found ~p", [Namespace]),
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

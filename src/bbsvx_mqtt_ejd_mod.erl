%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_mqtt_ejd_mod).

-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================
-include_lib("ejabberd/include/mqtt.hrl").

-behaviour(gen_mod).

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([handle_register_user/2, handle_mqtt_publish_hook/3, handle_mqtt_subscribe_hook/4,
         handle_mqtt_unsubscribe_hook/2]).

-define(MAX_UINT32, 4294967295).

start(Host, Opts) ->
    logger:info("bbsx_mqtt_ejd_mod:start/2 called with Host: ~p, Opts: ~p", [Host, Opts]),

    %% Publish my id to the welcome topic
    %%MyId = bbsvx_crypto_service:my_id(),
    %%mod_mqtt:publish({<<"bob1">>, <<"bob2">>, <<"bob3>>">>}, #publish{topic = <<"welcome">>, payload = MyId, retain = true}, 3000),
    ejabberd_hooks:add(register_user, Host, ?MODULE, handle_register_user, 50),
    ejabberd_hooks:add(mqtt_publish, Host, ?MODULE, handle_mqtt_publish_hook, 50),
    ejabberd_hooks:add(mqtt_subscribe, Host, ?MODULE, handle_mqtt_subscribe_hook, 50),
    ejabberd_hooks:add(mqtt_unsubscribe, Host, ?MODULE, handle_mqtt_unsubscribe_hook, 50),
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

handle_register_user(LUser, LServer) ->
    logger:info("---> Hook handle_register_user called with LUser: ~p, LServer: ~p",
                [LUser, LServer]),
    ok.

%% Manage contact requests
%% TODO: check if the user is already in the contact list
handle_mqtt_publish_hook(Usr, #publish{topic = Topic, payload = Payload}, _Exp) ->
    process_publish(Usr, binary:split(Topic, <<"/">>, [global]), binary_to_term(Payload)),
    ok;
handle_mqtt_publish_hook(Usr, Pkt, Exp) ->
    logger:warning("BBSVX ejabberd mod : Unmanaged packet ~p ~p", [Pkt, Exp]),
    ok.

%% Manage contact requests
handle_mqtt_subscribe_hook(Usr, <<"welcome">>, _SubOpts, _Id) ->
    logger:info("BBSVX ejabberd mod : Connection request from ~p", [Usr]),
    ok;
handle_mqtt_subscribe_hook(Usr, TopicFilter, SubOpts, Id) ->
    logger:info("bbsvx ejabberd mod : Subscribe request from ~p, TopicFilter: ~p, SubOpts: ~p, Id: ~p",
                [Usr, TopicFilter, SubOpts, Id]),
    ok.

handle_mqtt_unsubscribe_hook(Usr, Topic) ->
    logger:info("BBSVX ejabberd mod : Unsubscribe request from ~p, Topic: ~p", [Usr, Topic]),
    ok.

process_publish(Usr,
                [<<"ontologies">>, <<"contact">>, Namespace, ClientId] = Topic,
                {join, ClientId, {Host, Port}}) ->
    logger:info("BBSVX ejabberd mod : Got contact request : ~p ~p ~p", [Namespace, ClientId, {Host, Port}]),
    %% Signal connection service we have an incoming contact request
    bbsvx_connections_service:incoming_contact_request(ClientId, {Host, Port}, Namespace),
    ok;
process_publish(Usr, Topic, Payload) ->
    logger:info("BBSVX ejabberd mod : Process_publish called with Usr: ~p, Topic: ~p, Payload: ~p",
                [Usr, Topic, Payload]),
    ok.




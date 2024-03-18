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
-include("bbsvx_common_types.hrl").

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
handle_mqtt_publish_hook(_Usr, Pkt, Exp) ->
    logger:warning("BBSVX ejabberd mod : Unmanaged packet ~p ~p", [Pkt, Exp]),
    ok.

%% Manage contact requests
handle_mqtt_subscribe_hook(_Usr, <<"welcome">>, _SubOpts, _Id) ->
    ok;
handle_mqtt_subscribe_hook(_Usr, _TopicFilter, _SubOpts, _Id) ->
    ok.

%% Manage unsubscribe requests from inview

handle_mqtt_unsubscribe_hook(Usr, Topic) ->
    logger:info("BBSVX ejabberd mod : Unsubscribe request from ~p, Topic: ~p", [Usr, Topic]),
    process_unsubscribe(Usr, binary:split(Topic, <<"/">>, [global])),
    ok.


process_publish(_Usr,
                [<<"ontologies">>, <<"in">>, Namespace, RequesterClientId],
                {subscribe, #node_entry{node_id = RequesterClientId, host = RequesterHost, port = RequesterPort} = RequesterNode}) ->
    logger:info("BBSVX ejabberd mod : Got ontology : ~p subscribe request from: ~p ~p",
                [Namespace, RequesterClientId, {RequesterHost, RequesterPort}]),
    %% Signal connection service we have an incoming subscribe request to this ontology
    gproc:send({p, l, {ontology, Namespace}},
               {contact_request,
                RequesterNode}),
    %%bbsvx_connections_service:incoming_contact_request(ClientId, {Host, Port}, Namespace),
    ok;
process_publish(_Usr,
                [<<"ontologies">>, <<"in">>, Namespace, RequesterClientId],
                {inview_join_request,
                 #node_entry{host = ReqHost, port = ReqPort} = RequesterNode}) ->
    logger:info("BBSVX ejabberd mod : Got inview subscribe request : ~p ~p ~p",
                [Namespace, RequesterClientId, {ReqHost, ReqPort}]),
    %% Signal connection service we have an incoming contact request
    MyId = bbsvx_crypto_service:my_id(),
    {ok, {MyHost, MyPort}} = bbsvx_connections_service:my_host_port(),

    spawn(fun() ->
             R = mod_mqtt:publish({MyId, <<"localhost">>, <<"bob3>>">>},
                                  #publish{topic =
                                               iolist_to_binary([<<"ontologies/in/">>,
                                                                 Namespace,
                                                                 "/",
                                                                 RequesterClientId]),
                                           payload =
                                               term_to_binary({inview_join_accepted,
                                                               Namespace,
                                                               #node_entry{node_id = MyId,
                                                                           host = MyHost,
                                                                           port = MyPort,
                                                                           age = 0}}),
                                           retain = false},
                                  ?MAX_UINT32),
             logger:info("BBSVX ejabberd mod : Publish result: ~p", [R])
          end),
    gproc:send({p, l, {ontology, Namespace}}, {add_to_view, inview, RequesterNode}),
    ok;
%% MAnage incming forward requests
process_publish(_Usr,
                [<<"ontologies">>, <<"in">>, Namespace, _ReceivedFromClientId],
                {forwarded_subscription, Namespace, #node_entry{} = RequesterNode}) ->
    gproc:send({p, l, {ontology, Namespace}},
               {forwarded_subscription, Namespace, RequesterNode}),
    ok;
process_publish(_Usr,[<<"ontologies">>, <<"in">>, Namespace, _ReceivedFromClientId],{partial_view_exchange_in,Namespace,#node_entry{} = OriginNode,IncomingSamplePartialView}) ->
    gproc:send({p, l, {ontology, Namespace}},
               {partial_view_exchange_in,
                Namespace,
                #node_entry{} = OriginNode,
                IncomingSamplePartialView}),
    ok;
%% Manage reception of epto messages
process_publish(_Usr, [<<"ontologies">>, <<"in">>, Namespace, _FromClientId], {epto_message, Namespace, {receive_ball, NewBall}}) ->
   % logger:info("BBSVX ejabberd mod : Got epto message ~p", [Namespace]),
    gproc:send({n, l, {bbsvx_epto_dissemination_comp, Namespace}}, {receive_ball, NewBall}),
    ok;
%% Reception of empty inview messages
process_publish(_Usr, [<<"ontologies">>, <<"in">>, Namespace, _FromClientId], {empty_inview, Node}) ->
    gproc:send({p, l, {ontology, Namespace}}, {empty_inview, Node}),
    ok;
process_publish(_Usr, [<<"ontologies">>, <<"in">>, Namespace, _FromClientId], {left_inview, Namespace, #node_entry{} = Node}) ->
    gproc:send({p, l, {ontology, Namespace}}, {remove_from_view, inview, Node}),
    ok;
process_publish(_Usr, [<<"ontologies">>, <<"in">>, Namespace, _FromClientId],  {leader_election_info, _Namespace, Payload}) ->
    gproc:send({n, l, {leader_manager, Namespace}}, {leader_election_info, _Namespace, Payload}),
    ok;
process_publish(Usr, Topic, Payload) ->
    logger:info("BBSVX ejabberd mod : Unmanaged message ~p ~p ~p",
                [Usr, Topic, Payload]),
    ok.

process_unsubscribe(_Usr, [<<"ontologies">>, <<"in">>, Namespace, FromClientId]) ->
    logger:info("BBSVX ejabberd mod : Got inview unsubscribe request : ~p ~p",
                [Namespace, FromClientId]),
    %gproc:send({p, l, {ontology, Namespace}},
     %          {remove_from_view, inview, #node_entry{node_id = FromClientId}}),
    ok;
%% Catch all    
process_unsubscribe(Usr, Topic) ->
    logger:info("BBSVX ejabberd mod : Process_unsubscribe called with Usr: ~p, Topic: ~p",
                [Usr, Topic]),
    ok.
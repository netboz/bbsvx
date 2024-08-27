%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_transaction).

-author("yan").

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

-export([init/2, allowed_methods/2, malformed_request/2, content_types_provided/2,
         content_types_accepted/2]).
-export([accept_transaction/2, provide_transaction/2]).

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

%%%=============================================================================
%%% Cowboy Callbacks
%%%=============================================================================

init(Req0, State) ->
    {cowboy_rest, Req0, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>, <<"HEAD">>, <<"OPTIONS">>], Req, State}.

malformed_request(Req, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    try jiffy:decode(Body, [return_maps]) of
        DBody ->
            case validate_map_transaction(DBody) of
                #transaction{} = Transaction ->
                    {false, Req1, State#{transaction => Transaction}};
                {error, Reason} ->
                    Req2 =
                        cowboy_req:set_resp_body(
                            jiffy:encode([#{error => atom_to_binary(Reason)}]), Req1),
                    {true, Req2, State}
            end
    catch
        A:B ->
           ?'log-notice'("Malformed request ~p:~p", [A, B]),
            Req3 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"invalid_json">>}]), Req),
            {true, Req3, State}
    end.

content_types_provided(#{} = Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, provide_transaction}], Req, State}.

content_types_accepted(#{} = Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, accept_transaction}], Req, State}.

accept_transaction(Req0,
                   #{transaction := #transaction{namespace = Namespace} = Transaction} = State) ->
    try bbsvx_epto_service:broadcast(Namespace, Transaction) of
        ok ->
            Req1 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{status => <<"accepted">>}]), Req0),
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
                    jiffy:encode([#{error => <<"network_internal_error">>}]),
                    Req0),
            {true, Req3, State}
    end.

provide_transaction(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    DBody = jiffy:decode(Body, [return_maps]),
    case maps:get(<<"transaction_adress">>, DBody, undefined) of
        undefined ->
            Req1 =
                cowboy_req:set_resp_body(
                    jiffy:encode([#{error => <<"missing_transaction_adress">>}]), Req),
            {true, Req1, State};
        _ ->
            {false, Req, State#{body => DBody}}
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
-spec validate_map_transaction(Map :: map()) -> transaction().
validate_map_transaction(#{<<"namespace">> := Namespace,
                           <<"type">> := Type,
                           <<"signature">> := Signature,
                           <<"payload">> := Payload}) ->
    %% get number of elements of transaction record
    #transaction{type = binary_to_existing_atom(Type),
                 namespace = Namespace,
                 signature = Signature,
                 payload = Payload};
validate_map_transaction(Other) ->
    logger:warning("Invalid transaction map ~p", [Other]),
    {error, missing_field}.

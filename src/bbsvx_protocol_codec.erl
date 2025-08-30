%%%-----------------------------------------------------------------------------
%%% @doc
%%% Simple CBOR protocol codec for BBSvx P2P messages.
%%% Clean, fast implementation without encoding choice complexity.
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_protocol_codec).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

%% External API
-export([encode/1, decode_message_used/1]).

%%%=============================================================================
%%% API Functions
%%%=============================================================================

%% @doc Encode message using term_to_binary
-spec encode(tuple()) -> {ok, binary()} | {error, term()}.
encode(Message) ->
    try
        Binary = term_to_binary(Message, [compressed]),
        {ok, Binary}
    catch
        Error:Reason ->
            {error, {encode_error, Error, Reason}}
    end.

%% @doc Decode message with byte consumption for streaming protocol
-spec decode_message_used(binary()) -> {tuple(), non_neg_integer()} | error.
decode_message_used(Binary) ->
    try
        case binary_to_term(Binary, [safe, used]) of
            {Message, BytesUsed} when is_tuple(Message) -> 
                {Message, BytesUsed};
            _ -> 
                error
        end
    catch
        _:_ -> 
            error
    end.

%%%-----------------------------------------------------------------------------
%%% BBSvx Protocol Codec
%%%-----------------------------------------------------------------------------

-module(bbsvx_protocol_codec).

-moduledoc "BBSvx Protocol Codec\n\n"
"Simple protocol codec for BBSvx P2P messages using term_to_binary encoding.\n\n"
"Provides clean, fast encoding/decoding without choice complexity.".

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

%% External API
-export([encode/1, decode_message_used/1]).

%%%=============================================================================
%%% API Functions
%%%=============================================================================

%% Encode message using term_to_binary
-spec encode(tuple()) -> {ok, binary()} | {error, term()}.
encode(Message) ->
    try
        Binary = term_to_binary(Message, [compressed]),
        {ok, Binary}
    catch
        Error:Reason ->
            {error, {encode_error, Error, Reason}}
    end.

%% Decode message with byte consumption for streaming protocol
%% Note: We don't use [safe] option because:
%% 1. This is a trusted P2P network with nodes running same code
%% 2. The [safe] option rejects terms with atoms not in the atom table,
%%    which can happen with node names or dynamically created atoms
-spec decode_message_used(binary()) -> {tuple(), non_neg_integer()} | error.
decode_message_used(Binary) ->
    try
        case binary_to_term(Binary, [used]) of
            {Message, BytesUsed} when is_tuple(Message) ->
                {Message, BytesUsed};
            Other ->
                ?'log-warning'("decode_message_used: unexpected result ~p", [Other]),
                error
        end
    catch
        Class:Reason:_Stack ->
            %% Log detailed info for debugging decode failures
            BufferSize = byte_size(Binary),
            FirstBytes = binary:part(Binary, 0, min(30, BufferSize)),
            ?'log-debug'("decode_message_used: ~p:~p, size=~p, first_30_bytes=~w",
                        [Class, Reason, BufferSize, FirstBytes]),
            error
    end.

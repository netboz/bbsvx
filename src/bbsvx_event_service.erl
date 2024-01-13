%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_event_service).
-author("yan").


-export([emit/2, subscribe/1]).
%%%=============================================================================
%%% Global Definitions
%%%=============================================================================

emit(NameSpace, Event) ->
    gproc:send({p, l, NameSpace}, Event).

subscribe(NameSpace) ->
    gproc:reg({p, l, NameSpace}).
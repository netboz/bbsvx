%%%-------------------------------------------------------------------
%% @doc bbsvx public API
%% @end
%%%-------------------------------------------------------------------

-module(bbsvx_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    logger:info("BBSvx starting"),
    bbsvx_sup:start_link().

stop(_State) ->
    ok.

%% internal functions

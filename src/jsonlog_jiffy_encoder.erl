%%%-----------------------------------------------------------------------------
%%% BBSvx JSON Log Jiffy Encoder
%%%-----------------------------------------------------------------------------

-module(jsonlog_jiffy_encoder).

-moduledoc "BBSvx JSON Log Jiffy Encoder\n\n"
"Custom JSON encoder for structured logging using Jiffy library.\n\n"
"Handles log level filtering and report formatting for supervisor events.".

-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================
%% custom formatter callback
-export([format/2]).

format(
    #{
        in := In,
        level := Level,
        body := #{report := Report}
    },
    _
) when
    In == <<"application_controller:info_started/2">> orelse
        In == <<"supervisor:report_progress/2">> orelse
        Level == debug
->
    jiffy:encode(#{in => <<"supervisor:report_progress/2">>, body => print(Report)}, []);
format(Log, _Config) ->
    %% io:format("~n---->jsonlog_jiffy_encoder:encode/2: Log: ~p", [Log]),
    try jiffy:encode(Log, []) of
        Json ->
            Json
    catch
        _:_ ->
            jiffy:encode(#{error => <<"json_encode_error">>}, [])
    end.

print(Term) ->
    iolist_to_binary([
        lists:flatten(
            io_lib:format("~p", [Term])
        )
    ]).

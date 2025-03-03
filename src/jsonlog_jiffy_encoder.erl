%%%-----------------------------------------------------------------------------
%%% @doc
%%% Header built from template
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(jsonlog_jiffy_encoder).

-author("yan").

%%%=============================================================================
%%% Global Definitions
%%%=============================================================================
%% custom encoder callback
-export([encode/2]).

encode(#{in := In,
         level := Level,
         body := #{report := Report}},
       _)
    when In == <<"application_controller:info_started/2">>
         orelse In == <<"supervisor:report_progress/2">>
         orelse Level == debug ->
    jiffy:encode(#{in => <<"supervisor:report_progress/2">>, body => print(Report)}, []);
encode(Log, _Config) ->
    %% io:format("~n---->jsonlog_jiffy_encoder:encode/2: Log: ~p", [Log]),
    try jiffy:encode(Log, []) of
        Json ->
            Json
    catch
        _:_ ->
            jiffy:encode(#{error => <<"json_encode_error">>}, [])
    end.

print(Term) ->
    iolist_to_binary([lists:flatten(
                          io_lib:format("~p", [Term]))]).

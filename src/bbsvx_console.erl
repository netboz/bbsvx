%%%-----------------------------------------------------------------------------
%%% @doc
%%% BBSvx Console module for clique integration
%%% This module provides the integration point between nodetool and clique
%%% following the riak_core pattern
%%% @author yan
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_console).

-author("yan").

-export([command/1]).

%%%=============================================================================
%%% Public API
%%%=============================================================================

%% @doc
%% Process console commands via clique
%% This function is called by nodetool with command line arguments
%% @end
-spec command([string()]) -> ok.
command(Cmd) ->
    %% The command comes in as ["bbsvx-admin", "command", "args"...]
    %% We need to ensure clique is registered and then run the command
    try
        %% Ensure our CLI handlers are registered
        bbsvx_cli:register_cli(),
        
        %% Process the command through clique
        case clique:run(Cmd) of
            {error, Error} ->
                io:format("Error: ~p~n", [Error]),
                halt(1);
            Result ->
                print_clique_result(Result)
        end
    catch
        Class:Reason:Stacktrace ->
            io:format("Command failed: ~p:~p~n~p~n", [Class, Reason, Stacktrace]),
            halt(1)
    end.

%%%=============================================================================
%%% Internal Functions 
%%%=============================================================================

%% @doc
%% Print clique results in a user-friendly format
%% @end
print_clique_result([]) -> 
    ok;
print_clique_result([{alert, Messages} | Rest]) ->
    lists:foreach(fun(Msg) -> io:format("~s~n", [Msg]) end, Messages),
    print_clique_result(Rest);
print_clique_result([{text, Text} | Rest]) ->
    io:format("~s~n", [Text]),
    print_clique_result(Rest);
print_clique_result([{table, Data} | Rest]) ->
    print_table(Data),
    print_clique_result(Rest);
print_clique_result([Other | Rest]) ->
    io:format("~p~n", [Other]),
    print_clique_result(Rest).

%% @doc
%% Print tabular data
%% @end
print_table([]) ->
    ok;
print_table([{HeaderRow, DataRows}]) ->
    %% Print header
    print_row(HeaderRow),
    %% Print separator
    Widths = [length(atom_to_list(H)) || H <- HeaderRow],
    SepLine = string:join([string:copies("-", W) || W <- Widths], "-+-"),
    io:format("~s~n", [SepLine]),
    %% Print data rows
    lists:foreach(fun print_row/1, DataRows);
print_table(Data) ->
    io:format("~p~n", [Data]).

print_row(Row) when is_list(Row) ->
    FormattedRow = string:join([format_cell(Cell) || Cell <- Row], " | "),
    io:format("~s~n", [FormattedRow]);
print_row(Row) ->
    io:format("~p~n", [Row]).

format_cell(Cell) when is_atom(Cell) -> atom_to_list(Cell);
format_cell(Cell) when is_binary(Cell) -> binary_to_list(Cell);
format_cell(Cell) when is_integer(Cell) -> integer_to_list(Cell);
format_cell(Cell) when is_list(Cell) -> Cell;
format_cell(Cell) -> io_lib:format("~p", [Cell]).
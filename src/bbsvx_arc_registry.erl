%%%-----------------------------------------------------------------------------
%%% @doc
%%% Arc Registry - manages arc registrations for a namespace
%%% Replaces gproc for arc tracking with better performance and control
%%% @author Claude Code
%%% @end
%%%-----------------------------------------------------------------------------

-module(bbsvx_arc_registry).

-behaviour(gen_server).

-include("bbsvx.hrl").
-include_lib("logjam/include/logjam.hrl").

%% API
-export([start_link/1, stop/1]).
-export([register/5, unregister/3]).
-export([update_status/4, update_age/3, reset_age/3, update_target_node_id/4]).
-export([get_all_arcs/2, get_available_arcs/2, get_arc/3]).
-export([mirror/6, swap/6]).
-export([send/4]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    namespace :: binary(),
    in_table :: ets:tid(),
    out_table :: ets:tid(),
    monitors = #{} :: #{reference() => {in | out, binary()}}
}).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(NameSpace) ->
    gen_server:start_link({via, gproc, {n, l, {?MODULE, NameSpace}}}, ?MODULE, [NameSpace], []).

-spec stop(binary()) -> ok.
stop(NameSpace) ->
    gen_server:stop({via, gproc, {n, l, {?MODULE, NameSpace}}}).

%% @doc Register an arc connection process with metadata (single call)
-spec register(binary(), in | out, binary(), pid(), arc()) -> ok | {error, term()}.
register(NameSpace, Direction, Ulid, Pid, Arc) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {register, Direction, Ulid, Pid, Arc}).

%% @doc Unregister an arc
-spec unregister(binary(), in | out, binary()) -> ok.
unregister(NameSpace, Direction, Ulid) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {unregister, Direction, Ulid}).

%% @doc Update arc status (available | exchanging)
-spec update_status(binary(), in | out, binary(), available | exchanging) -> ok | {error, not_found}.
update_status(NameSpace, Direction, Ulid, Status) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {update_status, Direction, Ulid, Status}).

%% @doc Increment arc age
-spec update_age(binary(), in | out, binary()) -> ok | {error, not_found}.
update_age(NameSpace, Direction, Ulid) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {update_age, Direction, Ulid}).

%% @doc Reset arc age to 0
-spec reset_age(binary(), in | out, binary()) -> ok | {error, not_found}.
reset_age(NameSpace, Direction, Ulid) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {reset_age, Direction, Ulid}).

%% @doc Update the target node_id for an out arc (after receiving connect_ack)
-spec update_target_node_id(binary(), out, binary(), binary()) -> ok | {error, not_found}.
update_target_node_id(NameSpace, Direction, Ulid, TargetNodeId) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {update_target_node_id, Direction, Ulid, TargetNodeId}).

%% @doc Get all arcs (regardless of status) with their PIDs
-spec get_all_arcs(binary(), in | out) -> [{arc(), pid()}].
get_all_arcs(NameSpace, Direction) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {get_all_arcs, Direction}).

%% @doc Get only available arcs (status = available) with their PIDs
-spec get_available_arcs(binary(), in | out) -> [{arc(), pid()}].
get_available_arcs(NameSpace, Direction) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {get_available_arcs, Direction}).

%% @doc Get a specific arc by ULID with its PID
-spec get_arc(binary(), in | out, binary()) -> {ok, {arc(), pid()}} | {error, not_found}.
get_arc(NameSpace, Direction, Ulid) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {get_arc, Direction, Ulid}).

-spec mirror(binary(), node_entry(), binary(), binary(), binary(), pid()) -> ok.
mirror(NameSpace, OriginNode, Ulid, CurrentLock, NewLock, NewPid) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {mirror, OriginNode, Ulid, CurrentLock, NewLock, NewPid}).

-spec swap(binary(), node_entry(), binary(), binary(), binary(), pid()) -> ok | {error, term()}.
swap(NameSpace, NewOriginNode, Ulid, OldLock, NewLock, NewPid) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                    {swap, NewOriginNode, Ulid, OldLock, NewLock, NewPid}).

%% @doc Send a message to a specific arc connection process
-spec send(binary(), in | out, binary(), term()) -> ok | {error, not_found}.
send(NameSpace, Direction, Ulid, Message) ->
    case gen_server:call({via, gproc, {n, l, {?MODULE, NameSpace}}},
                         {whereis, Direction, Ulid}) of
        {ok, Pid} ->
            ?'log-info'("Arc Registry SEND: direction=~p PID=~p", [Direction, Pid]),
            Pid ! {send, Message},
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

init([NameSpace]) ->
    process_flag(trap_exit, true),
    ?'log-info'("Arc Registry ~p : Starting", [NameSpace]),

    %% Create ETS tables for in and out arcs
    InTable = ets:new(arc_in_table, [set, private, {keypos, 1}]),
    OutTable = ets:new(arc_out_table, [set, private, {keypos, 1}]),

    {ok, #state{
        namespace = NameSpace,
        in_table = InTable,
        out_table = OutTable,
        monitors = #{}
    }}.

handle_call({register, in, Ulid, Pid, Arc}, _From, #state{in_table = Table} = State) ->
    %% Check if already registered
    case ets:lookup(Table, Ulid) of
        [{Ulid, _OldArc, OldPid, _OldMonRef}] when OldPid =:= Pid ->
            %% Same PID re-registering, just update the arc
            MonRef = erlang:monitor(process, Pid),
            ets:insert(Table, {Ulid, Arc, Pid, MonRef}),
            NewMonitors = maps:put(MonRef, {in, Ulid}, State#state.monitors),
            {reply, ok, State#state{monitors = NewMonitors}};
        [{Ulid, _OldArc, OldPid, _}] ->
            %% Different PID trying to register same ULID - error
            ?'log-error'("Arc Registry ~p : ULID ~p already registered by ~p, rejecting ~p",
                        [State#state.namespace, Ulid, OldPid, Pid]),
            {reply, {error, already_registered}, State};
        [] ->
            %% New registration
            MonRef = erlang:monitor(process, Pid),
            ets:insert(Table, {Ulid, Arc, Pid, MonRef}),
            NewMonitors = maps:put(MonRef, {in, Ulid}, State#state.monitors),
            ?'log-info'("Arc Registry ~p : Registered in arc ~p for pid ~p",
                       [State#state.namespace, Ulid, Pid]),
            {reply, ok, State#state{monitors = NewMonitors}}
    end;

handle_call({register, out, Ulid, Pid, Arc}, _From, #state{out_table = Table} = State) ->
    %% Check if already registered
    case ets:lookup(Table, Ulid) of
        [{Ulid, _OldArc, OldPid, _OldMonRef}] when OldPid =:= Pid ->
            %% Same PID re-registering, just update the arc
            MonRef = erlang:monitor(process, Pid),
            ets:insert(Table, {Ulid, Arc, Pid, MonRef}),
            NewMonitors = maps:put(MonRef, {out, Ulid}, State#state.monitors),
            {reply, ok, State#state{monitors = NewMonitors}};
        [{Ulid, _OldArc, OldPid, _}] ->
            %% Different PID trying to register same ULID - error
            ?'log-error'("Arc Registry ~p : ULID ~p already registered by ~p, rejecting ~p",
                        [State#state.namespace, Ulid, OldPid, Pid]),
            {reply, {error, already_registered}, State};
        [] ->
            %% New registration
            MonRef = erlang:monitor(process, Pid),
            ets:insert(Table, {Ulid, Arc, Pid, MonRef}),
            NewMonitors = maps:put(MonRef, {out, Ulid}, State#state.monitors),
            ?'log-info'("Arc Registry ~p : Registered out arc ~p for pid ~p",
                       [State#state.namespace, Ulid, Pid]),
            {reply, ok, State#state{monitors = NewMonitors}}
    end;

handle_call({unregister, in, Ulid}, _From, #state{in_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, _Arc, _Pid, MonRef}] ->
            erlang:demonitor(MonRef, [flush]),
            ets:delete(Table, Ulid),
            NewMonitors = maps:remove(MonRef, State#state.monitors),
            ?'log-info'("Arc Registry ~p : Unregistered in arc ~p",
                       [State#state.namespace, Ulid]),
            {reply, ok, State#state{monitors = NewMonitors}};
        [] ->
            {reply, ok, State}
    end;

handle_call({unregister, out, Ulid}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, _Arc, _Pid, MonRef}] ->
            erlang:demonitor(MonRef, [flush]),
            ets:delete(Table, Ulid),
            NewMonitors = maps:remove(MonRef, State#state.monitors),
            ?'log-info'("Arc Registry ~p : Unregistered out arc ~p",
                       [State#state.namespace, Ulid]),
            {reply, ok, State#state{monitors = NewMonitors}};
        [] ->
            {reply, ok, State}
    end;

handle_call({update_status, in, Ulid, Status}, _From, #state{in_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{status = Status},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({update_status, out, Ulid, Status}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{status = Status},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({update_age, in, Ulid}, _From, #state{in_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{age = Arc#arc.age + 1},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({update_age, out, Ulid}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{age = Arc#arc.age + 1},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({reset_age, in, Ulid}, _From, #state{in_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{age = 0},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({reset_age, out, Ulid}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{age = 0},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({update_target_node_id, out, Ulid, TargetNodeId}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, #arc{target = Target} = Arc, Pid, MonRef}] ->
            UpdatedArc = Arc#arc{target = Target#node_entry{node_id = TargetNodeId}},
            ets:insert(Table, {Ulid, UpdatedArc, Pid, MonRef}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({get_all_arcs, in}, _From, #state{in_table = Table} = State) ->
    Arcs = ets:foldl(
        fun({_Ulid, Arc, Pid, _MonRef}, Acc) ->
            [{Arc, Pid} | Acc]
        end,
        [],
        Table
    ),
    {reply, Arcs, State};

handle_call({get_all_arcs, out}, _From, #state{out_table = Table} = State) ->
    Arcs = ets:foldl(
        fun({_Ulid, Arc, Pid, _MonRef}, Acc) ->
            [{Arc, Pid} | Acc]
        end,
        [],
        Table
    ),
    {reply, Arcs, State};

handle_call({get_available_arcs, in}, _From, #state{in_table = Table} = State) ->
    Arcs = ets:foldl(
        fun({_Ulid, #arc{status = available} = Arc, Pid, _MonRef}, Acc) ->
            [{Arc, Pid} | Acc];
           (_, Acc) ->
            Acc
        end,
        [],
        Table
    ),
    {reply, Arcs, State};

handle_call({get_available_arcs, out}, _From, #state{out_table = Table} = State) ->
    Arcs = ets:foldl(
        fun({_Ulid, #arc{status = available} = Arc, Pid, _MonRef}, Acc) ->
            [{Arc, Pid} | Acc];
           (_, Acc) ->
            Acc
        end,
        [],
        Table
    ),
    {reply, Arcs, State};

handle_call({mirror, OriginNode, Ulid, CurrentLock, NewLock, NewPid}, _From, #state{namespace = NameSpace, in_table = InTable, out_table = OutTable} = State) ->
    case ets:take(OutTable, Ulid) of
        [{Ulid, #arc{source = Source, target = Target, lock = CurrentLock} = OutArc, OldPid, OldMonRef}] ->
            %% Demonitor old connection and monitor the new one
            erlang:demonitor(OldMonRef, [flush]),
            NewMonRef = erlang:monitor(process, NewPid),
            %% Create mirrored arc
            MirroredArc = OutArc#arc{
                source = Target,
                target = Source,
                lock = NewLock,
                status = available
            },
            ets:insert(InTable, {Ulid, MirroredArc, NewPid, NewMonRef}),
            NewMonitors = maps:put(NewMonRef, {in, Ulid}, maps:remove(OldMonRef, State#state.monitors)),
            gen_statem:stop(OldPid, {shutdown, mirror}, infinity),
            arc_event(
                NameSpace,
                Ulid,
                #evt_arc_connected_in{
                    ulid = Ulid,
                    lock = NewLock,
                    source = OriginNode,
                    connection_type = mirror
                }
            ),

            ?'log-info'("Arc Registry ~p : Mirrored arc ~p (new pid ~p)",
                       [State#state.namespace, Ulid, NewPid]),
            {reply, ok, State#state{monitors = NewMonitors}};
        [ArcThatDoesNotMatch] ->
            %% Found but lock does not match,reinsert it
            ets:insert(OutTable, ArcThatDoesNotMatch),
            ?'log-error'("Arc Registry ~p : Cannot mirror arc ~p - lock mismatch",
                        [State#state.namespace, Ulid]),
            {reply, {error, lock_mismatch}, State};
        _ ->
            ?'log-error'("Arc Registry ~p : Cannot mirror arc ~p - not found in out table",
                        [State#state.namespace, Ulid]),
            {reply, {error, not_found}, State}
    end;

handle_call({swap, NewOriginNode, Ulid, OldLock, NewLock, NewPid}, _From, #state{namespace = NameSpace, in_table = InTable} = State) ->
    case ets:take(InTable, Ulid) of
        %% If needed, for security, we could check origin node match the values in PreviousOriginNode and NewOriginNode
        [{Ulid, #arc{target = Target, source = PreviousOriginNode, lock = OldLock} = InArc, OldPid, OldMonRef}] ->
            %% Demonitor old connection and monitor the new one
            erlang:demonitor(OldMonRef, [flush]),
            NewMonRef = erlang:monitor(process, NewPid),
            %% Create swapped arc
            SwappedArc = InArc#arc{
                source = NewOriginNode,
                lock = NewLock,
                status = available
            },
            ets:insert(InTable, {Ulid, SwappedArc, NewPid, NewMonRef}),
            NewMonitors = maps:put(NewMonRef, {in, Ulid}, maps:remove(OldMonRef, State#state.monitors)),
            gen_statem:stop(OldPid, {shutdown, {swap, NewOriginNode, NewLock}}, infinity),
            arc_event(NameSpace, Ulid, #evt_arc_swapped_in{
                ulid = Ulid,
                newlock = NewLock,
                destination = Target,
                previous_source = PreviousOriginNode,
                new_source = NewOriginNode
            }),

            ?'log-info'("Arc Registry ~p : Swapped arc ~p (new pid ~p)",
                       [State#state.namespace, Ulid, NewPid]),
            {reply, ok, State#state{monitors = NewMonitors}};
        [ArcThatDoesNotMatch] ->
            %% Found but lock does not match,reinsert it
            ets:insert(InTable, ArcThatDoesNotMatch),
            ?'log-error'("Arc Registry ~p : Cannot swap arc ~p  with lock ~p - lock mismatch ~p",
                        [State#state.namespace, Ulid, OldLock, ArcThatDoesNotMatch]),
            {reply, {error, lock_mismatch}, State};
        Other ->
            ?'log-error'("Arc Registry ~p : Cannot swap arc ~p - not found in in table ~p",
                        [State#state.namespace, Ulid, Other]),
            {reply, {error, not_found}, State}
    end;

handle_call({whereis, in, Ulid}, _From, #state{in_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, _Arc, Pid, _MonRef}] ->
            {reply, {ok, Pid}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({whereis, out, Ulid}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, _Arc, Pid, _MonRef}] ->
            {reply, {ok, Pid}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({get_arc, in, Ulid}, _From, #state{in_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, _MonRef}] ->
            {reply, {ok, {Arc, Pid}}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({get_arc, out, Ulid}, _From, #state{out_table = Table} = State) ->
    case ets:lookup(Table, Ulid) of
        [{Ulid, Arc, Pid, _MonRef}] ->
            {reply, {ok, {Arc, Pid}}, State};
        [] ->
            {reply, {error, not_found}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, Reason}, State) ->
    case maps:get(MonRef, State#state.monitors, undefined) of
        {in, Ulid} ->
            ets:delete(State#state.in_table, Ulid),
            NewMonitors = maps:remove(MonRef, State#state.monitors),
            ?'log-info'("Arc Registry ~p : Auto-removed in arc ~p (pid ~p died: ~p)",
                       [State#state.namespace, Ulid, Pid, Reason]),
            {noreply, State#state{monitors = NewMonitors}};
        {out, Ulid} ->
            ets:delete(State#state.out_table, Ulid),
            NewMonitors = maps:remove(MonRef, State#state.monitors),
            ?'log-info'("Arc Registry ~p : Auto-removed out arc ~p (pid ~p died: ~p)",
                       [State#state.namespace, Ulid, Pid, Reason]),
            {noreply, State#state{monitors = NewMonitors}};
        undefined ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    ?'log-info'("Arc Registry ~p : Terminating (~p)", [State#state.namespace, Reason]),
    ets:delete(State#state.in_table),
    ets:delete(State#state.out_table),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


-spec arc_event(binary(), binary(), term()) -> ok.
arc_event(NameSpace, MyUlid, Event) ->
    gproc:send(
        {p, l, {spray_exchange, NameSpace}},
        #incoming_event{
            event = Event,
            direction = in,
            origin_arc = MyUlid
        }
    ).
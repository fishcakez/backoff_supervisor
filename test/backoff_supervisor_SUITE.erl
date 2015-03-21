%%-------------------------------------------------------------------
%%
%% Copyright (c) 2015, James Fish <james@fishcakez.com>
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WaraNTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
-module(backoff_supervisor_SUITE).

-include_lib("common_test/include/ct.hrl").
-define(LONG_TIMEOUT, 10000).

%% common_test api

-export([all/0]).
-export([suite/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([group/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

%% test cases

-export([start_child/1]).
-export([start_child_with_info/1]).
-export([start_child_ignore/1]).
-export([start_child_error/1]).
-export([terminate_child/1]).
-export([restart_child/1]).
-export([delete_child/1]).
-export([which_children_worker/1]).
-export([which_children_supervisor/1]).
-export([count_children_worker/1]).
-export([count_children_supervisor/1]).
-export([child_shutdown_temporary/1]).
-export([child_shutdown_transient/1]).
-export([child_shutdown_permanent/1]).
-export([child_exit_temporary/1]).
-export([child_exit_transient/1]).
-export([child_exit_permanent/1]).

-export([increasing_delay_normal/1]).
-export([increasing_delay_jitter/1]).
-export([start_after_delay/1]).
-export([start_with_info/1]).
-export([start_error/1]).
-export([shutdown_brutal_kill/1]).
-export([shutdown_timeout/1]).
-export([shutdown_infinity/1]).

%% common_test api

all() ->
    [{group, simple_one_for_one},
     {group, backoff}].

suite() ->
    [{timetrap, {seconds, 120}}].

groups() ->
    [{simple_one_for_one, [parallel], [start_child,
                                       start_child_with_info,
                                       start_child_ignore,
                                       start_child_error,
                                       terminate_child,
                                       restart_child,
                                       delete_child,
                                       which_children_worker,
                                       which_children_supervisor,
                                       count_children_worker,
                                       count_children_supervisor,
                                       child_shutdown_temporary,
                                       child_shutdown_transient,
                                       child_shutdown_permanent,
                                       child_exit_temporary,
                                       child_exit_transient,
                                       child_exit_permanent]},
     {backoff, [parallel], [increasing_delay_normal,
                            increasing_delay_jitter,
                            start_after_delay,
                            start_with_info,
                            start_error,
                            shutdown_brutal_kill,
                            shutdown_timeout,
                            shutdown_infinity]}].

init_per_suite(Config) ->
    _ = application:start(sasl),
    Config.

end_per_suite(_Config) ->
    ok.

group(_Group) ->
    [].

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% test cases

start_child(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [worker()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, _} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),
    {error, {already_started, Pid2}} = supervisor:start_child(BSup, []),

    Ref = monitor(process, Pid2),
    exit(Pid2, shutdown),
    receive {'DOWN', Ref, _, _, shutdown} -> ok end,

    {ok, Pid3} = supervisor:start_child(BSup, []),
    {error, {already_started, Pid3}} = backoff_supervisor:start_child(BSup, []),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

start_child_with_info(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker({info, self()})]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker({info, self()})]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    Self = self(),
    {ok, Pid1, Self} = supervisor:start_child(SSup, []),
    Pid1 = receive {started, SSup, Child1, _} ->  Child1 end,
    {ok, Pid2, Self} = backoff_supervisor:start_child(BSup, []),
    Pid2 = receive {started, BSup, Child2, _} ->  Child2 end,
    {error, {already_started, Pid2}} = supervisor:start_child(BSup, []),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

start_child_ignore(_) ->
    Delay = 500,
    BSpec = {ok, {{normal, Delay, ?LONG_TIMEOUT},
                  [worker({ignore, 1,  self()}, temporary)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1},
                  [worker({ignore, 1, self()}, temporary)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    Time1 = now(),

    {ok, undefined} = supervisor:start_child(SSup, []),
    {ok, undefined} = backoff_supervisor:start_child(BSup, []),

    {Pid, Time2} = receive {started, BSup, Child, Now2} -> {Child, Now2} end,

    {error, {already_started, Pid}} = backoff_supervisor:start_child(BSup, []),

    Diff = timer:now_diff(Time2, Time1),

    _ = if
        Diff > Delay ->
                ok;
        true ->
                ct:pal("Diff: ~b~nDelay: ~b", [Diff, Delay]),
                exit({fast_diff, Diff, Delay})
    end,

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

start_child_error(_) ->
    Delay = 500,
    BSpec = {ok, {{normal, Delay, ?LONG_TIMEOUT},
                  [worker({{error, failed}, 1,  self()})]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1},
                  [worker({{error, failed}, 1, self()})]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    Time1 = now(),

    {error, failed} = supervisor:start_child(SSup, []),
    {error, failed} = backoff_supervisor:start_child(BSup, []),

    {Pid, Time2} = receive {started, BSup, Child, Now2} -> {Child, Now2} end,

    {error, {already_started, Pid}} = backoff_supervisor:start_child(BSup, []),

    Diff = timer:now_diff(Time2, Time1),

    _ = if
        Diff > Delay ->
                ok;
        true ->
                ct:pal("Diff: ~b~nDelay: ~b", [Diff, Delay]),
                exit({fast_diff, Diff, Delay})
    end,

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

terminate_child(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [worker()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    {error, not_found} = supervisor:terminate_child(SSup, Pid2),
    {error, not_found} = backoff_supervisor:terminate_child(BSup, Pid1),
    {error, not_found} = supervisor:terminate_child(BSup, Pid1),

    {error, simple_one_for_one} = supervisor:terminate_child(SSup, not_a_pid),
    {error, simple_one_for_one} = supervisor:terminate_child(BSup, not_a_pid),

    ok = supervisor:terminate_child(SSup, Pid1),
    ok = supervisor:terminate_child(SSup, Pid1),
    ok = backoff_supervisor:terminate_child(BSup, Pid2),
    ok = backoff_supervisor:terminate_child(BSup, Pid2),
    ok = supervisor:terminate_child(BSup, Pid2),

    {ok, Pid3} = backoff_supervisor:start_child(BSup, []),
    ok = supervisor:terminate_child(BSup, Pid3),

    {error, simple_one_for_one} = supervisor:terminate_child(SSup, not_a_pid),
    {error, simple_one_for_one} = supervisor:terminate_child(BSup, not_a_pid),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

restart_child(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [worker()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    {error, simple_one_for_one} = supervisor:restart_child(SSup, Pid1),
    {error, simple_one_for_one} = backoff_supervisor:restart_child(SSup, Pid2),
    {error, simple_one_for_one} = supervisor:restart_child(SSup, Pid2),

    ok = supervisor:terminate_child(SSup, Pid1),
    ok = backoff_supervisor:terminate_child(BSup, Pid2),

    {error, simple_one_for_one} = supervisor:restart_child(SSup, Pid1),
    {error, simple_one_for_one} = backoff_supervisor:restart_child(SSup, Pid2),
    {error, simple_one_for_one} = supervisor:restart_child(SSup, Pid2),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

delete_child(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [worker()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    {error, simple_one_for_one} = supervisor:delete_child(SSup, Pid1),
    {error, simple_one_for_one} = backoff_supervisor:delete_child(SSup, Pid2),
    {error, simple_one_for_one} = supervisor:delete_child(SSup, Pid2),

    ok = supervisor:terminate_child(SSup, Pid1),
    ok = backoff_supervisor:terminate_child(BSup, Pid2),

    {error, simple_one_for_one} = supervisor:delete_child(SSup, Pid1),
    {error, simple_one_for_one} = backoff_supervisor:delete_child(SSup, Pid2),
    {error, simple_one_for_one} = supervisor:delete_child(SSup, Pid2),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

which_children_worker(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [worker()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    [] = supervisor:which_children(SSup),
    [] = backoff_supervisor:which_children(BSup),
    [] = supervisor:which_children(BSup),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    [{undefined, Pid1, worker, dynamic}] = supervisor:which_children(SSup),
    [{undefined, Pid2, worker, dynamic}] =
        backoff_supervisor:which_children(BSup),
    [{undefined, Pid2, worker, dynamic}] = supervisor:which_children(BSup),

    ok = supervisor:terminate_child(SSup, Pid1),
    ok = backoff_supervisor:terminate_child(BSup, Pid2),

    [] = supervisor:which_children(SSup),
    [] = backoff_supervisor:which_children(BSup),
    [] = supervisor:which_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

which_children_supervisor(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [supervisor()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [supervisor()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    [] = supervisor:which_children(SSup),
    [] = backoff_supervisor:which_children(BSup),
    [] = supervisor:which_children(BSup),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    [{undefined, Pid1, supervisor, dynamic}] = supervisor:which_children(SSup),
    [{undefined, Pid2, supervisor, dynamic}] =
        backoff_supervisor:which_children(BSup),
    [{undefined, Pid2, supervisor, dynamic}] = supervisor:which_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

count_children_worker(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [worker()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    Count1 = supervisor:count_children(SSup),
    Count1 = backoff_supervisor:count_children(BSup),
    Count1 = supervisor:count_children(BSup),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    Count2 = supervisor:count_children(SSup),
    Count2 = backoff_supervisor:count_children(BSup),
    Count2 = supervisor:count_children(BSup),

    ok = supervisor:terminate_child(SSup, Pid1),
    ok = backoff_supervisor:terminate_child(BSup, Pid2),

    Count3 = supervisor:count_children(SSup),
    Count3 = backoff_supervisor:count_children(BSup),
    Count3 = supervisor:count_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

count_children_supervisor(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT}, [supervisor()]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [supervisor()]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    Count1 = supervisor:count_children(SSup),
    Count1 = backoff_supervisor:count_children(BSup),
    Count1 = supervisor:count_children(BSup),

    {ok, _} = supervisor:start_child(SSup, []),
    {ok, _} = backoff_supervisor:start_child(BSup, []),

    Count2 = supervisor:count_children(SSup),
    Count2 = backoff_supervisor:count_children(BSup),
    Count2 = supervisor:count_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

child_shutdown_temporary(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker(ok, temporary)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker(ok, temporary)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    ok = shutdown_child(Pid1),
    ok = shutdown_child(Pid2),

    [] = supervisor:which_children(SSup),
    [] = supervisor:which_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

child_shutdown_transient(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker(ok, transient)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker(ok, transient)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    ok = shutdown_child(Pid1),
    ok = shutdown_child(Pid2),

    [] = supervisor:which_children(SSup),
    [] = supervisor:which_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

child_shutdown_permanent(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker(ok, permanent)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker(ok, permanent)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    Trap = process_flag(trap_exit, true),

    ok = shutdown_child(Pid1),
    receive {'EXIT', SSup, shutdown} -> ok end,

    ok = shutdown_child(Pid2),
    receive {'EXIT', BSup,
             {shutdown, {reached_max_restart_intensity, worker, shutdown}}} ->
                ok
    end,

    _ = process_flag(trap_exit, Trap),

    ok.

child_exit_permanent(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker(ok, permanent)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker(ok, permanent)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    Trap = process_flag(trap_exit, true),

    ok = kill_child(Pid1),
    receive {'EXIT', SSup, shutdown} -> ok end,

    ok = kill_child(Pid2),
    receive {'EXIT', BSup,
             {shutdown, {reached_max_restart_intensity, worker, killed}}} ->
                ok
    end,

    _ = process_flag(trap_exit, Trap),

    ok.

child_exit_temporary(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker(ok, temporary)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker(ok, temporary)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    ok = kill_child(Pid1),
    ok = kill_child(Pid2),

    [] = supervisor:which_children(SSup),
    [] = supervisor:which_children(BSup),

    ok = shutdown(BSup),
    ok = shutdown(SSup),

    ok.

child_exit_transient(_) ->
    BSpec = {ok, {{jitter, ?LONG_TIMEOUT, ?LONG_TIMEOUT},
                  [worker(ok, transient)]}},
    {ok, BSup} = backoff_supervisor_test:start_link(BSpec),
    SSpec = {ok, {{simple_one_for_one, 0, 1}, [worker(ok, transient)]}},
    {ok, SSup} = backoff_supervisor_sup:start_link(SSpec),

    {ok, Pid1} = supervisor:start_child(SSup, []),
    {ok, Pid2} = backoff_supervisor:start_child(BSup, []),

    Trap = process_flag(trap_exit, true),

    ok = kill_child(Pid1),
    receive {'EXIT', SSup, shutdown} -> ok end,

    ok = kill_child(Pid2),
    receive {'EXIT', BSup,
             {shutdown, {reached_max_restart_intensity, worker, killed}}} ->
                ok
    end,

    _ = process_flag(trap_exit, Trap),

    ok.

increasing_delay_normal(_) ->
    Spec = {ok, {{normal, 100, ?LONG_TIMEOUT}, [worker({ignore,self()})]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    Time1 = receive {ignored, Sup, Now1} -> Now1 end,
    Time2 = receive {ignored, Sup, Now2} -> Now2 end,
    Time3 = receive {ignored, Sup, Now3} -> Now3 end,

    Diff1 = timer:now_diff(Time2, Time1),
    Diff2 = timer:now_diff(Time3, Time2),

    _ = if
        Diff1 < Diff2 ->
                ok;
        true ->
                ct:pal("Normal~nDiff 1: ~b~nDiff 2: ~b", [Diff1, Diff2]),
                exit({not_increasing, Diff1, Diff2})
    end,

    ok = shutdown(Sup),

    ok.

increasing_delay_jitter(_) ->
    Spec = {ok, {{jitter, 100, infinity}, [worker({ignore, self()})]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    Time1 = receive {ignored, Sup, Now1} -> Now1 end,
    Time2 = receive {ignored, Sup, Now2} -> Now2 end,
    Time3 = receive {ignored, Sup, Now3} -> Now3 end,

    Diff1 = timer:now_diff(Time2, Time1),
    Diff2 = timer:now_diff(Time3, Time2),

    _ = if
        Diff1 < Diff2 ->
                ok;
        true ->
                ct:pal("Jitter~nDiff 1: ~b~nDiff 2: ~b", [Diff1, Diff2]),
                exit({not_increasing, Diff1, Diff2})
    end,

    ok = shutdown(Sup),

    ok.

start_after_delay(_) ->
    Spec = {ok, {{normal, 1, 1}, [worker({ignore, 2, self()})]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    receive {ignored, Sup, _} -> ok end,
    receive {ignored, Sup, _} -> ok end,
    Pid = receive {started, Sup, Child, _} ->  Child end,

    Count = backoff_supervisor:count_children(Sup),
    1 = proplists:get_value(active, Count, 1),
    1 = proplists:get_value(workers, Count, 1),

    [{undefined, Pid, worker, dynamic}] =
        backoff_supervisor:which_children(Sup),

    {error, {already_started, Pid}} = backoff_supervisor:start_child(Sup, []),

    ok = shutdown(Sup),

    ok.

start_with_info(_) ->
    Spec = {ok, {{normal, 1, 1}, [worker({info, self()})]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    Pid = receive {started, Sup, Child, _} ->  Child end,

    Count = backoff_supervisor:count_children(Sup),
    1 = proplists:get_value(active, Count, 1),
    1 = proplists:get_value(workers, Count, 1),

    [{undefined, Pid, worker, dynamic}] =
        backoff_supervisor:which_children(Sup),

    {error, {already_started, Pid}} = backoff_supervisor:start_child(Sup, []),

    ok = shutdown(Sup),

    ok.

start_error(_) ->
    Spec = {ok, {{normal, 1, 1}, [worker({error, failure})]}},
    Trap = process_flag(trap_exit, true),
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    receive
        {'EXIT', Sup, {shutdown, {failed_to_start_child, worker, failure}}} ->
            ok
    end,
    process_flag(trap_exit, Trap),

    ok.

shutdown_brutal_kill(_) ->
    Spec = {ok, {{normal, 1, 1},
                 [worker({trap_exit, self()}, temporary, brutal_kill)]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    Pid = receive {started, Sup, Child, _} ->  Child end,

    Ref = monitor(process, Pid),

    ok = shutdown(Sup),

    receive {'DOWN', Ref, _, _, killed} -> ok end,

    ok.

shutdown_timeout(_) ->
    Spec = {ok, {{normal, 1, 1},
                 [worker({trap_exit, self()}, temporary, 1)]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    Pid = receive {started, Sup, Child, _} ->  Child end,

    Ref = monitor(process, Pid),

    ok = shutdown(Sup),

    receive {'DOWN', Ref, _, _, killed} -> ok end,

    ok.

shutdown_infinity(_) ->
    Spec = {ok, {{normal, 1, 1},
                 [worker({ok, self()}, temporary, infinity)]}},
    {ok, Sup} = backoff_supervisor_test:start_link(Spec),

    Pid = receive {started, Sup, Child, _} ->  Child end,

    Ref = monitor(process, Pid),

    ok = shutdown(Sup),

    receive {'DOWN', Ref, _, _, shutdown} -> ok end,

    ok.

%% Internal

supervisor() ->
    {supervisor, {backoff_supervisor_sup, start_link, []}, transient,
     infinity, supervisor, dynamic}.

worker() ->
    {worker, {backoff_supervisor_worker, start_link, []}, transient,
     5000, worker, dynamic}.

worker(Args) ->
    {worker, {backoff_supervisor_worker, start_link, [Args]}, transient,
     5000, worker, dynamic}.

worker(Args, Restart) ->
    {worker, {backoff_supervisor_worker, start_link, [Args]}, Restart,
     5000, worker, dynamic}.

worker(Args, Restart, Shutdown) ->
    {worker, {backoff_supervisor_worker, start_link, [Args]}, Restart,
     Shutdown, worker, dynamic}.

shutdown(Pid) ->
    Trap = process_flag(trap_exit, true),
    exit(Pid, shutdown),
    receive
        {'EXIT', Pid, shutdown} ->
            process_flag(trap_exit, Trap),
            ok;
        {'EXIT', Pid, Reason} ->
            process_flag(trap_exit, Trap),
            {error, Reason}
    end.

shutdown_child(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, _, _, shutdown} -> ok;
        {'DOWN', Ref, _, _, Reason} -> {error, Reason}
    end.

kill_child(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, _, _, killed} -> ok;
        {'DOWN', Ref, _, _, Reason} -> {error, Reason}
    end.

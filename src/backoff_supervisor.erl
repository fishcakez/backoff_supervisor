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
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
%% @doc `backoff_supervisor' is a simple supervisor for a single child. If the
%% child is not started the supervisor will make attempts to start it, with
%% increasing backoff between attempts. If the child returns an error from its
%% start function when an automatic start attempt is made the supervisor will
%% shutdown.
%%
%% If the restart type of the child is `permanent' the supervisor will shutdown
%% if the child exits with any reason.
%%
%% If the restart type is `transient' the supervisor will shutdown if the
%% child exits abnormally. If a `transient' child exits with a normal reason
%% (`normal', `shutdown', `{shutdown, any()}') the child is removed and a new
%% child is started after an initial delay.
%%
%% If the restart type of the child is `temporary' the child is removed on exit
%% and a new child is started after an initial delay.
%%
%% For the supervisor to continue making start attempts the child start function
%% must return `ignore'. However if a start attempt is made using
%% `start_child/2' an error will be ignored and the supervisor will not
%% shutdown. However the current delay between start attempts will be restarted.
%% If a child is alive `start_child/2' returns
%% `{error, {already_started, Pid}}', where `Pid' is the `pid()' of the child.
%%
%% `terminate_child/2', `delete_child/2' and `restart_child/2' behave the same
%% as the equivalent functions for a `simple_one_for_one' `supervisor'.
%% Therefore a `backoff_supervisor' is equivalent to a `simple_one_for_one'
%% `supervisor' with `0' maximum restarts - except only one child can be
%% running and the supervisor will try to start a child if no child is running
%% for a period of time. If one of theses attempts fails the supervisor will
%% shutdown. If one of these attempts returns `ignore' the supervisor will
%% increase the time period (up to a maximum) and try again.
%%
%% The specification for a `backoff_supervisor' uses a similar behaviour to a
%% supervisor. A callback module must implement a single function, `init/1'.
%% `init/1' should return `{ok, {{BackoffType, Start, Max}, [ChildSpec]}}' or
%% `ignore'. `BackoffType' is the `backoff' type to use, either `normal' for
%% exponential backoff or `jitter' for backoff with random increments. `Start'
%% is the initial delay, in milliseconds, before making a first attempt to start
%% the child. `Max' is the maximum delay, in milliseconds, between start
%% attempts. `ChildSpec' is the child specification of the child, which is a
%% `supervisor:child_spec()'. There must be a single `ChildSpec'. In the case of
%% `ignore' the `backoff_supervisor' will not start and return `ignore' from
%% `start_link/2,3'.
%%
%% The specification of a `backoff_supervisor' can be changed in the same way as
%% a `supervisor' using a code change. The backoff strategy will be used to set
%% the next delay, and all subsequent delays, but will not effect an active
%% delay. The child specification is updated for an active child and all
%% subsequent children. In the case of `ignore' the specification is unchanged.
%%
%% An example of a `backoff_supervisor' callback module:
%% ```
%% -module(backoff_example).
%%
%% -export([start_link/0]).
%% -export([init/1]).
%%
%% start_link() ->
%%     backoff_supervisor:start_link(?MODULE, []).
%%
%% init([]) ->
%%     {ok, {{jitter, 100, 5000},
%%           {name, {mod, fun, []}, transient, 5000, worker, [mod]}}}.
%% '''
%%
%% When declaring a child spec of a `backoff_supervisor' in its parent
%% supervisor the shutdown should be `infinity' and the child type `supervisor'.
%% A `backoff_supervisor' should not be used as the top level supervisor in an
%% application because that process is assumed to be a `supervisor'.
%%
%% @see supervisor
%% @see backoff
-module(backoff_supervisor).

-behaviour(gen_server).

-define(TIMER_MAX, 4294967295).

%% public api

-export([start_child/2]).
-export([restart_child/2]).
-export([terminate_child/2]).
-export([delete_child/2]).
-export([which_children/1]).
-export([count_children/1]).
-export([start_link/2]).
-export([start_link/3]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% types

-type backoff_supervisor() :: pid() | atom() | {global, any()} |
                              {via, module(), any()}.
-type backoff_spec() :: {normal | jitter, pos_integer(),
                         pos_integer() | infinity}.

-export_type([backoff_supervisor/0]).
-export_type([backoff_spec/0]).

-callback init(Args :: any()) ->
    {ok, {backoff_spec(), [supervisor:child_spec(), ...]}} | ignore.

-record(state, {name :: {pid(), module()} | {local, atom()} | {global, any()} |
                    {via, module(), any()},
                module :: module(),
                args :: any(),
                id :: any(),
                mfargs :: {module(), atom(), list()},
                restart :: temporary | transient | permanent,
                shutdown :: brutal_kill | timeout(),
                child_type :: worker | supervisor,
                modules :: dynamic | [module()],
                child :: undefined | pid(),
                child_mfargs :: undefined | {module(), atom(), list()},
                start :: pos_integer(),
                max :: pos_integer() | infinity,
                backoff_type :: normal | jitter,
                backoff :: backoff:backoff(),
                backoff_ref :: undefined | reference()}).

%% public api

%% @doc Start a child under the supervisor, if one is not already started.
%%
%% `ExtraArgs' will be appended to the list of arguments in the child
%% specification for this child. `ExtraArgs' will only be appended to this
%% child, subsequent children started by the supervisor automatically will not
%% have `ExtraArgs'.
%%
%% @see supervisor:start_child/2
-spec start_child(Supervisor, ExtraArgs) -> Result when
      Supervisor :: backoff_supervisor(),
      ExtraArgs :: [any()],
      Result :: supervisor:startchild_ret().
start_child(Supervisor, ExtraArgs) ->
    call(Supervisor, {start_child, ExtraArgs}).

%% @doc Restart a child under the supervisor, always returns
%% `{error, simple_one_for_one}'.
%%
%% @see supervisor:restart_child/2
-spec restart_child(Supervisor, Child) -> {error, simple_one_for_one} when
      Supervisor :: backoff_supervisor(),
      Child :: pid().
restart_child(Supervisor, Child) ->
    call(Supervisor, {restart_child, Child}).

%% @doc Terminate the child, `Child', under the supervisor, if it is the
%% supervisor's child.
%%
%% If `Child' is the supervisor's child it will be terminated. A new child will
%% automatically be started by the supervisor after an initial delay.
%%
%% @see supervisor:terminate_child/2
-spec terminate_child(Supervisor, Child) -> ok | {error, not_found} when
      Supervisor :: backoff_supervisor(),
      Child :: pid().
terminate_child(Supervisor, Child) ->
    call(Supervisor, {terminate_child, Child}).

%% @doc Delete a child under the supervisor, always returns
%% `{error, simple_one_for_one}'.
%%
%% @see supervisor:delete_child/2
-spec delete_child(Supervisor, Child) -> {error, simple_one_for_one} when
      Supervisor :: backoff_supervisor(),
      Child :: pid().
delete_child(Supervisor, Child) ->
    call(Supervisor, {delete_child, Child}).

%% @doc Return a list of child specifications and child processes.
%%
%% The list will be empty if there is no children under the supervisor, or
%% contain the information for the supervisors single child if is alive. The
%% name of the child will always be `undefined'.
%%
%% @see supervisor:which_children/1
-spec which_children(Supervisor) -> [Child] when
      Supervisor :: backoff_supervisor(),
      Child :: {undefined, pid(), supervisor | worker, dynamic | [module()]}.
which_children(Supervisor) ->
    call(Supervisor, which_children).

%% @doc Return a property list containing counts relating to the supervisor's
%% child specifications and child processes.
%%
%% @see supervisor:count_children/1
-spec count_children(Supervisor) -> [Count, ...] when
      Supervisor :: backoff_supervisor(),
      Count :: {specs, 1} | {active, 0 | 1} | {supervisors, 0 | 1} |
               {workers, 0 | 1}.
count_children(Supervisor) ->
    call(Supervisor, count_children).

%% @doc Starts a supervisor with callback module `Module' and argument `Args'.
%%
%% @see supervisor:start_link/2
-spec start_link(Module, Args) -> {ok, Pid} | ignore | {error, Reason} when
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: term().
start_link(Module, Args) ->
    gen_server:start_link(?MODULE, {self, Module, Args}, []).

%% @doc Starts a supervisor with name `Name', callback module `Module' and
%% argument `Args'.
%%
%% @see supervisor:start_link/3
-spec start_link(Name, Module, Args) ->
    {ok, Pid} | ignore | {error, Reason} when
      Name :: {local, atom()} | {global, any()} | {via, module(), any()},
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: term().
start_link(Name, Module, Args) ->
    gen_server:start_link(Name, ?MODULE, {Name, Module, Args}, []).

%% gen_server api

%% @private
init({self, Module, Args}) ->
    init({{self(), Module}, Module, Args});
init({Name, Module, Args}) ->
    process_flag(trap_exit, true),
    case catch Module:init(Args) of
        {ok, {BackoffSpec, StartSpec}} ->
            init(Name, Module, Args, BackoffSpec, StartSpec);
        ignore ->
            ignore;
        {'EXIT', Reason} ->
            {stop, Reason};
        Other ->
            {stop, {bad_return, {Module, init, Other}}}
    end.

%% @private
handle_call({start_child, ExtraArgs}, _, State) ->
    handle_start_child(ExtraArgs, State);
handle_call({restart_child, _}, _, State) ->
    {reply, {error, simple_one_for_one}, State};
handle_call({terminate_child, Terminate}, _, State) ->
    handle_terminate_child(Terminate, State);
handle_call({delete_child, _}, _, State) ->
    {reply, {error, simple_one_for_one}, State};
handle_call(which_children, _, State) ->
    handle_which_children(State);
handle_call(count_children, _, State) ->
    handle_count_children(State).

%% @private
handle_cast(Cast, State) ->
    {stop, {bad_cast, Cast}, State}.

%% @private
handle_info({timeout, TRef, ?MODULE}, State) ->
    handle_timeout(TRef, State);
handle_info({'EXIT', Pid, Reason}, State) ->
    handle_exit(Pid, Reason, State);
handle_info(Msg, State) ->
    error_logger:error_msg("Backoff Supervisor received unexpected message: ~p",
                           [Msg]),
    {noreply, State}.

%% @private
code_change(_, #state{module=Module, args=Args} = State, _) ->
    case catch Module:init(Args) of
        {ok, {BackoffSpec, StartSpec}} ->
            handle_code_change(BackoffSpec, StartSpec, State);
        ignore ->
            {ok, State};
        {'EXIT', _} = Exit ->
            {error, Exit};
        Other ->
            {error, {bad_return, {Module, init, Other}}}
    end.

%% @private
terminate(_Reason, State) ->
    shutdown(State).

%% Internal

call(Supervisor, Request) ->
    gen_server:call(Supervisor, Request, infinity).

init(Name, Module, Args, {_, _, _} = BackoffSpec, StartSpec) ->
    case check_backoff_spec(BackoffSpec) of
        ok ->
            do_init(Name, Module, Args, BackoffSpec, StartSpec);
        {error, Reason} ->
            {stop, {backoff_spec, Reason}}
    end;
init(_, _, _, Other, _) ->
    {stop, {bad_backoff_spec, Other}}.

do_init(Name, Module, Args, {BackoffType, Start, Max}, [ChildSpec]) ->
    case supervisor:check_childspecs([ChildSpec]) of
        ok ->
            {Id, MFA, Restart, Shutdown, ChildType, Modules} = ChildSpec,
            Backoff = backoff_init(BackoffType, Start, Max),
            BRef = backoff:fire(Backoff),
            State = #state{name=Name, module=Module, args=Args,
                           backoff_type=BackoffType, start=Start, max=Max,
                           backoff=Backoff, backoff_ref=BRef,
                           id=Id, mfargs=MFA, restart=Restart,
                           shutdown=Shutdown, child_type=ChildType,
                           modules=Modules},
            {ok, State};
        {error, Reason} ->
            {stop, {start_spec, Reason}}
    end;
do_init(_, _, _, _, StartSpec) ->
    {stop, {bad_start_spec, StartSpec}}.

check_backoff_spec({BackoffType, _, _})
  when not (BackoffType =:= normal orelse BackoffType =:= jitter) ->
    {error, {invalid_type, BackoffType}};
check_backoff_spec({_, Start, _})
  when not (is_integer(Start) andalso Start > 0 andalso Start =< ?TIMER_MAX) ->
    {error, {invalid_start, Start}};
check_backoff_spec({_, Start, Max})
  when not (Max >= Start andalso (is_integer(Max) orelse Max =:= infinity)) ->
    {error, {invalid_max, Max}};
check_backoff_spec({_, _, _}) ->
    ok.

backoff_init(BackoffType, Start, Max) ->
    Backoff = backoff:init(Start, min(Max, ?TIMER_MAX), self(), ?MODULE),
    backoff:type(Backoff, BackoffType).

handle_start_child(ExtraArgs, #state{child=undefined, backoff_ref=BRef} = State)
  when is_reference(BRef) ->
    _ = erlang:cancel_timer(BRef),
    do_start_child(ExtraArgs, State#state{backoff_ref=undefined});
handle_start_child(_, #state{child=Child, backoff_ref=undefined} = State)
  when is_pid(Child) ->
    {reply, {error, {already_started, Child}}, State}.

do_start_child(ExtraArgs, #state{mfargs={Mod, Fun, Args}} = State) ->
    NArgs = Args ++ ExtraArgs,
    case catch apply(Mod, Fun, NArgs) of
        {ok, Child} = OK when is_pid(Child) ->
            {reply, OK, started(Child, {Mod, Fun, NArgs}, State)};
        {ok, Child, _} = OK when is_pid(Child) ->
            {reply, OK, started(Child, {Mod, Fun, NArgs}, State)};
        ignore ->
            {reply, {ok, undefined}, fire(State)};
        {error, _} = Error ->
            {reply, Error, fire(State)};
        Reason ->
            {reply, {error, Reason}, fire(State)}
    end.

started(Child, MFA, #state{backoff=Backoff} = State) ->
    {_, NBackoff} = backoff:succeed(Backoff),
    State#state{child=Child, child_mfargs=MFA, backoff=NBackoff}.

fire(#state{backoff=Backoff} = State) ->
    State#state{backoff_ref=backoff:fire(Backoff)}.

handle_terminate_child(Child, #state{child=Child} = State) when is_pid(Child) ->
    Reply = shutdown(State),
    {reply, Reply, fire(State#state{child=undefined, child_mfargs=undefined})};
handle_terminate_child(Pid, State) when is_pid(Pid) ->
    case erlang:is_process_alive(Pid) of
        true ->
            {reply, {error, not_found}, State};
        false ->
            {reply, ok, State}
    end;
handle_terminate_child(_, State) ->
    {reply, {error, simple_one_for_one}, State}.

shutdown(#state{child=Child} = State) when is_pid(Child) ->
    Monitor = monitor(process, Child),
    shutdown(Monitor, State);
shutdown(#state{child=undefined}) ->
    ok.

shutdown(Monitor, #state{shutdown=brutal_kill, child=Child} = State) ->
    exit(Child, kill),
    shutdown_await(Monitor, killed, infinity, State);
shutdown(Monitor, #state{shutdown=Timeout, child=Child} = State) ->
    exit(Child, shutdown),
    shutdown_await(Monitor, shutdown, Timeout, State).

shutdown_await(Monitor, Reason, Timeout,
               #state{child=Child, restart=Restart} = State) ->
    case do_shutdown_await(Monitor, Child, Reason, Timeout) of
        ok ->
            ok;
        {error, normal} when Restart =/= permanent ->
            ok;
        {error, Reason2} ->
            supervisor_report(shutdown_error, Reason2, State)
    end.

do_shutdown_await(Monitor, Pid, Reason, Timeout) ->
    receive
        {'DOWN', Monitor, _, _, Reason} ->
            ok;
        {'DOWN', Monitor, _, _, Other} ->
            {error, Other}
    after
        Timeout ->
            shutdown_timeout(Monitor, Pid)
    end.

shutdown_timeout(Monitor, Pid) ->
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, _, _, Reason} ->
            {error, Reason}
    end.

supervisor_report(Error, Reason, #state{name=Name} = State) ->
    Report = [{supervisor, Name}, {errorContext, Error}, {reason, Reason},
              {offender, child(State)}],
    error_logger:error_report(supervisor_report, Report).

child(#state{child_mfargs=undefined, mfargs=MFA} = State) ->
    child(State#state{child_mfargs=MFA});
child(#state{child=Child, child_mfargs=MFA, id=Id,
             restart=Restart, shutdown=Shutdown, child_type=ChildType}) ->
    [{pid, Child}, {name, Id}, {mfargs, MFA}, {restart_type, Restart},
     {shutdown, Shutdown}, {child_type, ChildType}].

handle_which_children(#state{child=Child, child_type=ChildType,
                             modules=Modules} = State) when is_pid(Child) ->
    {reply, [{undefined, Child, ChildType, Modules}], State};
handle_which_children(#state{child=undefined} = State) ->
    {reply, [], State}.

handle_count_children(State) ->
    {reply, [{specs, 1} | do_count_children(State)], State}.

do_count_children(#state{child=Child, child_type=supervisor})
  when is_pid(Child) ->
    [{active, 1}, {supervisors, 1}, {workers, 0}];
do_count_children(#state{child=Child, child_type=worker}) when is_pid(Child) ->
    [{active, 1}, {supervisors, 0}, {workers, 1}];
do_count_children(#state{child=undefined}) ->
    [{active, 0}, {supervisors, 0}, {workers, 0}].

handle_timeout(BRef, #state{backoff_ref=BRef, mfargs={Mod, Fun, Args}} = State)
  when is_reference(BRef) ->
    NState = State#state{backoff_ref=undefined},
    case catch apply(Mod, Fun, Args) of
        {ok, Child} when is_pid(Child) ->
            restarted(Child, NState);
        {ok, Child, _} when is_pid(Child) ->
            restarted(Child, NState);
        ignore ->
            backoff(NState);
        {error, Reason} ->
            failed(Reason, NState);
        Reason ->
            failed(Reason, NState)
    end;
handle_timeout(_, State) ->
    {noreply, State}.

restarted(Child, #state{mfargs=MFA} = State) ->
    {noreply, started(Child, MFA, State)}.

backoff(#state{backoff=Backoff} = State) ->
    {_, NBackoff} = backoff:fail(Backoff),
    {noreply, fire(State#state{backoff=NBackoff})}.

failed(Reason, #state{id=Id, mfargs=MFA} = State) ->
    supervisor_report(start_error, Reason, State#state{child_mfargs=MFA}),
    NReason = {shutdown, {failed_to_start_child, Id, Reason}},
    {stop, NReason, State}.

handle_exit(Child, Reason, #state{child=Child} = State) when is_pid(Child) ->
    terminated(Reason, State);
handle_exit(_, _, State) ->
    {noreply, State}.

terminated(Reason, #state{restart=permanent} = State) ->
    terminated_stop(Reason, State);
terminated(normal, State) ->
    terminated(State);
terminated(shutdown, State) ->
    terminated(State);
terminated({shutdown, _}, State) ->
    terminated(State);
terminated(Reason, #state{restart=transient} = State) ->
    terminated_stop(Reason, State);
terminated(Reason, #state{restart=temporary} = State) ->
    supervisor_report(child_terminated, Reason, State),
    terminated(State).

terminated_stop(Reason, #state{id=Id} = State) ->
    supervisor_report(child_terminated, Reason, State),
    supervisor_report(shutdown, reached_max_restart_intensity, State),
    NReason = {shutdown, {reached_max_restart_intensity, Id, Reason}},
    {stop, NReason, State#state{child=undefined, child_mfargs=undefined}}.

terminated(State) ->
    {noreply, fire(State#state{child=undefined, child_mfargs=undefined})}.

handle_code_change({_, _, _} = BackoffSpec, StartSpec, State) ->
    case check_backoff_spec(BackoffSpec) of
        ok ->
            NState = change_backoff_spec(BackoffSpec, State),
            change_start_spec(StartSpec, NState);
        {error, Reason} ->
            {error, {backoff_spec, Reason}}
    end;
handle_code_change(Other, _, _) ->
    {error, {bad_backoff_spec, Other}}.

change_backoff_spec({BackoffType, Start, Max},
                     #state{start=Start, max=Max, backoff=Backoff} = State) ->
    State#state{backoff=backoff:type(Backoff, BackoffType)};
change_backoff_spec({BackoffType, Start, Max}, State) ->
    State#state{backoff=backoff_init(BackoffType, Start, Max)}.

change_start_spec([ChildSpec], State) ->
    case supervisor:check_childspecs([ChildSpec]) of
        ok ->
            {Id, MFA, Restart, Shutdown, ChildType, Modules} = ChildSpec,
            NState = State#state{id=Id, mfargs=MFA, restart=Restart,
                                 shutdown=Shutdown, child_type=ChildType,
                                 modules=Modules},
            {ok, NState};
        {error, Reason} ->
            {error, {start_spec, Reason}}
    end;
change_start_spec(Other, _) ->
    {stop, {bad_start_spec, Other}}.

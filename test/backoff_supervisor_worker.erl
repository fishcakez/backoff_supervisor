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
-module(backoff_supervisor_worker).

-behaviour(gen_server).

%% public api

-export([start_link/0]).
-export([start_link/1]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% public api

start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(ok) ->
    start_link();
start_link({ok, Pid}) ->
    {ok, Child} = start_link(),
    Pid ! {started, self(), Child, now()},
    {ok, Child};
start_link({ignore, Pid}) ->
    Pid ! {ignored, self(), now()},
    ignore;
start_link({ignore, N, Pid} = Args) when N > 0 ->
    case get(?MODULE) of
        undefined ->
            put(?MODULE, 0),
            start_link(Args);
        N ->
            {ok, Child} = start_link(),
            Pid ! {started, self(), Child, now()},
            {ok, Child};
        M ->
            Pid ! {ignored, self(), now()},
            put(?MODULE, M+1),
            ignore
    end;
start_link({info, Pid}) ->
    {ok, Child} = start_link(),
    Pid ! {started, self(), Child, now()},
    {ok, Child, Pid};
start_link({error, _} = Error) ->
    Error;
start_link({{error, _} = Error, N, Pid} = Args) when N > 0 ->
    case get(?MODULE) of
        undefined ->
            put(?MODULE, 0),
            start_link(Args);
        N ->
            {ok, Child} = start_link(),
            Pid ! {started, self(), Child, now()},
            {ok, Child};
        M ->
            put(?MODULE, M+1),
            Error
    end;
start_link({trap_exit, Pid}) ->
    {ok, Child} = gen_server:start_link(?MODULE, trap_exit, []),
    Pid ! {started, self(), Child, now()},
    {ok, Child}.

%% gen_server api

init(trap_exit) ->
    _ = process_flag(trap_exit, true),
    {ok, trap_exit};
init([]) ->
    {ok, undefined}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, trap_exit) ->
    timer:sleep(30000);
terminate(_Reason, _State) ->
    ok.

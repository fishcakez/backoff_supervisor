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
-module(backoff_supervisor_sup).

-behaviour(supervisor).

%% public api

-export([start_link/0]).
-export([start_link/1]).

%% supervisor api

-export([init/1]).

%% public api

start_link() ->
    supervisor:start_link(?MODULE, []).

start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

%% supervisor api

init([]) ->
    {ok, {{one_for_one, 1, 5}, []}};
init(Spec) ->
    Spec.

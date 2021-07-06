%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_resource_instance).

-behaviour(gen_server).

-include("emqx_resource.hrl").
-include("emqx_resource_utils.hrl").

-export([start_link/2]).

%% load resource instances from *.conf files
-export([ lookup/1
        , list_all/0
        , lookup_by_type/1
        , create_local/3
        ]).

-export([ hash_call/2
        , hash_call/3
        ]).

%% gen_server Callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(state, {worker_pool, worker_id}).

-type state() :: #state{}.

%%------------------------------------------------------------------------------
%% Start the registry
%%------------------------------------------------------------------------------

start_link(Pool, Id) ->
    gen_server:start_link({local, proc_name(?MODULE, Id)},
                          ?MODULE, {Pool, Id}, []).

%% call the worker by the hash of resource-instance-id, to make sure we always handle
%% operations on the same instance in the same worker.
hash_call(InstId, Request) ->
    hash_call(InstId, Request, infinity).

hash_call(InstId, Request, Timeout) ->
    gen_server:call(pick(InstId), Request, Timeout).

-spec lookup(instance_id()) -> {ok, resource_data()} | {error, Reason :: term()}.
lookup(InstId) ->
    case ets:lookup(emqx_resource_instance, InstId) of
        [] -> {error, not_found};
        [{_, Data}] -> {ok, Data#{id => InstId}}
    end.

force_lookup(InstId) ->
    {ok, Data} = lookup(InstId),
    Data.

-spec list_all() -> [resource_data()].
list_all() ->
    [Data#{id => Id} || {Id, Data} <- ets:tab2list(emqx_resource_instance)].

-spec lookup_by_type(module()) -> [resource_data()].
lookup_by_type(ResourceType) ->
    [Data || #{mod := Mod} = Data <- list_all()
             , Mod =:= ResourceType].

-spec create_local(instance_id(), resource_type(), resource_config()) ->
    {ok, resource_data()} | {error, term()}.
create_local(InstId, ResourceType, InstConf) ->
    case hash_call(InstId, {create, InstId, ResourceType, InstConf}, 15000) of
        {ok, Data} -> {ok, Data};
        Error -> Error
    end.

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

-spec init({atom(), integer()}) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term()} | ignore.
init({Pool, Id}) ->
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, #state{worker_pool = Pool, worker_id = Id}}.

handle_call({create, InstId, ResourceType, Config}, _From, State) ->
    {reply, do_create(InstId, ResourceType, Config), State};

handle_call({create_dry_run, InstId, ResourceType, Config}, _From, State) ->
    {reply, do_create_dry_run(InstId, ResourceType, Config), State};

handle_call({update, InstId, ResourceType, Config, Params}, _From, State) ->
    {reply, do_update(InstId, ResourceType, Config, Params), State};

handle_call({remove, InstId}, _From, State) ->
    {reply, do_remove(InstId), State};

handle_call({restart, InstId}, _From, State) ->
    {reply, do_restart(InstId), State};

handle_call({stop, InstId}, _From, State) ->
    {reply, do_stop(InstId), State};

handle_call({health_check, InstId}, _From, State) ->
    {reply, do_health_check(InstId), State};

handle_call(Req, _From, State) ->
    logger:error("Received unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{worker_pool = Pool, worker_id = Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------

%% suppress the race condition check, as these functions are protected in gproc workers
-dialyzer({nowarn_function, [do_update/4, do_create/3, do_restart/1, do_stop/1, do_health_check/1]}).
do_update(InstId, ResourceType, NewConfig, Params) ->
    case lookup(InstId) of
        {ok, #{mod := ResourceType, state := ResourceState, config := OldConfig}} ->
            Config = emqx_resource:call_config_merge(ResourceType, OldConfig,
                        NewConfig, Params),
            case do_create_dry_run(InstId, ResourceType, Config) of
                ok ->
                    do_remove(ResourceType, InstId, ResourceState),
                    do_create(InstId, ResourceType, Config);
                Error ->
                    Error
            end;
        {ok, #{mod := Mod}} when Mod =/= ResourceType ->
            {error, updating_to_incorrect_resource_type};
        {error, not_found} ->
            {error, not_found}
    end.

do_create(InstId, ResourceType, Config) ->
    case lookup(InstId) of
        {ok, _} -> {error, already_created};
        _ ->
            case emqx_resource:call_start(InstId, ResourceType, Config) of
                {ok, ResourceState} ->
                    ets:insert(emqx_resource_instance, {InstId,
                        #{mod => ResourceType, config => Config,
                          state => ResourceState, status => stopped}}),
                    _ = do_health_check(InstId),
                    {ok, force_lookup(InstId)};
                {error, Reason} ->
                    logger:error("start ~s resource ~s failed: ~p", [ResourceType, InstId, Reason]),
                    {error, Reason}
            end
    end.

do_create_dry_run(InstId, ResourceType, Config) ->
    case emqx_resource:call_start(InstId, ResourceType, Config) of
        {ok, ResourceState0} ->
            Return = case emqx_resource:call_health_check(InstId, ResourceType, ResourceState0) of
                {ok, ResourceState1} -> ok;
                {error, Reason, ResourceState1} ->
                    {error, Reason}
            end,
            _ = emqx_resource:call_stop(InstId, ResourceType, ResourceState1),
            Return;
        {error, Reason} ->
            {error, Reason}
    end.

do_remove(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState}} ->
            do_remove(Mod, InstId, ResourceState);
        Error ->
            Error
    end.

do_remove(Mod, InstId, ResourceState) ->
    _ = emqx_resource:call_stop(InstId, Mod, ResourceState),
    ets:delete(emqx_resource_instance, InstId),
    ok.

do_restart(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState, config := Config} = Data} ->
            _ = emqx_resource:call_stop(InstId, Mod, ResourceState),
            case emqx_resource:call_start(InstId, Mod, Config) of
                {ok, ResourceState} ->
                    ets:insert(emqx_resource_instance,
                        {InstId, Data#{state => ResourceState, status => started}}),
                    ok;
                {error, Reason} ->
                    ets:insert(emqx_resource_instance, {InstId, Data#{status => stopped}}),
                    {error, Reason}
            end;
        Error ->
            Error
    end.

do_stop(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState} = Data} ->
            _ = emqx_resource:call_stop(InstId, Mod, ResourceState),
            ets:insert(emqx_resource_instance, {InstId, Data#{status => stopped}}),
            ok;
        Error ->
            Error
    end.

do_health_check(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState0} = Data} ->
            case emqx_resource:call_health_check(InstId, Mod, ResourceState0) of
                {ok, ResourceState1} ->
                    ets:insert(emqx_resource_instance,
                        {InstId, Data#{status => started, state => ResourceState1}}),
                    ok;
                {error, Reason, ResourceState1} ->
                    logger:error("health check for ~p failed: ~p", [InstId, Reason]),
                    ets:insert(emqx_resource_instance,
                        {InstId, Data#{status => stopped, state => ResourceState1}}),
                    {error, Reason}
            end;
        Error ->
            Error
    end.

%%------------------------------------------------------------------------------
%% internal functions
%%------------------------------------------------------------------------------

proc_name(Mod, Id) ->
    list_to_atom(lists:concat([Mod, "_", Id])).

pick(InstId) ->
    gproc_pool:pick_worker(emqx_resource_instance, InstId).

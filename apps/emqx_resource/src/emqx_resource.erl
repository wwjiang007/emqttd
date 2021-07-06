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

-module(emqx_resource).

-include("emqx_resource.hrl").
-include("emqx_resource_utils.hrl").

%% APIs for resource types

-export([ get_type/1
        , list_types/0
        , list_types_verbose/0
        ]).

-export([ discover_resource_mods/0
        , is_resource_mod/1
        , call_instance/2
        ]).

-export([ query_success/1
        , query_failed/1
        ]).

%% APIs for instances

-export([ check_config/2
        , check_and_create/3
        , check_and_create_local/3
        , check_and_update/4
        , check_and_update_local/4
        , resource_type_from_str/1
        ]).

%% Sync resource instances and files
%% provisional solution: rpc:multical to all the nodes for creating/updating/removing
%% todo: replicate operations
-export([ create/3 %% store the config and start the instance
        , create_local/3
        , create_dry_run/3 %% run start/2, health_check/2 and stop/1 sequentially
        , create_dry_run_local/3
        , update/4 %% update the config, stop the old instance and start the new one
        , update_local/4
        , remove/1 %% remove the config and stop the instance
        , remove_local/1
        ]).

%% Calls to the callback module with current resource state
%% They also save the state after the call finished (except query/2,3).
-export([ restart/1  %% restart the instance.
        , health_check/1 %% verify if the resource is working normally
        , stop/1   %% stop the instance
        , query/2  %% query the instance
        , query/3  %% query the instance with after_query()
        ]).

%% Direct calls to the callback module
-export([ call_start/3  %% start the instance
        , call_health_check/3 %% verify if the resource is working normally
        , call_stop/3   %% stop the instance
        , call_config_merge/4 %% merge the config when updating
        , call_jsonify/2
        ]).

-export([ list_instances/0 %% list all the instances, id only.
        , list_instances_verbose/0 %% list all the instances
        , get_instance/1 %% return the data of the instance
        , list_instances_by_type/1 %% return all the instances of the same resource type
        % , dependents/1
        % , inc_counter/2 %% increment the counter of the instance
        % , inc_counter/3 %% increment the counter by a given integer
        ]).

-define(HOCON_CHECK_OPTS, #{atom_key => true, nullable => false}).

-optional_callbacks([ on_query/4
                    , on_health_check/2
                    , on_config_merge/3
                    , on_jsonify/1
                    , on_api_reply_format/1
                    ]).

-callback on_api_reply_format(resource_data()) -> jsx:json_term().

-callback on_config_merge(resource_config(), resource_config(), term()) -> resource_config().

-callback on_jsonify(resource_config()) -> jsx:json_term().

%% when calling emqx_resource:start/1
-callback on_start(instance_id(), resource_config()) ->
    {ok, resource_state()} | {error, Reason :: term()}.

%% when calling emqx_resource:stop/1
-callback on_stop(instance_id(), resource_state()) -> term().

%% when calling emqx_resource:query/3
-callback on_query(instance_id(), Request :: term(), after_query(), resource_state()) -> term().

%% when calling emqx_resource:health_check/2
-callback on_health_check(instance_id(), resource_state()) ->
    {ok, resource_state()} | {error, Reason:: term(), resource_state()}.

%% load specs and return the loaded resources this time.
-spec list_types_verbose() -> [resource_spec()].
list_types_verbose() ->
    [get_spec(Mod) || Mod <- list_types()].

-spec list_types() -> [module()].
list_types() ->
    discover_resource_mods().

-spec get_type(module()) -> {ok, resource_spec()} | {error, not_found}.
get_type(Mod) ->
    case is_resource_mod(Mod) of
        true -> {ok, get_spec(Mod)};
        false -> {error, not_found}
    end.

-spec get_spec(module()) -> resource_spec().
get_spec(Mod) ->
    maps:put(<<"resource_type">>, Mod, Mod:emqx_resource_schema()).

-spec discover_resource_mods() -> [module()].
discover_resource_mods() ->
    [Mod || {Mod, _} <- code:all_loaded(), is_resource_mod(Mod)].

-spec is_resource_mod(module()) -> boolean().
is_resource_mod(Mod) ->
    erlang:function_exported(Mod, emqx_resource_schema, 0).

-spec query_success(after_query()) -> ok.
query_success(undefined) -> ok;
query_success({{OnSucc, Args}, _}) ->
    safe_apply(OnSucc, Args).

-spec query_failed(after_query()) -> ok.
query_failed(undefined) -> ok;
query_failed({_, {OnFailed, Args}}) ->
    safe_apply(OnFailed, Args).

%% =================================================================================
%% APIs for resource instances
%% =================================================================================
-spec create(instance_id(), resource_type(), resource_config()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
create(InstId, ResourceType, Config) ->
    ?CLUSTER_CALL(create_local, [InstId, ResourceType, Config], {ok, _}).

-spec create_local(instance_id(), resource_type(), resource_config()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
create_local(InstId, ResourceType, Config) ->
    call_instance(InstId, {create, InstId, ResourceType, Config}).

-spec create_dry_run(instance_id(), resource_type(), resource_config()) ->
    ok | {error, Reason :: term()}.
create_dry_run(InstId, ResourceType, Config) ->
    ?CLUSTER_CALL(create_dry_run_local, [InstId, ResourceType, Config]).

-spec create_dry_run_local(instance_id(), resource_type(), resource_config()) ->
    ok | {error, Reason :: term()}.
create_dry_run_local(InstId, ResourceType, Config) ->
    call_instance(InstId, {create_dry_run, InstId, ResourceType, Config}).

-spec update(instance_id(), resource_type(), resource_config(), term()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
update(InstId, ResourceType, Config, Params) ->
    ?CLUSTER_CALL(update_local, [InstId, ResourceType, Config, Params], {ok, _}).

-spec update_local(instance_id(), resource_type(), resource_config(), term()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
update_local(InstId, ResourceType, Config, Params) ->
    call_instance(InstId, {update, InstId, ResourceType, Config, Params}).

-spec remove(instance_id()) -> ok | {error, Reason :: term()}.
remove(InstId) ->
    ?CLUSTER_CALL(remove_local, [InstId]).

-spec remove_local(instance_id()) -> ok | {error, Reason :: term()}.
remove_local(InstId) ->
    call_instance(InstId, {remove, InstId}).

%% =================================================================================
-spec query(instance_id(), Request :: term()) -> Result :: term().
query(InstId, Request) ->
    query(InstId, Request, undefined).

%% same to above, also defines what to do when the Module:on_query success or failed
%% it is the duty of the Moudle to apply the `after_query()` functions.
-spec query(instance_id(), Request :: term(), after_query()) -> Result :: term().
query(InstId, Request, AfterQuery) ->
    case get_instance(InstId) of
        {ok, #{mod := Mod, state := ResourceState}} ->
            %% the resource state is readonly to Moudle:on_query/4
            %% and the `after_query()` functions should be thread safe
            Mod:on_query(InstId, Request, AfterQuery, ResourceState);
        {error, Reason} ->
            error({get_instance, {InstId, Reason}})
    end.

-spec restart(instance_id()) -> ok | {error, Reason :: term()}.
restart(InstId) ->
    call_instance(InstId, {restart, InstId}).

-spec stop(instance_id()) -> ok | {error, Reason :: term()}.
stop(InstId) ->
    call_instance(InstId, {stop, InstId}).

-spec health_check(instance_id()) -> ok | {error, Reason :: term()}.
health_check(InstId) ->
    call_instance(InstId, {health_check, InstId}).

-spec get_instance(instance_id()) -> {ok, resource_data()} | {error, Reason :: term()}.
get_instance(InstId) ->
    emqx_resource_instance:lookup(InstId).

-spec list_instances() -> [instance_id()].
list_instances() ->
    [Id || #{id := Id} <- list_instances_verbose()].

-spec list_instances_verbose() -> [resource_data()].
list_instances_verbose() ->
    emqx_resource_instance:list_all().

-spec list_instances_by_type(module()) -> [resource_data()].
list_instances_by_type(ResourceType) ->
    emqx_resource_instance:lookup_by_type(ResourceType).

-spec call_start(instance_id(), module(), resource_config()) ->
    {ok, resource_state()} | {error, Reason :: term()}.
call_start(InstId, Mod, Config) ->
    ?SAFE_CALL(Mod:on_start(InstId, Config)).

-spec call_health_check(instance_id(), module(), resource_state()) ->
    {ok, resource_state()} | {error, Reason:: term(), resource_state()}.
call_health_check(InstId, Mod, ResourceState) ->
    ?SAFE_CALL(Mod:on_health_check(InstId, ResourceState)).

-spec call_stop(instance_id(), module(), resource_state()) -> term().
call_stop(InstId, Mod, ResourceState) ->
    ?SAFE_CALL(Mod:on_stop(InstId, ResourceState)).

-spec call_config_merge(module(), resource_config(), resource_config(), term()) ->
    resource_config().
call_config_merge(Mod, OldConfig, NewConfig, Params) ->
    case erlang:function_exported(Mod, on_config_merge, 3) of
        true -> ?SAFE_CALL(Mod:on_config_merge(OldConfig, NewConfig, Params));
        false -> NewConfig
    end.

-spec call_jsonify(module(), resource_config()) -> jsx:json_term().
call_jsonify(Mod, Config) ->
    case erlang:function_exported(Mod, on_jsonify, 1) of
        false -> Config;
        true -> ?SAFE_CALL(Mod:on_jsonify(Config))
    end.

-spec check_config(resource_type(), raw_resource_config()) ->
    {ok, resource_config()} | {error, term()}.
check_config(ResourceType, RawConfig) when is_binary(RawConfig) ->
    case hocon:binary(RawConfig, #{format => richmap}) of
        {ok, MapConfig} ->
            case ?SAFE_CALL(hocon_schema:check(ResourceType, MapConfig, ?HOCON_CHECK_OPTS)) of
                {error, Reason} -> {error, Reason};
                Config -> {ok, hocon_schema:richmap_to_map(Config)}
            end;
        Error -> Error
    end;
check_config(ResourceType, RawConfigTerm) ->
    case ?SAFE_CALL(hocon_schema:check_plain(ResourceType, RawConfigTerm, ?HOCON_CHECK_OPTS)) of
        {error, Reason} -> {error, Reason};
        Config -> {ok, Config}
    end.

-spec check_and_create(instance_id(), resource_type(), raw_resource_config()) ->
    {ok, resource_data()} | {error, term()}.
check_and_create(InstId, ResourceType, RawConfig) ->
    check_and_do(ResourceType, RawConfig,
        fun(InstConf) -> create(InstId, ResourceType, InstConf) end).

-spec check_and_create_local(instance_id(), resource_type(), raw_resource_config()) ->
    {ok, resource_data()} | {error, term()}.
check_and_create_local(InstId, ResourceType, RawConfig) ->
    check_and_do(ResourceType, RawConfig,
        fun(InstConf) -> create_local(InstId, ResourceType, InstConf) end).

-spec check_and_update(instance_id(), resource_type(), raw_resource_config(), term()) ->
    {ok, resource_data()} | {error, term()}.
check_and_update(InstId, ResourceType, RawConfig, Params) ->
    check_and_do(ResourceType, RawConfig,
        fun(InstConf) -> update(InstId, ResourceType, InstConf, Params) end).

-spec check_and_update_local(instance_id(), resource_type(), raw_resource_config(), term()) ->
    {ok, resource_data()} | {error, term()}.
check_and_update_local(InstId, ResourceType, RawConfig, Params) ->
    check_and_do(ResourceType, RawConfig,
        fun(InstConf) -> update_local(InstId, ResourceType, InstConf, Params) end).

check_and_do(ResourceType, RawConfig, Do) when is_function(Do) ->
    case check_config(ResourceType, RawConfig) of
        {ok, InstConf} -> Do(InstConf);
        Error -> Error
    end.

%% =================================================================================

-spec resource_type_from_str(string()) -> {ok, resource_type()} | {error, term()}.
resource_type_from_str(ResourceType) ->
    try Mod = list_to_existing_atom(str(ResourceType)),
        case emqx_resource:is_resource_mod(Mod) of
            true -> {ok, Mod};
            false -> {error, {invalid_resource, Mod}}
        end
    catch error:badarg ->
        {error, {resource_not_found, ResourceType}}
    end.

call_instance(InstId, Query) ->
    emqx_resource_instance:hash_call(InstId, Query).

safe_apply(Func, Args) ->
    ?SAFE_CALL(erlang:apply(Func, Args)).

str(S) when is_binary(S) -> binary_to_list(S);
str(S) when is_list(S) -> S.

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

-module(emqx_rule_monitor).

-behavior(gen_server).

-include("rule_engine.hrl").
-include_lib("emqx/include/logger.hrl").
-logger_header("[Rule Monitor]").

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([ start_link/0
        , stop/0
        , ensure_resource_retrier/2
        , retry_loop/3
        ]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:stop(?MODULE).

init([]) ->
    _ = erlang:process_flag(trap_exit, true),
    {ok, #{retryers => #{}}}.

ensure_resource_retrier(ResId, Interval) ->
    gen_server:cast(?MODULE, {create_restart_handler, resource, ResId, Interval}).

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({create_restart_handler, Tag, Obj, Interval}, State) ->
    Objects = maps:get(Tag, State, #{}),
    NewState = case maps:find(Obj, Objects) of
        error ->
            update_object(Tag, Obj,
                create_restart_handler(Tag, Obj, Interval), State);
        {ok, _Pid} ->
            State
    end,
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #{retryers := Retryers}) ->
    case maps:take(Pid, Retryers) of
        {{Tag, Obj}, Retryers2} ->
            Objects = maps:get(Tag, State, #{}),
            {noreply, State#{Tag => maps:remove(Obj, Objects),
                             retryers => Retryers2}};
        error ->
            ?LOG(error, "got unexpected proc down: ~p ~p", [Pid, Reason]),
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

update_object(Tag, Obj, Retryer, State) ->
    Objects = maps:get(Tag, State, #{}),
    Retryers = maps:get(retryers, State, #{}),
    State#{
        Tag => Objects#{Obj => Retryer},
        retryers => Retryers#{Retryer => {Tag, Obj}}
    }.

create_restart_handler(Tag, Obj, Interval) ->
    ?LOG(info, "keep restarting ~p ~p, interval: ~p", [Tag, Obj, Interval]),
    %% spawn a dedicated process to handle the restarting asynchronously
    spawn_link(?MODULE, retry_loop, [Tag, Obj, Interval]).

retry_loop(resource, ResId, Interval) ->
    case emqx_rule_registry:find_resource(ResId) of
        {ok, #resource{type = Type, config = Config}} ->
            try
                {ok, #resource_type{on_create = {M, F}}} =
                    emqx_rule_registry:find_resource_type(Type),
                ok = emqx_rule_engine:init_resource(M, F, ResId, Config),
                refresh_and_enable_rules_of_resource(ResId)
            catch
                Err:Reason:ST ->
                    ?LOG(warning, "init_resource failed: ~p, ~0p",
                        [{Err, Reason}, ST]),
                    timer:sleep(Interval),
                    ?MODULE:retry_loop(resource, ResId, Interval)
            end;
        not_found ->
            ok
    end.

refresh_and_enable_rules_of_resource(ResId) ->
    lists:foreach(
        fun (#rule{id = Id, enabled = false, state = refresh_failed_at_bootup} = Rule) ->
                emqx_rule_engine:refresh_rule(Rule),
                emqx_rule_registry:add_rule(Rule#rule{enabled = true, state = normal}),
                ?LOG(info, "rule ~s is refreshed and re-enabled", [Id]);
            (_) -> ok
        end, emqx_rule_registry:find_rules_depends_on_resource(ResId)).

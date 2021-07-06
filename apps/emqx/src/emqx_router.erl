%%--------------------------------------------------------------------
%% Copyright (c) 2017-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_router).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").
-include("types.hrl").
-include_lib("ekka/include/ekka.hrl").

-logger_header("[Router]").

%% Mnesia bootstrap
-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).
-copy_mnesia({mnesia, [copy]}).

-export([start_link/2]).

%% Route APIs
-export([ add_route/1
        , add_route/2
        , do_add_route/1
        , do_add_route/2
        ]).

-export([ delete_route/1
        , delete_route/2
        , do_delete_route/1
        , do_delete_route/2
        ]).

-export([ match_routes/1
        , lookup_routes/1
        , has_routes/1
        ]).

-export([print_routes/1]).

-export([topics/0]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-type(group() :: binary()).

-type(dest() :: node() | {group(), node()}).

-define(ROUTE_TAB, emqx_route).
-rlog_shard({?ROUTE_SHARD, ?ROUTE_TAB}).

%%--------------------------------------------------------------------
%% Mnesia bootstrap
%%--------------------------------------------------------------------

mnesia(boot) ->
    ok = ekka_mnesia:create_table(?ROUTE_TAB, [
                {type, bag},
                {ram_copies, [node()]},
                {record_name, route},
                {attributes, record_info(fields, route)},
                {storage_properties, [{ets, [{read_concurrency, true},
                                             {write_concurrency, true}]}]}]);
mnesia(copy) ->
    ok = ekka_mnesia:copy_table(?ROUTE_TAB, ram_copies).

%%--------------------------------------------------------------------
%% Start a router
%%--------------------------------------------------------------------

-spec(start_link(atom(), pos_integer()) -> startlink_ret()).
start_link(Pool, Id) ->
    gen_server:start_link({local, emqx_misc:proc_name(?MODULE, Id)},
                          ?MODULE, [Pool, Id], [{hibernate_after, 1000}]).

%%--------------------------------------------------------------------
%% Route APIs
%%--------------------------------------------------------------------

-spec(add_route(emqx_topic:topic()) -> ok | {error, term()}).
add_route(Topic) when is_binary(Topic) ->
    add_route(Topic, node()).

-spec(add_route(emqx_topic:topic(), dest()) -> ok | {error, term()}).
add_route(Topic, Dest) when is_binary(Topic) ->
    call(pick(Topic), {add_route, Topic, Dest}).

-spec(do_add_route(emqx_topic:topic()) -> ok | {error, term()}).
do_add_route(Topic) when is_binary(Topic) ->
    do_add_route(Topic, node()).

-spec(do_add_route(emqx_topic:topic(), dest()) -> ok | {error, term()}).
do_add_route(Topic, Dest) when is_binary(Topic) ->
    Route = #route{topic = Topic, dest = Dest},
    case lists:member(Route, lookup_routes(Topic)) of
        true  -> ok;
        false ->
            ok = emqx_router_helper:monitor(Dest),
            case emqx_topic:wildcard(Topic) of
                true  ->
                    maybe_trans(fun insert_trie_route/1, [Route]);
                false -> insert_direct_route(Route)
            end
    end.

%% @doc Match routes
-spec(match_routes(emqx_topic:topic()) -> [emqx_types:route()]).
match_routes(Topic) when is_binary(Topic) ->
    case match_trie(Topic) of
        [] -> lookup_routes(Topic);
        Matched ->
            lists:append([lookup_routes(To) || To <- [Topic | Matched]])
    end.

%% Optimize: routing table will be replicated to all router nodes.
match_trie(Topic) ->
    case emqx_trie:empty() of
        true -> [];
        false -> emqx_trie:match(Topic)
    end.

-spec(lookup_routes(emqx_topic:topic()) -> [emqx_types:route()]).
lookup_routes(Topic) ->
    ets:lookup(?ROUTE_TAB, Topic).

-spec(has_routes(emqx_topic:topic()) -> boolean()).
has_routes(Topic) when is_binary(Topic) ->
    ets:member(?ROUTE_TAB, Topic).

-spec(delete_route(emqx_topic:topic()) -> ok | {error, term()}).
delete_route(Topic) when is_binary(Topic) ->
    delete_route(Topic, node()).

-spec(delete_route(emqx_topic:topic(), dest()) -> ok | {error, term()}).
delete_route(Topic, Dest) when is_binary(Topic) ->
    call(pick(Topic), {delete_route, Topic, Dest}).

-spec(do_delete_route(emqx_topic:topic()) -> ok | {error, term()}).
do_delete_route(Topic) when is_binary(Topic) ->
    do_delete_route(Topic, node()).

-spec(do_delete_route(emqx_topic:topic(), dest()) -> ok | {error, term()}).
do_delete_route(Topic, Dest) ->
    Route = #route{topic = Topic, dest = Dest},
    case emqx_topic:wildcard(Topic) of
        true  ->
            maybe_trans(fun delete_trie_route/1, [Route]);
        false -> delete_direct_route(Route)
    end.

-spec(topics() -> list(emqx_topic:topic())).
topics() ->
    mnesia:dirty_all_keys(?ROUTE_TAB).

%% @doc Print routes to a topic
-spec(print_routes(emqx_topic:topic()) -> ok).
print_routes(Topic) ->
    lists:foreach(fun(#route{topic = To, dest = Dest}) ->
                      io:format("~s -> ~s~n", [To, Dest])
                  end, match_routes(Topic)).

call(Router, Msg) ->
    gen_server:call(Router, Msg, infinity).

pick(Topic) ->
    gproc_pool:pick_worker(router_pool, Topic).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id]) ->
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, #{pool => Pool, id => Id}}.

handle_call({add_route, Topic, Dest}, _From, State) ->
    Ok = do_add_route(Topic, Dest),
    {reply, Ok, State};

handle_call({delete_route, Topic, Dest}, _From, State) ->
    Ok = do_delete_route(Topic, Dest),
    {reply, Ok, State};

handle_call(Req, _From, State) ->
    ?LOG(error, "Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?LOG(error, "Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG(error, "Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #{pool := Pool, id := Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

insert_direct_route(Route) ->
    ekka_mnesia:dirty_write(?ROUTE_TAB, Route).

insert_trie_route(Route = #route{topic = Topic}) ->
    case mnesia:wread({?ROUTE_TAB, Topic}) of
        [] -> emqx_trie:insert(Topic);
        _  -> ok
    end,
    mnesia:write(?ROUTE_TAB, Route, sticky_write).

delete_direct_route(Route) ->
    ekka_mnesia:dirty_delete_object(?ROUTE_TAB, Route).

delete_trie_route(Route = #route{topic = Topic}) ->
    case mnesia:wread({?ROUTE_TAB, Topic}) of
        [Route] -> %% Remove route and trie
                  ok = mnesia:delete_object(?ROUTE_TAB, Route, sticky_write),
                   emqx_trie:delete(Topic);
        [_|_]   -> %% Remove route only
                   mnesia:delete_object(?ROUTE_TAB, Route, sticky_write);
        []      -> ok
    end.

%% @private
-spec(maybe_trans(function(), list(any())) -> ok | {error, term()}).
maybe_trans(Fun, Args) ->
    case persistent_term:get(emqx_route_lock_type) of
        key ->
            trans(Fun, Args);
        global ->
            %% Assert:
            mnesia = ekka_rlog:backend(), %% TODO: do something smarter than just crash
            lock_router(),
            try mnesia:sync_dirty(Fun, Args)
            after
                unlock_router()
            end;
        tab ->
            trans(fun() ->
                          emqx_trie:lock_tables(),
                          apply(Fun, Args)
                  end, [])
    end.

%% The created fun only terminates with explicit exception
-dialyzer({nowarn_function, [trans/2]}).

-spec(trans(function(), list(any())) -> ok | {error, term()}).
trans(Fun, Args) ->
    {WPid, RefMon} =
        spawn_monitor(
            %% NOTE: this is under the assumption that crashes in Fun
            %% are caught by mnesia:transaction/2.
            %% Future changes should keep in mind that this process
            %% always exit with database write result.
            fun() ->
                    Res = case ekka_mnesia:transaction(?ROUTE_SHARD, Fun, Args) of
                              {atomic, Ok} -> Ok;
                              {aborted, Reason} -> {error, Reason}
                          end,
                    exit({shutdown, Res})
            end),
    %% Receive a 'shutdown' exit to pass result from the short-lived process.
    %% so the receive below can be receive-mark optimized by the compiler.
    %%
    %% If the result is sent as a regular message, we'll have to
    %% either demonitor (with flush which is essentially a 'receive' since
    %% the process is no longer alive after the result has been received),
    %% or use a plain 'receive' to drain the normal 'DOWN' message.
    %% However the compiler does not optimize this second 'receive'.
    receive
        {'DOWN', RefMon, process, WPid, Info} ->
            case Info of
                {shutdown, Result} -> Result;
                _ -> {error, {trans_crash, Info}}
            end
    end.

lock_router() ->
    %% if Retry is not 0, global:set_lock could sleep a random time up to 8s.
    %% Considering we have a limited number of brokers, it is safe to use sleep 1 ms.
    case global:set_lock({?MODULE, self()}, [node() | nodes()], 0) of
        false ->
            %% Force to sleep 1ms instead.
            timer:sleep(1),
            lock_router();
        true ->
            ok
    end.

unlock_router() ->
    global:del_lock({?MODULE, self()}).

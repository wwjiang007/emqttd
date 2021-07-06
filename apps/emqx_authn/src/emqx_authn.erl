%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authn).

-include("emqx_authn.hrl").

-export([ enable/0
        , disable/0
        ]).

-export([authenticate/1]).

-export([ create_chain/1
        , delete_chain/1
        , lookup_chain/1
        , list_chains/0
        , bind/2
        , unbind/2
        , list_bindings/1
        , list_bound_chains/1
        , create_authenticator/2
        , delete_authenticator/2
        , update_authenticator/3
        , lookup_authenticator/2
        , list_authenticators/1
        , move_authenticator_to_the_front/2
        , move_authenticator_to_the_end/2
        , move_authenticator_to_the_nth/3
        ]).

-export([ import_users/3
        , add_user/3
        , delete_user/3
        , update_user/4
        , lookup_user/3
        , list_users/2
        ]).

-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).

-define(CHAIN_TAB, emqx_authn_chain).
-define(BINDING_TAB, emqx_authn_binding).

-rlog_shard({?AUTH_SHARD, ?CHAIN_TAB}).
-rlog_shard({?AUTH_SHARD, ?BINDING_TAB}).

%%------------------------------------------------------------------------------
%% Mnesia bootstrap
%%------------------------------------------------------------------------------

%% @doc Create or replicate tables.
-spec(mnesia(boot) -> ok).
mnesia(boot) ->
    %% Optimize storage
    StoreProps = [{ets, [{read_concurrency, true}]}],
    %% Chain table
    ok = ekka_mnesia:create_table(?CHAIN_TAB, [
                {ram_copies, [node()]},
                {record_name, chain},
                {local_content, true},
                {attributes, record_info(fields, chain)},
                {storage_properties, StoreProps}]),
    %% Binding table
    ok = ekka_mnesia:create_table(?BINDING_TAB, [
                {ram_copies, [node()]},
                {record_name, binding},
                {local_content, true},
                {attributes, record_info(fields, binding)},
                {storage_properties, StoreProps}]).

enable() ->
    case emqx:hook('client.authenticate', {?MODULE, authenticate, []}) of
        ok -> ok;
        {error, already_exists} -> ok
    end.

disable() ->
    emqx:unhook('client.authenticate', {?MODULE, authenticate, []}),
    ok.

authenticate(#{listener_id := ListenerID} = ClientInfo) ->
    case lookup_chain_by_listener(ListenerID, simple) of
        {error, _} ->
            {error, no_authenticators};
        {ok, ChainID} ->
            case mnesia:dirty_read(?CHAIN_TAB, ChainID) of
                [#chain{authenticators = []}] ->
                    {error, no_authenticators};
                [#chain{authenticators = Authenticators}] ->
                    do_authenticate(Authenticators, ClientInfo);
                [] ->
                    {error, no_authenticators}
            end
    end.

do_authenticate([], _) ->
    {error, user_not_found};
do_authenticate([{_, #authenticator{provider = Provider, state = State}} | More], ClientInfo) ->
    case Provider:authenticate(ClientInfo, State) of
        ignore -> do_authenticate(More, ClientInfo);
        ok -> ok;
        {ok, NewClientInfo} -> {ok, NewClientInfo};
        {stop, Reason} -> {error, Reason}
    end.

create_chain(#{id   := ID,
               type := Type}) ->
    trans(
        fun() ->
            case mnesia:read(?CHAIN_TAB, ID, write) of
                [] ->
                    Chain = #chain{id = ID,
                                   type = Type,
                                   authenticators = [],
                                   created_at = erlang:system_time(millisecond)},
                    mnesia:write(?CHAIN_TAB, Chain, write),
                    {ok, serialize_chain(Chain)};
                [_ | _] ->
                    {error, {already_exists, {chain, ID}}}
            end
        end).

delete_chain(ID) ->
    trans(
        fun() ->
            case mnesia:read(?CHAIN_TAB, ID, write) of
                [] ->
                    {error, {not_found, {chain, ID}}};
                [#chain{authenticators = Authenticators}] ->
                    _ = [do_delete_authenticator(Authenticator) || {_, Authenticator} <- Authenticators],
                    mnesia:delete(?CHAIN_TAB, ID, write)
            end
        end).

lookup_chain(ID) ->
    case mnesia:dirty_read(?CHAIN_TAB, ID) of
        [] ->
            {error, {not_found, {chain, ID}}};
        [Chain] ->
            {ok, serialize_chain(Chain)}
    end.

list_chains() ->
    Chains = ets:tab2list(?CHAIN_TAB),
    {ok, [serialize_chain(Chain) || Chain <- Chains]}.

bind(ChainID, Listeners) ->
    %% TODO: ensure listener id is valid
    trans(
        fun() ->
            case mnesia:read(?CHAIN_TAB, ChainID, write) of
                [] ->
                    {error, {not_found, {chain, ChainID}}};
                [#chain{type = AuthNType}] ->
                    Result = lists:foldl(
                                 fun(ListenerID, Acc) ->
                                     case mnesia:read(?BINDING_TAB, {ListenerID, AuthNType}, write) of
                                         [] ->
                                             Binding = #binding{bound = {ListenerID, AuthNType}, chain_id = ChainID},
                                             mnesia:write(?BINDING_TAB, Binding, write),
                                             Acc;
                                         _ ->
                                             [ListenerID | Acc]
                                     end
                                 end, [], Listeners),
                    case Result of
                        [] -> ok;
                        Listeners0 -> {error, {already_bound, Listeners0}}
                    end
            end
        end).

unbind(ChainID, Listeners) ->
    trans(
        fun() ->
            Result = lists:foldl(
                        fun(ListenerID, Acc) ->
                            MatchSpec = [{{binding, {ListenerID, '_'}, ChainID}, [], ['$_']}],
                            case mnesia:select(?BINDING_TAB, MatchSpec, write) of
                                [] ->
                                    [ListenerID | Acc];
                                [#binding{bound = Bound}] ->
                                    mnesia:delete(?BINDING_TAB, Bound, write),
                                    Acc
                            end
                        end, [], Listeners),
            case Result of
                [] -> ok;
                Listeners0 ->
                    {error, {not_found, Listeners0}}
            end
        end).

list_bindings(ChainID) ->
    trans(
        fun() ->
            MatchSpec = [{{binding, {'$1', '_'}, ChainID}, [], ['$1']}],
            Listeners = mnesia:select(?BINDING_TAB, MatchSpec),
            {ok, #{chain_id => ChainID, listeners => Listeners}}
        end).

list_bound_chains(ListenerID) ->
    trans(
        fun() ->
            MatchSpec = [{{binding, {ListenerID, '_'}, '_'}, [], ['$_']}],
            Bindings = mnesia:select(?BINDING_TAB, MatchSpec),
            Chains = [{AuthNType, ChainID} || #binding{bound = {_, AuthNType},
                                                    chain_id = ChainID} <- Bindings],
            {ok, maps:from_list(Chains)}
        end).

create_authenticator(ChainID, #{name := Name,
                                type := Type,
                                config := Config}) ->
    UpdateFun =
        fun(Chain = #chain{type = AuthNType, authenticators = Authenticators}) ->
            case lists:keymember(Name, 1, Authenticators) of
                true ->
                    {error, {already_exists, {authenticator, Name}}};
                false ->
                    Provider = authenticator_provider(AuthNType, Type),
                    case Provider:create(ChainID, Name, Config) of
                        {ok, State} ->
                            Authenticator = #authenticator{name = Name,
                                                           type = Type,
                                                           provider = Provider,
                                                           config = Config,
                                                           state = State},
                            NChain = Chain#chain{authenticators = Authenticators ++ [{Name, Authenticator}]},
                            ok = mnesia:write(?CHAIN_TAB, NChain, write),
                            {ok, serialize_authenticator(Authenticator)};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
        end,
    update_chain(ChainID, UpdateFun).

delete_authenticator(ChainID, AuthenticatorName) ->
    UpdateFun = fun(Chain = #chain{authenticators = Authenticators}) ->
                    case lists:keytake(AuthenticatorName, 1, Authenticators) of
                        false ->
                            {error, {not_found, {authenticator, AuthenticatorName}}};
                        {value, {_, Authenticator}, NAuthenticators} ->
                            _ = do_delete_authenticator(Authenticator),
                            NChain = Chain#chain{authenticators = NAuthenticators},
                            mnesia:write(?CHAIN_TAB, NChain, write)
                    end
                end,
    update_chain(ChainID, UpdateFun).

update_authenticator(ChainID, AuthenticatorName, Config) ->
    UpdateFun = fun(Chain = #chain{authenticators = Authenticators}) ->
                    case proplists:get_value(AuthenticatorName, Authenticators, undefined) of
                        undefined ->
                            {error, {not_found, {authenticator, AuthenticatorName}}};
                        #authenticator{provider = Provider,
                                       config   = OriginalConfig,
                                       state    = State} = Authenticator ->
                            NewConfig = maps:merge(OriginalConfig, Config),
                            case Provider:update(ChainID, AuthenticatorName, NewConfig, State) of
                                {ok, NState} ->
                                    NAuthenticator = Authenticator#authenticator{config = NewConfig,
                                                                                 state = NState},
                                    NAuthenticators = update_value(AuthenticatorName, NAuthenticator, Authenticators),
                                    ok = mnesia:write(?CHAIN_TAB, Chain#chain{authenticators = NAuthenticators}, write),
                                    {ok, serialize_authenticator(NAuthenticator)};
                                {error, Reason} ->
                                    {error, Reason}
                            end
                    end
                 end,
    update_chain(ChainID, UpdateFun).

lookup_authenticator(ChainID, AuthenticatorName) ->
    case mnesia:dirty_read(?CHAIN_TAB, ChainID) of
        [] ->
            {error, {not_found, {chain, ChainID}}};
        [#chain{authenticators = Authenticators}] ->
            case proplists:get_value(AuthenticatorName, Authenticators, undefined) of
                undefined ->
                    {error, {not_found, {authenticator, AuthenticatorName}}};
                Authenticator ->
                    {ok, serialize_authenticator(Authenticator)}
            end
    end.

list_authenticators(ChainID) ->
    case mnesia:dirty_read(?CHAIN_TAB, ChainID) of
        [] ->
            {error, {not_found, {chain, ChainID}}};
        [#chain{authenticators = Authenticators}] ->
            {ok, serialize_authenticators(Authenticators)}
    end.

move_authenticator_to_the_front(ChainID, AuthenticatorName) ->
    UpdateFun = fun(Chain = #chain{authenticators = Authenticators}) ->
                    case move_authenticator_to_the_front_(AuthenticatorName, Authenticators) of
                        {ok, NAuthenticators} ->
                            NChain = Chain#chain{authenticators = NAuthenticators},
                            mnesia:write(?CHAIN_TAB, NChain, write);
                        {error, Reason} ->
                            {error, Reason}
                    end
                 end,
    update_chain(ChainID, UpdateFun).

move_authenticator_to_the_end(ChainID, AuthenticatorName) ->
    UpdateFun = fun(Chain = #chain{authenticators = Authenticators}) ->
                    case move_authenticator_to_the_end_(AuthenticatorName, Authenticators) of
                        {ok, NAuthenticators} ->
                            NChain = Chain#chain{authenticators = NAuthenticators},
                            mnesia:write(?CHAIN_TAB, NChain, write);
                        {error, Reason} ->
                            {error, Reason}
                    end
                 end,
    update_chain(ChainID, UpdateFun).

move_authenticator_to_the_nth(ChainID, AuthenticatorName, N) ->
    UpdateFun = fun(Chain = #chain{authenticators = Authenticators}) ->
                    case move_authenticator_to_the_nth_(AuthenticatorName, Authenticators, N) of
                        {ok, NAuthenticators} ->
                            NChain = Chain#chain{authenticators = NAuthenticators},
                            mnesia:write(?CHAIN_TAB, NChain, write);
                        {error, Reason} ->
                            {error, Reason}
                    end
                 end,
    update_chain(ChainID, UpdateFun).

import_users(ChainID, AuthenticatorName, Filename) ->
    call_authenticator(ChainID, AuthenticatorName, import_users, [Filename]).

add_user(ChainID, AuthenticatorName, UserInfo) ->
    call_authenticator(ChainID, AuthenticatorName, add_user, [UserInfo]).

delete_user(ChainID, AuthenticatorName, UserID) ->
    call_authenticator(ChainID, AuthenticatorName, delete_user, [UserID]).

update_user(ChainID, AuthenticatorName, UserID, NewUserInfo) ->
    call_authenticator(ChainID, AuthenticatorName, update_user, [UserID, NewUserInfo]).

lookup_user(ChainID, AuthenticatorName, UserID) ->
    call_authenticator(ChainID, AuthenticatorName, lookup_user, [UserID]).

list_users(ChainID, AuthenticatorName) ->
    call_authenticator(ChainID, AuthenticatorName, list_users, []).

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

authenticator_provider(simple, 'built-in-database') -> emqx_authn_mnesia;
authenticator_provider(simple, jwt) -> emqx_authn_jwt;
authenticator_provider(simple, mysql) -> emqx_authn_mysql;
authenticator_provider(simple, postgresql) -> emqx_authn_pgsql.

% authenticator_provider(enhanced, 'enhanced-built-in-database') -> emqx_enhanced_authn_mnesia.

do_delete_authenticator(#authenticator{provider = Provider, state = State}) ->
    Provider:destroy(State).
    
update_value(Key, Value, List) ->
    lists:keyreplace(Key, 1, List, {Key, Value}).

move_authenticator_to_the_front_(AuthenticatorName, Authenticators) ->
    move_authenticator_to_the_front_(AuthenticatorName, Authenticators, []).

move_authenticator_to_the_front_(AuthenticatorName, [], _) ->
    {error, {not_found, {authenticator, AuthenticatorName}}};
move_authenticator_to_the_front_(AuthenticatorName, [{AuthenticatorName, _} = Authenticator | More], Passed) ->
    {ok, [Authenticator | (lists:reverse(Passed) ++ More)]};
move_authenticator_to_the_front_(AuthenticatorName, [Authenticator | More], Passed) ->
    move_authenticator_to_the_front_(AuthenticatorName, More, [Authenticator | Passed]).

move_authenticator_to_the_end_(AuthenticatorName, Authenticators) ->
    move_authenticator_to_the_end_(AuthenticatorName, Authenticators, []).

move_authenticator_to_the_end_(AuthenticatorName, [], _) ->
    {error, {not_found, {authenticator, AuthenticatorName}}};
move_authenticator_to_the_end_(AuthenticatorName, [{AuthenticatorName, _} = Authenticator | More], Passed) ->
    {ok, lists:reverse(Passed) ++ More ++ [Authenticator]};
move_authenticator_to_the_end_(AuthenticatorName, [Authenticator | More], Passed) ->
    move_authenticator_to_the_end_(AuthenticatorName, More, [Authenticator | Passed]).

move_authenticator_to_the_nth_(AuthenticatorName, Authenticators, N)
  when N =< length(Authenticators) andalso N > 0 ->
    move_authenticator_to_the_nth_(AuthenticatorName, Authenticators, N, []);
move_authenticator_to_the_nth_(_, _, _) ->
    {error, out_of_range}.

move_authenticator_to_the_nth_(AuthenticatorName, [], _, _) ->
    {error, {not_found, {authenticator, AuthenticatorName}}};
move_authenticator_to_the_nth_(AuthenticatorName, [{AuthenticatorName, _} = Authenticator | More], N, Passed)
  when N =< length(Passed) ->
    {L1, L2} = lists:split(N - 1, lists:reverse(Passed)),
    {ok, L1 ++ [Authenticator] ++ L2 ++ More};
move_authenticator_to_the_nth_(AuthenticatorName, [{AuthenticatorName, _} = Authenticator | More], N, Passed) ->
    {L1, L2} = lists:split(N - length(Passed) - 1, More),
    {ok, lists:reverse(Passed) ++ L1 ++ [Authenticator] ++ L2};
move_authenticator_to_the_nth_(AuthenticatorName, [Authenticator | More], N, Passed) ->
    move_authenticator_to_the_nth_(AuthenticatorName, More, N, [Authenticator | Passed]).

update_chain(ChainID, UpdateFun) ->
    trans(
        fun() ->
            case mnesia:read(?CHAIN_TAB, ChainID, write) of
                [] ->
                    {error, {not_found, {chain, ChainID}}};
                [Chain] ->
                    UpdateFun(Chain)
            end
        end).

lookup_chain_by_listener(ListenerID, AuthNType) ->
    case mnesia:dirty_read(?BINDING_TAB, {ListenerID, AuthNType}) of
        [] ->
            {error, not_found};
        [#binding{chain_id = ChainID}] ->
            {ok, ChainID}
    end.


call_authenticator(ChainID, AuthenticatorName, Func, Args) ->
    case mnesia:dirty_read(?CHAIN_TAB, ChainID) of
        [] ->
            {error, {not_found, {chain, ChainID}}};
        [#chain{authenticators = Authenticators}] ->
            case proplists:get_value(AuthenticatorName, Authenticators, undefined) of
                undefined ->
                    {error, {not_found, {authenticator, AuthenticatorName}}};
                #authenticator{provider = Provider, state = State} ->
                    case erlang:function_exported(Provider, Func, length(Args) + 1) of
                        true ->
                            erlang:apply(Provider, Func, Args ++ [State]);
                        false ->
                            {error, unsupported_feature}
                    end
            end
    end.

serialize_chain(#chain{id = ID,
                       type = Type,
                       authenticators = Authenticators,
                       created_at = CreatedAt}) ->
    #{id => ID,
      type => Type,
      authenticators => serialize_authenticators(Authenticators),
      created_at => CreatedAt}.

% serialize_binding(#binding{bound = {ListenerID, _},
%                            chain_id = ChainID}) ->
%     #{listener_id => ListenerID,
%       chain_id => ChainID}.

serialize_authenticators(Authenticators) ->
    [serialize_authenticator(Authenticator) || {_, Authenticator} <- Authenticators].

serialize_authenticator(#authenticator{name = Name,
                                       type = Type,
                                       config = Config}) ->
    #{name => Name,
      type => Type,
      config => Config}.

trans(Fun) ->
    trans(Fun, []).

trans(Fun, Args) ->
    case ekka_mnesia:transaction(?AUTH_SHARD, Fun, Args) of
        {atomic, Res} -> Res;
        {aborted, Reason} -> {error, Reason}
    end.

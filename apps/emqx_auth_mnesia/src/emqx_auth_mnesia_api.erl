%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_auth_mnesia_api).

-include_lib("stdlib/include/qlc.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(TABLE, emqx_user).

-import(proplists, [get_value/2]).
-import(minirest,  [return/1]).
-export([paginate/5]).

-export([ list_clientid/2
        , lookup_clientid/2
        , add_clientid/2
        , update_clientid/2
        , delete_clientid/2
        ]).

-rest_api(#{name   => list_clientid,
            method => 'GET',
            path   => "/auth_clientid",
            func   => list_clientid,
            descr  => "List available clientid in the cluster"
           }).

-rest_api(#{name   => lookup_clientid,
            method => 'GET',
            path   => "/auth_clientid/:bin:clientid",
            func   => lookup_clientid,
            descr  => "Lookup clientid in the cluster"
           }).

-rest_api(#{name   => add_clientid,
            method => 'POST',
            path   => "/auth_clientid",
            func   => add_clientid,
            descr  => "Add clientid in the cluster"
           }).

-rest_api(#{name   => update_clientid,
            method => 'PUT',
            path   => "/auth_clientid/:bin:clientid",
            func   => update_clientid,
            descr  => "Update clientid in the cluster"
           }).

-rest_api(#{name   => delete_clientid,
            method => 'DELETE',
            path   => "/auth_clientid/:bin:clientid",
            func   => delete_clientid,
            descr  => "Delete clientid in the cluster"
           }).

-export([ list_username/2
        , lookup_username/2
        , add_username/2
        , update_username/2
        , delete_username/2
        ]).

-rest_api(#{name   => list_username,
            method => 'GET',
            path   => "/auth_username",
            func   => list_username,
            descr  => "List available username in the cluster"
           }).

-rest_api(#{name   => lookup_username,
            method => 'GET',
            path   => "/auth_username/:bin:username",
            func   => lookup_username,
            descr  => "Lookup username in the cluster"
           }).

-rest_api(#{name   => add_username,
            method => 'POST',
            path   => "/auth_username",
            func   => add_username,
            descr  => "Add username in the cluster"
           }).

-rest_api(#{name   => update_username,
            method => 'PUT',
            path   => "/auth_username/:bin:username",
            func   => update_username,
            descr  => "Update username in the cluster"
           }).

-rest_api(#{name   => delete_username,
            method => 'DELETE',
            path   => "/auth_username/:bin:username",
            func   => delete_username,
            descr  => "Delete username in the cluster"
           }).

%%------------------------------------------------------------------------------
%% Auth Clientid Api
%%------------------------------------------------------------------------------

list_clientid(_Bindings, Params) ->
    MatchSpec = ets:fun2ms(fun({?TABLE, {clientid, Clientid}, Password, CreatedAt}) -> {?TABLE, {clientid, Clientid}, Password, CreatedAt} end),
    return({ok, paginate(?TABLE, MatchSpec, Params, fun emqx_auth_mnesia_cli:comparing/2, fun({?TABLE, {clientid, X}, _, _}) -> #{clientid => X} end)}).

lookup_clientid(#{clientid := Clientid}, _Params) ->
    return({ok, format(emqx_auth_mnesia_cli:lookup_user({clientid, urldecode(Clientid)}))}).

add_clientid(_Bindings, Params) ->
    [ P | _] = Params,
    case is_list(P) of
        true -> return(do_add_clientid(Params, []));
        false ->
            Re = do_add_clientid(Params),
            case Re of
                ok -> return(ok);
                {error, Error} -> return({error, format_msg(Error)})
            end
    end.

do_add_clientid([ Params | ParamsN ], ReList ) ->
    Clientid = urldecode(get_value(<<"clientid">>, Params)),
    do_add_clientid(ParamsN, [{Clientid, format_msg(do_add_clientid(Params))} | ReList]);

do_add_clientid([], ReList) ->
    {ok, ReList}.

do_add_clientid(Params) ->
    Clientid = urldecode(get_value(<<"clientid">>, Params)),
    Password = urldecode(get_value(<<"password">>, Params)),
    Login = {clientid, Clientid},
    case validate([login, password], [Login, Password]) of
        ok ->
            emqx_auth_mnesia_cli:add_user(Login, Password);
        Err -> Err
    end.

update_clientid(#{clientid := Clientid}, Params) ->
    Password = get_value(<<"password">>, Params),
    case validate([password], [Password]) of
        ok -> return(emqx_auth_mnesia_cli:update_user({clientid, urldecode(Clientid)}, urldecode(Password)));
        Err -> return(Err)
    end.

delete_clientid(#{clientid := Clientid}, _) ->
    return(emqx_auth_mnesia_cli:remove_user({clientid, urldecode(Clientid)})).

%%------------------------------------------------------------------------------
%% Auth Username Api
%%------------------------------------------------------------------------------

list_username(_Bindings, Params) ->
    MatchSpec = ets:fun2ms(fun({?TABLE, {username, Username}, Password, CreatedAt}) -> {?TABLE, {username, Username}, Password, CreatedAt} end),
    return({ok, paginate(?TABLE, MatchSpec, Params, fun emqx_auth_mnesia_cli:comparing/2, fun({?TABLE, {username, X}, _, _}) -> #{username => X} end)}).

lookup_username(#{username := Username}, _Params) ->
    return({ok, format(emqx_auth_mnesia_cli:lookup_user({username, urldecode(Username)}))}).

add_username(_Bindings, Params) ->
    [ P | _] = Params,
    case is_list(P) of
        true -> return(do_add_username(Params, []));
        false ->
            case do_add_username(Params) of
                ok -> return(ok);
                {error, Error} -> return({error, format_msg(Error)})
            end
    end.

do_add_username([ Params | ParamsN ], ReList ) ->
    Username = urldecode(get_value(<<"username">>, Params)),
    do_add_username(ParamsN, [{Username, format_msg(do_add_username(Params))} | ReList]);

do_add_username([], ReList) ->
    {ok, ReList}.

do_add_username(Params) ->
    Username = urldecode(get_value(<<"username">>, Params)),
    Password = urldecode(get_value(<<"password">>, Params)),
    Login = {username, Username},
    case validate([login, password], [Login, Password]) of
        ok ->
            emqx_auth_mnesia_cli:add_user(Login, Password);
        Err -> Err
    end.

update_username(#{username := Username}, Params) ->
    Password = get_value(<<"password">>, Params),
    case validate([password], [Password]) of
        ok -> return(emqx_auth_mnesia_cli:update_user({username, urldecode(Username)}, urldecode(Password)));
        Err -> return(Err)
    end.

delete_username(#{username := Username}, _) ->
    return(emqx_auth_mnesia_cli:remove_user({username, urldecode(Username)})).

%%------------------------------------------------------------------------------
%% Paging Query
%%------------------------------------------------------------------------------

paginate(Tables, MatchSpec, Params, ComparingFun, RowFun) ->
    Qh = query_handle(Tables, MatchSpec),
    Count = count(Tables, MatchSpec),
    Page = page(Params),
    Limit = limit(Params),
    Cursor = qlc:cursor(Qh),
    case Page > 1 of
        true  ->
            _ = qlc:next_answers(Cursor, (Page - 1) * Limit),
            ok;
        false -> ok
    end,
    Rows = qlc:next_answers(Cursor, Limit),
    qlc:delete_cursor(Cursor),
    #{meta  => #{page => Page, limit => Limit, count => Count},
      data  => [RowFun(Row) || Row <- lists:sort(ComparingFun, Rows)]}.

query_handle(Table, MatchSpec) when is_atom(Table) ->
    Options = {traverse, {select, MatchSpec}},
    qlc:q([R|| R <- ets:table(Table, Options)]);
query_handle([Table], MatchSpec) when is_atom(Table) ->
    Options = {traverse, {select, MatchSpec}},
    qlc:q([R|| R <- ets:table(Table, Options)]);
query_handle(Tables, MatchSpec) ->
    Options = {traverse, {select, MatchSpec}},
    qlc:append([qlc:q([E || E <- ets:table(T, Options)]) || T <- Tables]).

count(Table, MatchSpec) when is_atom(Table) ->
    [{MatchPattern, Where, _Re}] = MatchSpec,
    NMatchSpec = [{MatchPattern, Where, [true]}],
    ets:select_count(Table, NMatchSpec);
count([Table], MatchSpec) when is_atom(Table) ->
    [{MatchPattern, Where, _Re}] = MatchSpec,
    NMatchSpec = [{MatchPattern, Where, [true]}],
    ets:select_count(Table, NMatchSpec);
count(Tables, MatchSpec) ->
    lists:sum([count(T, MatchSpec) || T <- Tables]).

page(Params) ->
    binary_to_integer(proplists:get_value(<<"_page">>, Params, <<"1">>)).

limit(Params) ->
    case proplists:get_value(<<"_limit">>, Params) of
        undefined -> 10;
        Size      -> binary_to_integer(Size)
    end.

%%------------------------------------------------------------------------------
%% Interval Funcs
%%------------------------------------------------------------------------------

format([{?TABLE, {clientid, ClientId}, Password, _InterTime}]) ->
    #{clientid => ClientId,
      password => Password};

format([{?TABLE, {username, Username}, Password, _InterTime}]) ->
    #{username => Username,
      password => Password};

format([]) ->
    #{}.

validate([], []) ->
    ok;
validate([K|Keys], [V|Values]) ->
   case do_validation(K, V) of
       false -> {error, K};
       true  -> validate(Keys, Values)
   end.

do_validation(login, {clientid, V}) when is_binary(V)
                     andalso byte_size(V) > 0 ->
    true;
do_validation(login, {username, V}) when is_binary(V)
                     andalso byte_size(V) > 0 ->
    true;
do_validation(password, V) when is_binary(V)
                     andalso byte_size(V) > 0 ->
    true;
do_validation(_, _) ->
    false.

format_msg(Message)
  when is_atom(Message);
       is_binary(Message) -> Message;

format_msg(Message) when is_tuple(Message) ->
    iolist_to_binary(io_lib:format("~p", [Message])).

urldecode(S) ->
    emqx_http_lib:uri_decode(S).

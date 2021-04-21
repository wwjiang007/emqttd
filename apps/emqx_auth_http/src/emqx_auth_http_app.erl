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

-module(emqx_auth_http_app).

-behaviour(application).

-emqx_plugin(auth).

-include("emqx_auth_http.hrl").

-export([ start/2
        , stop/1
        ]).

%%--------------------------------------------------------------------
%% Application Callbacks
%%--------------------------------------------------------------------

start(_StartType, _StartArgs) ->
    {ok, Sup} = emqx_auth_http_sup:start_link(),
    translate_env(),
    load_hooks(),
    {ok, Sup}.

stop(_State) ->
    unload_hooks().

%%--------------------------------------------------------------------
%% Internel functions
%%--------------------------------------------------------------------

translate_env() ->
    lists:foreach(fun translate_env/1, [auth_req, super_req, acl_req]).

translate_env(EnvName) ->
    case application:get_env(?APP, EnvName) of
        undefined -> ok;
        {ok, Req} ->
            {ok, PoolSize} = application:get_env(?APP, pool_size),
            {ok, ConnectTimeout} = application:get_env(?APP, connect_timeout),
            URL = proplists:get_value(url, Req),
            {ok, #{host := Host0,
                   path := Path0,
                   port := Port,
                   scheme := Scheme}} = emqx_http_lib:uri_parse(URL),
            Path = path(Path0),
            {Inet, Host} = parse_host(Host0),
            MoreOpts = case Scheme of
                        http ->
                            [{transport_opts, [Inet]}];
                        https ->
                            CACertFile = application:get_env(?APP, cacertfile, undefined),
                            CertFile = application:get_env(?APP, certfile, undefined),
                            KeyFile = application:get_env(?APP, keyfile, undefined),
                            Verify = case application:get_env(?APP, verify, fasle) of
                                         true -> verify_peer;
                                         false -> verify_none
                                     end,
                            SNI = case application:get_env(?APP, server_name_indication, undefined) of
                                    "disable" -> disable;
                                    SNI0 -> SNI0
                                  end,
                            TLSOpts = lists:filter(
                                        fun({_, V}) ->
                                            V =/= <<>> andalso V =/= undefined
                                        end, [{keyfile, KeyFile},
                                              {certfile, CertFile},
                                              {cacertfile, CACertFile},
                                              {verify, Verify},
                                              {server_name_indication, SNI}]),
                            NTLSOpts = [ {versions, emqx_tls_lib:default_versions()}
                                       , {ciphers, emqx_tls_lib:default_ciphers()}
                                       | TLSOpts
                                       ],
                            [{transport, ssl}, {transport_opts, [Inet | NTLSOpts]}]
                        end,
            PoolOpts = [{host, Host},
                        {port, Port},
                        {pool_size, PoolSize},
                        {pool_type, random},
                        {connect_timeout, ConnectTimeout},
                        {retry, 5},
                        {retry_timeout, 1000}] ++ MoreOpts,
            Method = proplists:get_value(method, Req),
            Headers = proplists:get_value(headers, Req),
            NHeaders = ensure_content_type_header(Method, to_lower(Headers)),
            NReq = lists:keydelete(headers, 1, Req),
            {ok, Timeout} = application:get_env(?APP, timeout),
            application:set_env(?APP, EnvName, [{path, Path},
                                                {headers, NHeaders},
                                                {timeout, Timeout},
                                                {pool_name, list_to_atom("emqx_auth_http/" ++ atom_to_list(EnvName))},
                                                {pool_opts, PoolOpts} | NReq])
    end.

load_hooks() ->
    case application:get_env(?APP, auth_req) of
        undefined -> ok;
        {ok, AuthReq} ->
            ok = emqx_auth_http:register_metrics(),
            PoolOpts = proplists:get_value(pool_opts, AuthReq),
            PoolName = proplists:get_value(pool_name, AuthReq),
            {ok, _} = ehttpc_sup:start_pool(PoolName, PoolOpts),
            case application:get_env(?APP, super_req) of
                undefined ->
                    emqx_hooks:put('client.authenticate', {emqx_auth_http, check, [#{auth => maps:from_list(AuthReq),
                                                                                     super => undefined}]});
                {ok, SuperReq} ->
                    PoolOpts1 = proplists:get_value(pool_opts, SuperReq),
                    PoolName1 = proplists:get_value(pool_name, SuperReq),
                    {ok, _} = ehttpc_sup:start_pool(PoolName1, PoolOpts1),
                    emqx_hooks:put('client.authenticate', {emqx_auth_http, check, [#{auth => maps:from_list(AuthReq),
                                                                                     super => maps:from_list(SuperReq)}]})
            end
    end,
    case application:get_env(?APP, acl_req) of
        undefined -> ok;
        {ok, ACLReq} ->
            ok = emqx_acl_http:register_metrics(),
            PoolOpts2 = proplists:get_value(pool_opts, ACLReq),
            PoolName2 = proplists:get_value(pool_name, ACLReq),
            {ok, _} = ehttpc_sup:start_pool(PoolName2, PoolOpts2),
            emqx_hooks:put('client.check_acl', {emqx_acl_http, check_acl, [#{acl => maps:from_list(ACLReq)}]})
    end,
    ok.

unload_hooks() ->
    emqx:unhook('client.authenticate', {emqx_auth_http, check}),
    emqx:unhook('client.check_acl', {emqx_acl_http, check_acl}),
    _ = ehttpc_sup:stop_pool('emqx_auth_http/auth_req'),
    _ = ehttpc_sup:stop_pool('emqx_auth_http/super_req'),
    _ = ehttpc_sup:stop_pool('emqx_auth_http/acl_req'),
    ok.

parse_host(Host) ->
    case inet:parse_address(Host) of
        {ok, Addr} when size(Addr) =:= 4 -> {inet, Addr};
        {ok, Addr} when size(Addr) =:= 8 -> {inet6, Addr};
        {error, einval} ->
            case inet:getaddr(Host, inet6) of
                {ok, _} -> {inet6, Host};
                {error, _} -> {inet, Host}
            end
    end.

to_lower(Headers) ->
    [{string:to_lower(K), V} || {K, V} <- Headers].

ensure_content_type_header(Method, Headers)
  when Method =:= post orelse Method =:= put ->
    Headers;
ensure_content_type_header(_Method, Headers) ->
    lists:keydelete("content-type", 1, Headers).

path("") ->
    "/";
path(Path) ->
    Path.


%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_mod_presence).

-behaviour(emqx_gen_mod).

-include("emqx.hrl").
-include("logger.hrl").

-logger_header("[Presence]").

%% emqx_gen_mod callbacks
-export([ load/1
        , unload/1
        ]).

-export([ on_client_connected/4
        , on_client_disconnected/4
        ]).

-ifdef(TEST).
-export([ reason/1 ]).
-endif.

load(Env) ->
    emqx_hooks:add('client.connected',    {?MODULE, on_client_connected, [Env]}),
    emqx_hooks:add('client.disconnected', {?MODULE, on_client_disconnected, [Env]}).

unload(_Env) ->
    emqx_hooks:del('client.connected',    {?MODULE, on_client_connected}),
    emqx_hooks:del('client.disconnected', {?MODULE, on_client_disconnected}).

on_client_connected(ClientInfo, ConnAck, ConnInfo, Env) ->
    #{peerhost := PeerHost} = ClientInfo,
    #{clean_start := CleanStart,
      proto_name := ProtoName,
      proto_ver := ProtoVer,
      keepalive := Keepalive,
      expiry_interval := ExpiryInterval} = ConnInfo,
    ClientId = clientid(ClientInfo, ConnInfo),
    Username = username(ClientInfo, ConnInfo),
    Presence = #{clientid => ClientId,
                 username => Username,
                 ipaddress => ntoa(PeerHost),
                 proto_name => ProtoName,
                 proto_ver => ProtoVer,
                 keepalive => Keepalive,
                 connack => ConnAck,
                 clean_start => CleanStart,
                 expiry_interval => ExpiryInterval,
                 ts => erlang:system_time(millisecond)
                },
    case emqx_json:safe_encode(Presence) of
        {ok, Payload} ->
            emqx_broker:safe_publish(
              make_msg(qos(Env), topic(connected, ClientId), Payload));
        {error, _Reason} ->
            ?LOG(error, "Failed to encode 'connected' presence: ~p", [Presence])
    end.

on_client_disconnected(ClientInfo, Reason, ConnInfo, Env) ->
    ClientId = clientid(ClientInfo, ConnInfo),
    Username = username(ClientInfo, ConnInfo),
    Presence = #{clientid => ClientId,
                 username => Username,
                 reason => reason(Reason),
                 ts => erlang:system_time(millisecond)
                },
    case emqx_json:safe_encode(Presence) of
        {ok, Payload} ->
            emqx_broker:safe_publish(
              make_msg(qos(Env), topic(disconnected, ClientId), Payload));
        {error, _Reason} ->
            ?LOG(error, "Failed to encode 'disconnected' presence: ~p", [Presence])
    end.

clientid(#{clientid := undefined}, #{clientid := ClientId}) -> ClientId;
clientid(#{clientid := ClientId}, _ConnInfo) -> ClientId.

username(#{username := undefined}, #{username := Username}) -> Username;
username(#{username := Username}, _ConnInfo) -> Username.

make_msg(QoS, Topic, Payload) ->
    emqx_message:set_flag(
      sys, emqx_message:make(
             ?MODULE, QoS, Topic, iolist_to_binary(Payload))).

topic(connected, ClientId) ->
    emqx_topic:systop(iolist_to_binary(["clients/", ClientId, "/connected"]));
topic(disconnected, ClientId) ->
    emqx_topic:systop(iolist_to_binary(["clients/", ClientId, "/disconnected"])).

qos(Env) -> proplists:get_value(qos, Env, 0).

reason(Reason) when is_atom(Reason) -> Reason;
reason({shutdown, Reason}) when is_atom(Reason) -> Reason;
reason({Error, _}) when is_atom(Error) -> Error;
reason(_) -> internal_error.

-compile({inline, [ntoa/1]}).
ntoa(IpAddr) -> iolist_to_binary(inet:ntoa(IpAddr)).


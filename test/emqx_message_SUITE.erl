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

-module(emqx_message_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> emqx_ct:all(?MODULE).

suite() ->
    [{ct_hooks, [cth_surefire]}, {timetrap, {seconds, 30}}].

t_make(_) ->
    Msg = emqx_message:make(<<"topic">>, <<"payload">>),
    ?assertEqual(?QOS_0, emqx_message:qos(Msg)),
    ?assertEqual(undefined, emqx_message:from(Msg)),
    ?assertEqual(<<"payload">>, emqx_message:payload(Msg)),
    Msg1 = emqx_message:make(<<"clientid">>, <<"topic">>, <<"payload">>),
    ?assertEqual(?QOS_0, emqx_message:qos(Msg1)),
    ?assertEqual(<<"topic">>, emqx_message:topic(Msg1)),
    Msg2 = emqx_message:make(<<"clientid">>, ?QOS_2, <<"topic">>, <<"payload">>),
    ?assert(is_binary(emqx_message:id(Msg2))),
    ?assertEqual(?QOS_2, emqx_message:qos(Msg2)),
    ?assertEqual(<<"clientid">>, emqx_message:from(Msg2)),
    ?assertEqual(<<"topic">>, emqx_message:topic(Msg2)),
    ?assertEqual(<<"payload">>, emqx_message:payload(Msg2)).

t_get_set_flags(_) ->
    Msg = #message{id = <<"id">>, qos = ?QOS_1, flags = undefined},
    Msg1 = emqx_message:set_flags(#{retain => true}, Msg),
    ?assertEqual(#{retain => true}, emqx_message:get_flags(Msg1)).

t_get_set_flag(_) ->
    Msg = emqx_message:make(<<"clientid">>, <<"topic">>, <<"payload">>),
    Msg2 = emqx_message:set_flag(retain, false, Msg),
    Msg3 = emqx_message:set_flag(dup, Msg2),
    ?assert(emqx_message:get_flag(dup, Msg3)),
    ?assertNot(emqx_message:get_flag(retain, Msg3)),
    Msg4 = emqx_message:unset_flag(dup, Msg3),
    Msg5 = emqx_message:unset_flag(retain, Msg4),
    Msg5 = emqx_message:unset_flag(badflag, Msg5),
    ?assertEqual(undefined, emqx_message:get_flag(dup, Msg5, undefined)),
    ?assertEqual(undefined, emqx_message:get_flag(retain, Msg5, undefined)),
    Msg6 = emqx_message:set_flags(#{dup => true, retain => true}, Msg5),
    ?assert(emqx_message:get_flag(dup, Msg6)),
    ?assert(emqx_message:get_flag(retain, Msg6)),
    Msg7 = #message{id = <<"id">>, qos = ?QOS_1, flags = undefined},
    Msg8 = emqx_message:set_flag(retain, Msg7),
    Msg9 = emqx_message:set_flag(retain, true, Msg7),
    ?assertEqual(#{retain => true}, emqx_message:get_flags(Msg8)),
    ?assertEqual(#{retain => true}, emqx_message:get_flags(Msg9)).

t_get_set_headers(_) ->
    Msg = emqx_message:make(<<"clientid">>, <<"topic">>, <<"payload">>),
    Msg1 = emqx_message:set_headers(#{a => 1, b => 2}, Msg),
    Msg2 = emqx_message:set_headers(#{c => 3}, Msg1),
    ?assertEqual(#{a => 1, b => 2, c => 3}, emqx_message:get_headers(Msg2)).

t_get_set_header(_) ->
    Msg = emqx_message:make(<<"clientid">>, <<"topic">>, <<"payload">>),
    Msg1 = emqx_message:set_header(a, 1, Msg),
    Msg2 = emqx_message:set_header(b, 2, Msg1),
    Msg3 = emqx_message:set_header(c, 3, Msg2),
    ?assertEqual(1, emqx_message:get_header(a, Msg3)),
    ?assertEqual(4, emqx_message:get_header(d, Msg2, 4)),
    Msg4 = emqx_message:remove_header(a, Msg3),
    Msg4 = emqx_message:remove_header(a, Msg4),
    ?assertEqual(#{b => 2, c => 3}, emqx_message:get_headers(Msg4)).

t_undefined_headers(_) ->
    Msg = #message{id = <<"id">>, qos = ?QOS_0, headers = undefined},
    Msg1 = emqx_message:set_headers(#{a => 1, b => 2}, Msg),
    ?assertEqual(1, emqx_message:get_header(a, Msg1)),
    Msg2 = emqx_message:set_header(c, 3, Msg),
    ?assertEqual(3, emqx_message:get_header(c, Msg2)).

t_format(_) ->
    Msg = emqx_message:make(<<"clientid">>, <<"topic">>, <<"payload">>),
    io:format("~s~n", [emqx_message:format(Msg)]),
    Msg1 = #message{id = <<"id">>,
                    qos = ?QOS_0,
                    flags = undefined,
                    headers = undefined
                   },
    io:format("~s~n", [emqx_message:format(Msg1)]).

t_is_expired(_) ->
    Msg = emqx_message:make(<<"clientid">>, <<"topic">>, <<"payload">>),
    ?assertNot(emqx_message:is_expired(Msg)),
    Msg1 = emqx_message:set_headers(#{'Message-Expiry-Interval' => 1}, Msg),
    timer:sleep(500),
    ?assertNot(emqx_message:is_expired(Msg1)),
    timer:sleep(600),
    ?assert(emqx_message:is_expired(Msg1)),
    timer:sleep(1000),
    Msg = emqx_message:update_expiry(Msg),
    Msg2 = emqx_message:update_expiry(Msg1),
    ?assertEqual(1, emqx_message:get_header('Message-Expiry-Interval', Msg2)).

% t_to_list(_) ->
%     error('TODO').
    
t_to_packet(_) ->
    Pkt = #mqtt_packet{header = #mqtt_packet_header{type   = ?PUBLISH,
                                                    qos    = ?QOS_0,
                                                    retain = false,
                                                    dup    = false},
                       variable = #mqtt_packet_publish{topic_name = <<"topic">>,
                                                       packet_id  = 10,
                                                       properties = #{}},
                       payload = <<"payload">>},
    Msg = emqx_message:make(<<"clientid">>, ?QOS_0, <<"topic">>, <<"payload">>),
    ?assertEqual(Pkt, emqx_message:to_packet(10, Msg)).

t_to_map(_) ->
    Msg = emqx_message:make(<<"clientid">>, ?QOS_1, <<"topic">>, <<"payload">>),
    List = [{id, emqx_message:id(Msg)},
            {qos, ?QOS_1},
            {from, <<"clientid">>},
            {flags, #{dup => false}},
            {headers, #{}},
            {topic, <<"topic">>},
            {payload, <<"payload">>},
            {timestamp, emqx_message:timestamp(Msg)}],
    ?assertEqual(List, emqx_message:to_list(Msg)),
    ?assertEqual(maps:from_list(List), emqx_message:to_map(Msg)).

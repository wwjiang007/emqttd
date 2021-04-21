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

-module(emqx_recon_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(output_patterns(V), ((V)++"")).

all() -> [{group, cli}].

groups() ->
    [{cli, [sequence],
      [cli_memory,
       cli_allocated,
       cli_bin_leak,
       cli_node_stats,
       cli_remote_load,
       cli_usage]}
    ].

init_per_suite(Config) ->
    emqx_ct_helpers:start_apps([emqx_recon]),
    Config.

end_per_suite(_Config) ->
    emqx_ct_helpers:stop_apps([emqx_recon]).

cli_memory(_) ->
    mock_print(),
    Output = emqx_recon_cli:cmd(["memory"]),
    Zip = lists:zip(Output, [ ?output_patterns("usage/current")
                            , ?output_patterns("usage/max")
                            , ?output_patterns("used/current")
                            , ?output_patterns("used/max")
                            , ?output_patterns("allocated/current")
                            , ?output_patterns("allocated/max")
                            , ?output_patterns("unused/current")
                            , ?output_patterns("unused/max")
                            ]),
    %ct:pal("=======~p", [Zip]),
    [?assertMatch({match, _}, re:run(Line, Match, [{capture,all,list}]))
     || {Line, Match} <- Zip],
    unmock_print().

cli_allocated(_) ->
    mock_print(),
    Output = emqx_recon_cli:cmd(["allocated"]),
    Zip = lists:zip(Output, [ ?output_patterns("binary_alloc/current")
                            , ?output_patterns("driver_alloc/current")
                            , ?output_patterns("eheap_alloc/current")
                            , ?output_patterns("ets_alloc/current")
                            , ?output_patterns("fix_alloc/current")
                            , ?output_patterns("ll_alloc/current")
                            , ?output_patterns("sl_alloc/current")
                            , ?output_patterns("std_alloc/current")
                            , ?output_patterns("temp_alloc/current")
                            , ?output_patterns("binary_alloc/max")
                            , ?output_patterns("driver_alloc/max")
                            , ?output_patterns("eheap_alloc/max")
                            , ?output_patterns("ets_alloc/max")
                            , ?output_patterns("fix_alloc/max")
                            , ?output_patterns("ll_alloc/max")
                            , ?output_patterns("sl_alloc/max")
                            , ?output_patterns("std_alloc/max")
                            , ?output_patterns("temp_alloc/max")
                            ]),
    ct:pal("=======~p", [Zip]),
    [?assertMatch({match, _}, re:run(Line, Match, [{capture,all,list}]))
     || {Line, Match} <- Zip],
    unmock_print().

cli_bin_leak(_) ->
    mock_print(),
    Output = emqx_recon_cli:cmd(["bin_leak"]),
    [?assertMatch({match, _}, re:run(Line, "current_function", [{capture,all,list}]))
     || Line <- Output],
    unmock_print().

cli_node_stats(_) ->
    emqx_recon_cli:cmd(["node_stats"]).

cli_remote_load(_) ->
    emqx_recon_cli:cmd(["remote_load", "emqx_recon_cli"]).

cli_usage(_) ->
    emqx_recon_cli:cmd(["usage"]).

mock_print() ->
    catch meck:unload(emqx_ctl),
    meck:new(emqx_ctl, [non_strict, passthrough]),
    meck:expect(emqx_ctl, print, fun(Arg) -> emqx_ctl:format(Arg) end),
    meck:expect(emqx_ctl, print, fun(Msg, Arg) -> emqx_ctl:format(Msg, Arg) end),
    meck:expect(emqx_ctl, usage, fun(Usages) -> emqx_ctl:format_usage(Usages) end).

unmock_print() ->
    meck:unload().


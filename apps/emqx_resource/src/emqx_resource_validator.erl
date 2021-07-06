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

-module(emqx_resource_validator).

-export([ min/2
        , max/2
        , equals/2
        , enum/1
        , required/1
        ]).

max(Type, Max) ->
    limit(Type, '=<', Max).

min(Type, Min) ->
    limit(Type, '>=', Min).

equals(Type, Expected) ->
    limit(Type, '==', Expected).

enum(Items) ->
    fun(Value) ->
        return(lists:member(Value, Items),
            err_limit({enum, {is_member_of, Items}, {got, Value}}))
    end.

required(ErrMsg) ->
    fun(undefined) -> {error, ErrMsg};
       (_) -> ok
    end.

limit(Type, Op, Expected) ->
    L = len(Type),
    fun(Value) ->
        Got = L(Value),
        return(erlang:Op(Got, Expected),
            err_limit({Type, {Op, Expected}, {got, Got}}))
    end.

len(array) -> fun erlang:length/1;
len(string) -> fun string:length/1;
len(_Type) -> fun(Val) -> Val end.

err_limit({Type, {Op, Expected}, {got, Got}}) ->
    io_lib:format("Expect the ~s value ~s ~p but got: ~p", [Type, Op, Expected, Got]).

return(true, _) -> ok;
return(false, Error) ->
    {error, Error}.

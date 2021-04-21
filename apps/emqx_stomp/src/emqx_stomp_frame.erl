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

%% @doc
%%
%% Stomp Frame:
%%
%% COMMAND
%% header1:value1
%% header2:value2
%%
%% Body^@
%%
%% Stomp 1.2 BNF grammar:
%%
%% NULL                = <US-ASCII null (octet 0)>
%% LF                  = <US-ASCII line feed (aka newline) (octet 10)>
%% CR                  = <US-ASCII carriage return (octet 13)>
%% EOL                 = [CR] LF
%% OCTET               = <any 8-bit sequence of data>
%%
%% frame-stream        = 1*frame
%%
%% frame               = command EOL
%%                       *( header EOL )
%%                       EOL
%%                       *OCTET
%%                       NULL
%%                       *( EOL )
%%
%% command             = client-command | server-command
%%
%% client-command      = "SEND"
%%                       | "SUBSCRIBE"
%%                       | "UNSUBSCRIBE"
%%                       | "BEGIN"
%%                       | "COMMIT"
%%                       | "ABORT"
%%                       | "ACK"
%%                       | "NACK"
%%                       | "DISCONNECT"
%%                       | "CONNECT"
%%                       | "STOMP"
%%
%% server-command      = "CONNECTED"
%%                       | "MESSAGE"
%%                       | "RECEIPT"
%%                       | "ERROR"
%%
%% header              = header-name ":" header-value
%% header-name         = 1*<any OCTET except CR or LF or ":">
%% header-value        = *<any OCTET except CR or LF or ":">
%%
%% @end

-module(emqx_stomp_frame).

-include("emqx_stomp.hrl").

-export([ init_parer_state/1
        , parse/2
        , serialize/1
        ]).

-export([ make/2
        , make/3
        , format/1
        ]).

-define(NULL,  0).
-define(CR,    $\r).
-define(LF,    $\n).
-define(BSL,   $\\).
-define(COLON, $:).

-define(IS_ESC(Ch), Ch == ?CR; Ch == ?LF; Ch == ?BSL; Ch == ?COLON).

-record(parser_state, {cmd,
                       headers = [],
                       hdname,
                       acc = <<>> :: binary(),
                       limit}).

-record(frame_limit, {max_header_num, max_header_length, max_body_length}).

-type(result() :: {ok, stomp_frame(), binary()}
                | {more, parser()}
                | {error, any()}).

-type(parser() :: #{phase := none | command | headers | hdname | hdvalue | body,
                    pre => binary(),
                    state := #parser_state{}}).

%% @doc Initialize a parser
-spec init_parer_state([proplists:property()]) -> parser().
init_parer_state(Opts) ->
    #{phase => none, state => #parser_state{limit = limit(Opts)}}.

limit(Opts) ->
    #frame_limit{max_header_num     = g(max_header_num,    Opts, ?MAX_HEADER_NUM),
                 max_header_length  = g(max_header_length, Opts, ?MAX_BODY_LENGTH),
                 max_body_length    = g(max_body_length,   Opts, ?MAX_BODY_LENGTH)}.

g(Key, Opts, Val) ->
    proplists:get_value(Key, Opts, Val).

-spec parse(binary(), parser()) -> result().
parse(<<>>, Parser) ->
    {more, Parser};

parse(Bytes, #{phase := body, len := Len, state := State}) ->
    parse(body, Bytes, State, Len);

parse(Bytes, Parser = #{pre := Pre}) ->
    parse(<<Pre/binary, Bytes/binary>>, maps:without([pre], Parser));
parse(<<?CR, ?LF, Rest/binary>>, #{phase := Phase, state := State}) ->
    parse(Phase, <<?LF, Rest/binary>>, State);
parse(<<?CR>>, Parser) ->
    {more, Parser#{pre => <<?CR>>}};
parse(<<?CR, _Ch:8, _Rest/binary>>, _Parser) ->
    {error, linefeed_expected};

parse(<<?BSL>>, Parser = #{phase := Phase}) when Phase =:= hdname; Phase =:= hdvalue ->
    {more, Parser#{pre => <<?BSL>>}};
parse(<<?BSL, Ch:8, Rest/binary>>, #{phase := Phase, state := State}) when Phase =:= hdname; Phase =:= hdvalue ->
    parse(Phase, Rest, acc(unescape(Ch), State));

parse(Bytes, #{phase := none, state := State}) ->
    parse(command, Bytes, State).

%% @private
parse(command, <<?LF, Rest/binary>>, State = #parser_state{acc = Acc}) ->
    parse(headers, Rest, State#parser_state{cmd = Acc, acc = <<>>});
parse(command, <<Ch:8, Rest/binary>>, State) ->
    parse(command, Rest, acc(Ch, State));

parse(headers, <<?LF, Rest/binary>>, State) ->
    parse(body, Rest, State, content_len(State#parser_state{acc = <<>>}));
parse(headers, Bin, State) ->
    parse(hdname, Bin, State);

parse(hdname, <<?LF, _Rest/binary>>, _State) ->
    {error, unexpected_linefeed};
parse(hdname, <<?COLON, Rest/binary>>, State = #parser_state{acc = Acc}) ->
    parse(hdvalue, Rest, State#parser_state{hdname = Acc, acc = <<>>});
parse(hdname, <<Ch:8, Rest/binary>>, State) ->
    parse(hdname, Rest, acc(Ch, State));

parse(hdvalue, <<?LF, Rest/binary>>, State = #parser_state{headers = Headers, hdname = Name, acc = Acc}) ->
    parse(headers, Rest, State#parser_state{headers = add_header(Name, Acc, Headers), hdname = undefined, acc = <<>>});
parse(hdvalue, <<Ch:8, Rest/binary>>, State) ->
    parse(hdvalue, Rest, acc(Ch, State)).

%% @private
parse(body, <<>>, State, Length) ->
    {more, #{phase => body, length => Length, state => State}};
parse(body, Bin, State, none) ->
    case binary:split(Bin, <<?NULL>>) of
        [Chunk, Rest] ->
            {ok, new_frame(acc(Chunk, State)), Rest};
        [Chunk] ->
            {more, #{phase => body, length => none, state => acc(Chunk, State)}}
    end;
parse(body, Bin, State, Len) when byte_size(Bin) >= (Len+1) ->
    <<Chunk:Len/binary, ?NULL, Rest/binary>> = Bin,
    {ok, new_frame(acc(Chunk, State)), Rest};
parse(body, Bin, State, Len) ->
    {more, #{phase => body, length => Len - byte_size(Bin), state => acc(Bin, State)}}.

add_header(Name, Value, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {Name, _} -> Headers;
        false     -> [{Name, Value} | Headers]
    end.

content_len(#parser_state{headers = Headers}) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Val} -> list_to_integer(binary_to_list(Val));
        false    -> none
    end.

new_frame(#parser_state{cmd = Cmd, headers = Headers, acc = Acc}) ->
    #stomp_frame{command = Cmd, headers = Headers, body = Acc}.

acc(Chunk, State = #parser_state{acc = Acc}) when is_binary(Chunk) ->
    State#parser_state{acc = <<Acc/binary, Chunk/binary>>};
acc(Ch, State = #parser_state{acc = Acc}) ->
    State#parser_state{acc = <<Acc/binary, Ch:8>>}.

%% \r (octet 92 and 114) translates to carriage return (octet 13)
%% \n (octet 92 and 110) translates to line feed (octet 10)
%% \c (octet 92 and 99) translates to : (octet 58)
%% \\ (octet 92 and 92) translates to \ (octet 92)
unescape($r)  -> ?CR;
unescape($n)  -> ?LF;
unescape($c)  -> ?COLON;
unescape($\\) -> ?BSL;
unescape(_Ch) -> {error, cannnot_unescape}.

serialize(#stomp_frame{command = Cmd, headers = Headers, body = Body}) ->
    Headers1 = lists:keydelete(<<"content-length">>, 1, Headers),
    Headers2 =
    case iolist_size(Body) of
        0   -> Headers1;
        Len -> Headers1 ++ [{<<"content-length">>, Len}]
    end,
    [Cmd, ?LF, [serialize(header, Header) || Header <- Headers2], ?LF, Body, 0].

serialize(header, {Name, Val}) when is_integer(Val) ->
    [escape(Name), ?COLON, integer_to_list(Val), ?LF];
serialize(header, {Name, Val}) ->
    [escape(Name), ?COLON, escape(Val), ?LF].

escape(Bin) when is_binary(Bin) ->
    << <<(escape(Ch))/binary>> || <<Ch>> <= Bin >>;
escape(?CR)    -> <<?BSL, $r>>;
escape(?LF)    -> <<?BSL, $n>>;
escape(?BSL)   -> <<?BSL, ?BSL>>;
escape(?COLON) -> <<?BSL, $c>>;
escape(Ch)     -> <<Ch>>.


%% @doc Make a frame
make(<<"CONNECTED">>, Headers) ->
    #stomp_frame{command = <<"CONNECTED">>,
                 headers = [{<<"server">>, ?STOMP_SERVER} | Headers]};

make(Command, Headers) ->
    #stomp_frame{command = Command, headers = Headers}.

make(Command, Headers, Body) ->
    #stomp_frame{command = Command, headers = Headers, body = Body}.

%% @doc Format a frame
format(Frame) -> serialize(Frame).


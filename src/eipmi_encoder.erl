%%%=============================================================================
%%% Copyright (c) 2012 Lindenbaum GmbH
%%%
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% @doc
%%% A module providing encoding functionality for RMCP packets.
%%% @end
%%%=============================================================================

-module(eipmi_encoder).

-export([ack/1,
         ping/2,
         ipmi/4,
         request/3]).

-include("eipmi.hrl").

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Encodes a RMCP ACK packet. An ACK is a requested response to a formerly
%% received message. To be able to associate the ACK with the message it is
%% generated for specific values must/will be copied from the header of the
%% received message.
%% @end
%%------------------------------------------------------------------------------
-spec ack(#rmcp_header{}) -> binary().
ack(Header = #rmcp_header{class = ?RMCP_ASF}) ->
    header(Header, ?RMCP_ACK).

%%------------------------------------------------------------------------------
%% @doc
%% Encodes a RMCP ASF Ping packet. A Ping is usually sent to retrieve the IPMI
%% capabilities of the far end.
%% @end
%%------------------------------------------------------------------------------
-spec ping(#rmcp_header{}, #asf_ping{}) -> binary().
ping(Header = #rmcp_header{class = ?RMCP_ASF}, #asf_ping{iana = I, tag = T}) ->
    HeaderBin = header(Header, ?RMCP_NORMAL),
    PingBin = <<I:32, ?ASF_PING:8, T:8, 0:8, 0:8>>,
    <<HeaderBin/binary, PingBin/binary>>.

%%------------------------------------------------------------------------------
%% @doc
%% Encodes a RMCP IPMI packet. This encapsulates the logic of binary packet
%% construction with authentication and checksum calculation. Please note that
%% currently only IPMI requests are supported.
%% @end
%%------------------------------------------------------------------------------
-spec ipmi(#rmcp_header{}, proplists:proplist(), eipmi:request(), binary()) ->
                  binary().
ipmi(Header = #rmcp_header{class = ?RMCP_IPMI}, Properties, Req, Data) ->
    HeaderBin = header(Header, ?RMCP_NORMAL),
    SessionBin = session(Properties, Data),
    RequestBin = request(Properties, Req, Data),
    Length = size(RequestBin),
    <<HeaderBin/binary, SessionBin/binary, Length:8, RequestBin/binary>>.

%%------------------------------------------------------------------------------
%% @doc
%% Encodes a raw IPMB request according the standard format:
%%   `rsSA, netFn/rsLUN, chk1, rqSA, rqSeq/rqLUN, cmd, <data>, chk2'
%% Calling this directly is useful for e.g. bridged requests. Refer to chapter
%% 6.13, BMC Message Bridging in the IPMI specification.
%% @end
%%------------------------------------------------------------------------------
-spec request(proplists:proplist(), {eipmi:req_net_fn(), 0..255}, binary()) ->
                     binary().
request(Properties, {NetFn, Cmd}, Data) ->
    Head = request_head(NetFn, Properties),
    HeadSum = checksum(Head),
    Tail = request_tail(Properties, Cmd, Data),
    TailSum = checksum(Tail),
    <<Head/binary, HeadSum:8/signed, Tail/binary, TailSum:8/signed>>.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
header(#rmcp_header{version = V, seq_nr = S, class = C}, Ack) ->
    <<V:8, 0:8, S:8, Ack:1, 0:2, C:5>>.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
session(Properties, Data) ->
    S = proplists:get_value(inbound_seq_nr, Properties),
    I = proplists:get_value(session_id, Properties),
    P = proplists:get_value(password, Properties),
    AuthType = proplists:get_value(auth_type, Properties),
    session(AuthType, S, I, P, Data).

%%------------------------------------------------------------------------------
%% @private
%% This will also do the authentication according to the multi session
%% authentication.
%%------------------------------------------------------------------------------
session(none, S, I, _P, _Data) ->
    Type = eipmi_auth:encode_type(none),
    <<0:4, Type:4, S:32/little, I:32/little>>;
session(pwd, S, I, P, _Data) ->
    Type = eipmi_auth:encode_type(pwd),
    C = eipmi_auth:encrypt(pwd, P),
    <<0:4, Type:4, S:32/little, I:32/little, C/binary>>;
session(T, S, I, P, Data) ->
    Type = eipmi_auth:encode_type(T),
    C = eipmi_util:normalize(16, P),
    ToEncrypt = <<C/binary, I:32/little, Data/binary, S:32/little, C/binary>>,
    Ci = eipmi_auth:encrypt(T, ToEncrypt),
    <<0:4, Type:4, S:32/little, I:32/little, Ci/binary>>.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
request_head(NetFn, Properties) ->
    A = proplists:get_value(rs_addr, Properties),
    L = proplists:get_value(rs_lun, Properties),
    <<A:8, NetFn:6, L:2>>.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
request_tail(Properties, Cmd, Data) ->
    A = proplists:get_value(rq_addr, Properties),
    S = proplists:get_value(rq_seq_nr, Properties),
    L = proplists:get_value(rq_lun, Properties),
    <<A:8, S:6, L:2, Cmd:8, Data/binary>>.

%%------------------------------------------------------------------------------
%% @doc
%% Calculates the two's complement of the 8-bit checksum of the input binary.
%% Use <code>(checksum(Binary)):8/signed</code> to insert into a binary.
%% @end
%%------------------------------------------------------------------------------
checksum(Binary) ->
    bnot sum(Binary, 0) + 1.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
sum(<<>>, Sum) ->
    Sum;
sum(<<Byte:8, Rest/binary>>, Sum) ->
    sum(Rest, (Sum + Byte) rem 256).

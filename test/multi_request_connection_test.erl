%% A batch of tests to verify that Webmachine can properly handle
%% multiple requests on the same connection in various situations.
%%
%% This is mostly regression tests to verify that the mechanism that
%% ensures that request bodies get read before request processing
%% finishes.
-module(multi_request_connection_test).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-export([
         init/1,
         allowed_methods/2,
         content_types_provided/2,
         content_types_accepted/2,
         echo_disp_path/2,
         process_post/2,
         echo_partial_body/2,
         is_authorized/2,
         delete_resource/2,
         delete_completed/2
        ]).

%%% TESTS

multi_req_tests() ->
    [
     fun double_get/1,
     fun post_then_get/1,
     fun unauthorized_post_then_get/1,
     fun too_large_unauthorized_post_then_get/1,
     fun half_chunk_then_get/1,
     fun half_unchunk_then_get/1,
     fun delete_with_body_then_get/1
    ].

%% Two GETs is the simplest happy-path, because there are no bodies to
%% skip.
double_get(Ctx) ->
    DispPath1 = "get1",
    DispPath2 = "get2",
    Req1 = build_request("GET", DispPath1, [], []),
    Req2 = build_request("GET", DispPath2, [], []),
    Responses = send_requests(Ctx, [Req1, Req2]),
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath1}, hd(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath2}, hd(tl(Responses))),
    ok.

%% Successful POST then GET is the next simplest happy-path, because
%% the resource should have consumed the POST body.
post_then_get(Ctx) ->
    DispPath1 = "post1",
    DispPath2 = "get3",
    Req1 = build_request("POST", DispPath1,
                         [{"content-type", "text/plain"}], "check"),
    Req2 = build_request("GET", DispPath2, [], []),
    Responses = send_requests(Ctx, [Req1, Req2]),
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 204"++_, _, []}, hd(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath2}, hd(tl(Responses))),
    ok.

%% First real body-skipping test. The POST is unauthorized, so the
%% resource never reads its body.
unauthorized_post_then_get(Ctx) ->
    DispPath1 = "unauth",
    DispPath2 = "get4",
    Req1 = build_request("POST", DispPath1,
                         [{"content-type", "text/plain"}], "check"),
    Req2 = build_request("GET", DispPath2, [], []),
    Responses = send_requests(Ctx, [Req1, Req2]),
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 401"++_, _, _}, hd(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath2}, hd(tl(Responses))),
    ok.

%% This time the unread body is larger than we are prepared to skip,
%% so the GET _does_ get ignored.
too_large_unauthorized_post_then_get(Ctx) ->
    DispPath1 = "unauth",
    DispPath2 = "get5",
    ReqBody = "This is a moderately sized string.",
    Req1 = build_request("POST", DispPath1,
                         [{"content-type", "text/plain"}], ReqBody),
    Req2 = build_request("GET", DispPath2, [], []),
    {ok, RestoreMaxFlush} = application:get_env(webmachine, max_flush_bytes),
    application:set_env(webmachine, max_flush_bytes, length(ReqBody)-3),
    Responses = try send_requests(Ctx, [Req1, Req2])
                after
                    application:set_env(
                      webmachine, max_flush_bytes, RestoreMaxFlush)
                end,
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 401"++_, _, _}, hd(Responses)),
    {ok, _, Headers, _} = hd(Responses),
    ?assertEqual({"Connection", "close"},
                 lists:keyfind("Connection", 1, Headers)),
    ?assertMatch({error, closed}, hd(tl(Responses))),
    ok.

%% Here PUT processing begins to stream an unchunked body, but does
%% not finish. The flush mechanism should pick up where it left off.
half_unchunk_then_get(Ctx) ->
    DispPath1 = "put1",
    DispPath2 = "get6",
    ReqBody = "This is a string containing more than twelve bytes.",
    Req1 = build_request("PUT", DispPath1,
                         [{"content-type", "text/plain"}], ReqBody),
    Req2 = build_request("GET", DispPath2, [], []),
    Responses = send_requests(Ctx, [Req1, Req2]),
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, _}, hd(Responses)),
    {ok, _, _, RespBody} = hd(Responses),
    %% if these RespBody asserts fail, the test is invalid because the
    %% whole request body was read by the resource
    ?assertEqual(1, string:str(ReqBody, RespBody)),
    ?assert(length(RespBody) < length(ReqBody)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath2}, hd(tl(Responses))),
    ok.

%% Here PUT processing begins to stream a chunked body, but does not
%% finish. The flush mechanism should pick up where it left off.
half_chunk_then_get(Ctx) ->
    DispPath1 = "put2",
    DispPath2 = "get7",
    ReqBody = ["This is", " a string", " containing",
               " more than", " twelve bytes."],
    Req1 = build_request("PUT", DispPath1,
                         [{"content-type", "text/plain"}], {chunked, ReqBody}),
    Req2 = build_request("GET", DispPath2, [], []),
    Responses = send_requests(Ctx, [Req1, Req2]),
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, _}, hd(Responses)),
    {ok, _, _, RespBody} = hd(Responses),
    %% if these RespBody asserts fail, the test is invalid because the
    %% whole request body was read by the resource
    ?assertEqual(1, string:str(lists:flatten(ReqBody), RespBody)),
    ?assert(length(RespBody) < length(lists:flatten(ReqBody))),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath2}, hd(tl(Responses))),
    ok.

%% DELETE with a body was specifically handled before the introduction
%% of webmachine_request:maybe_flush_req_body. Does it still work?
delete_with_body_then_get(Ctx) ->
    DispPath1 = "delete1",
    DispPath2 = "get8",
    Req1 = build_request("DELETE", DispPath1,
                         [{"content-type", "text/plain"}], "check"),
    Req2 = build_request("GET", DispPath2, [], []),
    Responses = send_requests(Ctx, [Req1, Req2]),
    ?assertEqual(2, length(Responses)),
    ?assertMatch({ok, "HTTP/1.1 204"++_, _, []}, hd(Responses)),
    ?assertMatch({ok, "HTTP/1.1 200"++_, _, DispPath2}, hd(tl(Responses))),
    ok.

%%% SUPPORT/UTIL

build_request(Method, Path, Headers, Body) ->
    [Method, " /", atom_to_list(?MODULE), "/", Path, " HTTP/1.1\r\n",
     [ [K, ": ", V, "\r\n"] || {K, V} <- Headers ],
     case Body of
         [] ->
             "\r\n";
         {chunked, Chunks} ->
             [["Transfer-encoding: chunked\r\n\r\n"
              |[build_chunk(C) || C <- Chunks]]
             |"0\r\n\r\n"];
         _ ->
             ["Content-length: ", integer_to_list(length(Body)), "\r\n\r\n",
              Body]
     end].

build_chunk(Bytes) ->
    [mochihex:to_hex(length(Bytes)), "\r\n", Bytes, "\r\n"].

%% httpc, ibrowse, curl etc. will all reuse a connection ... when they
%% think they should. For these tests we need to force the requests to
%% be sent on the same connection, so we'll marshal bytes onto and off
%% of the socket directly.
send_requests(Ctx, RequestList) ->
    {ok, Sock} = gen_tcp:connect("localhost",
                                 wm_integration_test_util:get_port(Ctx),
                                 [list, {active, false}]),
    ok = gen_tcp:send(Sock, iolist_to_binary(RequestList)),
    Responses = receive_responses(Sock, length(RequestList)),
    gen_tcp:close(Sock),
    Responses.

receive_responses(Socket, ResponseCount) ->
    lists:reverse(
      element(3,
              lists:foldl(fun(_, {Buffer, Sock, Resps}) ->
                                  {Resp, NewBuffer} =
                                      receive_response(Buffer, Sock),
                                  {NewBuffer, Sock, [Resp|Resps]}
                          end,
                          {[], Socket, []},
                          lists:seq(1, ResponseCount)))).

receive_response(Buffer, Sock) ->
    case string:split(Buffer, "\r\n\r\n") of
        [Head,MaybeBody] ->
            [Code|RawHeaders] = string:tokens(Head, "\r\n"),
            Headers = [ list_to_tuple(string:tokens(H, ": "))
                        || H <- RawHeaders ],
            BodyLength = case lists:keyfind("Content-Length", 1, Headers) of
                             {_, Lstr} ->
                                 list_to_integer(Lstr);
                             false ->
                                 0
                         end,
            StartBody = lists:flatten(MaybeBody),
            {Body, NewBuffer} =
                case length(StartBody) > BodyLength of
                    true ->
                        %% responses to the two test requests almost
                        %% always come in separate packets, but
                        %% occasionally everything comes in one
                        %% packet, so we need to buffer unused bytes
                        lists:split(BodyLength, StartBody);
                    false ->
                        {receive_body(Sock,
                                      BodyLength-length(StartBody),
                                      [StartBody]),
                         []}
                end,
            {{ok, Code, Headers, Body}, NewBuffer};
        _IncompleteHead ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {error, _} = Error ->
                    {Error, Buffer};
                {ok, Data} ->
                    receive_response(Buffer++Data, Sock)
            end
    end.

receive_body(_Sock, 0, Acc) ->
    lists:flatten(lists:reverse(Acc));
receive_body(Sock, Remaining, Acc) when Remaining > 0 ->
    case gen_tcp:recv(Sock, Remaining, 2000) of
        {ok, BodyData} ->
            receive_body(Sock, Remaining-length(BodyData), [BodyData|Acc]);
        {error, _} = Error ->
            Error
    end.

%%% REQUEST MODULE

init([]) ->
    {ok, undefined}.

allowed_methods(RD, Ctx) ->
    {['GET','HEAD','OPTIONS','POST','PUT','DELETE'], RD, Ctx}.

content_types_provided(RD, Ctx) ->
    {[{"text/plain", echo_disp_path}], RD, Ctx}.

content_types_accepted(RD, Ctx) ->
    {[{"text/plain", echo_partial_body}], RD, Ctx}.

echo_disp_path(RD, Ctx) ->
    {wrq:disp_path(RD), RD, Ctx}.

delete_resource(RD, Ctx) ->
    %% do not check for a request body!
    {true, RD, Ctx}.

delete_completed(RD, Ctx) ->
    {true, RD, Ctx}.

is_authorized(RD, Ctx) ->
    case wrq:disp_path(RD) of
        "unauth" ->
            {"Basic realm=multireqtest", RD, Ctx};
        _ ->
            {true, RD, Ctx}
    end.

% POST reads the request body in "standard" non-streaming
process_post(RD, Ctx) ->
    _Body = wrq:req_body(RD),
    {true, RD, Ctx}.

% PUT reads twelve bytes of the body in streaming mode
echo_partial_body(RD, Ctx) ->
    Bytes = stream(2, wrq:stream_req_body(RD, 4)),
    RD2 = wrq:set_resp_header("content-type", "text/plain", RD),
    RD3 = wrq:set_resp_body(Bytes, RD2),
    {true, RD3, Ctx}.

stream(Count, {Bytes, Stream}) ->
    lists:flatten(
      lists:reverse(
        element(2, lists:foldl(fun(_, {S, Acc}) ->
                                       {B, Next} = S(),
                                       {Next, [B|Acc]}
                               end,
                               {Stream, [Bytes]},
                               lists:seq(1, Count))))).


%%% TEST SETUP

multireq_test_() ->
    {foreach,
     %% Setup
     fun() ->
             DL = [{[atom_to_list(?MODULE), '*'], ?MODULE, []}],
             wm_integration_test_util:start(?MODULE, "0.0.0.0", DL)
     end,
     %% Cleanup
     fun(Ctx) ->
             wm_integration_test_util:stop(Ctx)
     end,
     %% Test functions provided with context from setup
     [fun(Ctx) ->
              {spawn, {with, Ctx, multi_req_tests()}}
      end]}.

-endif.

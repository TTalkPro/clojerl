%%%-------------------------------------------------------------------
%%% @doc clj2_io — *out* for 03-print (clojerl2-021).
%%%
%%% Output goes to the calling process's group leader (Erlang's io
%%% protocol), which is Clojure's *out*. with_out_str/1 runs a thunk with
%%% a temporary collecting io server as group leader and returns what was
%%% written (registered for 020: *in*/*err*, binding *out*).
%%%-------------------------------------------------------------------
-module(clj2_io).

-export([write/1, with_out_str/1]).

write(Bin) -> io:put_chars(Bin), nil.

with_out_str(Thunk) ->
    Old = group_leader(),
    Collector = spawn_link(fun() -> collect([]) end),
    group_leader(Collector, self()),
    try Thunk()
    after
        group_leader(Old, self())
    end,
    Collector ! {done, self()},
    receive {out, Collector, Bin} -> Bin end.

collect(Acc) ->
    receive
        {io_request, From, Ref, Req} ->
            {Reply, Acc1} = request(Req, Acc),
            From ! {io_reply, Ref, Reply},
            collect(Acc1);
        {done, Pid} ->
            unlink(Pid),
            Pid ! {out, self(), unicode:characters_to_binary(lists:reverse(Acc))}
    end.

request({put_chars, _Enc, Chars}, Acc) -> {ok, [Chars | Acc]};
request({put_chars, _Enc, M, F, A}, Acc) -> {ok, [apply(M, F, A) | Acc]};
request({put_chars, Chars}, Acc) -> {ok, [Chars | Acc]};
request({requests, Rs}, Acc) ->
    lists:foldl(fun(R, {_, A}) -> request(R, A) end, {ok, Acc}, Rs);
request(_, Acc) -> {{error, enotsup}, Acc}.

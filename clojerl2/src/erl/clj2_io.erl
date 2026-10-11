%%%-------------------------------------------------------------------
%%% @doc clj2_io — *out*, *err*, *in* over the Erlang io protocol
%%% (clojerl2-020, designs/03 §8).
%%%
%%% *out* *err* *in* are dynamic vars of clojure.core whose values are
%%% Erlang io devices: standard_io, standard_error, or a pid speaking the
%%% io protocol. Printing writes to *out*, read-line reads from *in*, so
%%% (binding [*out* w] ...) redirects, and futures and agent actions see
%%% the redirection (bindings travel with them). Erlang code calling
%%% io:format writes to its group leader, not to *out*.
%%%
%%% with-out-str binds *out* to a string writer (a process collecting
%%% what is written); with-in-str binds *in* to a string reader. Text is
%%% UTF-8 throughout: writers collect chardata and encode once.
%%%-------------------------------------------------------------------
-module(clj2_io).

-export([out/0, write/1, write/2, read_line/0, read_line/1]).
-export([with_out_str/1, with_in_str/2, string_writer/0, contents/1, string_reader/1, close/1]).
-export([slurp/2, spit/3]).

%% the device a dynamic var holds (before clojure.core is loaded: the
%% standard devices)
device(Name, Default) ->
    try clj2_var:deref('clojure.core', Name)
    catch error:_ -> Default
    end.

out() -> device('*out*', standard_io).
in() -> device('*in*', standard_io).

write(Chars) -> write(out(), Chars).

write(Dev, Chars) -> ok = io:put_chars(Dev, unicode:characters_to_binary(Chars)), nil.

%% @doc (read-line): the next line of *in* without its line terminator, or
%% nil at the end
read_line() -> read_line(in()).

read_line(Dev) ->
    case io:get_line(Dev, '') of
        eof -> nil;
        {error, _} -> nil;
        Data ->
            B = unicode:characters_to_binary(Data),
            case binary:split(B, [<<"\r\n">>, <<"\n">>]) of
                [Line, _] -> Line;
                [Line] -> Line
            end
    end.

%%====================================================================
%% with-out-str / with-in-str
%%====================================================================

with_out_str(Thunk) ->
    W = string_writer(),
    clj2_var:push_binding('clojure.core', '*out*', W),
    try Thunk()
    after clj2_var:pop_binding('clojure.core', '*out*')
    end,
    Out = contents(W),
    close(W),
    Out.

with_in_str(S, Thunk) ->
    R = string_reader(S),
    clj2_var:push_binding('clojure.core', '*in*', R),
    try Thunk()
    after
        clj2_var:pop_binding('clojure.core', '*in*'),
        close(R)
    end.

%% @doc A device that collects what is written to it; contents/1 reads it.
string_writer() -> spawn(fun() -> writer([]) end).

contents(W) ->
    Ref = monitor(process, W),
    W ! {contents, self(), Ref},
    receive
        {Ref, Bin} -> demonitor(Ref, [flush]), Bin;
        {'DOWN', Ref, _, _, _} -> erlang:error({clj2_writer_closed, W})
    end.

close(Dev) when is_pid(Dev) -> Dev ! close, nil;
close(_) -> nil.

writer(Acc) ->
    receive
        {io_request, From, Ref, Req} ->
            {Reply, Acc1} = put_request(Req, Acc),
            From ! {io_reply, Ref, Reply},
            writer(Acc1);
        {contents, From, Ref} ->
            From ! {Ref, unicode:characters_to_binary(lists:reverse(Acc))},
            writer(Acc);
        close -> ok
    end.

put_request({put_chars, unicode, Chars}, Acc) -> {ok, [Chars | Acc]};
put_request({put_chars, latin1, Chars}, Acc) -> {ok, [unicode:characters_to_list(Chars, latin1) | Acc]};
put_request({put_chars, Enc, M, F, A}, Acc) -> put_request({put_chars, Enc, apply(M, F, A)}, Acc);
put_request({put_chars, Chars}, Acc) -> put_request({put_chars, latin1, Chars}, Acc);
put_request({requests, Rs}, Acc) ->
    lists:foldl(fun(R, {_, A}) -> put_request(R, A) end, {ok, Acc}, Rs);
put_request({setopts, _}, Acc) -> {ok, Acc};
put_request(getopts, Acc) -> {[{binary, true}, {encoding, unicode}], Acc};
put_request(_, Acc) -> {{error, enotsup}, Acc}.

%% @doc A device that reads from the string S.
string_reader(S) -> spawn(fun() -> reader(unicode:characters_to_binary(S)) end).

reader(Rest) ->
    receive
        {io_request, From, Ref, Req} ->
            {Reply, Rest1} = get_request(Req, Rest),
            From ! {io_reply, Ref, Reply},
            reader(Rest1);
        close -> ok
    end.

get_request(_, <<>>) -> {eof, <<>>};
get_request({get_line, _Enc, _Prompt}, Rest) ->
    case binary:split(Rest, <<"\n">>) of
        [Line, After] -> {<<Line/binary, "\n">>, After};
        [Line] -> {Line, <<>>}
    end;
get_request({get_chars, _Enc, _Prompt, N}, Rest) ->
    Cs = string:slice(Rest, 0, N),
    {Cs, binary:part(Rest, byte_size(Cs), byte_size(Rest) - byte_size(Cs))};
get_request({setopts, _}, Rest) -> {ok, Rest};
get_request(getopts, Rest) -> {[{binary, true}, {encoding, unicode}], Rest};
get_request(_, Rest) -> {{error, enotsup}, Rest}.

%%====================================================================
%% files
%%====================================================================

%% @doc (slurp path): the file's text (UTF-8)
slurp(Path, _Opts) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Why} -> erlang:error(file_error(Path, Why))
    end.

%% @doc (spit path content & {:append bool})
spit(Path, Content, Opts) ->
    Modes = case clj2_coll:get(Opts, ':append') of
                true -> [append];
                _ -> [write]
            end,
    case file:write_file(Path, unicode:characters_to_binary(clj2_rt:str([Content])), Modes) of
        ok -> nil;
        {error, Why} -> erlang:error(file_error(Path, Why))
    end.

file_error(Path, Why) ->
    clj2_rt:ex_info(iolist_to_binary([Path, ": ", atom_to_binary(Why)]),
                    clj2_coll:hash_map_kv([':path', Path, ':reason', Why]), nil).

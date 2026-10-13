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
-export([set_write_hook/1]).

-export([out/0, write/1, write/2, read_line/0, read_line/1]).
-export([with_out_str/1, with_in_str/2, string_writer/0, is_string_writer/1, contents/1, string_reader/1, close/1]).
-export([slurp/2, spit/3]).
-export([read_form/4]).

%% the device a dynamic var holds (before clojure.core is loaded: the
%% standard devices)
device(Name, Default) ->
    try clj2_var:deref('clojure.core', Name)
    catch error:_ -> Default
    end.

out() -> device('*out*', standard_io).
in() -> device('*in*', standard_io).

write(Chars) -> write(out(), Chars).

write(Dev, Chars) when is_pid(Dev); is_atom(Dev) ->
    ok = io:put_chars(Dev, unicode:characters_to_binary(Chars)), nil;
%% *out* bound to a writer value (clojure.pprint's pretty writer, a
%% StringBuilder ...): the registered write hook takes it, else its .write
write(W, Chars) ->
    S = unicode:characters_to_binary(Chars),
    Handled = case persistent_term:get({?MODULE, write_hook}, nil) of
                  nil -> false;
                  Hook -> clj2_rt:invoke(Hook, [S]) =:= true
              end,
    %% a writer value: the hook, its own -write (clojure.pprint's writers),
    %% else .write
    Handled orelse
        case clj2_proto:type_method(W, '-write', [S]) of
            {ok, _} -> true;
            error -> clj2_jvm:method(W, write, [S])
        end,
    nil.

%% @doc (__set-pprint-write-hook! f): f takes each string written to a
%% *out* that is not an io device, and answers true when it wrote it
set_write_hook(F) -> persistent_term:put({?MODULE, write_hook}, F), nil.

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
string_writer() ->
    W = spawn(fun() -> writer([]) end),
    put({clj2_string_writer, W}, true),
    W.

%% @doc Made by string_writer/0 in this process (its .toString is its text)
is_string_writer(W) -> get({clj2_string_writer, W}) =:= true.

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

%% (read) on a string reader: one form, read here so that the rest
%% stays unread (read-line after read sees what follows the form)
get_request(clj2_read_form, Rest) ->
    case clj2_reader:read(Rest) of
        {ok, Form, _, After} ->
            Text = binary:part(Rest, 0, byte_size(Rest) - byte_size(After)),
            {{form, Form, Text}, After};
        {eof, _} -> {eof, <<>>};
        {error, _, Msg} -> {{error, Msg}, <<>>}
    end;
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
%% read / read+string
%%====================================================================

%% @doc (read stream eof-error? eof-value): the next form of the stream as
%% data; WithText: [form text] as read+string gives it
read_form(Dev0, EofError, EofValue, WithText) ->
    Dev = case Dev0 of nil -> in(); _ -> Dev0 end,
    R = case is_pid(Dev) andalso io_request(Dev, clj2_read_form) of
            {error, enotsup} -> read_by_lines(Dev, <<>>);
            false -> read_by_lines(Dev, <<>>);
            Other -> Other
        end,
    case R of
        {form, Form, Text} ->
            V = clj2_p_parse:data_form(Form, clj2_rt_eval:current_ns()),
            case WithText of
                true -> clj2_coll:vector([V, string:trim(Text, leading)]);
                false -> V
            end;
        eof when EofError =:= false orelse EofError =:= nil ->
            case WithText of
                true -> clj2_coll:vector([EofValue, <<>>]);
                false -> EofValue
            end;
        eof -> erlang:error(clj2_rt:ex_info(<<"EOF while reading">>,
                                            clj2_coll:hash_map_kv([':type', ':RuntimeException']), nil));
        {error, Msg} -> erlang:error(clj2_rt:ex_info(Msg, clj2_coll:hash_map_kv([':type', ':RuntimeException']), nil))
    end.

io_request(Dev, Req) ->
    Ref = monitor(process, Dev),
    Dev ! {io_request, self(), Ref, Req},
    receive
        {io_reply, Ref, Reply} -> demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, _, _, _} -> eof
    end.

%% another device (standard_io ...): lines until they hold a whole form
read_by_lines(Dev, Acc) ->
    case io:get_line(Dev, '') of
        Eof when Eof =:= eof; element(1, Eof) =:= error ->
            case clj2_reader:read(Acc) of
                {ok, Form, _, _} -> {form, Form, Acc};
                _ -> eof
            end;
        Data ->
            Acc1 = <<Acc/binary, (unicode:characters_to_binary(Data))/binary>>,
            case clj2_reader:read(Acc1) of
                {ok, Form, _, After} -> {form, Form, binary:part(Acc1, 0, byte_size(Acc1) - byte_size(After))};
                {eof, _} -> read_by_lines(Dev, Acc1);
                {error, _, <<"EOF", _/binary>>} -> read_by_lines(Dev, Acc1);
                {error, _, Msg} -> {error, Msg}
            end
    end.

%%====================================================================
%% files
%%====================================================================

%% @doc (slurp path): the file's text (UTF-8)
%% a nil path is the JVM's IllegalArgumentException, not a file named "nil"
%% (file:read_file/write_file take atoms as names)
slurp(nil, _Opts) -> nil_path(<<"Reader">>);
%% a reader (an io device: java.io.StringReader, clojure.java.io/reader):
%% everything it has left
slurp(Dev, _Opts) when is_pid(Dev) -> read_rest(Dev, []);
slurp(Path, _Opts) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Why} -> erlang:error(file_error(Path, Why))
    end.

read_rest(Dev, Acc) ->
    case io:get_chars(Dev, '', 4096) of
        eof -> unicode:characters_to_binary(lists:reverse(Acc));
        {error, _} -> unicode:characters_to_binary(lists:reverse(Acc));
        Chars -> read_rest(Dev, [Chars | Acc])
    end.

%% @doc (spit path content & {:append bool})
spit(nil, _Content, _Opts) -> nil_path(<<"Writer">>);
spit(Path, Content, Opts) ->
    Modes = case clj2_coll:get(Opts, ':append') of
                true -> [append];
                _ -> [write]
            end,
    case file:write_file(Path, unicode:characters_to_binary(clj2_rt:str([Content])), Modes) of
        ok -> nil;
        {error, Why} -> erlang:error(file_error(Path, Why))
    end.

nil_path(What) ->
    erlang:error(clj2_rt:ex_info(<<"Cannot open <nil> as a ", What/binary, ".">>,
                                 clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).

file_error(Path, Why) ->
    clj2_rt:ex_info(iolist_to_binary([Path, ": ", atom_to_binary(Why)]),
                    clj2_coll:hash_map_kv([':path', Path, ':reason', Why]), nil).

%%%-------------------------------------------------------------------
%%% @doc clj2_repl — the read-eval-print loop (clojerl2-023).
%%%
%%% Every form goes through the compiler (designs/02 §5, D11: no
%%% interpreter): clj2_compiler:eval/1, form at a time, in the current
%%% namespace (*ns*, per process). Input is read line by line until the
%%% buffer holds complete forms ("EOF while reading" from the reader means
%%% read on), so a form may span lines and a line may hold several forms.
%%%
%%% Text: the terminal is put in unicode mode and lines are read as UTF-8
%%% binaries (clojerl2 strings); everything printed goes out as chardata
%%% through unicode:characters_to_binary/1, never iolist_to_binary/1.
%%%
%%% Line editing and history come from OTP's line editor
%%% (shell:start_interactive({noshell, cooked}), OTP 26+) when stdin is a
%%% terminal; history persists with `-kernel shell_history enabled' (the
%%% clojerl2 script sets it).
%%%-------------------------------------------------------------------
-module(clj2_repl).

-export([start/0, start/1, eval_print/1, format_error/3, setup_io/0, banner/0]).

start() -> start(#{}).

%% Opts: banner (true)
start(Opts) ->
    setup_io(),
    case maps:get(banner, Opts, true) of
        true -> out([banner(), "\n"]);
        false -> ok
    end,
    loop(<<>>).

setup_io() ->
    _ = [io:setopts(D, [{encoding, unicode}]) || D <- [standard_io, standard_error]],
    ok = io:setopts(standard_io, [binary]),
    _ = try shell:start_interactive({noshell, cooked}) catch _:_ -> ok end,
    ok.

banner() ->
    unicode:characters_to_binary(
      ["clojerl2 ", clj2_cli:build(), " (Erlang/OTP ", erlang:system_info(otp_release), ")\n",
       "Exit: Ctrl-D or :repl/quit"]).

loop(Buf) ->
    Prompt = case Buf of
                 <<>> -> [atom_to_binary(clj2_rt_eval:current_ns()), "=> "];
                 _ -> "  #_=> "
             end,
    case io:get_line(unicode:characters_to_list(Prompt)) of
        eof -> out("\n");
        {error, _} -> ok;
        Line ->
            Buf1 = <<Buf/binary, (unicode:characters_to_binary(Line))/binary>>,
            case clj2_reader:read_all(Buf1, #{file => "REPL"}) of
                {ok, Forms, _} ->
                    case run(Forms) of
                        quit -> ok;
                        continue -> loop(<<>>)
                    end;
                {error, _, <<"REPL: EOF while reading", _/binary>>} -> loop(Buf1);
                {error, _, <<"EOF while reading", _/binary>>} -> loop(Buf1);
                {error, {L, C}, Msg} ->
                    err(io_lib:format("Syntax error reading source at (REPL:~b:~b).~n~ts~n", [L, C, Msg])),
                    loop(<<>>)
            end
    end.

run([]) -> continue;
run([F | Rest]) ->
    case F of
        {clj2_loc, _, _, ':repl/quit', _} -> quit;
        ':repl/quit' -> quit;
        _ -> eval_print(F), run(Rest)
    end.

%% @doc Evaluate one form and print its value, or the error. Keeps *1,
%% *2, *3 and *e.
eval_print(Form) ->
    try clj2_compiler:eval({forms, [Form]}, #{file => "REPL"}) of
        V ->
            out([clj2_print:pr_str(V), "\n"]),
            Get = fun(N) -> try clj2_var:deref('clojure.core', N) catch _:_ -> nil end end,
            P1 = Get('*1'), P2 = Get('*2'),
            [clj2_var:set_binding('clojure.core', N, X) || {N, X} <- [{'*3', P2}, {'*2', P1}, {'*1', V}]],
            {ok, V}
    catch
        C:R:S ->
            clj2_var:set_binding('clojure.core', '*e', R),
            err(format_error(C, R, S)),
            {error, {C, R}}
    end.

out(Chars) -> io:put_chars(standard_io, unicode:characters_to_binary(Chars)).
err(Chars) -> io:put_chars(standard_error, unicode:characters_to_binary(Chars)).

%%====================================================================
%% Error reports
%%====================================================================

%% @doc An exception as a Clojure-style report (chardata, ends in a newline).
format_error(error, {clj2_compile, {L, C}, {Phase, Why}}, _S) ->
    io_lib:format("Syntax error compiling at (~ts:~b:~b).~n~ts~n", [where(), L, C, compile_msg(Phase, Why)]);
format_error(error, {clj2_lint, Es}, _S) ->
    io_lib:format("Syntax error compiling (BEAM lint):~n~ts~n", [brief(Es)]);
format_error(error, {clj2_read, Msg}, _S) ->
    io_lib:format("Syntax error reading source.~n~ts~n", [Msg]);
format_error(error, {clj2_read, {L, C}, Msg}, _S) ->
    io_lib:format("Syntax error reading source at (~b:~b).~n~ts~n", [L, C, Msg]);
format_error(error, {clj2_require, Why}, _S) ->
    io_lib:format("Could not load namespace: ~ts~n", [brief(Why)]);
format_error(error, {clj2_load, Path, Why}, _S) ->
    io_lib:format("Could not load ~ts:~n~ts~n", [Path, brief(Why)]);
format_error(C, {'clojure.lang.ExceptionInfo', _, #{':message' := M} = I}, S) ->
    Data = case maps:get(':data', I, nil) of
               nil -> "";
               D -> [" ", clj2_print:pr_str(D)]
           end,
    io_lib:format("Execution error (ExceptionInfo)~ts.~n~ts~ts~n", [at(C, S), M, Data]);
%% BEAM's own exceptions keep BEAM's names (badarith, badarg, ...)
format_error(C, R, S) when is_atom(R) ->
    io_lib:format("Execution error (~ts:~ts)~ts.~n", [C, R, at(C, S)]);
format_error(C, R, S) when is_tuple(R), is_atom(element(1, R)) ->
    io_lib:format("Execution error (~ts:~ts)~ts.~n~ts~n", [C, element(1, R), at(C, S), brief(R)]);
format_error(C, R, S) ->
    io_lib:format("Execution error (~ts)~ts.~n~ts~n", [C, at(C, S), brief(R)]).

where() -> "REPL".

compile_msg(resolve, {unresolved_symbol, S}) ->
    io_lib:format("Unable to resolve symbol: ~ts in this context", [S]);
compile_msg(resolve, {no_such_var, Ns, S}) ->
    io_lib:format("No such var: ~ts/~ts", [Ns, S]);
compile_msg(link, {arity, M, Name, N}) ->
    io_lib:format("Wrong number of args (~b) passed to: ~ts/~ts", [N, ns_of(M), Name]);
compile_msg(driver, {ns_not_found, Ns}) ->
    io_lib:format("No namespace: ~ts found", [Ns]);
compile_msg(Phase, Why) ->
    io_lib:format("~ts: ~ts", [Phase, brief(Why)]).

%% a REPL var's module `ns$v$name' → ns
ns_of(M) ->
    case string:split(atom_to_list(M), "$v$") of
        [Ns, _] -> Ns;
        _ -> atom_to_list(M)
    end.

%% the innermost Clojure frame: " at (file:line)"
at(_C, S) ->
    case [{F, L} || {_, _, _, Info} <- S,
                    F <- [proplists:get_value(file, Info)], is_list(F),
                    F =:= "REPL" orelse lists:suffix(".clj", F) orelse lists:suffix(".cljc", F),
                    L <- [proplists:get_value(line, Info)], is_integer(L)] of
        [{F, L} | _] -> io_lib:format(" at (~ts:~b)", [F, L]);
        [] -> ""
    end.

brief(T) -> io_lib:format("~tP", [T, 20]).

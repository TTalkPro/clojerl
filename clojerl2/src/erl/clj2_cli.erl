%%%-------------------------------------------------------------------
%%% @doc clj2_cli — the `clojerl2' command (clojerl2-023), started by
%%% bin/clojerl2 (`erl -noshell -run clj2_cli main -extra ARGS').
%%%
%%%   clojerl2                       REPL
%%%   clojerl2 -e EXPR ...           evaluate, print each non-nil value
%%%   clojerl2 FILE [ARGS]           evaluate the file form at a time
%%%   clojerl2 -m NS [ARGS]          require NS, call its -main with ARGS
%%%   -p, --source-path DIRS         where require looks (`:'-separated;
%%%                                  default src:., or $CLJ2_PATH)
%%%   -v, --version / -h, --help
%%%
%%% ARGS go to *command-line-args* (a list of strings) and to -main.
%%% The exit status is 1 when evaluation raises. The banner and --version
%%% name the commit clojerl2 was built from (designs/04 §4.3), written to
%%% ebin/clj2.build by `make'.
%%%-------------------------------------------------------------------
-module(clj2_cli).

-export([main/0, main/1, build/0]).

main() -> main(init:get_plain_arguments()).

main(Args) ->
    Status = try run(parse(Args, #{exprs => []})) of
                 _ -> 0
             catch
                 throw:{usage, Msg} ->
                     io:put_chars(standard_error, unicode:characters_to_binary([Msg, "\n", usage()])),
                     2;
                 C:R:S ->
                     io:put_chars(standard_error, unicode:characters_to_binary(clj2_repl:format_error(C, R, S))),
                     1
             end,
    halt(Status).

parse([H, Dirs | T], Acc) when H =:= "-p"; H =:= "--source-path" ->
    parse(T, Acc#{path => string:split(Dirs, ":", all)});
parse([H, E | T], Acc = #{exprs := Es}) when H =:= "-e"; H =:= "--eval" ->
    parse(T, Acc#{exprs := Es ++ [E]});
parse([H, Ns | T], Acc) when H =:= "-m"; H =:= "--main" -> Acc#{main => Ns, args => T};
parse([H | _], Acc) when H =:= "-h"; H =:= "--help" -> Acc#{help => true};
parse([H | _], Acc) when H =:= "-v"; H =:= "--version" -> Acc#{version => true};
parse([[$- | _] = Opt | _], _) when Opt =/= "-" -> throw({usage, ["unknown option ", Opt]});
parse([File | T], Acc) -> Acc#{file => File, args => T};
parse([], Acc) -> Acc.

usage() ->
    "usage: clojerl2 [-p DIRS] [-e EXPR]... [FILE [ARGS] | -m NS [ARGS]]\n".

run(#{help := true}) -> io:put_chars(usage());
run(#{version := true}) -> io:put_chars(unicode:characters_to_binary(["clojerl2 ", build(), "\n"]));
run(Opts) ->
    clj2_repl:setup_io(),
    clj2_rt_eval:set_source_path(source_path(Opts)),
    {ok, _} = clj2_core:ensure(),
    Args = [unicode:characters_to_binary(A) || A <- maps:get(args, Opts, [])],
    clj2_var:set_binding('clojure.core', '*command-line-args*', case Args of [] -> nil; _ -> Args end),
    [print_value(clj2_compiler:eval(unicode:characters_to_binary(E))) || E <- maps:get(exprs, Opts)],
    case Opts of
        #{main := Ns} ->
            NsA = list_to_atom(Ns),
            clj2_rt_eval:require([NsA]),
            {ok, #{vars := #{'-main' := Info}} = E} = clj2_ns:info(NsA),
            Main = clj2_rt:var_fn(maps:get(module, Info, maps:get(module, E)), '-main', Info),
            clj2_rt:invoke(Main, Args);
        #{file := File} ->
            clj2_rt_eval:load_file(File);
        #{exprs := [_ | _]} -> ok;
        _ ->
            clj2_repl:start()
    end.

print_value(nil) -> ok;
print_value(V) -> io:put_chars(standard_io, unicode:characters_to_binary([clj2_print:pr_str(V), "\n"])).

source_path(#{path := P}) -> P;
source_path(_) ->
    case os:getenv("CLJ2_PATH") of
        false -> ["src", "."];
        P -> string:split(P, ":", all)
    end.

%% @doc The commit clojerl2 was built from (ebin/clj2.build, written by
%% `make'); in a rebar3 build, the application's version.
build() ->
    File = filename:join(filename:dirname(code:which(?MODULE)), "clj2.build"),
    case file:read_file(File) of
        {ok, B} -> string:trim(B);
        {error, _} ->
            _ = application:load(clojerl2),
            case application:get_key(clojerl2, vsn) of
                {ok, V} -> unicode:characters_to_binary(V);
                undefined -> <<"dev">>
            end
    end.

%%%-------------------------------------------------------------------
%%% @doc REPL evaluation (clojerl2-023): defs at the REPL, redefinition
%%% semantics (designs/02 §5), the current namespace, require, eval
%%% module bounds, error reports, unicode text.
%%%-------------------------------------------------------------------
-module(clj2_repl_tests).

-include_lib("eunit/include/eunit.hrl").

%% each test in a fresh namespace of its own, current in this process; it
%% refers clojure.core, as one made by an ns form does ((in-ns 'x) alone
%% makes a bare one, see current_ns/0)
ev(Src) -> clj2_compiler:eval(unicode:characters_to_binary(Src)).

fresh(Ns) ->
    {ok, _} = clj2_core:ensure(),
    clj2_rt_eval:restore_ns(undefined),
    clj2_ns:remove(Ns),
    clj2_ns:ensure(Ns),
    clj2_rt_eval:in_ns(Ns).

repl_test_() ->
    {setup, fun() -> {ok, _} = clj2_core:ensure() end, fun(_) -> ok end,
     [ {"def, defn and defmacro at the REPL", fun defs/0}
     , {"redefinition: old fn values run the old code", fun redefine/0}
     , {"in-ns, ns and *ns* are per process", fun current_ns/0}
     , {"eval, read-string, load-string, macroexpand", fun eval_fns/0}
     , {"require from the source path, :as and :refer", fun require_/0}
     , {"eval modules stay bounded", fun eval_modules_bounded/0}
     , {"compile:forms runs outside the caller", fun compile_isolated/0}
     , {"error reports", fun errors/0}
     , {"unicode text", fun unicode/0}
     ]}.

defs() ->
    fresh('t.repl.defs'),
    ?assertEqual({var, nil, {'t.repl.defs', x}}, ev("(def x 41)")),
    ?assertEqual(42, ev("(inc x)")),
    ev("(defn twice [f a] (f (f a)))"),
    ?assertEqual(43, ev("(twice inc x)")),
    ev("(defmacro unless [c & body] `(if ~c nil (do ~@body)))"),
    ?assertEqual(':ok', ev("(unless false :ok)")),
    %% a def in one form is usable by the next form of the same source
    ?assertEqual(7, ev("(def seven 7) seven")),
    %% the var lives in a module of its own, registered with the namespace
    ?assertMatch({ok, #{vars := #{x := #{module := 't.repl.defs$v$x'}}}}, clj2_ns:info('t.repl.defs')),
    ?assertEqual(<<"#'t.repl.defs/x">>, clj2_print:pr_str(ev("(def x 1)"))).

redefine() ->
    fresh('t.repl.redef'),
    ev("(defn f [x] (* x 2))"),
    ev("(def g f)"),
    ev("(def h (fn [x] (f x)))"),
    ev("(defn f [x] (* x 3))"),
    %% g holds the value of f taken before: the old version's code;
    %% calls through the var (h, direct calls) reach the new one
    ?assertEqual([3, 2, 3], clj2_coll:vec_to_list(ev("[(f 1) (g 1) (h 1)]"))),
    %% BEAM keeps two versions of a module: one more redefinition purges
    %% the one g came from, and g no longer runs (designs/02 §5)
    ev("(defn f [x] (* x 4))"),
    ?assertEqual(4, ev("(h 1)")),
    ?assertError({badfun, _}, ev("(g 1)")).

current_ns() ->
    fresh('t.repl.cur'),
    ?assertEqual('t.repl.cur', ev("*ns*")),
    ?assertEqual('t.repl.other', ev("(in-ns 't.repl.other)")),
    ?assertEqual('t.repl.other', clj2_rt_eval:current_ns()),
    ev("(def here 1)"),
    ?assertMatch({ok, #{vars := #{here := _}}}, clj2_ns:info('t.repl.other')),
    %% a namespace in-ns creates refers nothing, as on the JVM, until a
    %% refer-clojure (ns and in-ns stay reachable)
    ?assertEqual(nil, ev("(clojure.core/resolve 'inc)")),
    ?assertError({clj2_compile, _, {resolve, {unresolved_symbol, inc}}}, ev("(inc 1)")),
    ?assertEqual(true, ev("(clojure.core/var? (clojure.core/resolve 'in-ns))")),
    ev("(clojure.core/refer-clojure :exclude '[dec])"),
    ?assertEqual(2, ev("(inc 1)")),
    ?assertEqual(nil, ev("(resolve 'dec)")),
    ev("(ns t.repl.third)"),
    ?assertEqual('t.repl.third', ev("*ns*")),
    ?assertEqual(1, ev("t.repl.other/here")),
    %% another process has its own *ns*
    Self = self(),
    spawn(fun() -> Self ! {ns, clj2_rt_eval:current_ns()} end),
    receive {ns, Other} -> ?assertEqual(user, Other) end,
    %% compiling a namespace binds *ns* to it only while it compiles
    {ok, _} = clj2_compiler:load_ns(<<"(ns t.repl.loaded) (defmacro which [] `'~*ns*) (def w (which))">>),
    ?assertEqual('t.repl.loaded', ev("t.repl.loaded/w")),
    ?assertEqual('t.repl.third', clj2_rt_eval:current_ns()).

eval_fns() ->
    fresh('t.repl.eval'),
    ?assertEqual(3, ev("(eval '(+ 1 2))")),
    ?assertEqual([1, 2], ev("(read-string \"(1 2) :ignored\")")),
    ?assertEqual(6, ev("(load-string \"(def a 2) (* a 3)\")")),
    ?assertEqual(['if', a, ['do', b]], ev("(macroexpand-1 '(when a b))")),
    ?assertEqual(['if', a, ['do', b]], ev("(macroexpand '(when a b))")),
    ?assertEqual(5, ev("(eval (list 'let ['x 5] 'x))")).

require_() ->
    fresh('t.repl.req'),
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "clj2_repl_tests_" ++ os:getpid()]),
    ok = filelib:ensure_dir(filename:join([Dir, "t", "x"])),
    ok = file:write_file(filename:join([Dir, "t", "req_lib.clj"]),
                         <<"(ns t.req-lib)\n(defn hello [x] (str \"hi \" x))\n(def answer 42)\n">>),
    Old = clj2_rt_eval:source_path(),
    clj2_rt_eval:set_source_path([Dir]),
    try
        clj2_ns:remove('t.req-lib'),
        ?assertEqual(nil, ev("(require '[t.req-lib :as lib :refer [hello]])")),
        ?assertEqual(<<"hi 1">>, ev("(lib/hello 1)")),
        ?assertEqual(<<"hi 2">>, ev("(hello 2)")),
        %% an ns form at the REPL requires too
        ev("(ns t.repl.req2 (:require [t.req-lib :refer [answer]]))"),
        ?assertEqual(42, ev("answer")),
        ?assertError({clj2_require, {not_found, 't.nowhere', _}}, ev("(require 't.nowhere)")),
        %% load-file: a script, form at a time
        Script = filename:join(Dir, "script.clj"),
        ok = file:write_file(Script, <<"(def s1 20)\n(+ s1 1)\n">>),
        ?assertEqual(21, clj2_rt_eval:load_file(Script))
    after
        clj2_rt_eval:set_source_path(Old),
        file:del_dir_r(Dir)
    end.

eval_modules_bounded() ->
    fresh('t.repl.gc'),
    Count = fun() -> length([M || {M, _} <- code:all_loaded(), lists:prefix("clj2_eval_", atom_to_list(M))]) end,
    [ev("(+ 1 " ++ integer_to_list(N) ++ ")") || N <- lists:seq(1, 250)],
    ?assert(Count() =< 100),
    %% a result's closure keeps working while its module is in the window
    F = ev("(fn [x] (* x 10))"),
    ?assertEqual(70, clj2_rt:invoke(F, [7])).

compile_isolated() ->
    fresh('t.repl.iso'),
    Before = lists:sort([K || {K, _} <- get()]),
    ev("(defn iso [x] x) (iso 1)"),
    After = lists:sort([K || {K, _} <- get()]),
    %% only dynamic bindings (*ns*) and lazy-seq memos (per process by
    %% design, designs/03 §5.3) may appear in the caller's dictionary
    ?assertEqual([], [K || K <- After -- Before,
                           not is_tuple(K) orelse not lists:member(element(1, K), [clj2_dyn, clj2_lazy])]).

errors() ->
    Report = fun(Src) ->
                     try ev(Src), no_error
                     catch C:R:S -> unicode:characters_to_binary(clj2_repl:format_error(C, R, S))
                     end
             end,
    fresh('t.repl.err'),
    ?assertMatch(<<"Syntax error compiling at (REPL:1:1).\nUnable to resolve symbol: nope", _/binary>>,
                 Report("nope")),
    ev("(defn one [a] a)"),
    ?assertMatch(<<"Syntax error compiling", _/binary>>, Report("(one 1 2)")),
    ?assertMatch(<<"Execution error (ExceptionInfo)", _/binary>>, Report("(throw (ex-info \"boom\" {}))")),
    ?assertMatch(<<"Execution error (error:badarith)", _/binary>>, Report("(/ 1 0)")).

unicode() ->
    fresh('t.repl.utf'),
    ?assertEqual(<<"中文"/utf8>>, ev("(str \"中\" \"文\")")),
    ?assertEqual(2, ev("(count \"中文\")")),
    ?assertEqual(<<"\"你好\""/utf8>>, ev("(pr-str \"你好\")")),
    ?assertEqual(<<"你好"/utf8>>, ev("(with-out-str (print \"你好\"))")),
    ?assertEqual(<<"#'t.repl.utf/名字"/utf8>>, clj2_print:pr_str(ev("(def 名字 1)"))),
    %% keywords read from source, format padding counts characters
    ?assertEqual(<<":中文"/utf8>>, clj2_print:pr_str(ev(":中文"))),
    ?assertEqual(<<"中文"/utf8>>, ev("(name :中文)")),
    ?assertEqual(<<"[   中|文 ]"/utf8>>, ev("(format \"[%4s|%-2s]\" \"中\" \"文\")")),
    %% the printer's fallback (~tp) must not break on code points > 255
    ?assertMatch(<<_/binary>>, clj2_print:pr_str({some_tag, [20013, 25991]})).

%%%-------------------------------------------------------------------
%%% @doc Tests for the nanopass framework, the pass chain and the
%%% absform emitter. The "probe" group pins the bugs found in the
%%% retired Scheme-layer stage0 (designs/08 §5) so they cannot come
%%% back in the Clojure pipeline.
%%%-------------------------------------------------------------------
-module(clj2_compiler_tests).

-include_lib("eunit/include/eunit.hrl").

%% a toy pass for fixpoint_test/0
-export([pass/0, run/2]).

ev(S) -> clj2_compiler:eval(list_to_binary(S)).

%% compile error reason, without the position
cerr(S) ->
    try ev(S), no_error
    catch error:{clj2_compile, _Pos, Why} -> Why
    end.

%%====================================================================
%% Framework
%%====================================================================

lang_extends_test() ->
    L0 = clj2_lang:get(l0),
    L1 = clj2_lang:get(l1),
    L3 = clj2_lang:get(l3),
    ?assertEqual(expr, clj2_np:nonterminal_of(L0, sym)),
    ?assertEqual(none, clj2_np:nonterminal_of(L1, sym)),
    ?assertEqual(expr, clj2_np:nonterminal_of(L1, local)),
    ?assertEqual(none, clj2_np:nonterminal_of(L3, letfn)),
    ?assertEqual(none, clj2_np:nonterminal_of(L3, recur)),
    ?assertEqual(expr, clj2_np:nonterminal_of(L3, group_ref)),
    %% inherited unchanged
    ?assertEqual(expr, clj2_np:nonterminal_of(L3, 'if')).

check_accepts_and_rejects_test() ->
    L1 = clj2_lang:get(l1),
    A = erl_anno:new(1),
    Good = {eval, A, {'if', A, {local, A, {x, 1}}, {const, A, 1}, {const, A, nil}}},
    ?assertEqual(ok, clj2_np:check(L1, Good)),
    %% an unresolved symbol is not L1
    Bad = {eval, A, {'if', A, {sym, A, x}, {const, A, 1}, {const, A, nil}}},
    ?assertError({clj2_np, {bad_tree, l1, [{eval, 1}, {'if', 1}], {op_not_in_nonterminal, expr, sym}}},
                 clj2_np:check(L1, Bad)),
    %% wrong field count
    ?assertError({clj2_np, {bad_tree, l1, [{eval, 1}], {bad_arity, expr, 'if', 3, _}}},
                 clj2_np:check(L1, {eval, A, {'if', A, {const, A, 1}}})),
    %% an expression is not a top-level node
    ?assertError({clj2_np, {bad_tree, l1, [], {op_not_in_nonterminal, top, const}}},
                 clj2_np:check(L1, {const, A, 1})).

descend_auto_passthrough_test() ->
    %% a "pass" that only knows `const' still rebuilds every other node
    L0 = clj2_lang:get(l0),
    A = erl_anno:new(1),
    T = {do, A, [{const, A, 1}], {'if', A, {const, A, 2}, {const, A, 3}, {sym, A, s}}},
    Inc = fun Inc({const, CA, N}, D) when is_integer(N) -> {const, CA, N + D};
              Inc(N, D) -> clj2_np:descend(L0, #{expr => Inc}, N, D)
          end,
    ?assertEqual({do, A, [{const, A, 11}], {'if', A, {const, A, 12}, {const, A, 13}, {sym, A, s}}},
                 Inc(T, 10)),
    ?assertEqual(6, clj2_np:fold(L0, fun(_, Acc) -> Acc + 1 end, 0, T)).

pipeline_checks_every_boundary_test() ->
    %% every pass output is validated against its `out' language
    ?assertEqual(42, clj2_compiler:eval(<<"(let* [x 42] x)">>, #{check => true})).

deterministic_build_test() ->
    Src = <<"(ns det.ns) (def x (erlang/+ 1 2))\n"
            "(def f (fn* f [n] (letfn* [g (fn* [m] (if (erlang/== m 0) :done (g (erlang/- m 1))))] (g n))))">>,
    {ok, _, _, B1} = clj2_compiler:compile_ns(Src),
    {ok, _, _, B2} = clj2_compiler:compile_ns(Src),
    ?assertEqual(B1, B2).

anno_reaches_beam_test() ->
    Forms = clj2_compiler:forms(<<"\n\n  (erlang/error :here)">>, anno),
    {function, _, run, 0, [{clause, _, _, _, [Call]}]} = lists:keyfind(function, 1, Forms),
    ?assertEqual({3, 3}, erl_anno:location(element(2, Call))).

%%====================================================================
%% Semantics
%%====================================================================

truthiness_test_() ->
    [ ?_assertEqual(':y', ev("(if 0 :y :n)"))
    , ?_assertEqual(':y', ev("(if () :y :n)"))
    , ?_assertEqual(':y', ev("(if \"\" :y :n)"))
    , ?_assertEqual(':n', ev("(if nil :y :n)"))
    , ?_assertEqual(':n', ev("(if false :y :n)"))
    , ?_assertEqual(nil, ev("(if false :y)"))
    ].

constants_test_() ->
    [ ?_assertEqual(nil, ev(""))
    , ?_assertEqual(nil, ev("(do)"))
    , ?_assertEqual(<<"s">>, ev("\"s\""))
    , ?_assertEqual([1, a, ':k'], ev("'(1 a :k)"))
    , ?_assertEqual([], ev("()"))
    , ?_assertEqual(3, ev("1 2 3"))
    ].

let_and_closures_test_() ->
    [ ?_assertEqual(3, ev("(let* [x 1 y (erlang/+ x 2)] y)"))
    , ?_assertEqual(2, ev("(let* [x 1 x (erlang/+ x 1)] x)"))
    , ?_assertEqual(42, ev("(((fn* [x] (fn* [y] (erlang/+ x y))) 40) 2)"))
    , ?_assertEqual(7, ev("(let* [f (fn* [x] (erlang/* x x))] (erlang/+ (f 2) 3))"))
    ].

loop_recur_test_() ->
    [ ?_assertEqual(499999500000,
                    ev("(loop* [i 0 acc 0] (if (erlang/< i 1000000) "
                       "(recur (erlang/+ i 1) (erlang/+ acc i)) acc))"))
      %% recur in a fn clause
    , ?_assertEqual(120, ev("((fn* [n acc] (if (erlang/== n 0) acc "
                            "(recur (erlang/- n 1) (erlang/* acc n)))) 5 1)"))
      %% recur in a variadic clause passes the rest arg as one value
    , ?_assertEqual([3], ev("((fn* [x & r] (if r r (recur x '(3)))) 1)"))
      %% recur targets the innermost loop
    , ?_assertEqual(6, ev("(loop* [i 0 s 0] (if (erlang/< i 3) "
                          "(recur (erlang/+ i 1) (erlang/+ s (loop* [j 0] (if (erlang/< j 2) (recur (erlang/+ j 1)) j)))) s))"))
    ].

arities_test_() ->
    F = "(fn* ([] :zero) ([x] x) ([x y & r] r))",
    [ ?_assertEqual(':zero', ev("(" ++ F ++ ")"))
    , ?_assertEqual(1, ev("(" ++ F ++ " 1)"))
    , ?_assertEqual(nil, ev("(" ++ F ++ " 1 2)"))
    , ?_assertEqual([3, 4], ev("(" ++ F ++ " 1 2 3 4)"))
    , ?_assertEqual(nil, ev("((fn* [& r] r))"))
    , ?_assertError({clj2_arity, 1, _}, ev("((fn* ([] 0) ([a b] 2)) 1)"))
    , ?_assertError({clj2_not_ifn, 1}, ev("(1 2)"))
      %% single fixed-arity fn is a plain Erlang fun (platform interop)
    , ?_assertEqual([2, 4], ev("(lists/map (fn* [x] (erlang/* 2 x)) '(1 2))"))
      %% self-named fns
    , ?_assertEqual(6, ev("((fn* fact [n] (if (erlang/== n 0) 1 (erlang/* n (fact (erlang/- n 1))))) 3)"))
    , ?_assertEqual(1, ev("((fn* f ([] (f 1)) ([x] x)))"))
    ].

letfn_test_() ->
    EvenOdd = "(letfn* [ev? (fn* [n] (if (erlang/== n 0) true (od? (erlang/- n 1)))) "
              "od? (fn* [n] (if (erlang/== n 0) false (ev? (erlang/- n 1))))] ",
    [ ?_assertEqual(true, ev(EvenOdd ++ "(ev? 10))"))
      %% members call each other in tail position: constant stack
    , ?_assertEqual(false, ev(EvenOdd ++ "(ev? 1000001))"))
      %% members capture outer locals
    , ?_assertEqual(15, ev("(let* [k 5] (letfn* [f (fn* [x] (erlang/* k x))] (f 3)))"))
    , ?_assertEqual(':done', ev("(letfn* [f (fn* [n] (if (erlang/== n 0) :done (g n))) "
                                "g (fn* [n] (f (erlang/- n 1)))] (f 5))"))
    ].

try_test_() ->
    [ ?_assertEqual(':boom', ev("(try (throw :boom) (catch :error e e))"))
    , ?_assertEqual(1, ev("(try (erlang/throw 1) (catch :throw e e))"))
    , ?_assertEqual(bye, ev("(try (erlang/exit 'bye) (catch :exit e e))"))
    , ?_assertEqual(x, ev("(try (erlang/throw 'x) (catch :error e :wrong) (catch :default e e))"))
    , ?_assertEqual(5, ev("(try 5 (finally (erlang/put :k 1)))"))
    , ?_assertError(':up', ev("(try (throw :up) (catch :throw e e))"))
    ].

%%====================================================================
%% Probes: bugs of the retired stage0 (sk_emit), re-expressed in Clojure
%%====================================================================

probe_test_() ->
    [ %% outer bindings survive a try (sk: PostEnv started from #{})
      ?_assertEqual(5, ev("(let* [x 5] (try 1 (catch :default e 0)) x)"))
    , ?_assertEqual(5, ev("(let* [x 5] (try 1 (finally 2)) x)"))
      %% repeated and nested conditionals (sk: hard-coded 'Val' → unsafe_var)
    , ?_assertEqual(3, ev("(let* [a false b 3] (if a a b) (if a a b))"))
    , ?_assertEqual(3, ev("(let* [a false b false c 3] (if (if a a b) (if a a b) c))"))
      %% statements inside arguments keep their order (sk: reversed Pre)
    , ?_assertEqual(3, ev("(erlang/+ (let* [x 1 y (erlang/+ x 1)] y) (do (erlang/put :p 1) 1))"))
    , ?_assertEqual(3, ev("(erlang/+ (if true 1 2) (if false 1 2))"))
      %% fn bodies with inner fns / lets inside letfn (sk: unbound_outer)
    , ?_assertEqual(0, ev("(letfn* [f (fn* [n] (if (erlang/== n 0) 0 ((fn* [y] (f y)) (erlang/- n 1))))] (f 3))"))
    , ?_assertEqual(':done', ev("(letfn* [f (fn* [n] (let* [m (erlang/- n 1)] (if (erlang/< m 0) :done (f m))))] (f 3))"))
      %% values of a try used afterwards (sk: unsafe_var across try)
    , ?_assertEqual(9, ev("(let* [r (try 9 (catch :default e 0))] r)"))
    , ?_assertEqual(9, ev("(let* [r (try (throw 9) (catch :error e e))] r)"))
    ].

%%====================================================================
%% Compile errors
%%====================================================================

errors_test_() ->
    [ ?_assertEqual({resolve, {unresolved_symbol, nope}}, cerr("nope"))
    , ?_assertEqual({resolve, {erlang_fun_needs_call_position, 'lists/map'}}, cerr("lists/map"))
    , ?_assertEqual({recur, recur_without_target}, cerr("(recur 1)"))
    , ?_assertEqual({recur, recur_not_in_tail_position},
                    cerr("(loop* [i 0] (erlang/+ 1 (recur i)))"))
    , ?_assertEqual({recur, {recur_arity, 1, 2}}, cerr("(loop* [i 0] (recur 1 2))"))
    , ?_assertEqual({recur, recur_across_try}, cerr("(loop* [i 0] (try (recur i)))"))
    , ?_assertEqual({syntax, duplicate_fn_arity}, cerr("(fn* ([x] 1) ([y] 2))"))
    , ?_assertEqual({syntax, {bad_catch_class, 'Foo'}}, cerr("(try 1 (catch Foo e e))"))
    , ?_assertEqual({syntax, {not_at_top_level, ns}}, cerr("(let* [a 1] (ns t.nope))"))
      %% a tagged literal with no reader function compiles, and raises when
      %% evaluated (so a file that mentions one still loads)
    , ?_assertEqual(<<"No reader function for tag inst">>,
                    ev("(try #inst \"2020-01-01\" (catch Throwable e (ex-message e)))"))
    , ?_assertMatch({syntax, {bad_regex, <<"(">>, _}}, cerr("#\"(\""))
      %% positions are reported
    , ?_assertError({clj2_compile, {2, 3}, {resolve, {unresolved_symbol, nope}}},
                    ev("\n  nope"))
    ].

%%====================================================================
%% Framework: includes, fixpoint, diff-languages
%%====================================================================

includes_test() ->
    L5 = clj2_lang:get(l5),
    A = erl_anno:new(1),
    %% a triv (local) is accepted where an expr is expected
    ?assertEqual(ok, clj2_np:check(L5, {eval, A, {local, A, {x, 1}}})),
    %% ...but an expr is not accepted where a triv is (ANF invariant)
    Nested = {invoke, A, {local, A, {f, 1}}, [{invoke, A, {local, A, {g, 2}}, []}]},
    ?assertError({clj2_np, {bad_tree, l5, [{eval, 1}, {invoke, 2}, 1],
                            {op_not_in_nonterminal, triv, invoke}}},
                 clj2_np:check(L5, {eval, A, Nested})).

%% a toy pass for the fixpoint combinator: counts an integer down
pass() -> #{name => count_down, in => l0, out => l0}.
run(N, St) when N > 0 -> {N - 1, St#{rounds => maps:get(rounds, St, 0) + 1}};
run(N, St) -> {N, St}.

fixpoint_test() ->
    Run = fun(Max) ->
                  clj2_np:run([{fixpoint, [?MODULE], #{max_iter => Max}}], 5,
                              #{check => false, state => #{}})
          end,
    ?assertMatch({0, #{rounds := 5}}, Run(10)),     % stops once unchanged
    ?assertMatch({2, #{rounds := 3}}, Run(3)).      % or at max_iter

diff_languages_test() ->
    D = clj2_np:diff_languages(clj2_lang:get(l2), clj2_lang:get(l3)),
    ?assertEqual(#{added => [fn_group, group_ref], removed => [letfn], changed => []},
                 maps:get(expr, D)),
    ?assertNot(maps:is_key(clause, D)).

%%====================================================================
%% case*
%%====================================================================

case_test_() ->
    F = "(fn* [x] (case* x 1 :one (2 3) :two-three \"s\" :str [1 2] :vec {:a 1} :map :d))",
    C = fun(Arg) -> ev("(" ++ F ++ " " ++ Arg ++ ")") end,
    [ ?_assertEqual(':one', C("1"))
    , ?_assertEqual(':two-three', C("3"))
    , ?_assertEqual(':str', C("\"s\""))
    , ?_assertEqual(':vec', C("[1 2]"))
    , ?_assertEqual(':map', C("{:a 1}"))
      %% a map constant matches only an equal map (no subset matching)
    , ?_assertEqual(':d', C("{:a 1 :b 2}"))
    , ?_assertEqual(':d', C("1.0"))
    , ?_assertEqual(<<"No matching clause: 9">>, ev("(try ((fn* [x] (case* x 1 :one)) 9) (catch IllegalArgumentException e (ex-message e)))"))
      %% recur from a case branch is in tail position
    , ?_assertEqual(':done', ev("(loop* [i 0] (case* i 3 :done (recur (erlang/+ i 1))))"))
    , ?_assertEqual({syntax, duplicate_case_test}, cerr("(case* 1 1 :a (2 1) :b)"))
    ].

%%====================================================================
%% const-fold, ANF, verify
%%====================================================================

run_body(Src) ->
    Forms = clj2_compiler:forms(list_to_binary(Src), cf),
    {function, _, run, 0, [{clause, _, _, _, Body}]} = lists:keyfind(function, 1, Forms),
    Body.

const_fold_test_() ->
    [ ?_assertMatch([{integer, _, 1}], run_body("(if true 1 2)"))
    , ?_assertMatch([{integer, _, 2}], run_body("(if nil 1 2)"))
    , ?_assertMatch([{integer, _, 3}], run_body("(erlang/+ 1 2)"))
    , ?_assertMatch([{integer, _, 6}], run_body("(let* [x 2 y x] (erlang/* y 3))"))
    , ?_assertMatch([{atom, _, ':b'}], run_body("(case* 2 1 :a 2 :b)"))
    , ?_assertMatch([{integer, _, 6}], run_body("(if (erlang/== (erlang/+ 1 1) 2) (erlang/* 2 3) 0)"))
      %% a failing pure call is not folded: the error stays at run time
    , ?_assertError(badarith, ev("(erlang/+ 1 :a)"))
    ].

%% Clojure evaluates arguments left to right; ANF makes that explicit
%% (Erlang leaves call-argument order unspecified).
anf_order_test() ->
    Log = ev("(do (erlang/put :log '()) "
             "(erlang/tuple_size (erlang/make_tuple 0 "
             "  (do (erlang/put :log (lists/append (erlang/get :log) '(1))) 0))) "
             "(erlang/setelement 1 (erlang/make_tuple 1 nil)"
             "  (do (erlang/put :log (lists/append (erlang/get :log) '(2))) 0))"
             "(lists/append (do (erlang/put :log (lists/append (erlang/get :log) '(3))) '())"
             "              (do (erlang/put :log (lists/append (erlang/get :log) '(4))) '()))"
             "(erlang/get :log))"),
    ?assertEqual([1, 2, 3, 4], Log).

verify_test_() ->
    L5 = clj2_lang:get(l5),
    A = erl_anno:new(1),
    Run = fun(T) -> clj2_np:check(L5, T), clj2_p_verify:run([T], #{}) end,
    Twice = {eval, A, {'let', A, [{bind, A, {x, 1}, {const, A, 1}}],
                       {'let', A, [{bind, A, {x, 1}, {const, A, 2}}], {local, A, {x, 1}}}}},
    Escaped = {eval, A, {do, A, [{'let', A, [{bind, A, {x, 1}, {const, A, 1}}], {const, A, nil}}],
                         {local, A, {x, 1}}}},
    [ ?_assertError({clj2_compile, _, {verify, {bound_twice, {x, 1}}}}, Run(Twice))
    , ?_assertError({clj2_compile, _, {verify, {out_of_scope, {x, 1}}}}, Run(Escaped))
    ].

%% release mode: inline and const-fold enable each other in the
%% fixpoint group
inline_test_() ->
    Body = fun(Src, Mode) ->
                   Forms = clj2_compiler:forms(list_to_binary(Src), inl, #{mode => Mode}),
                   {function, _, run, 0, [{clause, _, _, _, B}]} = lists:keyfind(function, 1, Forms),
                   B
           end,
    Src = "((fn* [x] (erlang/+ x 1)) 2)",
    [ ?_assertMatch([{integer, _, 3}], Body(Src, release))
    , ?_assertNotMatch([{integer, _, 3}], Body(Src, dev))
      %% a loop that never recurs becomes a let
    , ?_assertMatch([{integer, _, 1}], Body("(loop* [i 1] i)", release))
      %% a recurring loop is kept
    , ?_assertEqual(10, clj2_compiler:eval(<<"(loop* [i 0] (if (erlang/< i 10) (recur (erlang/+ i 1)) i))">>,
                                           #{mode => release}))
    , ?_assertEqual(3, clj2_compiler:eval(<<"((fn* [a b] (erlang/- a b)) (erlang/+ 2 3) 2)">>,
                                          #{mode => release}))
    ].

%%====================================================================
%% Labs, trace, positions, M2 acceptance
%%====================================================================

labs_guard_sublanguage_test() ->
    Labs = clj2_lang:get(labs),
    A = erl_anno:new(1),
    Clause = fun(G) -> {efunction, A, f, 1,
                        [{eclause, A, [{evar, A, {x, 1}}], [[G]], [{elit, A, ok}]}]} end,
    ?assertEqual(ok, clj2_np:check(Labs, Clause({gcall, A, is_function, [{evar, A, {x, 1}}]}))),
    %% a remote call is not a guard: a grammar error, before erl_lint
    ?assertError({clj2_np, {bad_tree, labs, _, {op_not_in_nonterminal, eguard, eremote}}},
                 clj2_np:check(Labs, Clause({eremote, A, m, f, []}))),
    ?assertError({clj2_np, {bad_tree, labs, _, {bad_terminal, gbif, put}}},
                 clj2_np:check(Labs, Clause({gcall, A, put, [{elit, A, 1}]}))).

trace_test() ->
    Self = self(),
    Names = [parse, resolve, validate_recur, lower_loop, lower_letfn, link, const_fold,
             normalize_anf, verify, lower_labs, emit],
    3 = clj2_compiler:eval(<<"(erlang/+ 1 2)">>,
                           #{trace => Names,
                             trace_fun => fun(N, Out, _) -> Self ! {traced, N, Out} end}),
    Got = fun G(Acc) -> receive {traced, N, O} -> G([{N, O} | Acc]) after 0 -> lists:reverse(Acc) end end([]),
    %% each pass once, in order; const_fold may run several rounds (fixpoint)
    FirstSeen = lists:foldl(fun(P, Acc) -> case lists:member(P, Acc) of
                                               true -> Acc;
                                               false -> Acc ++ [P]
                                           end
                            end, [], Got),
    ?assertEqual([{parse, l0}, {resolve, l1}, {validate_recur, l1}, {lower_loop, l2},
                  {lower_letfn, l3}, {link, l4}, {const_fold, l4}, {normalize_anf, l5},
                  {verify, l5}, {lower_labs, labs}, {emit, absform}],
                 FirstSeen),
    ?assert(length(Got) - length(FirstSeen) =< 7).   % extra const_fold rounds only

%% Source positions survive to the BEAM line table (designs/02 §4)
line_in_stacktrace_test() ->
    Src = <<"(ns t.line)\n\n(def f (fn* []\n  (erlang/error :here)))\n">>,
    {ok, Ns} = clj2_compiler:load_ns(Src),
    try
        try 't.line':f() of _ -> error(no_exception)
        catch error:':here':St ->
                [{_, f, 0, Info} | _] = St,
                ?assertEqual(4, proplists:get_value(line, Info)),
                ?assertEqual("t.line.clj", proplists:get_value(file, Info))
        end
    after
        clj2_ns:remove(Ns), code:purge(Ns), code:delete(Ns), code:purge(Ns)
    end.

%% M2 acceptance (designs/04 §7, clojerl2-010): reader → pass chain →
%% absform → compile:forms → beam → ERTS, (f 1) returns 2.
m2_acceptance_test() ->
    {ok, Ns} = clj2_compiler:load_ns(<<"(ns t.m2) (def f (fn* [x] (erlang/+ x 1)))">>),
    try
        ?assertEqual(2, 't.m2':f(1)),
        ?assertEqual(2, clj2_compiler:eval(<<"(t.m2/f 1)">>))
    after
        clj2_ns:remove(Ns), code:purge(Ns), code:delete(Ns), code:purge(Ns)
    end.

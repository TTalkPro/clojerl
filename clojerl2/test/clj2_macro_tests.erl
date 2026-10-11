%%%-------------------------------------------------------------------
%%% @doc Macros: defmacro, form-at-a-time expansion, syntax-quote.
%%%-------------------------------------------------------------------
-module(clj2_macro_tests).

-include_lib("eunit/include/eunit.hrl").

load(Src) ->
    {ok, Ns} = clj2_compiler:load_ns(list_to_binary(Src)),
    Ns.

unload(Ns) ->
    clj2_ns:remove(Ns),
    M = clj2_ns:module(Ns),
    code:purge(M), code:delete(M), code:purge(M).

with_ns(Srcs, Tests) ->
    {setup,
     fun() -> [load(S) || S <- Srcs] end,
     fun(Nss) -> [unload(N) || N <- lists:reverse(Nss)] end,
     Tests}.

ev(Src) -> clj2_compiler:eval(list_to_binary(Src)).
ev(Src, Ns) -> clj2_compiler:eval(list_to_binary(Src), #{ns => Ns}).

cerr(Src) ->
    try clj2_compiler:compile_ns(list_to_binary(Src)), no_error
    catch error:{clj2_compile, _, Why} -> Why
    end.

-define(M1,
        "(ns t.m1)\n"
        %% used in the same file, right after its definition
        "(defmacro unless [c & body] `(if ~c nil (do ~@body)))\n"
        "(def f (fn* [x] (unless x :no)))\n"
        %% a helper defined earlier runs at expansion time
        "(def square (fn* [n] (erlang/* n n)))\n"
        "(defmacro sq [n] (square n))\n"
        "(def nine (sq 3))\n"
        %% defn, written as a macro
        "(defmacro defn [name & fdecl] `(def ~name (fn* ~name ~@fdecl)))\n"
        "(defn fact [n] (if (erlang/== n 0) 1 (erlang/* n (fact (erlang/- n 1)))))\n"
        "(defn arities ([] 0) ([a] 1) ([a & r] r))\n"
        %% hygiene: x# does not capture the caller's x
        "(defmacro inc1 [v] `(let* [x# ~v] (erlang/+ x# 1)))\n"
        "(defn hyg [] (let* [x 10] (inc1 x)))\n"
        %% recursive, multi-arity, variadic
        "(defmacro my-and ([] true) ([x] x) ([x & r] `(let* [a# ~x] (if a# (my-and ~@r) a#))))\n"
        "(defn and3 [a b c] (my-and a b c))\n"
        %% &env and &form
        "(defmacro nlocals [] (maps/size (erlang/element 3 &env)))\n"
        "(defn two-locals [] (let* [a 1 b 2] (nlocals)))\n"
        "(defmacro form-len [& _] (erlang/length &form))\n"
        "(def three (form-len x y))\n"
        %% locals shadow macros
        "(defn shadow [] (let* [unless (fn* [a b] :fn)] (unless 1 2)))\n"
        %% a macro that defines a macro
        "(defmacro defconst [n v] `(defmacro ~n [] ~v))\n"
        "(defconst five 5)\n"
        "(def k (five))\n"
        %% collections built by a macro and by literals
        "(defmacro pair [a b] [a b])\n"
        "(defn mk-pair [x] (pair x (erlang/+ x 1)))\n").

-define(M2,
        "(ns t.m2 (:require [t.m1 :as m :refer [unless]]))\n"
        "(def g (fn* [x] (unless x :refer)))\n"
        "(def h (fn* [x] (m/unless x :alias)))\n"
        "(def i (fn* [] (m/fact 4)))\n").

same_ns_test_() ->
    with_ns([?M1],
            [ ?_assertEqual(':no', 't.m1':f(false))
            , ?_assertEqual(nil, 't.m1':f(true))
            , ?_assertEqual(9, 't.m1':nine())
            , ?_assertEqual(120, 't.m1':fact(5))
            , ?_assertEqual(0, 't.m1':arities())
            , ?_assertEqual([2, 3], 't.m1':arities(1, [2, 3]))
            , ?_assertEqual(11, 't.m1':hyg())
            , ?_assertEqual(3, 't.m1':and3(1, 2, 3))
            , ?_assertEqual(false, 't.m1':and3(1, false, 3))
              %% &env: a, b, and the fn's own name (defn makes a named fn*)
            , ?_assertEqual(3, 't.m1':'two-locals'())
            , ?_assertEqual(3, 't.m1':three())
            , ?_assertEqual(':fn', 't.m1':shadow())
            , ?_assertEqual(5, 't.m1':k())
            , ?_assertEqual({vector, nil, {1, 2}}, 't.m1':'mk-pair'(1))
              %% macros are registered as such
            , ?_assertMatch({ok, #{vars := #{unless := #{macro := true, kind := fn, variadic := 3},
                                             f := #{macro := false}}}},
                            clj2_ns:info('t.m1'))
              %% compile-time segments are gone after the compile
            , ?_assertEqual(false, code:is_loaded('t.m1$ct1'))
            ]).

other_ns_test_() ->
    with_ns([?M1, ?M2],
            [ ?_assertEqual(':refer', 't.m2':g(false))
            , ?_assertEqual(':alias', 't.m2':h(false))
            , ?_assertEqual(24, 't.m2':i())
              %% eval in a namespace sees its macros
            , ?_assertEqual(':no', ev("(unless false :no)", 't.m1'))
            , ?_assertEqual(':no', ev("(t.m1/unless false :no)"))
            ]).

macroexpand_test_() ->
    with_ns([?M1],
            [ ?_assertEqual(['if', c, nil, [do, a, b]],
                            clj2_compiler:macroexpand_1([unless, c, a, b], 't.m1'))
            , ?_assertEqual([foo, x], clj2_compiler:macroexpand_1([foo, x], 't.m1'))
            ]).

syntax_quote_test_() ->
    [ ?_assertEqual(['user/a', 'user/b'], ev("`(a b)"))
      %% special forms and keywords stay; Erlang-qualified symbols stay
    , ?_assertEqual(['if', ':k', 'lists/map', nil], ev("`(if :k lists/map nil)"))
    , ?_assertEqual([1, 2, 3, 4], ev("(let* [x 1 ys '(2 3)] `(~x ~@ys 4))"))
    , ?_assertEqual({vector, nil, {1, 2}}, ev("(let* [x 2] `[1 ~x])"))
    , ?_assertEqual({map, nil, #{':a' => 1}}, ev("(let* [x 1] `{:a ~x})"))
      %% the same x# within one syntax-quote is one symbol
    , ?_assertMatch([S, S], ev("`(x# x#)"))
    , ?_assertEqual({vector, nil, {}}, ev("`[]"))
    ].

literals_test_() ->
    [ ?_assertEqual({vector, nil, {1, 2}}, ev("[1 (erlang/+ 1 1)]"))
    , ?_assertEqual({vector, nil, {1, 2}}, ev("[1 2]"))
    , ?_assertEqual({map, nil, #{':a' => 2}}, ev("{:a (erlang/+ 1 1)}"))
    , ?_assertEqual({set, nil, #{1 => nil}}, ev("#{1}"))
    , ?_assertEqual({vector, nil, {a, {vector, nil, {b}}}}, ev("'[a [b]]"))
    , ?_assertEqual(3, ev("(#(erlang/+ %1 %2) 1 2)"))
      %% a constant literal is built from its elements' values
    , ?_assertEqual({map, nil, #{':a' => [1]}}, ev("{:a '(1)}"))
    , ?_assertEqual({vector, nil, {[quote, x]}}, ev("'['x]"))
    ].

deterministic_test() ->
    {ok, _, _, B1} = clj2_compiler:compile_ns(list_to_binary(?M1)),
    {ok, _, _, B2} = clj2_compiler:compile_ns(list_to_binary(?M1)),
    ?assertEqual(B1, B2).

%% top-level forms before a defmacro run at compile time (JVM Clojure
%% also loads what it compiles); a failure there is a compile error
compile_time_failure_test() ->
    ?assertMatch({driver, {compile_time_load_failed, {error, ':early', _}}},
                 cerr("(ns t.ct) (throw :early) (defmacro m [] 1)")),
    ?assertEqual(false, code:is_loaded('t.ct$ct1')).

errors_test_() ->
    with_ns([?M1],
            [ ?_assertMatch({macroexpand, boom, {error, ':bad'}},
                            cerr("(ns t.e) (defmacro boom [] (throw :bad)) (def x (boom))"))
            , ?_assertEqual({resolve, {cannot_take_value_of_macro, unless}},
                            cerr("(ns t.e (:require [t.m1 :refer [unless]])) (def x (fn* [] unless))"))
            , ?_assertEqual({syntax, {not_at_top_level, defmacro}},
                            cerr("(ns t.e) (def x (fn* [] (defmacro m [] 1)))"))
            , ?_assertEqual({syntax, unquote_outside_syntax_quote}, cerr("(ns t.e) (def x ~y)"))
            , ?_assertEqual({syntax, ns_must_be_first_form}, cerr("(def h 1) (ns t.e)"))
            , ?_assertEqual(false, code:is_loaded('t.e$ct1'))
            ]).

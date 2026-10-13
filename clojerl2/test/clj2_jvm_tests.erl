%%%-------------------------------------------------------------------
%%% @doc The JVM interop syntax that is kept (clj2_jvm, clojerl2-053):
%%% deftype/defrecord methods and fields, exceptions, BigDecimal, writers,
%%% toString/equals/hashCode. Java classes (String, Math, Long ...) are not.
%%%-------------------------------------------------------------------
-module(clj2_jvm_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.jvm'}).

pr(Src) -> clj2_print:pr_str(ev(Src)).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.jvm').

statics_test() ->
    setup(),
    ?assertEqual(<<"0">>, ev("(str BigDecimal/ZERO)")),
    ?assertEqual(<<"1.5M">>, pr("(BigDecimal/valueOf 1.5)")),
    %% Java classes' statics are gone: Erlang and Clojure do that work
    [?assertMatch({'clojure.lang.ExceptionInfo', _, _}, catch_error(S))
     || S <- ["(Math/sqrt 16)", "Long/MAX_VALUE", "(Integer/parseInt \"42\")", "(System/getProperty \"x\")"]],
    ?assertEqual(4.0, ev("(math/sqrt 16)")),
    ?assertEqual(42, ev("(parse-long \"42\")")).

methods_test() ->
    setup(),
    ?assertEqual('t.jvm.P', ev("(do (defrecord P [x]) (class (->P 1)))")),
    ?assertEqual(1, ev("(.-x (->P 1))")),
    ?assertEqual(<<"#t.jvm.P{:x 1}">>, ev("(.toString (->P 1))")),
    ?assertEqual(true, ev("(.equals (->P 1) (->P 1))")),
    %% a deftype's protocol methods
    ?assertEqual(3, ev("(do (defprotocol Sz (size [x])) (deftype Bag [n] Sz (size [_] n)) (.size (Bag. 3)))")),
    ?assertEqual(<<"m">>, ev("(.getMessage (ex-info \"m\" {}))")),
    ?assertEqual(<<"1.50">>, ev("(.toPlainString (.setScale 1.5M 2))")),
    %% an io device as a writer
    ?assertEqual(<<"ab">>, ev("(with-out-str (.write *out* \"a\") (.append *out* \\b))")),
    %% a member on a local of the same name as a class is an instance call
    ?assertEqual(<<"x">>, ev("(let [String (->P \"x\")] (.-x String))")),
    %% syntax-quote leaves member and class symbols alone
    ?assertEqual(<<"(.toUpperCase String)">>, pr("`(.toUpperCase String)")),
    %% String's methods are not provided: clojure.string does that work
    ?assertMatch({'clojure.lang.ExceptionInfo', _, _}, catch_error("(.toUpperCase \"abc\")")),
    ?assertMatch({'clojure.lang.ExceptionInfo', _, _}, catch_error("(.foo 1)")).

constructors_test() ->
    setup(),
    ?assertEqual(<<"boom">>, ev("(try (throw (Exception. \"boom\")) (catch Exception e (ex-message e)))")),
    ?assertEqual(<<"[java.lang.IllegalArgumentException \"bad\"]">>,
                 pr("(try (throw (new IllegalArgumentException \"bad\"))"
                    "  (catch IllegalArgumentException e [(class e) (.getMessage e)]))")),
    %% catch selects by class: an ArithmeticException is not caught as one
    ?assertEqual(<<":outer">>,
                 pr("(try (try (throw (IllegalStateException. \"s\")) (catch ArithmeticException _ :inner))"
                    "  (catch RuntimeException _ :outer))")),
    ?assertEqual(<<"#t.jvm.Q{:a 1}">>, pr("(do (defrecord Q [a]) (new Q 1))")),
    ?assertEqual(<<"2.5M">>, pr("(BigDecimal. \"2.5\")")),
    [?assertMatch({'clojure.lang.ExceptionInfo', _, _}, catch_error(S))
     || S <- ["(StringBuilder. \"a\")", "(java.util.ArrayList.)", "(java.util.Date.)"]].

catch_error(Src) ->
    try ev(Src) of V -> {no_error, V}
    catch error:R -> R
    end.

%%%-------------------------------------------------------------------
%%% @doc JVM interop syntax over host shims (clj2_jvm): expected values
%%% are what Clojure 1.12 on the JVM gives.
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
    ?assertEqual(4.0, ev("(Math/sqrt 16)")),
    ?assertEqual(9223372036854775807, ev("Long/MAX_VALUE")),
    ?assertEqual(9223372036854775807, ev("(. Long MAX_VALUE)")),
    ?assertEqual(-2147483648, ev("Integer/MIN_VALUE")),
    ?assertEqual(42, ev("(Integer/parseInt \"42\")")),
    ?assertEqual(255, ev("(Long/parseLong \"ff\" 16)")),
    ?assertEqual(255, ev("(java.lang.Long/parseLong \"ff\" 16)")),
    ?assertEqual(1000.0, ev("(Double/parseDouble \"1e3\")")),
    ?assertEqual(<<"ff">>, ev("(Long/toHexString 255)")),
    ?assertEqual(<<"ffffffffffffffff">>, ev("(Long/toHexString -1)")),
    ?assertEqual(-4, ev("(Math/floorDiv -7 2)")),
    ?assertEqual(1, ev("(Math/floorMod -7 2)")),
    ?assertEqual(3, ev("(Math/round 2.5)")),
    ?assertEqual(true, ev("(Character/isDigit \\5)")),
    ?assertEqual(true, ev("(Character/isLetter \\中)")),
    ?assertEqual(<<"\n">>, ev("(System/getProperty \"line.separator\")")).

methods_test() ->
    setup(),
    ?assertEqual(<<"ABC">>, ev("(.toUpperCase \"abc\")")),
    ?assertEqual(<<"ABC">>, ev("(. \"abc\" toUpperCase)")),
    ?assertEqual(<<"bc">>, ev("(. \"abc\" (substring 1))")),
    ?assertEqual(<<"el">>, ev("(.substring \"hello\" 1 3)")),
    ?assertEqual(<<"BC">>, ev("(.. \"abc\" toUpperCase (substring 1))")),
    ?assertEqual(3, ev("(.length \"日本語\")")),
    ?assertEqual(2, ev("(.indexOf \"hello\" \"l\")")),
    ?assertEqual(-1, ev("(.indexOf \"hello\" \"z\")")),
    ?assertEqual(true, ev("(.startsWith \"hello\" \"he\")")),
    ?assertEqual(<<"a-b">>, ev("(.replace \"a b\" \" \" \"-\")")),
    ?assertEqual(-1, ev("(.compareTo \"a\" \"b\")")),
    ?assertEqual(3, ev("(.size [1 2 3])")),
    ?assertEqual(2, ev("(.get [1 2 3] 1)")),
    ?assertEqual(1, ev("(.intValue 1.9)")),
    ?assertEqual(<<"t.jvm.P">>, ev("(do (defrecord P [x]) (.getName (class (->P 1))))")),
    ?assertEqual(1, ev("(.-x (->P 1))")),
    %% a member on a local of the same name as a class is an instance call
    ?assertEqual(<<"X">>, ev("(let [String \"x\"] (.toUpperCase String))")),
    %% syntax-quote leaves member and class symbols alone
    ?assertEqual(<<"Q">>, ev("(do (defmacro up [s] `(.toUpperCase ~s)) (up \"q\"))")),
    ?assertEqual(<<"(.toUpperCase String)">>, pr("`(.toUpperCase String)")),
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
    ?assertEqual(<<"For input string: \"x\"">>,
                 ev("(try (Integer/parseInt \"x\") (catch NumberFormatException e (.getMessage e)))")),
    ?assertEqual(<<"ab1">>, ev("(str (doto (StringBuilder. \"a\") (.append \"b\") (.append 1)))")),
    ?assertEqual(<<"#t.jvm.Q{:a 1}">>, pr("(do (defrecord Q [a]) (new Q 1))")).

catch_error(Src) ->
    try ev(Src) of V -> {no_error, V}
    catch error:R -> R
    end.

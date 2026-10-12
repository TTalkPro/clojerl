%%%-------------------------------------------------------------------
%%% @doc def/defn metadata, fn conditions, vars as fns and protocol
%%% dispatch on JVM classes and interfaces: expected values are what
%%% Clojure 1.12 on the JVM gives.
%%%-------------------------------------------------------------------
-module(clj2_defs_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.defs'}).

pr(Src) -> clj2_print:pr_str(ev(Src)).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.defs').

def_meta_test() ->
    setup(),
    %% metadata values are evaluated when the def runs; constants stay
    ?assertEqual(true, ev("(do (def ^{:af rest} mv 1) (fn? (:af (meta (var mv)))))")),
    ?assertEqual(3, ev("(do (def ^{:k (+ 1 2)} mv2 1) (:k (meta (var mv2))))")),
    ?assertEqual(<<"[:a 1]">>, pr("(do (def ^{:v [:a 1]} mv3 1) (:v (meta (var mv3))))")),
    %% defn: {:doc} then the attr-map, then :arglists unless given
    ?assertEqual(<<"attr">>, ev("(do (defn tam \"docstring\" {:doc \"attr\"} [x] x) (:doc (meta (var tam))))")),
    ?assertEqual(<<"[\"d\" 42 ([x])]">>,
                 pr("(do (defn fdm \"d\" {:attr 42} [x] x) [(:doc (meta (var fdm))) (:attr (meta (var fdm))) (:arglists (meta (var fdm)))])")),
    ?assertEqual(<<"([a b] [a b & c])">>, pr("(do (defn ar ([a b] a) ([a b & c] b)) (:arglists (meta (var ar))))")),
    ?assertEqual(<<"([custom])">>, pr("(do (defn fdm1 {:arglists '([custom])} [x] x) (:arglists (meta (var fdm1))))")),
    ?assertEqual(<<"([test & body])">>, pr("(:arglists (meta (var when)))")),
    ?assertEqual(<<"([a b])">>, pr("(do (defmacro mq2 [a b] a) (:arglists (meta (var mq2))))")).

conditions_test() ->
    setup(),
    ev("(defn pp [x] {:pre [(pos? x)] :post [(> % 10)]} (* x 100))"),
    ?assertEqual(100, ev("(pp 1)")),
    ?assertEqual(<<"Assert failed: (pos? x)">>, ev("(try (pp -1) (catch AssertionError e (ex-message e)))")),
    ?assertEqual(<<"Assert failed: (> % 10)">>,
                 ev("(try ((fn [x] {:post [(> % 10)]} x) 1) (catch AssertionError e (ex-message e)))")),
    %% a lone map is the body, not conditions
    ?assertEqual(<<"{:pre 1}">>, pr("((fn [] {:pre 1}))")),
    ?assertEqual(<<":ae">>, pr("(try (assert false) (catch AssertionError _ :ae))")).

misc_test() ->
    setup(),
    ?assertEqual(42, ev("(do (def vf (fn [x] (inc x))) ((var vf) 41))")),
    ?assertEqual(<<"{}">>, pr("(ex-data (ex-info \"m\" nil))")),
    ?assertEqual(<<"{:a 1}">>, pr("(conj {:a 1} nil)")),
    ?assertEqual(<<"()">>, pr("(sort-by first nil)")),
    ?assertEqual(<<"No matching clause: 3">>,
                 ev("(try (case 3 1 :a 2 :b) (catch IllegalArgumentException e (ex-message e)))")),
    ?assertEqual(<<"%">>, ev("(name '%)")),
    ?assertEqual(false, ev("(= {:b nil} {})")),
    ?assertEqual(<<"{:k 9}">>, pr("(meta (into (empty (with-meta {:a 1} {:k 9})) {:b 2}))")),
    ?assertEqual(<<"{:k 9}">>, pr("(meta (pop (with-meta [1 2] {:k 9})))")),
    ?assertEqual(<<"{:k 9}">>, pr("(meta (disj (with-meta #{1 2} {:k 9}) 2))")),
    ?assertEqual(<<"[0]">>, pr("(subvec [0 1 2] 0.5 1.33)")),
    ?assertEqual(':ioobe', ev("(try (subvec [0 1 2 3] 1 5) (catch IndexOutOfBoundsException _ :ioobe))")),
    ?assertEqual(<<"[:a :b]">>, pr("(vec (sort (keys (filter (fn [e] true) {:a 1 :b 2}))))")),
    ?assertEqual(':cce', ev("(try (vec (keys [\"ab\"])) (catch ClassCastException _ :cce))")),
    ?assertEqual(<<"[:npe true]">>, pr("[(try (the-ns nil) (catch NullPointerException _ :npe)) (try (ns-name 42) false (catch ClassCastException _ true))]")),
    ?assertEqual(<<"9223372036854775808N">>, pr("9223372036854775808")),
    ?assertEqual(<<"9223372036854775808">>, ev("(str 9223372036854775808)")),
    ?assertEqual(<<"(:msig :nsig)">>, pr("(do (defprotocol Psig (msig [this] [this a] \"m doc\") (nsig [this])) (sort (keys (:sigs Psig))))")),
    ?assertEqual(<<"m doc">>, ev("(:doc (:msig (:sigs Psig)))")).

numbers_test() ->
    setup(),
    ?assertEqual(<<"[123 3]">>, pr("[(bigint \"123\") (bigint 7/2)]")),
    ?assertEqual(':t', ev("(try (parse-long 42) (catch IllegalArgumentException _ :t))")),
    ?assertEqual(<<"[3.0 -31.0 1.5 nil 0.5]">>,
                 pr("[(parse-double \"0x1.8p1\") (parse-double \"-0x1fp0\") (Double/parseDouble \"1.5d\") (parse-double \"abc\") (parse-double \".5\")]")),
    ?assertEqual(<<"[:nfe :nfe 127]">>,
                 pr("[(try (Long/parseLong \"9223372036854775808\") (catch NumberFormatException _ :nfe))"
                    " (try (Byte/decode \"0x80\") (catch NumberFormatException _ :nfe)) (Byte/decode \"0x7f\")]")).

alias_refer_test() ->
    setup(),
    ?assertEqual(<<"1,2">>, ev("(do (require 'clojure.string) (alias 'st 'clojure.string) (st/join \",\" [1 2]))")),
    ?assertEqual(7, ev("(load-string \"(ns t.ola1) (defn olf [] 7) (ns t.olb1 (:require [t.ola1 :refer :all])) (olf)\")")).

class_designators_test() ->
    setup(),
    ev("(do (defprotocol Pe (pe [x])) (extend-protocol Pe Map (pe [m] :map) Number (pe [n] :num)"
       "  clojure.lang.IPersistentVector (pe [v] :vec) Object (pe [o] :obj)))"),
    ?assertEqual(<<"[:map :map :num :num :vec :obj]">>,
                 pr("[(pe {:a 1}) (pe (sorted-map 1 2)) (pe 1) (pe 1.5) (pe [1]) (pe \"s\")]")),
    %% a type of the namespace wins over a JVM class of the same name
    ?assertEqual(':mine', ev("(do (defrecord Range [a]) (extend-protocol Pe Range (pe [x] :mine)) (pe (->Range 1)))")),
    %% an impl added later is seen by values that fell back before
    ?assertEqual(':set', ev("(do (pe #{}) (extend-protocol Pe java.util.Set (pe [s] :set)) (pe #{}))")).

arrays_and_vars_test() ->
    setup(),
    ?assertEqual(<<"[[0 5 0] 3 (1 2 44) [\"a\" \"b\"] [2 4 6]]">>,
                 pr("(let [a (long-array 3)] (aset a 1 5)"
                    " [(vec a) (alength a) (seq (byte-array [1 2 300])) (vec (into-array [\"a\" \"b\"]))"
                    "  (vec (amap (int-array [1 2 3]) i r (* 2 (aget r i))))])")),
    ?assertEqual('[J', ev("(class (long-array 1))")),
    ?assertEqual(<<"Index 5 out of bounds for length 1">>,
                 ev("(try (aget (long-array 1) 5) (catch ArrayIndexOutOfBoundsException e (ex-message e)))")),
    ?assertEqual(<<"[10 2]">>, pr("(with-local-vars [x 1 y 2] (var-set x 10) [(var-get x) @y])")),
    ev("(def ^:dynamic *wb* 1)"),
    ?assertEqual(<<"[2 [3 1]]">>,
                 pr("[(with-bindings* {(var *wb*) 2} (fn [] *wb*))"
                    " (do (push-thread-bindings {(var *wb*) 3}) (let [v *wb*] (pop-thread-bindings) [v *wb*]))]")),
    ?assertEqual(<<"(\"A\" \"B\")">>, pr("(map (memfn toUpperCase) [\"a\" \"b\"])")).

extend_test() ->
    setup(),
    ev("(defprotocol PX (mx [x]) (nx [x y]))"),
    ev("(extend String PX {:mx (fn [s] (str \"s:\" s)) :nx (fn [s y] [s y])})"),
    ev("(extend nil PX {:mx (fn [_] :nil)})"),
    ?assertEqual(<<"[\"s:a\" [\"a\" 1] :nil true]">>, pr("[(mx \"a\") (nx \"a\" 1) (mx nil) (satisfies? PX \"x\")]")),
    ?assertEqual(true, ev("(contains? (set (extenders PX)) java.lang.String)")).

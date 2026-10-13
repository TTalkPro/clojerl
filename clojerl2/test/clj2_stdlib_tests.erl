%%%-------------------------------------------------------------------
%%% @doc The standard library namespaces ported for the clojure-test-suite
%%% gate (clojerl2-022): clojure.test, clojure.walk, clojure.template,
%%% clojure.set; the namespace reflection functions (resolve, ns-publics,
%%% intern ...) they lean on; and the literals the runtime has no value
%%% for (##NaN, 1.5M, #inst), which read and raise when evaluated.
%%%-------------------------------------------------------------------
-module(clj2_stdlib_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.stdlib'}).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.stdlib').

plain(X) ->
    case clj2_coll:is_vector(X) orelse is_list(X) orelse (is_tuple(X) andalso element(1, X) =:= lazy_seq) of
        true -> [plain(Y) || Y <- clj2_coll:to_list(X)];
        false -> X
    end.

%% deftest / is / are / testing / thrown? / fixtures / run-tests: the
%% summary counts and the fixture order
clojure_test_test() ->
    setup(),
    ev("(require '[clojure.test :as t :refer [deftest is are testing use-fixtures]])"),
    ev("(def log (atom []))"),
    ev("(use-fixtures :once (fn [f] (swap! log conj :once) (f)))"),
    ev("(use-fixtures :each (fn [f] (swap! log conj :each) (f)))"),
    ev("(deftest t-arith"
       "  (testing \"common\""
       "    (are [in ex] (= ex (abs in)) -1 1 1 1)"
       "    (is (= 4 (+ 2 2)))"
       "    (is (= 5 (+ 2 2)) \"deliberate\")"
       "    (is (thrown? ArithmeticException (/ 1 0)))"
       "    (is (thrown? Exception (/ 1 0)))"
       "    (is (thrown? NoSuchClass (throw (ex-info \"x\" {}))))"
       "    (is (thrown-with-msg? ExceptionInfo #\"boo\" (throw (ex-info \"boom\" {}))))"
       "    (is (instance? String \"s\"))"
       "    (is (throw (ex-info \"err\" {})))))"),
    ev("(deftest t-two (is (= 1 1)))"),
    %% a test is a var whose :test metadata runs it, and the var calls test-var
    ?assertEqual(true, ev("(fn? (:test (meta (var t-arith))))")),
    ev("(def summary (atom nil))"),
    Out = ev("(with-out-str (binding [t/*test-out* *out*]"
             "  (reset! summary (t/run-tests 't.stdlib))))"),
    ?assertEqual([2, 8, 2, 1], plain(ev("[(:test @summary) (:pass @summary) (:fail @summary) (:error @summary)]"))),
    ?assertEqual(false, ev("(t/successful? @summary)")),
    ?assertEqual([':once', ':each', ':each'], plain(ev("@log"))),
    ?assert(binary:match(Out, <<"FAIL in (t-arith)">>) =/= nomatch),
    ?assert(binary:match(Out, <<"deliberate">>) =/= nomatch),
    ?assert(binary:match(Out, <<"ERROR in (t-arith)">>) =/= nomatch),
    ?assert(binary:match(Out, <<"Ran 2 tests containing 11 assertions.">>) =/= nomatch),
    %% a redefined test replaces its registry entry: still 2 tests
    ev("(deftest t-two (is (= 2 2)))"),
    ev("(with-out-str (binding [t/*test-out* *out*] (reset! summary (t/run-tests 't.stdlib))))"),
    ?assertEqual(2, ev("(:test @summary)")),
    %% test-var on one var, and an assert-expr extension (the suite's p/thrown?)
    ev("(defmethod t/assert-expr 'my-thrown? [msg form]"
       "  `(try ~@(rest form) (t/do-report {:type :fail :message ~msg :expected '~form :actual nil})"
       "        (catch Throwable e# (t/do-report {:type :pass :message ~msg :expected '~form :actual e#}) e#)))"),
    ev("(deftest t-ext (is (my-thrown? (/ 1 0))) (is (my-thrown? 1)))"),
    ev("(with-out-str (binding [t/*test-out* *out* t/*report-counters* (atom t/*initial-report-counters*)]"
       "  (t/test-var (var t-ext)) (reset! summary @t/*report-counters*)))"),
    ?assertEqual([1, 1, 1], plain(ev("[(:test @summary) (:pass @summary) (:fail @summary)]"))).

walk_template_set_test() ->
    setup(),
    ev("(require '[clojure.walk :as w] '[clojure.template :as tp] '[clojure.set :as s])"),
    ?assertEqual([2, 3, [4, 5]], plain(ev("(w/postwalk (fn [x] (if (number? x) (inc x) x)) [1 2 [3 4]])"))),
    ?assertEqual([':a', ':b'], plain(ev("(w/postwalk-replace '{x :a y :b} '[x y])"))),
    ?assertEqual(true, ev("(= {:a {:b 1}} (w/keywordize-keys {\"a\" {\"b\" 1}}))")),
    ?assertEqual(true, ev("(= '(do (+ 4 2) (+ 5 3)) (macroexpand '(tp/do-template [x y] (+ y x) 2 4 3 5)))")),
    ?assertEqual(true, ev("(= #{1 2 3} (s/union #{1} #{2} #{3}))")),
    ?assertEqual(true, ev("(= #{2} (s/intersection #{1 2} #{2 3}))")),
    ?assertEqual(true, ev("(= #{1} (s/difference #{1 2} #{2}))")),
    ?assertEqual(true, ev("(= #{{:a 1 :b 2 :c 3}} (s/join #{{:a 1 :b 2}} #{{:a 1 :c 3}}))")),
    ?assertEqual(true, ev("(= {1 :a} (s/map-invert {:a 1}))")),
    ?assertEqual([true, false], plain(ev("[(s/subset? #{1} #{1 2}) (s/superset? #{1} #{1 2})]"))).

reflection_test() ->
    setup(),
    ev("(def pub 1) (defn- priv [] 2) (def ^:dynamic *d* 3)"),
    ?assertEqual(true, ev("(var? (resolve 'pub))")),
    ?assertEqual(nil, ev("(resolve 'no-such-thing)")),
    ?assertEqual('java.lang.String', ev("(resolve 'String)")),
    ?assertEqual(3, ev("((var-get (resolve 'inc)) 2)")),
    ?assertEqual(3, ev("((var-get (ns-resolve 'clojure.core 'inc)) 2)")),
    %% a symbol the env binds resolves to nothing
    ?assertEqual([nil, true], plain(ev("[(resolve '{pub 1} 'pub) (some? (ns-resolve *ns* {} 'pub))]"))),
    ?assertEqual([true, false, true], plain(ev("[(contains? (ns-publics 't.stdlib) 'pub)"
                                                 " (contains? (ns-publics 't.stdlib) 'priv)"
                                                 " (contains? (ns-interns 't.stdlib) 'priv)]"))),
    ?assertEqual([true, true], plain(ev("[(contains? (ns-map 't.stdlib) 'pub) (contains? (ns-map 't.stdlib) 'inc)]"))),
    ?assertEqual(true, ev("(contains? (ns-refers 't.stdlib) 'inc)")),
    ev("(require '[clojure.string :as st])"),
    ?assertEqual(true, ev("(= 'clojure.string (get (ns-aliases 't.stdlib) 'st))")),
    ?assertEqual(true, ev("(var? (ns-resolve 't.stdlib 'st/upper-case))")),
    ev("(ns-unalias 't.stdlib 'st)"),
    ?assertEqual(nil, ev("(get (ns-aliases 't.stdlib) 'st)")),
    ?assertEqual(41, ev("(do (intern 't.stdlib 'iv 41) (var-get (find-var 't.stdlib/iv)))")),
    ?assertEqual(40, ev("(do (intern 't.stdlib 'ivf (fn [x] (* x 10))) (ivf 4))")),
    ?assertEqual([false, true], plain(ev("[(bound? (intern 't.stdlib 'unb)) (bound? (var pub))]"))),
    ?assertEqual(nil, ev("(find-var 't.stdlib/nope)")),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':data' := {map, _, #{':type' := ':IllegalArgumentException'}}}},
                 ev("(find-var 'unqualified)")),
    ?assertEqual(nil, ev("(do (ns-unmap 't.stdlib 'pub) (resolve 'pub))")),
    ?assertEqual(nil, ev("(do (create-ns 'gone.ns) (remove-ns 'gone.ns) (find-ns 'gone.ns))")),
    ?assertEqual(<<"A">>, ev("((requiring-resolve 'clojure.string/upper-case) \"a\")")),
    ?assertError({'clojure.lang.ExceptionInfo', _, _}, ev("(requiring-resolve 'unqualified)")),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':data' := {map, _, #{':type' := ':NullPointerException'}}}},
                 ev("(resolve nil)")),
    %% a compiled namespace registers its ns form's aliases and refers
    ok = file:write_file("/tmp/clj2_stdlib_tests_reg.clj",
                         <<"(ns t.reg (:require [clojure.string :as s :refer [join]])) (defn f [] (s/upper-case (join [\"a\" \"b\"])))">>),
    ev("(load-file \"/tmp/clj2_stdlib_tests_reg.clj\")"),
    ?assertEqual(true, ev("(= 'clojure.string (get (ns-aliases 't.reg) 's))")),
    ?assertEqual(true, ev("(= (ns-resolve 'clojure.string 'join) (get (ns-refers 't.reg) 'join))")),
    file:delete("/tmp/clj2_stdlib_tests_reg.clj").

%% ##NaN and #inst are read, print as read, and raise when evaluated (as a
%% case constant they match nothing); 1.5M is a BigDecimal
unsupported_literals_test() ->
    setup(),
    ?assertEqual(':ArithmeticException', ev("(try ##NaN (catch ArithmeticException e (:type (ex-data e))))")),
    ?assertEqual(<<"1.5M">>, ev("(pr-str 1.5M)")),            % a BigDecimal now (clojerl2-037)
    ?assertEqual(<<"No reader function for tag foo">>,
                 ev("(try #foo \"2010-11-12\" (catch Throwable e (ex-message e)))")),
    ?assertEqual(1289520000000, ev("(inst-ms #inst \"2010-11-12\")")),   % #inst is a Date (clojerl2-039)
    ?assertEqual(<<"##NaN 4.0M #foo \"x\"">>, ev("(pr-str '##NaN '4.0M '#foo \"x\")")),
    ?assertEqual(':one', ev("(case 1 ##Inf :inf 4.0M :bd 1 :one :d)")),
    ?assertEqual(':d', ev("(case 4 ##Inf :inf ##-Inf :ninf :d)")),
    %% a macro sees them as read
    ?assertEqual(':tagged', ev("(do (defmacro kind [x] (if (vector? x) :vec :tagged)) (kind ##NaN))")).

%% transient refuses what the JVM refuses, without realizing a lazy seq
transient_test() ->
    setup(),
    ?assertEqual(':cce', ev("(try (transient (sorted-map :a 1)) (catch ClassCastException e :cce))")),
    ?assertEqual(':cce', ev("(try (transient (range)) (catch ClassCastException e :cce))")),
    ?assertEqual([1, 2], plain(ev("(persistent! (conj! (transient [1]) 2))"))),
    ?assertEqual(':iae', ev("(try (apply assoc {:a 1} [:b 2 :c]) (catch IllegalArgumentException e :iae))")),
    ?assertEqual(':cce', ev("(try (assoc #{1} 1 2) (catch ClassCastException e :cce))")).

%% refer, refer-clojure, use, the ns form's :refer-clojure filters, ns-unmap
%% of a referred name, and private vars across namespaces
refer_test() ->
    setup(),
    %% :exclude / :only / :rename, seen by the compiler, resolve and ns-map
    ?assertEqual(true, ev("(= [nil nil false (var clojure.core/filter)]"
                          "   (load-string \"(ns t.rf1 (:refer-clojure :exclude [map]))"
                          "     [(resolve 'map) (ns-resolve 't.rf1 'map) (contains? (ns-map 't.rf1) 'map) (resolve 'filter)]\"))")),
    ?assertEqual(true, ev("(= '[t.rf1/map clojure.core/filter] (load-string \"(in-ns 't.rf1) [`map `filter]\"))")),
    ?assertEqual(true, ev("(= [nil (var clojure.core/map) [2 3]]"
                          "   (load-string \"(ns t.rf2 (:refer-clojure :rename {map core-map}))"
                          "     [(resolve 'map) (resolve 'core-map) (core-map inc [1 2])]\"))")),
    ?assertEqual(true, ev("(= [nil (var clojure.core/prn)]"
                          "   (load-string \"(ns t.rf3 (:refer-clojure :only [prn resolve])) [(resolve 'map) (resolve 'prn)]\"))")),
    %% an excluded name used before the namespace defines it does not compile
    ?assertError({clj2_compile, _, {resolve, {unresolved_symbol, get}}},
                 ev("(load-string \"(ns t.rf4 (:refer-clojure :exclude [get])) (defn probe [] (get {:a 1} :a))\")")),
    %% a later refer-clojure adds what it maps
    ?assertEqual(true, ev("(= [true nil] (load-string \"(ns t.rf5 (:refer-clojure :only [inc]))"
                          "  (clojure.core/refer-clojure :exclude '[dec])"
                          "  [(clojure.core/some? (clojure.core/resolve 'map)) (clojure.core/resolve 'dec)]\"))")),
    %% refer and use
    ev("(load-string \"(ns t.rf-src) (def helper 9) (defn- hid [] 1)\")"),
    ?assertEqual(9, ev("(load-string \"(ns t.rf6 (:use [t.rf-src])) helper\")")),
    ?assertEqual(nil, ev("(load-string \"(ns t.rf7) (refer 't.rf-src) (resolve 'hid)\")")),
    ?assertEqual(9, ev("(load-string \"(ns t.rf8) (refer 't.rf-src :rename '{helper h}) h\")")),
    ?assertEqual([<<"IllegalAccessError">>, <<"nope does not exist">>],
                 plain(ev("(load-string \"(ns t.rf9) (try (refer 't.rf-src :only '[nope]) :ok"
                          "  (catch Throwable e [(.getSimpleName (class e)) (ex-message e)]))\")"))),
    ?assertEqual([<<"IllegalAccessError">>, <<"hid is not public">>],
                 plain(ev("(load-string \"(ns t.rf10) (try (refer 't.rf-src :only '[hid]) :ok"
                          "  (catch Throwable e [(.getSimpleName (class e)) (ex-message e)]))\")"))),
    ?assertEqual(<<"nope2 does not exist">>,
                 ev("(try (require '[clojure.string :refer [nope2]]) :ok (catch Throwable e (ex-message e)))")),
    %% ns-unmap takes away an implicit clojure.core refer too
    ?assertEqual(nil, ev("(load-string \"(ns t.rf11) (ns-unmap *ns* 'map) (resolve 'map)\")")),
    %% another namespace's private fn and macro are refused; (var ns/x) reaches it
    ev("(load-string \"(ns t.rf-priv) (defn- pf [] :reached) (defmacro ^:private pm [] :pm)\")"),
    ?assertError({clj2_compile, _, {resolve, {not_public, <<"var: t.rf-priv/pf is not public">>}}},
                 ev("(load-string \"(ns t.rf12) (map t.rf-priv/pf [1])\")")),
    ?assertError({clj2_compile, _, {resolve, {not_public, <<"var: #'t.rf-priv/pf is not public">>}}},
                 ev("(load-string \"(ns t.rf13) (t.rf-priv/pf)\")")),
    ?assertError({clj2_compile, _, {resolve, {not_public, <<"var: #'t.rf-priv/pm is not public">>}}},
                 ev("(load-string \"(ns t.rf14) (t.rf-priv/pm)\")")),
    ?assertEqual(':reached', ev("(load-string \"(ns t.rf15) (@#'t.rf-priv/pf)\")")).

%% read-string expands syntax-quote as the JVM reader does, keeps reader
%% metadata on collections; alter-meta! :macro makes a var a macro
read_and_macro_meta_test() ->
    setup(),
    ?assertEqual(true, ev("(= '(quote clojure.core/map) (read-string \"`map\"))")),
    ?assertEqual(true, ev("(= '(quote t.stdlib/nope) (read-string \"`nope\"))")),
    ?assertEqual(true, ev("(= {:k 1} (meta (read-string \"^{:k 1} [1]\")))")),
    ev("(defmacro amac1 [x] (list (quote +) x 1))"),
    ev("(def amac2 @#'amac1)"),
    ev("(alter-meta! #'amac2 merge (meta #'amac1))"),
    ?assertEqual(6, ev("(amac2 5)")).

%% def inside an expression: the var exists when the form compiles, the
%% root is set when the def runs, the value is the var (clj2_p_parse
%% nested_def/3)
nested_def_test() ->
    setup(),
    ev("(let [c (atom 0)] (defn nd-counter [] (swap! c inc)))"),
    ?assertEqual([1, 2], plain(ev("[(nd-counter) (nd-counter)]"))),
    ?assertEqual(true, ev("(var? (def nd-v 2))")),
    ?assertEqual(2, ev("nd-v")),
    %% compiling it interns the var; running it binds the root
    ev("(defn nd-make [] (def nd-made 42) :ok)"),
    ?assertEqual(false, ev("(bound? #'nd-made)")),
    ?assertEqual([':ok', 42], plain(ev("[(nd-make) nd-made]"))),
    ev("(when false (defn nd-never [] 1))"),
    ?assertEqual(false, ev("(bound? #'nd-never)")),
    %% an existing fn var is redefined
    ev("(defn nd-twice [] 1)"),
    ev("(when true (defn nd-twice [] 2))"),
    ?assertEqual(2, ev("(nd-twice)")),
    %% a nested def of a var that exists keeps it until it runs
    ev("(def nd-keep 7)"),
    ev("(when false (def nd-keep 8))"),
    ?assertEqual(7, ev("nd-keep")),
    ev("(let [x 5] (defmulti nd-mm (fn [v] (if (> v x) :big :small))))"),
    ev("(defmethod nd-mm :big [_] :big)"),
    ev("(defmethod nd-mm :small [_] :small)"),
    ?assertEqual([':small', ':big'], plain(ev("[(nd-mm 1) (nd-mm 9)]"))),
    ev("(dotimes [i 3] (def nd-last i))"),
    ?assertEqual(2, ev("nd-last")),
    ev("(let [d 1] (defn nd-doc \"the doc\" [] d))"),
    ?assertEqual(<<"the doc">>, ev("(:doc (meta #'nd-doc))")),
    %% in a namespace file, also after a compile-time segment (defmacro)
    ok = file:write_file("/tmp/clj2_nested_def_ns.clj",
                         <<"(ns t.nested-file) (let [c (atom 10)] (defn tick [] (swap! c inc)))"
                           " (defmacro m [] 1) (when (= 1 (m)) (def flag :set)) (dotimes [i 2] (def last-i i))">>),
    ev("(load-file \"/tmp/clj2_nested_def_ns.clj\")"),
    ?assertEqual([11, ':set', 1], plain(ev("[(t.nested-file/tick) t.nested-file/flag t.nested-file/last-i]"))),
    file:delete("/tmp/clj2_nested_def_ns.clj").

%% a nested def of a fn the same file defined above: calls inside the
%% file, from fns defined before it, and from outside all see the new fn
%% (the var keeps its value in the var table); name metadata survives the
%% defining macros
nested_redefinition_and_name_meta_test() ->
    setup(),
    ok = file:write_file("/tmp/clj2_redef_ns.clj",
                         <<"(ns t.redef-file) (defn f [] 1) (defn g [] (f)) (when true (defn f [] 2))"
                           " (defmacro m [] :m) (def inside [(f) (g)])">>),
    ev("(load-file \"/tmp/clj2_redef_ns.clj\")"),
    ?assertEqual([[2, 2], 2, 2], plain(ev("[t.redef-file/inside (t.redef-file/f) (t.redef-file/g)]"))),
    file:delete("/tmp/clj2_redef_ns.clj"),
    ev("(defn ^:private nm-p1 [] 1)"),
    ev("(defn ^{:doc \"d1\"} nm-p2 [] 1)"),
    ev("(defmulti ^:private nm-p3 identity)"),
    ev("(defonce ^:private nm-p4 1)"),
    ?assertEqual([true, <<"d1">>, true, true],
                 plain(ev("[(:private (meta #'nm-p1)) (:doc (meta #'nm-p2)) (:private (meta #'nm-p3)) (:private (meta #'nm-p4))]"))).


%% clojerl2-042 follow-up: type and extension forms inside expressions,
%% mutable deftype fields
expression_type_forms_test() ->
    setup(),
    ev("(defprotocol EtP (etp [x]))"),
    ?assertEqual([false, ':s'], plain(ev("(let [a (satisfies? EtP \"s\")] (extend-protocol EtP String (etp [x] :s)) [a (etp \"q\")])"))),
    ?assertEqual(2, ev("(let [_ (defrecord EtR [a b])] (:b (->EtR 1 2)))")),
    ev("(defprotocol EtCnt (et-inc! [c]) (et-cur [c]))"),
    ev("(deftype EtCounter [^:volatile-mutable n] EtCnt (et-inc! [c] (set! n (inc n)) c) (et-cur [c] n))"),
    ?assertEqual(2, ev("(let [c (EtCounter. 0)] (et-inc! c) (et-inc! c) (et-cur c))")).

%% clojerl2-042: the remaining pending categories - read/read+string,
%% for, cond->, definline, print-method, *print-meta*, #error, local vars,
%% Var methods, JVM docstrings, eduction, format, atom options, records
pending_sweep_test() ->
    setup(),
    ?assertEqual([[1, 2], [1, <<" rest">>], [42, <<"42">>], [0, 1, 2, 3, 4], [1, 3]],
                 plain(ev("[(with-in-str \"1 2\" [(read) (read)]) (with-in-str \"1 rest\\nnext\" [(read) (read-line)])"
                          " (with-in-str \"42 x\" (read+string))"
                          " (for [x (range 10) :let [y (* x 2)] :while (< y 10)] x) (for [x (range 10) :when (odd? x) :while (< x 5)] x)]"))),
    ev("(definline sw-sq [x] `(* ~x ~x))"),
    ev("(defrecord SwPt [x y])"),
    ev("(defmethod print-method SwPt [r w] (.write w (str \"<\" (:x r) \">\")))"),
    ?assertEqual([9, <<"[<1>]">>, <<"^{:k 1} [1]">>, <<"clojure.lang.ExceptionInfo: boom {:a 1}">>, true],
                 plain(ev("[(sw-sq 3) (pr-str [(->SwPt 1 2)]) (binding [*print-meta* true] (pr-str (with-meta [1] {:k 1})))"
                          " (str (ex-info \"boom\" {:a 1})) (clojure.string/starts-with? (pr-str (ex-info \"x\" {})) \"#error\")]"))),
    ev("(remove-method print-method SwPt)"),
    ?assertEqual([[1, 2, 1], [true, true], true, true],
                 plain(ev("[(let [v (with-local-vars [x nil] x)] (alter-var-root v (constantly 1)) [(deref v) (with-bindings {v 2} (deref v)) (deref v)])"
                          " (with-local-vars [x 1] [(thread-bound? x) (bound? x)])"
                          " (string? (:doc (meta #'map))) (identical? > (var-get #'>))]"))),
    ?assertEqual([':uoe', [2, 3, 4], <<"0x000000ff">>, <<"0x1.0p1">>, [{map, nil, #{':m' => 1}}, true, true], {map, nil, #{':b' => 2}}],
                 plain(ev("[(try (count (eduction (map inc) [1 2 3])) (catch UnsupportedOperationException _ :uoe)) (vec (eduction (map inc) [1 2 3]))"
                          " (format \"%#010x\" 255) (format \"%.1a\" 1.9999)"
                          " (let [a (atom 1 :meta {:m 1})] [(meta a) (map? (->SwPt 1 2)) (coll? (->SwPt 1 2))])"
                          " (.-__extmap (assoc (->SwPt 1 2) :b 2))]"))).

%% clojerl2-041: host types - Keyword methods, Murmur3, charsets, Thread,
%% Executors, Iterator, interface tags on deftype/defrecord, ISeq deftypes
host_types_test() ->
    setup(),
    ?assertEqual([x, <<"y">>, <<"x">>, 1871679806, -1640530378],
                 plain(ev("[(.sym :x) (.getName :x/y) (.getNamespace :x/y) (clojure.lang.Murmur3/hashLong 42) (clojure.lang.Util/hashCombine 17 42)]"))),
    ?assertEqual([<<"\x{e9}"/utf8>>, [97, 16#FFFD, 16#FFFD, 98], [-23], ':ue'],
                 plain(ev("[(String. (byte-array [233]) \"windows-1252\") (mapv int (String. (byte-array [97 -64 -81 98]) \"UTF-8\"))"
                          " (vec (.getBytes (String. (byte-array [-61 -87]) \"UTF-8\") \"windows-1252\"))"
                          " (try (String. (byte-array [1]) \"NOPE\") (catch java.io.UnsupportedEncodingException _ :ue))]"))),
    ?assertEqual([1, [3, [1, 2]], true],
                 plain(ev("(do (def ^:dynamic *ht* 1)"
                          " (binding [*ht* 2] (let [r (atom nil) t (Thread. (fn [] (reset! r *ht*)))] (.start t) (.join t)"
                          " [@r (let [ex (java.util.concurrent.Executors/newFixedThreadPool 2) fs (.invokeAll ex [(fn [] 1) (fn [] 2)])]"
                          "      [(.invokeAny ex [(fn [] (throw (ex-info \"x\" {}))) (fn [] 3)]) (mapv (fn [f] (.get f)) fs)])"
                          "  (try (.next (.iterator [])) (catch java.util.NoSuchElementException _ true))])))"))),
    ev("(defprotocol HtP (htp [x]))"),
    ev("(extend-protocol HtP clojure.lang.IReduceInit (htp [x] :ireduce))"),
    ev("(deftype HtT [] clojure.lang.IReduceInit (reduce [_ f init] init))"),
    ev("(deftype HtSq [i] clojure.lang.ISeq (first [_] i) (next [_] (when (< i 3) (HtSq. (inc i)))) (seq [this] this))"),
    ?assertEqual([':ireduce', true, [1, 2, 3], 3, 6],
                 plain(ev("[(htp (->HtT)) (satisfies? clojure.lang.IReduceInit (->HtT)) (vec (HtSq. 1)) (count (HtSq. 1)) (reduce + (HtSq. 1))]"))).

%% clojerl2-040: reader - digit separators, JVM read errors, read-string
%% opts, data readers, record literals, #=
reader_forms_test() ->
    setup(),
    ?assertEqual([1000000, 65535, 42, 1007, 10.55, 3000, 255],
                 plain(ev("[1_000_000 0xFF_FF 0_52 36rR_Z 1_0.5_5 3_000N 0xFFN]"))),
    ?assertEqual([<<"Invalid number: 1_">>, <<"Unmatched delimiter: }">>, ':nfe', ':dup', ':ise'],
                 plain(ev("[(try (read-string \"1_\") (catch Exception e (ex-message e)))"
                          " (try (read-string \"[1 2}\") (catch Exception e (ex-message e)))"
                          " (try (read-string \"1a\") (catch NumberFormatException _ :nfe))"
                          " (try (read-string \"#{1 1}\") (catch IllegalArgumentException _ :dup))"
                          " (try (read-string \"#(%0)\") (catch IllegalStateException _ :ise))]"))),
    ?assertEqual([1, ':end', <<"garbage!">>, 3, [foo, 42]],
                 plain(ev("[(read-string {:features #{:clj}} \"#?(:clj 1 :cljs 2)\") (read-string {:eof :end} \" \")"
                          " (str (read-string \"garbage!@\")) (read-string \"#=(+ 1 2)\")"
                          " (binding [*default-data-reader-fn* (fn [t v] [t v])] (read-string \"#foo 42\"))]"))),
    ev("(defrecord RdPt [x y])"),
    ?assertEqual([[quote, x], 1, <<"a">>],
                 plain(ev("(let [x 5] [(:x #t.stdlib.RdPt{:x 'x}) (:y #t.stdlib.RdPt[0 1]) (:x (read-string \"#t.stdlib.RdPt[\\\"a\\\" 2]\"))])"))).

%% clojerl2-039: clojure.edn, clojure.math, clojure.pprint, clojure.repl,
%% #inst, *print-length*/*print-level*
stdlib_namespaces_test() ->
    setup(),
    ev("(require '[clojure.edn :as edn] '[clojure.math :as m] '[clojure.pprint :as pp] 'clojure.repl)"),
    ?assertEqual([[6, 8], ':end', <<"Invalid constituent character: @">>, <<"No reader function for tag foo">>],
                 plain(ev("[(edn/read-string {:readers {'w (fn [v] (* 2 v))}} \"[#w 3 #w 4]\")"
                          " (edn/read-string {:eof :end} \"\")"
                          " (try (edn/read-string \"a@b\") (catch RuntimeException e (ex-message e)))"
                          " (try (edn/read-string \"#foo 1\") (catch RuntimeException e (ex-message e)))]"))),
    ?assertEqual([5, <<"long overflow">>], plain(ev("[(long (m/hypot 3 4)) (try (m/add-exact Long/MAX_VALUE 1) (catch ArithmeticException e (ex-message e)))]"))),
    ?assertEqual(<<"{:aaaa 1111111111,\n :bbbb 2222222222,\n :cccc 3333333333,\n :dddd 4444444444,\n :eeee 5555555555,\n :ffff 66666666666}\n">>,
                 ev("(with-out-str (pp/pprint {:aaaa 1111111111 :bbbb 2222222222 :cccc 3333333333 :dddd 4444444444 :eeee 5555555555 :ffff 66666666666}))")),
    ?assertEqual([<<"3.14">>, <<"1, 2, 3">>, <<"1,234,567">>],
                 plain(ev("[(pp/cl-format nil \"~,2f\" 3.14159) (pp/cl-format nil \"~{~a~^, ~}\" [1 2 3]) (pp/cl-format nil \"~:d\" 1234567)]"))),
    ?assertEqual([<<"[1 2 ...]">>, <<"[:a [:b #]]">>], plain(ev("[(binding [*print-length* 2] (pr-str [1 2 3])) (binding [*print-level* 2] (pr-str [:a [:b [:c]]]))]"))),
    ?assertEqual(true, ev("(clojure.string/includes? (with-out-str (clojure.repl/doc when)) \"Macro\")")),
    ?assertEqual(<<"#inst \"2020-06-01T08:00:00.000-00:00\"">>, ev("(pr-str #inst \"2020-06-01T10:00:00+02:00\")")).

%% clojerl2-038: compiler forms
compiler_forms_test() ->
    setup(),
    ?assertEqual([1, 2, 3], plain(ev("(loop* [a 1 b (+ a 1) c (+ b 1)] [a b c])"))),
    ?assertEqual([0, 1, 2], plain(ev("(take 3 (apply (fn [& xs] xs) (range)))"))),
    ?assertEqual(true, ev("(= (read-string \"`(a ~b)\") '(clojure.core/seq (clojure.core/concat (clojure.core/list (quote t.stdlib/a)) (clojure.core/list b))))")),
    ?assertEqual([42, false], plain(ev("[``42 (nil? ``nil)]"))),
    ev("(defmacro sq38-outer [n] `(defmacro ~(symbol (str \"sq38-\" n)) [x# y#] `(vector ~y# ~x#)))"),
    ev("(sq38-outer one)"),
    ?assertEqual([2, 1], plain(ev("(sq38-one 1 2)"))),
    ev("(defmacro m38 [& [a & more]] (list 'quote [a (vec more)]))"),
    ?assertEqual([1, [2, 3]], plain(ev("(m38 1 2 3)"))),
    ev("(defn tam38 ([x] x) ([x y] y) {:extra 7})"),
    ?assertEqual(7, ev("(:extra (meta #'tam38))")),
    ev("(defonce once38 1)"), ev("(defonce once38 2)"),
    ?assertEqual(1, ev("once38")),
    ev("(declare decl38)"),
    ?assertEqual(true, ev("(:declared (meta #'decl38))")),
    {ok, _} = clj2_compiler:load_ns(<<"(ns t.dt38) (defprotocol P (mk [this pair]))"
                                      " (deftype T [n] :no-print true P (mk [this [k v]] [n k v]) Object (toString [_] (str \"T\" n)))">>),
    ?assertEqual([1, ':a', ':b'], plain(ev("(t.dt38/mk (t.dt38/->T 1) [:a :b])"))),
    ?assertEqual(<<"T1">>, ev("(str (t.dt38/->T 1))")).

%% clojerl2-035: Erlang errors get the JVM class of the failing call;
%% core fns check their arguments as the JVM does
jvm_exception_classes_test() ->
    setup(),
    ?assertEqual([':cce', ':npe', ':npe', ':cce', ':cce', ':ae', ':iae', ':sioobe', ':uoe', ':npe'],
                 plain(ev("[(try (+ 1 \"a\") (catch ClassCastException _ :cce))"
                          " (try (+ nil 1) (catch NullPointerException _ :npe))"
                          " (try (< nil 1) (catch NullPointerException _ :npe))"
                          " (try (< 1 \"a\") (catch ClassCastException _ :cce))"
                          " (try (compare 1 \"a\") (catch ClassCastException _ :cce))"
                          " (try (/ 1 0) (catch ArithmeticException _ :ae))"
                          " (try (bit-and \"a\" 1) (catch IllegalArgumentException _ :iae))"
                          " (try (nth \"abc\" 5) (catch StringIndexOutOfBoundsException _ :sioobe))"
                          " (try (nth #{1} 0) (catch UnsupportedOperationException _ :uoe))"
                          " (try (name nil) (catch NullPointerException _ :npe))]"))),
    ?assertEqual(<<"For input string: \"zz\" under radix 16">>,
                 ev("(try (Long/parseLong \"zz\" 16) (catch NumberFormatException e (ex-message e)))")).

core_argument_checks_test() ->
    setup(),
    ?assertEqual([<<"find not supported on type: clojure.lang.PersistentHashSet">>, [':a', 1],
                  <<"No value supplied for key: 1">>, <<"Can't pop empty list">>,
                  <<"Vector arg to map conj must be a pair">>, nil, -1, [], nil, 0.5],
                 plain(ev("[(try (find #{1} 1) (catch IllegalArgumentException e (ex-message e))) (find {:a 1} :a)"
                          " (try (sorted-map 1) (catch IllegalArgumentException e (ex-message e)))"
                          " (try (pop ()) (catch IllegalStateException e (ex-message e)))"
                          " (try (into {} [[1]]) (catch IllegalArgumentException e (ex-message e)))"
                          " (keyword 5) (compare :cat :animal/cat) (nthrest [1] 5) (nth nil 5) (mod -5.5 2)]"))),
    ?assertEqual(<<"{:a 1, :b nil}">>, ev("(pr-str (persistent! (assoc! (transient {}) :a 1 :b)))")),
    ?assertEqual(':iae', ev("(try (mapcat identity 5) :no (catch IllegalArgumentException _ :iae))")).

%% clojerl2-034: #() rest args; range checks its bounds at the call;
%% sequence is lazy; a namespace's vars through var objects while it loads
anon_fn_rest_args_test() ->
    setup(),
    ?assertEqual([[1, 2, 3], [2, 3], [3], [1, 2, 3]],
                 plain(ev("[(#(do %&) 1 2 3) (#(do % %&) 1 2 3) (#(do %2 %&) 1 2 3)"
                          " ((fn [& xs] (apply #(vec %&) xs)) 1 2 3)]"))).

range_checks_bounds_test() ->
    setup(),
    ?assertEqual(':cce', ev("(try (range \"a\") (catch ClassCastException e :cce))")),
    ?assertEqual(':npe', ev("(try (range 0 nil) (catch NullPointerException e :npe))")),
    ?assertEqual([0, 1, 2], plain(ev("(take 3 (range))"))).

lazy_sequence_test() ->
    setup(),
    ?assertEqual([[1, 2, 3], [[0, 1], [2, 3]], 1, [1, 3, 5], [[1, 2, 3], [4, 5]]],
                 plain(ev("[(take 3 (sequence (map inc) (range))) (take 2 (sequence (partition-all 2) (range)))"
                          " (first (eduction (map inc) (range))) (sequence (comp (filter odd?) (take 3)) (range 100))"
                          " (sequence (partition-all 3) [1 2 3 4 5])]"))),
    %% nothing runs until the seq is walked, so the xform's state belongs
    %% to the process that walks it (JVM: the first element is realized at
    %% the call; :pending/laziness)
    ?assertEqual(0, ev("(let [a (atom 0)] (sequence (map (fn [x] (swap! a inc) x)) (range 5)) @a)")).

vars_while_namespace_loads_test() ->
    setup(),
    {ok, _} = clj2_compiler:load_ns(<<"(ns t.loading34) (def v 5) (defn f [x] (inc x)) (defmacro m [a] (list 'inc a))"
                                      " (def r [@#'v ((var f) 41) (apply (var m) ['(m 1) nil 1])"
                                      " (macroexpand-1 '(m 5)) (str *ns*)])">>),
    ?assertEqual([5, 42, [inc, 1], [inc, 5], <<"t.loading34">>], plain(ev("t.loading34/r"))).

%% clojerl2-032: a var given a value at run time moves it into the var
%% table once; every later change is a table write
nested_redefinition_is_a_table_write_test() ->
    setup(),
    ev("(defn rw-f [] 0)"),
    ev("(defn rw-g [n] (def rw-f (fn [] n)) (rw-f))"),
    ev("(def rw-held rw-f)"),
    %% 200 changes in one evaluation (was ~9 ms each: a module load each)
    {Us, Last} = timer:tc(fun() -> ev("(last (map rw-g (range 1 201)))") end),
    ?assertEqual(200, Last),
    ?assert(Us < 1000000),
    ?assertEqual(0, ev("(rw-held)")),                       % the value taken before stays the old fn
    %% a process sitting in the old code does not stop later changes
    ev("(def rw-p (promise))"),
    ev("(defn rw-slow [] (deref rw-p) :old-done)"),
    ev("(def rw-fut (future (rw-slow)))"),
    timer:sleep(50),
    ev("(defn rw-h [n] (def rw-slow (fn [] n)) (rw-slow))"),
    ?assertEqual([1, 2, 3], plain(ev("[(rw-h 1) (rw-h 2) (rw-h 3)]"))),
    ev("(deliver rw-p 1)"),
    ?assertEqual(':old-done', ev("(deref rw-fut 1000 :timeout)")),
    %% a top-level def after that is an assignment too
    ev("(defn rw-slow [] :top)"),
    ?assertEqual(':top', ev("(rw-slow)")).

%% a namespace file: a def nested in a later compile-time segment keeps
%% the earlier segment's value until it runs; a second top-level def
%% replaces the value
segment_and_duplicate_defs_test() ->
    setup(),
    {ok, _} = clj2_compiler:load_ns(<<"(ns t.seg32) (defn f [] 1) (defmacro m1 [] :m1)"
                                      " (def seen [(f)]) (when true (defn f [] 2))"
                                      " (defmacro m2 [] (f)) (def x 1) (def held x) (def x 5) (def x)"
                                      " (defn run [] [seen (m2) (f) held x])">>),
    ?assertEqual([[1], 2, 2, 1, 5], plain(ev("(t.seg32/run)"))).

%% alter-var-root, with-redefs: REPL vars, vars of a namespace module
%% (calls between its vars reach the new value), constants, restore on
%% throw, watches and validators
var_root_changes_test() ->
    setup(),
    ev("(def avr-x 1)"),
    ?assertEqual(11, ev("(alter-var-root (var avr-x) + 4 6)")),
    ?assertEqual(11, ev("avr-x")),
    {ok, _} = clj2_compiler:load_ns(<<"(ns t.wr32) (def k 10) (defn query [x] [:real x])"
                                      " (defn handle [] [(query 1) k])">>),
    ev("(def wr-before t.wr32/query)"),
    ?assertEqual([[':mock', 1], 99],
                 plain(ev("(with-redefs [t.wr32/query (fn [x] [:mock x]) t.wr32/k 99] (t.wr32/handle))"))),
    ?assertEqual([[':real', 1], 10], plain(ev("(t.wr32/handle)"))),
    ?assertEqual([':real', 3], plain(ev("(wr-before 3)"))),
    ?assertEqual([':real', 1], plain(ev("(try (with-redefs [t.wr32/query (fn [x] (throw (ex-info \"x\" {})))]"
                                        " (t.wr32/handle)) (catch :default e (t.wr32/query 1)))"))),
    %% the redefinition reaches another process (it is the root)
    ?assertEqual([':m', ':m'], plain(ev("(with-redefs [t.wr32/query (fn [_] :m)] [(t.wr32/query 0) @(future (t.wr32/query 0))])"))),
    %% watches see every root change, a validator gates it
    ev("(def wv 1) (def wv-log (atom []))"),
    ev("(add-watch (var wv) :w (fn [k r o n] (swap! wv-log conj [o n])))"),
    ev("(alter-var-root (var wv) inc)"),
    ev("(def wv 5)"),
    ?assertEqual([[1, 2], [2, 5]], plain(ev("@wv-log"))),
    ev("(set-validator! (var wv) pos?)"),
    ?assertEqual(':ise', ev("(try (alter-var-root (var wv) -) (catch IllegalStateException _ :ise))")),
    ?assertEqual(5, ev("wv")),
    %% set! of a dynamic var writes this process's binding
    ev("(def ^:dynamic *sb* 1)"),
    ?assertEqual([2, 1], plain(ev("[(binding [*sb* 0] (set! *sb* 2) *sb*) *sb*]"))).

%% at the REPL, a nested def of a fn var other code links to keeps that
%% code working and reaching the new fn, whatever arities the two have
nested_redefinition_at_repl_test() ->
    setup(),
    ev("(defn rr-f [] 1)"), ev("(defn rr-g [] (rr-f))"),
    ev("(when true (defn rr-f ([] 2) ([x] x)))"),
    ?assertEqual([2, 2, 7], plain(ev("[(rr-g) (rr-f) (rr-f 7)]"))),
    ev("(defn rr-h [a] a)"), ev("(defn rr-k [] (rr-h 1))"),
    ev("(when true (def rr-h (fn [& xs] (count xs))))"),
    ?assertEqual([1, 0, 3], plain(ev("[(rr-k) (rr-h) (rr-h 1 2 3)]"))),
    ev("(defn rr-v [a & r] [a r])"), ev("(defn rr-w [] (rr-v 1 2 3))"),
    ev("(when true (defn rr-v [& xs] (vec xs)))"),
    ?assertEqual([[1, 2, 3], [9]], plain(ev("[(rr-w) (rr-v 9)]"))),
    %% an arity the new fn lacks fails when called, as on the JVM
    ev("(defn rr-z [a b] (+ a b))"), ev("(defn rr-y [] (rr-z 1 2))"),
    ev("(when true (defn rr-z [a] a))"),
    ?assertEqual(':arity', ev("(try (rr-y) (catch Throwable e :arity))")).

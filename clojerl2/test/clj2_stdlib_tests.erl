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

%% ##NaN, 1.5M and #inst are read, print as read, and raise when evaluated
%% (as a case constant they match nothing)
unsupported_literals_test() ->
    setup(),
    ?assertEqual(':ArithmeticException', ev("(try ##NaN (catch ArithmeticException e (:type (ex-data e))))")),
    ?assertEqual(<<"1.5M: BigDecimal literals are not supported yet (clojerl2 :pending/numbers)">>,
                 ev("(try 1.5M (catch Throwable e (ex-message e)))")),
    ?assertEqual(<<"No reader function for tag inst">>,
                 ev("(try #inst \"2010-11-12\" (catch Throwable e (ex-message e)))")),
    ?assertEqual(<<"##NaN 4.0M #inst \"x\"">>, ev("(pr-str '##NaN '4.0M '#inst \"x\")")),
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

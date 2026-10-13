;;   Portions of this file are from Clojure's src/clj/clojure/test.clj,
;;   Copyright (c) Rich Hickey. All rights reserved.
;;   The use and distribution terms for that software are covered by the
;;   Eclipse Public License 1.0; this file keeps that notice.
;;
;;   Shaped after jolt's stdlib/clojure/test.clj (EPL-1.0), adapted to
;;   clojerl2 (clojerl2-022): a registry instead of var scanning, cells
;;   instead of refs, the namespace captured when deftest expands.

(ns clojure.test
  "A practical subset of clojure.test: deftest / is / are / testing /
  use-fixtures / run-tests / test-var, the report and assert-expr
  multimethods, with (thrown? Class body) and (thrown-with-msg? Class re
  body) inside `is'. Tests are recorded in a registry when deftest
  expands (and in the var's :test metadata); run-tests runs a
  namespace's registered tests inside its fixtures."
  (:require [clojure.string :as str]
            [clojure.template :as temp]))

;;;; ------------------------------------------------------------------
;;;; State

(def ^:dynamic *load-tests*
  "Bind to false when loading production code: deftest / with-test /
  set-test then define nothing."
  true)
(def ^:dynamic *stack-trace-depth* nil)   ; accepted, there are no stack traces to cap
(def ^:dynamic *report-counters* nil)     ; a cell over the counters, bound per run
(def *initial-report-counters* {:test 0, :pass 0, :fail 0, :error 0})
(def ^:dynamic *testing-vars* (list))     ; the vars under test, innermost first
(def ^:dynamic *testing-contexts* (list)) ; the testing strings, innermost first
(def ^:dynamic *test-out* *out*)

(defmacro with-test-out
  "Runs body with *out* bound to the value of *test-out*."
  [& body]
  `(binding [*out* *test-out*] ~@body))

;; deftest records each test here: [{:ns sym :name sym :fn thunk}], in
;; definition order; a redefinition replaces its entry in place.
(def ^:private registry (clj2_ref/cell []))
(def ^:private once-fixtures (clj2_ref/cell {}))   ; ns symbol -> [fixture fns]
(def ^:private each-fixtures (clj2_ref/cell {}))

(defn register-test!
  "Record the test thunk f as ns-sym/name, replacing an entry already
  registered under that name (a reloaded test runs once)."
  [ns-sym name f]
  (clj2_ref/swap registry
         (fn [r]
           (let [entry {:ns ns-sym :name name :fn f}
                 i (first (keep-indexed (fn [i t] (when (and (= name (:name t)) (= ns-sym (:ns t))) i)) r))]
             (if i (assoc r i entry) (conj r entry))))
         nil)
  nil)

;;;; ------------------------------------------------------------------
;;;; Reporting

(defn- err-text
  "A thrown value's message, else its printed form."
  [e]
  (or (ex-message e) (pr-str e)))

(defn- report-value [v]
  (if (instance? Throwable v) (err-text v) (pr-str v)))

(defn testing-vars-str
  "Returns a string representation of the current test: the names in
  *testing-vars* as a list, then the source file and line of the
  assertion when known."
  [m]
  (let [{:keys [file line]} m]
    (str (reverse (map (fn [v] (:name (meta v))) *testing-vars*))
         (when (or file line) (str " (" file ":" line ")")))))

(defn testing-contexts-str
  "Returns a string representation of the current test context, outermost
  first."
  []
  (str/join " " (reverse *testing-contexts*)))

(defn inc-report-counter
  "Increments the named counter in *report-counters*, when bound."
  [name]
  (when *report-counters*
    (clj2_ref/swap *report-counters* update (list name (fnil inc 0)))))

(defmulti report
  "The reporting multimethod: dispatches on the :type of the report map
  (:pass :fail :error :summary :begin-test-ns ...). A different reporter
  adds methods."
  :type)

(defmethod report :default [m]
  (with-test-out (prn m)))

(defmethod report :pass [m]
  (with-test-out (inc-report-counter :pass)))

(defmethod report :fail [m]
  (with-test-out
    (inc-report-counter :fail)
    (println "\nFAIL in" (testing-vars-str m))
    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    (when-let [message (:message m)] (println message))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (report-value (:actual m)))))

(defmethod report :error [m]
  (with-test-out
    (inc-report-counter :error)
    (println "\nERROR in" (testing-vars-str m))
    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    (when-let [message (:message m)] (println message))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (report-value (:actual m)))))

(defmethod report :summary [m]
  (with-test-out
    (println "\nRan" (:test m) "tests containing"
             (+ (:pass m) (:fail m) (:error m)) "assertions.")
    (println (:fail m) "failures," (:error m) "errors.")))

(defmethod report :begin-test-ns [m]
  (with-test-out (println "\nTesting" (:ns m))))

(defmethod report :end-test-ns [m])
(defmethod report :begin-test-var [m])
(defmethod report :end-test-var [m])

(defn do-report
  "Calls report with the map m; the seam every assertion goes through."
  [m]
  (report m))

;;;; ------------------------------------------------------------------
;;;; Assertions

(defn get-possibly-unbound-var
  "Like var-get but returns nil if the var is unbound."
  [v]
  (try (var-get v) (catch Throwable _ nil)))

(defn function?
  "True when x is a function, or a symbol naming a var whose value is a
  function (not a macro)."
  [x]
  (if (symbol? x)
    (when-let [v (resolve x)]
      (when (var? v)
        (when-let [value (get-possibly-unbound-var v)]
          (and (fn? value) (not (:macro (meta v)))))))
    (fn? x)))

(defn assert-predicate
  "Returns generic assertion code for any functional predicate. The
  'expected' argument to 'report' will contains the original form, the
  'actual' argument will contain the form with all its sub-forms
  evaluated. If the predicate returns false, the 'actual' form will be
  wrapped in (not...)."
  [msg form]
  (let [args (rest form)
        pred (first form)]
    `(let [values# (list ~@args)
           result# (apply ~pred values#)]
       (if result#
         (do-report {:type :pass, :message ~msg,
                     :expected '~form, :actual (cons '~pred values#)})
         (do-report {:type :fail, :message ~msg,
                     :expected '~form, :actual (list '~'not (cons '~pred values#))}))
       result#)))

(defn assert-any
  "Returns generic assertion code for any test, including macros, host
  method calls, or isolated symbols."
  [msg form]
  `(let [value# ~form]
     (if value#
       (do-report {:type :pass, :message ~msg,
                   :expected '~form, :actual value#})
       (do-report {:type :fail, :message ~msg,
                   :expected '~form, :actual value#}))
     value#))

(defmulti assert-expr
  "The assertion extension point: `is' expands (assert-expr msg form),
  dispatched on the form's head symbol (or :always-fail / :default)."
  (fn [msg form]
    (cond
      (nil? form) :always-fail
      (seq? form) (first form)
      :else :default)))

(defmethod assert-expr :always-fail [msg form]
  `(do-report {:type :fail, :message ~msg}))

(defmethod assert-expr :default [msg form]
  (if (and (sequential? form) (function? (first form)))
    (assert-predicate msg form)
    (assert-any msg form)))

(defmethod assert-expr 'instance? [msg form]
  (if (< (count form) 3)
    ;; (instance? x) alone (a reader conditional left no class): the JVM's
    ;; ArityException at run time, as an :error of this assertion (a direct
    ;; call with the wrong arity would not compile, :fn/arity-at-compile-time)
    `(do-report {:type :error, :message ~msg, :expected '~form,
                 :actual (ex-info "Wrong number of args passed to: clojure.core/instance?"
                                  {:type :ArityException})})
    (let [klass (second form)
          object (nth form 2)]
      `(let [klass# ~klass
             object# ~object]
         (let [result# (instance? klass# object#)]
           (if result#
             (do-report {:type :pass, :message ~msg,
                         :expected '~form, :actual (class object#)})
             (do-report {:type :fail, :message ~msg,
                         :expected '~form, :actual (class object#)}))
           result#)))))

;; The class a catch names, resolved when the assertion expands (bare
;; java.lang names, simple names the class model knows); a name it does
;; not know is kept and matched by its last segment at run time.
(defn- class-sym [klass]
  (let [r (clj2_class/resolve klass)]
    (if (erlang/is_tuple r)
      (erlang/element 2 r)
      (let [r2 (clj2_class/resolve_simple klass)]
        (if (erlang/is_tuple r2) (erlang/element 2 r2) klass)))))

(defn- simple-name [c]
  (let [s (str c)
        i (str/last-index-of s ".")]
    (if i (subs s (inc i)) s)))

(defn thrown-match?
  "Does the thrown value e belong to class c (a symbol): by the class
  model, else by simple name."
  [c e]
  (or (instance? c e)
      (= (simple-name c) (simple-name (class e)))))

;; (is (thrown? c expr)): true if c is thrown; returns the thrown value.
;; Every throwable is caught and its class checked, so a class the model
;; does not know still compiles.
(defmethod assert-expr 'thrown? [msg form]
  (let [klass (class-sym (second form))
        body (nthnext form 2)]
    `(try ~@body
          (do-report {:type :fail, :message ~msg,
                      :expected '~form, :actual nil})
          (catch Throwable e#
            (if (thrown-match? '~klass e#)
              (do (do-report {:type :pass, :message ~msg,
                              :expected '~form, :actual e#})
                  e#)
              (do (do-report {:type :fail, :message ~msg,
                              :expected '~form, :actual e#})
                  nil))))))

;; (is (thrown-with-msg? c re expr)): c thrown, with a message re-find
;; matches; returns the thrown value.
(defmethod assert-expr 'thrown-with-msg? [msg form]
  (let [klass (class-sym (second form))
        re (nth form 2)
        body (nthnext form 3)]
    `(try ~@body
          (do-report {:type :fail, :message ~msg, :expected '~form, :actual nil})
          (catch Throwable e#
            (let [m# (or (ex-message e#) (str e#))]
              (if (and (thrown-match? '~klass e#) (re-find ~re m#))
                (do-report {:type :pass, :message ~msg,
                            :expected '~form, :actual e#})
                (do-report {:type :fail, :message ~msg,
                            :expected '~form, :actual e#}))
              e#)))))

(defmacro try-expr
  "Used by the 'is' macro to catch unexpected exceptions.
  You don't call this."
  [msg form]
  `(try ~(assert-expr msg form)
        (catch Throwable t#
          (do-report {:type :error, :message ~msg,
                      :expected '~form, :actual t#}))))

(defmacro is
  "Generic assertion macro. 'form' is any predicate test. 'msg' is an
  optional message to attach to the assertion.

  Example: (is (= 4 (+ 2 2)) \"Two plus two should be 4\")

  Special forms:
  (is (thrown? c body)) checks that an instance of c is thrown from
  body, fails if not; then returns the thing thrown.
  (is (thrown-with-msg? c re body)) checks that an instance of c is
  thrown AND that the message on the exception matches (with re-find)
  the regular expression re."
  ([form] `(is ~form nil))
  ([form msg] `(try-expr ~msg ~form)))

(defmacro are
  "Checks multiple assertions with a template expression.
  See clojure.template/do-template for an explanation of templates.

  Example: (are [x y] (= x y)
                2 (+ 1 1)
                4 (* 2 2))
  Expands to:
           (do (is (= 2 (+ 1 1)))
               (is (= 4 (* 2 2))))

  Note: This breaks some reporting features, such as line numbers."
  [argv expr & args]
  (if (or
       ;; (are [] true) is meaningless but ok
       (and (empty? argv) (empty? args))
       ;; Catch wrong number of args
       (and (pos? (count argv))
            (pos? (count args))
            (zero? (mod (count args) (count argv)))))
    `(temp/do-template ~argv (is ~expr) ~@args)
    (throw (IllegalArgumentException. "The number of args doesn't match are's argv or neither are empty"))))

(defmacro testing
  "Adds a new string to the list of testing contexts. May be nested,
  but must occur inside a test function (deftest)."
  [string & body]
  `(binding [*testing-contexts* (conj *testing-contexts* ~string)]
     ~@body))

;;;; ------------------------------------------------------------------
;;;; Defining tests

;; The namespace is the one deftest expands in (*ns* at run time is
;; whatever the loading process has), and the thunk goes to both the
;; var's :test metadata, where clojure.test keeps it, and the registry.
(defn- def-test-form [name body extra-meta]
  (let [ns-sym (symbol (str *ns*))]
    `(do
       (def ~name (fn [] (test-var (var ~name))))
       (let [t# (fn [] ~@body)]
         (alter-meta! (var ~name) merge ~extra-meta {:test t#})
         (register-test! '~ns-sym '~name t#))
       (var ~name))))

(defmacro deftest
  "Defines a test function with no arguments. Test functions may call
  other tests, so tests may be composed. If you compose tests, you
  should also define a function named test-ns-hook; run-tests will
  call test-ns-hook instead of testing all vars.

  Note: Actually, the test body goes in the :test metadata on the var,
  and the real function (the value of the var) calls test-var on
  itself.

  When *load-tests* is false, deftest is ignored."
  [name & body]
  (when *load-tests*
    (def-test-form name body nil)))

(defmacro deftest-
  "Like deftest but creates a private var."
  [name & body]
  (when *load-tests*
    (def-test-form name body {:private true})))

(defmacro with-test
  "Takes any definition form (that returns a Var) as the first argument.
  Remaining body goes in the :test metadata function for that Var.

  When *load-tests* is false, only evaluates the definition, ignoring
  the tests."
  [definition & body]
  (if *load-tests*
    `(doto ~definition (alter-meta! assoc :test (fn [] ~@body)))
    definition))

(defmacro set-test
  "Experimental.
  Sets :test metadata of the named var to a fn with the given body.
  The var must already exist.  Does not modify the value of the var.

  When *load-tests* is false, set-test is ignored."
  [name & body]
  (when *load-tests*
    `(alter-meta! (var ~name) assoc :test (fn [] ~@body))))

;;;; ------------------------------------------------------------------
;;;; Fixtures

(defn use-fixtures*
  "(use-fixtures) with the namespace given: fixtures are per namespace."
  [ns-sym fixture-type & fns]
  (cond
    (= fixture-type :once) (clj2_ref/swap once-fixtures assoc (list ns-sym (vec fns)))
    (= fixture-type :each) (clj2_ref/swap each-fixtures assoc (list ns-sym (vec fns)))
    :else (throw (IllegalArgumentException. (str "Unknown fixture type: " fixture-type)))))

(defmacro use-fixtures
  "Wrap test runs in a fixture function to perform setup and
  teardown. Using a fixture-type of :each wraps every test
  individually, while :once wraps the whole run in a single function."
  [fixture-type & fns]
  `(use-fixtures* '~(symbol (str *ns*)) ~fixture-type ~@fns))

(defn- default-fixture
  "The default, empty, fixture function.  Just calls its argument."
  [f]
  (f))

(defn compose-fixtures
  "Composes two fixture functions, creating a new fixture function
  that combines their behavior."
  [f1 f2]
  (fn [g] (f1 (fn [] (f2 g)))))

(defn join-fixtures
  "Composes a collection of fixtures, in order.  Always returns a valid
  fixture function, even if the collection is empty."
  [fixtures]
  (reduce compose-fixtures default-fixture fixtures))

;;;; ------------------------------------------------------------------
;;;; Running tests

(defn test-var
  "If v has a function in its :test metadata, calls that function,
  with *testing-vars* bound to (conj *testing-vars* v)."
  [v]
  (when-let [t (:test (meta v))]
    (binding [*testing-vars* (conj *testing-vars* v)]
      (do-report {:type :begin-test-var, :var v})
      (inc-report-counter :test)
      (try (t)
           (catch Throwable e
             (do-report {:type :error, :message "Uncaught exception, not in assertion."
                         :expected nil, :actual e})))
      (do-report {:type :end-test-var, :var v}))))

;; a registered test by its var when it still resolves (so the report
;; names it), else by its thunk
(defn- run-registered-test [t]
  (let [v (when (find-ns (:ns t)) (ns-resolve (:ns t) (:name t)))]
    (if (and v (:test (meta v)))
      (test-var v)
      (binding [*testing-vars* (conj *testing-vars* (with-meta [] {:name (:name t)}))]
        (inc-report-counter :test)
        (try ((:fn t))
             (catch Throwable e
               (do-report {:type :error, :message "Uncaught exception, not in assertion."
                           :expected nil, :actual e})))))))

(defn test-vars
  "Groups vars by their namespace and runs test-var on them with
  appropriate fixtures assuming that the current directory is the root
  of the namespaces' source files."
  [vars]
  (doseq [[ns vars] (group-by (fn [v] (:ns (meta v))) vars)]
    (let [once-fixture-fn (join-fixtures (get @once-fixtures ns []))
          each-fixture-fn (join-fixtures (get @each-fixtures ns []))]
      (once-fixture-fn
       (fn []
         (doseq [v vars]
           (when (:test (meta v))
             (each-fixture-fn (fn [] (test-var v))))))))))

(defn- registered-tests [ns-sym]
  (filter (fn [t] (= ns-sym (:ns t))) @registry))

(defn- run-ns-tests
  "The namespace's registered tests, each inside its :each fixtures, all
  inside its :once fixtures."
  [ns-sym]
  (let [once-fixture-fn (join-fixtures (get @once-fixtures ns-sym []))
        each-fixture-fn (join-fixtures (get @each-fixtures ns-sym []))]
    (once-fixture-fn
     (fn []
       (doseq [t (registered-tests ns-sym)]
         (each-fixture-fn (fn [] (run-registered-test t))))))))

(defn test-all-vars
  "Calls test-vars on every var interned in the namespace, with fixtures."
  [ns]
  (test-vars (vals (ns-interns ns))))

(defn- ns-hook [ns-sym]
  (when (find-ns ns-sym)
    (let [v (ns-resolve ns-sym 'test-ns-hook)]
      (when (var? v) v))))

(defn test-ns
  "If the namespace defines a function named test-ns-hook, calls that.
  Otherwise, runs the namespace's registered tests inside its fixtures.
  Returns a map of counters."
  [ns]
  (let [ns-sym (if (symbol? ns) ns (ns-name ns))]
    (binding [*report-counters* (clj2_ref/cell *initial-report-counters*)]
      (do-report {:type :begin-test-ns, :ns ns-sym})
      (if-let [hook (ns-hook ns-sym)]
        ((var-get hook))
        (run-ns-tests ns-sym))
      (do-report {:type :end-test-ns, :ns ns-sym})
      @*report-counters*)))

(defmacro run-test
  "Runs a single test: (run-test my-test)."
  [test-symbol]
  `(test-var (var ~test-symbol)))

(defn run-test-var
  "Runs a single test var, given the var itself."
  [v]
  (test-vars [v]))

(defn run-tests
  "Runs all tests in the given namespaces; prints results.
  Defaults to current namespace if none given. Returns a map
  summarizing test results."
  ([] (run-tests *ns*))
  ([& namespaces]
   (let [summary (assoc (apply merge-with + (map test-ns namespaces))
                        :type :summary)]
     (do-report summary)
     summary)))

(defn run-all-tests
  "Runs all tests in all namespaces; prints results.
  Optional argument is a regular expression; only namespaces with
  names matching the regular expression (with re-matches) will be
  tested."
  ([] (apply run-tests (distinct (map :ns @registry))))
  ([re] (apply run-tests (filter (fn [n] (re-matches re (name n))) (distinct (map :ns @registry))))))

(defn successful?
  "Returns true if the given test summary indicates all tests were
  successful, false otherwise."
  [summary]
  (and (zero? (:fail summary 0))
       (zero? (:error summary 0))))

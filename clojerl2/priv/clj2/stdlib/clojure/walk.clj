;;   Portions of this file are from Clojure's src/clj/clojure/walk.clj,
;;   Copyright (c) Rich Hickey. All rights reserved.
;;   The use and distribution terms for that software are covered by the
;;   Eclipse Public License 1.0 (../../../../../LICENSE records clojerl2's
;;   own terms; this file keeps the EPL-1.0 notice of its origin).
;;
;;   Ported to clojerl2 from jolt's stdlib/clojure/walk.clj (EPL-1.0;
;;   clojerl2-022), which carries the eager-walk and record-rebuild fixes.

(ns clojure.walk
  "Generic tree walking over Clojure data: walk, prewalk, postwalk and the
  replace / keywordize-keys helpers built on them.")

(defn walk
  "Traverses form, an arbitrary data structure. inner and outer are
  functions. Applies inner to each element of form, building up a data
  structure of the same type, then applies outer to the result."
  [inner outer form]
  (cond
    ;; vectors and maps first so seq? cannot swallow them; the rebuilt
    ;; collection keeps the form's metadata, as on the JVM
    (vector? form) (outer (with-meta (vec (map inner form)) (meta form)))
    ;; a record is map? too, but (empty record) is a plain map: conj the
    ;; walked entries back onto the original so its type survives
    (record? form) (outer (reduce (fn [r x] (conj r (inner x))) form form))
    (map? form) (outer (with-meta (into (empty form) (map inner form)) (meta form)))
    (list? form) (outer (with-meta (apply list (map inner form)) (meta form)))
    ;; eager, as Clojure's: an inner with side effects runs now
    (seq? form) (outer (with-meta (doall (map inner form)) (meta form)))
    (coll? form) (outer (with-meta (into (empty form) (map inner form)) (meta form)))
    :else (outer form)))

(defn postwalk
  "Performs a depth-first, post-order traversal of form. Calls f on each
  sub-form, uses f's return value in place of the original."
  [f form]
  (walk (partial postwalk f) f form))

(defn prewalk
  "Like postwalk, but does pre-order traversal."
  [f form]
  (walk (partial prewalk f) identity (f form)))

(defn postwalk-demo
  "Demonstrates the behavior of postwalk by printing each form as it is walked."
  [form]
  (postwalk (fn [x] (print "Walked: ") (prn x) x) form))

(defn prewalk-demo
  "Demonstrates the behavior of prewalk by printing each form as it is walked."
  [form]
  (prewalk (fn [x] (print "Walked: ") (prn x) x) form))

(defn postwalk-replace
  "Recursively transforms form by replacing keys in smap with their
  values. Does replacement at the leaves of the tree first."
  [smap form]
  (postwalk (fn [x] (if (contains? smap x) (get smap x) x)) form))

(defn prewalk-replace
  "Recursively transforms form by replacing keys in smap with their
  values. Does replacement at the root of the tree first."
  [smap form]
  (prewalk (fn [x] (if (contains? smap x) (get smap x) x)) form))

(defn macroexpand-all
  "Recursively performs all possible macroexpansions in form."
  [form]
  (prewalk (fn [x] (if (seq? x) (macroexpand x) x)) form))

(defn keywordize-keys
  "Recursively transforms all map keys from strings to keywords."
  [m]
  (let [f (fn [[k v]] (if (string? k) [(keyword k) v] [k v]))]
    (postwalk (fn [x] (if (map? x) (into {} (map f x)) x)) m)))

(defn stringify-keys
  "Recursively transforms all map keys from keywords to strings."
  [m]
  (let [f (fn [[k v]] (if (keyword? k) [(name k) v] [k v]))]
    (postwalk (fn [x] (if (map? x) (into {} (map f x)) x)) m)))

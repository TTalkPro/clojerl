(ns clojure.string
  "String functions (clojerl2-020). Strings are UTF-8 binaries indexed
  by code point (known divergence :string/code-point-indexing); the work
  is done by clj2_string."
  (:refer-clojure :exclude [replace reverse]))

;; Every fn takes its string through str (a keyword or a symbol is its
;; name, as Java's toString), and refuses nil, as on the JVM.
(defn- ->s [s]
  (if (nil? s)
    (throw (ex-info "clojure.string: nil string" {:type :NullPointerException}))
    (str s)))

;; Where the JVM passes the argument to a Java method that takes a
;; CharSequence or a String (reverse's StringBuilder, escape's .length,
;; starts-with?'s prefix ...), anything else is a ClassCastException: a
;; keyword is not its name there.
(defn- cast-fail [x to]
  (throw (ex-info (str "class " (clj2_class/class_of x) " cannot be cast to class " to)
                  {:type :ClassCastException})))
(defn- ->cs [s]
  (cond (string? s) s
        (nil? s) (->s s)
        (= 'java.lang.StringBuilder (clj2_class/class_of s)) (str s)
        :else (cast-fail s "java.lang.CharSequence")))
(defn- ->string [s]
  (cond (string? s) s
        (nil? s) (->s s)
        :else (cast-fail s "java.lang.String")))

(defn upper-case [s] (clj2_string/upper (->s s)))
(defn lower-case [s] (clj2_string/lower (->s s)))
(defn capitalize [s] (clj2_string/capitalize (->s s)))
(defn trim [s] (clj2_string/trim (->s s)))
(defn triml [s] (clj2_string/triml (->s s)))
(defn trimr [s] (clj2_string/trimr (->s s)))
(defn trim-newline [s] (clj2_string/trim_newline (->s s)))
(defn blank? [s] (clj2_string/is_blank s))
(defn starts-with? [s substr] (clj2_string/starts_with (->s s) (->string substr)))
(defn ends-with? [s substr] (clj2_string/ends_with (->s s) (->string substr)))
(defn includes? [s substr] (clj2_string/includes (->s s) (->cs substr)))
(defn index-of
  ([s value] (clj2_string/index_of s value 0))
  ([s value from-index] (clj2_string/index_of s value from-index)))
(defn last-index-of
  ([s value] (clj2_string/last_index_of s value nil))
  ([s value from-index] (clj2_string/last_index_of s value from-index)))
(defn reverse [s] (clj2_string/reverse (->cs s)))
(defn join
  ([coll] (clj2_string/join "" coll))
  ([separator coll] (clj2_string/join separator coll)))
(defn split
  ([s re] (clj2_string/split s re 0))
  ([s re limit] (clj2_string/split s re limit)))
(defn split-lines [s] (clj2_string/split_lines s))
(defn- check-replace [match replacement]
  (when (nil? match) (throw (ex-info "Invalid match arg: " {:type :IllegalArgumentException})))
  (when (nil? replacement) (throw (ex-info "clojure.string: nil replacement" {:type :NullPointerException}))))
;; a string match takes a string replacement (CharSequence.replace); a
;; pattern's replacement fn must return a string (quoteReplacement)
(defn- replacement-of [match replacement]
  (cond (string? match) (->cs replacement)
        (and (regex? match) (fn? replacement)) (fn [m] (->string (replacement m)))
        :else replacement))
(defn replace [s match replacement]
  (check-replace match replacement)
  (clj2_string/replace (->s s) match (replacement-of match replacement) 'all))
(defn replace-first [s match replacement]
  (check-replace match replacement)
  (clj2_string/replace (->s s) match (replacement-of match replacement) 'first))
(defn escape [s cmap] (clj2_string/escape (->cs s) cmap))
(defn re-quote-replacement [replacement] (clj2_string/re_quote_replacement (->s replacement)))

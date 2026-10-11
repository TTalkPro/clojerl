(ns clojure.string
  "String functions (clojerl2-020). Strings are UTF-8 binaries indexed
  by code point (known divergence :string/code-point-indexing); the work
  is done by clj2_string."
  (:refer-clojure :exclude [replace reverse]))

(defn upper-case [s] (clj2_string/upper (str s)))
(defn lower-case [s] (clj2_string/lower (str s)))
(defn capitalize [s] (clj2_string/capitalize (str s)))
(defn trim [s] (clj2_string/trim s))
(defn triml [s] (clj2_string/triml s))
(defn trimr [s] (clj2_string/trimr s))
(defn trim-newline [s] (clj2_string/trim_newline s))
(defn blank? [s] (clj2_string/is_blank s))
(defn starts-with? [s substr] (clj2_string/starts_with s substr))
(defn ends-with? [s substr] (clj2_string/ends_with s substr))
(defn includes? [s substr] (clj2_string/includes s substr))
(defn index-of
  ([s value] (clj2_string/index_of s value 0))
  ([s value from-index] (clj2_string/index_of s value from-index)))
(defn last-index-of
  ([s value] (clj2_string/last_index_of s value nil))
  ([s value from-index] (clj2_string/last_index_of s value from-index)))
(defn reverse [s] (clj2_string/reverse s))
(defn join
  ([coll] (clj2_string/join "" coll))
  ([separator coll] (clj2_string/join separator coll)))
(defn split
  ([s re] (clj2_string/split s re 0))
  ([s re limit] (clj2_string/split s re limit)))
(defn split-lines [s] (clj2_string/split_lines s))
(defn replace [s match replacement] (clj2_string/replace s match replacement 'all))
(defn replace-first [s match replacement] (clj2_string/replace s match replacement 'first))
(defn escape [s cmap] (clj2_string/escape s cmap))
(defn re-quote-replacement [replacement] (clj2_string/re_quote_replacement replacement))

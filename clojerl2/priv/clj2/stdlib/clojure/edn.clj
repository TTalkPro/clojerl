(ns clojure.edn
  "Reading EDN data: clojure.core's literals, no code (no syntax-quote,
  #(), #' ...), tagged elements through :readers and :default.")

(defn read-string
  "Reads one EDN value from string s (nil for nil). opts: :eof, the value
  at end of input (none: end of input is an error); :readers, a map from
  tag symbol to reader fn; :default, a fn of tag and value for other tags."
  ;; as Clojure 1.12: with no opts, the end of input is nil
  ([s] (read-string {:eof nil} s))
  ([opts s] (clj2_edn/read_string opts s)))

(defn read
  "Reads the next EDN value from a reader (one made by java.io.StringReader
  or clojure.java.io): all of what it has left is read as one string."
  ([stream] (read {} stream))
  ([opts stream] (read-string opts (slurp stream))))

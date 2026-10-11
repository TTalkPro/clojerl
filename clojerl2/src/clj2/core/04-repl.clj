;; clojure.core — layer 04-repl (designs/04 §6.1, clojerl2-021).
;;
;; REPL helpers, library side. Docstrings come from the namespace
;; registry (clj2_ns: a var's `doc', designs/02 §2.1). The REPL itself is
;; clojerl2-023; `source' needs source retention and is not provided.

(in-ns 'clojure.core)

(defn print-doc [sym]
  (let [found (clj2_ns/find_var sym)]
    (if (nil? found)
      (println (str "No var " sym))
      (let [[ns-name var-name info] found]
        (println "-------------------------")
        (println (str ns-name "/" var-name))
        (when (get info :macro) (println "Macro"))
        (when-let [ar (seq (get info :arities))] (println (str "  arities: " (pr-str (vec ar)))))
        (when-let [d (get info :doc)] (println (str "  " d)))))
    nil))

(defmacro doc [sym] `(print-doc '~sym))

(defn dir-fn [ns-sym] (sort (map first (clj2_ns/public_vars ns-sym))))

(defmacro dir [ns-sym] `(doseq [v# (dir-fn '~ns-sym)] (println v#)))

(defn find-doc [s]
  (doseq [[ns-name var-name info] (clj2_ns/all_vars)]
    (when-let [d (get info :doc)]
      (when (or (clj2_rt/str_contains (str var-name) s) (clj2_rt/str_contains d s))
        (print-doc (symbol (str ns-name) (str var-name)))))))

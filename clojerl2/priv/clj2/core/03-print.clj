;; clojure.core — layer 03-print (designs/04 §6.1, clojerl2-021).
;;
;; pr/print family over the layer-0 printer (clj2_print) and *out*
;; (clj2_io: the process's group leader). print-method dispatch and
;; *print-length* etc. need multimethods/dynamic vars (017, 020).

(in-ns 'clojure.core)

;; Erlang io devices (clj2_io): rebinding them redirects printing and
;; reading, also inside futures and agent actions.
(def ^:dynamic *out* 'standard_io)
(def ^:dynamic *err* 'standard_error)
(def ^:dynamic *in* 'standard_io)

(defn pr-str [& xs] (clj2_rt/str (interpose " " (map #(clj2_print/pr_str %) xs))))
(defn prn-str [& xs] (str (apply pr-str xs) "\n"))
(defn print-str [& xs] (clj2_rt/str (interpose " " (map #(clj2_print/print_str %) xs))))
(defn println-str [& xs] (str (apply print-str xs) "\n"))

(defn pr [& xs] (clj2_io/write (apply pr-str xs)))
(defn prn [& xs] (clj2_io/write (apply prn-str xs)))
(defn print [& xs] (clj2_io/write (apply print-str xs)))
(defn println [& xs] (clj2_io/write (apply println-str xs)))
(defn newline [] (clj2_io/write "\n"))
(defn flush [] nil)

(defmacro with-out-str [& body]
  `(clj2_io/with_out_str (fn [] ~@body)))

(defn printf [fmt & args] (print (apply format fmt args)))

(defn read-line [] (clj2_io/read_line))

(defmacro with-in-str [s & body]
  `(clj2_io/with_in_str ~s (fn [] ~@body)))


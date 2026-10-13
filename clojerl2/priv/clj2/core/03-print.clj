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

(defn line-seq
  "The lines of text from rdr as a lazy sequence of strings."
  [rdr]
  (when-let [line (clj2_io/read_line rdr)]
    (cons line (lazy-seq (line-seq rdr)))))

(defn read
  "Reads the next object from stream (default *in*)."
  ([] (clj2_io/read_form *in* true nil false))
  ([stream] (clj2_io/read_form stream true nil false))
  ([opts stream]
   (if (contains? opts :eof)
     (clj2_io/read_form stream false (:eof opts) false)
     (clj2_io/read_form stream true nil false)))
  ([stream eof-error? eof-value] (clj2_io/read_form stream eof-error? eof-value false))
  ([stream eof-error? eof-value recursive?] (clj2_io/read_form stream eof-error? eof-value false)))

(defn read+string
  "Like read, and also returns the string read, as [form text]."
  ([] (clj2_io/read_form *in* true nil true))
  ([stream] (clj2_io/read_form stream true nil true))
  ([stream eof-error? eof-value] (clj2_io/read_form stream eof-error? eof-value true))
  ([stream eof-error? eof-value recursive?] (clj2_io/read_form stream eof-error? eof-value true))
  ([opts stream]
   (if (contains? opts :eof)
     (clj2_io/read_form stream false (:eof opts) true)
     (clj2_io/read_form stream true nil true))))

(defmacro with-in-str [s & body]
  `(clj2_io/with_in_str ~s (fn [] ~@body)))


;; clojure.pprint's hooks: core printing reaches a pretty writer bound to
;; *out* through the write hook (clj2_io:write/2); routing is the body as is
(defn __set-pprint-write-hook! [f] (clj2_io/set_write_hook f))
(defn __with-pprint-routing [f] (f))

;; as clojure.core's core_print: under *print-namespace-maps*, a map whose
;; keys are all qualified idents of one namespace → [ns map-without-it]
(defn- lift-ns [m]
  (when *print-namespace-maps*
    (loop [ns nil [[k v :as entry] & entries] (seq m) lm {}]
      (if entry
        (when (qualified-ident? k)
          (let [strip (if (symbol? k) (symbol (name k)) (keyword (name k)))]
            (if ns
              (when (= ns (namespace k)) (recur ns entries (assoc lm strip v)))
              (recur (namespace k) entries (assoc lm strip v)))))
        [ns (apply conj (empty m) lm)]))))

;; print-method: the printer consults it for a value whose type has a
;; method of the user's (clj2_print); :default is the built-in printer
(def print-method (clj2_multi/new 'clojure.core 'print-method (fn [x writer] (clj2_class/type_of x)) :default nil))
(defmethod print-method :default [x writer] (clj2_print/write_builtin x writer))
(def print-dup (clj2_multi/new 'clojure.core 'print-dup (fn [x writer] (clj2_class/type_of x)) :default nil))
(defmethod print-dup :default [x writer] (print-method x writer))

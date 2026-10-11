;; clojure.core — layer 01-core (designs/04 §6.1, clojerl2-021).
;;
;; The bulk of clojure.core over 00-kernel: seq and collection library,
;; maps, higher-order fns, comparison/sorting, strings, exceptions,
;; control macros. Written in Clojure on the kernel and layer-0
;; primitives (clj2_coll, clj2_rt). Reference types (atom, agent ...,
;; 018), multimethods (017), regex and the IO layer (020) come later.

(in-ns 'clojure.core)

;;;; ------------------------------------------------------------------
;;;; Seqs
;;;; ------------------------------------------------------------------

(defn sequence
  ([coll] (if (seq? coll) coll (or (seq coll) '())))
  ([xform coll] (or (seq (transduce xform (completing conj) [] coll)) '())))

(defn cat [rf]
  (fn ([] (rf))
      ([r] (rf r))
      ([r x] (reduce (fn [acc y] (let [v (rf acc y)] (if (reduced? v) (reduced v) v))) r x))))

(defn keep
  ([f] (fn [rf] (fn ([] (rf)) ([r] (rf r)) ([r x] (let [v (f x)] (if (nil? v) r (rf r v)))))))
  ([f coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [v (f (first s))]
         (if (nil? v) (keep f (rest s)) (cons v (keep f (rest s)))))))))

(defn map-indexed [f coll]
  (map f (range) coll))

(defn keep-indexed [f coll]
  (keep (fn [[i x]] (f i x)) (map vector (range) coll)))

(defn mapv
  ([f coll] (vec (map f coll)))
  ([f c1 c2] (vec (map f c1 c2))))

(defn filterv [pred coll] (vec (filter pred coll)))

(defn reductions
  ([f coll]
   (lazy-seq
     (if-let [s (seq coll)]
       (reductions f (first s) (rest s))
       (list (f)))))
  ([f init coll]
   (cons init
         (lazy-seq
           (when-let [s (seq coll)]
             (reductions f (f init (first s)) (rest s)))))))

(defn partition
  ([n coll] (partition n n coll))
  ([n step coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [p (take n s)]
         (when (= n (count p))
           (cons p (partition n step (nthrest s step)))))))))

(defn partition-all
  ([n coll] (partition-all n n coll))
  ([n step coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [p (vec (take n s))]
         (cons (seq p) (partition-all n step (nthrest s step))))))))

(defn partition-by [f coll]
  (lazy-seq
    (when-let [s (seq coll)]
      (let [fst (first s)
            fv (f fst)
            run (cons fst (take-while #(= fv (f %)) (next s)))]
        (cons run (partition-by f (seq (drop (count run) s))))))))

(defn group-by [f coll]
  (reduce (fn [m x] (let [k (f x)] (assoc m k (conj (get m k []) x)))) {} coll))

(defn frequencies [coll]
  (reduce (fn [m x] (assoc m x (inc (get m x 0)))) {} coll))

(defn distinct [coll]
  (let [step (fn step [xs seen]
               (lazy-seq
                 (when-let [s (seq xs)]
                   (let [f (first s)]
                     (if (contains? seen f)
                       (step (rest s) seen)
                       (cons f (step (rest s) (conj seen f))))))))]
    (step coll #{})))

(defn dedupe [coll]
  (let [step (fn step [xs prev first?]
               (lazy-seq
                 (when-let [s (seq xs)]
                   (let [f (first s)]
                     (if (and (not first?) (= f prev))
                       (step (rest s) prev false)
                       (cons f (step (rest s) f false)))))))]
    (step coll nil true)))

(defn interpose [sep coll]
  (drop 1 (mapcat (fn [x] (list sep x)) coll)))

(defn interleave
  ([] '())
  ([c1] (lazy-seq c1))
  ([c1 c2]
   (lazy-seq
     (let [s1 (seq c1) s2 (seq c2)]
       (when (and s1 s2)
         (cons (first s1) (cons (first s2) (interleave (rest s1) (rest s2)))))))))

(defn tree-seq [branch? children root]
  (let [walk (fn walk [node]
               (lazy-seq
                 (cons node
                       (when (branch? node)
                         (mapcat walk (children node))))))]
    (walk root)))

(defn flatten [x]
  (filter (complement sequential?) (rest (tree-seq sequential? seq x))))

(defn nthrest [coll n] (or (nthnext coll n) '()))

(defn take-last [n coll]
  (let [v (vec coll) c (count v)]
    (seq (drop (max 0 (- c n)) v))))

(defn drop-last
  ([coll] (drop-last 1 coll))
  ([n coll] (map (fn [x _] x) coll (drop n coll))))

(defn butlast [coll] (seq (drop-last coll)))

(defn take-nth [n coll]
  (lazy-seq
    (when-let [s (seq coll)]
      (cons (first s) (take-nth n (drop n s))))))

(defn split-at [n coll] [(take n coll) (drop n coll)])
(defn split-with [pred coll] [(take-while pred coll) (drop-while pred coll)])

(defn not-any? [pred coll] (not (some pred coll)))
(defn not-every? [pred coll] (not (every? pred coll)))
(defn run! [f coll] (reduce (fn [_ x] (f x) nil) nil coll) nil)

(defn rseq [v] (seq (reverse v)))

(defn max-key
  ([k x] x)
  ([k x y] (if (> (k x) (k y)) x y))
  ([k x y & more] (reduce #(max-key k %1 %2) (max-key k x y) more)))

(defn min-key
  ([k x] x)
  ([k x y] (if (< (k x) (k y)) x y))
  ([k x y & more] (reduce #(min-key k %1 %2) (min-key k x y) more)))

(defn trampoline
  ([f] (let [ret (f)] (if (fn? ret) (recur ret) ret)))
  ([f & args] (trampoline #(apply f args))))

;;;; ------------------------------------------------------------------
;;;; Collections and maps
;;;; ------------------------------------------------------------------

(defn peek [coll]
  (cond (vector? coll) (when (pos? (count coll)) (nth coll (dec (count coll))))
        :else (first coll)))

(defn pop [coll]
  (cond (vector? coll) (if (zero? (count coll))
                         (throw (ex-info "Can't pop empty vector" {}))
                         (vec (take (dec (count coll)) coll)))
        :else (rest coll)))

(defn subvec
  ([v start] (subvec v start (count v)))
  ([v start end] (vec (take (- end start) (drop start v)))))

(defn disj
  ([s] s)
  ([s k] (if (contains? s k) (set (remove #(= % k) s)) s))
  ([s k & ks] (reduce disj (disj s k) ks)))

(defn empty [coll]
  (cond (vector? coll) []
        (map? coll) {}
        (set? coll) #{}
        (seq? coll) '()
        :else nil))

(defn not-empty [coll] (when (seq coll) coll))

(defn seqable? [x] (or (nil? x) (coll? x) (string? x)))

(defn distinct? [& xs] (= (count xs) (count (set xs))))

(defn find [m k] (when (contains? m k) [k (get m k)]))
(defn key [e] (nth e 0))
(defn val [e] (nth e 1))

(defn zipmap [ks vs]
  (loop [m {} ks (seq ks) vs (seq vs)]
    (if (and ks vs)
      (recur (assoc m (first ks) (first vs)) (next ks) (next vs))
      m)))

(defn merge [& maps]
  (when (some identity maps)
    (reduce (fn [m x] (if (nil? x) m (conj (or m {}) x))) maps)))

(defn merge-with [f & maps]
  (when (some identity maps)
    (reduce (fn [m x]
              (reduce (fn [acc [k v]]
                        (if (contains? acc k) (assoc acc k (f (get acc k) v)) (assoc acc k v)))
                      (or m {}) x))
            maps)))

(defn update
  ([m k f] (assoc m k (f (get m k))))
  ([m k f x] (assoc m k (f (get m k) x)))
  ([m k f x y] (assoc m k (f (get m k) x y)))
  ([m k f x y & more] (assoc m k (apply f (get m k) x y more))))

(defn get-in
  ([m ks] (reduce get m ks))
  ([m ks not-found]
   (loop [m m ks (seq ks)]
     (if ks
       (if (contains? m (first ks)) (recur (get m (first ks)) (next ks)) not-found)
       m))))

(defn assoc-in [m [k & ks] v]
  (if ks
    (assoc m k (assoc-in (get m k) ks v))
    (assoc m k v)))

(defn update-in [m [k & ks] f & args]
  (if ks
    (assoc m k (apply update-in (get m k) ks f args))
    (assoc m k (apply f (get m k) args))))

(defn select-keys [m ks]
  (reduce (fn [acc k] (if (contains? m k) (assoc acc k (get m k)) acc)) {} ks))

(defn update-vals [m f] (reduce (fn [acc [k v]] (assoc acc k (f v))) {} m))
(defn update-keys [m f] (reduce (fn [acc [k v]] (assoc acc (f k) v)) {} m))

(defn reduce-kv [f init m]
  (if (vector? m)
    (reduce (fn [acc [i x]] (f acc i x)) init (map vector (range) m))
    (reduce (fn [acc [k v]] (f acc k v)) init m)))

(defn array-map [& kvs] (apply hash-map kvs))

;;;; ------------------------------------------------------------------
;;;; Functions
;;;; ------------------------------------------------------------------

(defn juxt [& fs] (fn [& args] (vec (map #(apply % args) fs))))

(defn fnil
  ([f x] (fn [a & more] (apply f (if (nil? a) x a) more)))
  ([f x y] (fn [a b & more] (apply f (if (nil? a) x a) (if (nil? b) y b) more))))

(defn every-pred [& ps] (fn [& xs] (every? (fn [p] (every? p xs)) ps)))
(defn some-fn [& ps] (fn [& xs] (some (fn [p] (some p xs)) ps)))

;;;; ------------------------------------------------------------------
;;;; Comparison, sorting, numbers
;;;; ------------------------------------------------------------------

(defn compare [x y] (clj2_rt/compare x y))

(defn sort
  ([coll] (sort compare coll))
  ([cmp coll] (seq (clj2_rt/sort cmp coll))))

(defn sort-by
  ([keyfn coll] (sort-by keyfn compare coll))
  ([keyfn cmp coll] (sort (fn [a b] (cmp (keyfn a) (keyfn b))) coll)))

(defn shuffle [coll] (vec (map second (sort-by first (map (fn [x] [(rand/uniform) x]) coll)))))
(defn rand ([] (rand/uniform_real)) ([n] (* n (rand/uniform_real))))
(defn rand-int [n] (dec (rand/uniform n)))
(defn rand-nth [coll] (nth coll (rand-int (count coll))))

(defn boolean [x] (if x true false))
(defn int? [x] (integer? x))
(defn pos-int? [x] (and (integer? x) (pos? x)))
(defn neg-int? [x] (and (integer? x) (neg? x)))
(defn nat-int? [x] (and (integer? x) (not (neg? x))))
(defn double? [x] (float? x))
(defn any? [_] true)
(defn abs [x] (erlang/abs x))
(defn bit-and [x y] (erlang/band x y))
(defn bit-or [x y] (erlang/bor x y))
(defn bit-xor [x y] (erlang/bxor x y))
(defn bit-not [x] (erlang/bnot x))
(defn bit-shift-left [x n] (erlang/bsl x n))
(defn bit-shift-right [x n] (erlang/bsr x n))
(defn hash [x] (erlang/phash2 x))
(defn parse-long [s] (try (erlang/binary_to_integer s) (catch :error _ nil)))
(defn parse-double [s]
  (try (erlang/binary_to_float s)
       (catch :error _ (try (erlang/float (erlang/binary_to_integer s)) (catch :error _ nil)))))
(defn parse-boolean [s] (case s "true" true "false" false nil))

;;;; ------------------------------------------------------------------
;;;; Strings and exceptions
;;;; ------------------------------------------------------------------

(defn subs
  ([s start] (clj2_rt/subs s start nil))
  ([s start end] (clj2_rt/subs s start end)))

(defn format [fmt & args] (clj2_rt/format fmt args))

(defn ex-info
  ([msg data] (clj2_rt/ex_info msg data nil))
  ([msg data cause] (clj2_rt/ex_info msg data cause)))
(defn ex-message [e] (clj2_rt/ex_message e))
(defn ex-data [e] (clj2_rt/ex_data e))
(defn ex-cause [e] (clj2_rt/ex_cause e))

;;;; ------------------------------------------------------------------
;;;; Control macros (after the functions their expanders call)
;;;; ------------------------------------------------------------------

(defmacro if-some
  ([bindings then] `(if-some ~bindings ~then nil))
  ([bindings then else]
   (let [form (first bindings) tst (second bindings)]
     `(let* [temp# ~tst]
        (if (nil? temp#) ~else (let [~form temp#] ~then))))))

(defmacro when-some [bindings & body]
  `(if-some ~bindings (do ~@body) nil))

(defmacro when-first [bindings & body]
  (let [x (first bindings) xs (second bindings)]
    `(when-let [s# (seq ~xs)] (let [~x (first s#)] ~@body))))

(defmacro cond-> [expr & clauses]
  (let [g (gensym "cond__")
        steps (map (fn [[test step]]
                     `(if ~test (-> ~g ~step) ~g))
                   (partition 2 clauses))]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro cond->> [expr & clauses]
  (let [g (gensym "cond__")
        steps (map (fn [[test step]]
                     `(if ~test (->> ~g ~step) ~g))
                   (partition 2 clauses))]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro some-> [expr & forms]
  (let [g (gensym "some__")
        steps (map (fn [step] `(if (nil? ~g) nil (-> ~g ~step))) forms)]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro some->> [expr & forms]
  (let [g (gensym "some__")
        steps (map (fn [step] `(if (nil? ~g) nil (->> ~g ~step))) forms)]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro as-> [expr name & forms]
  `(let [~name ~expr ~@(interleave (repeat name) (butlast forms))]
     ~(if (empty? forms) name (last forms))))

(defmacro condp [pred expr & clauses]
  (let [gpred (gensym "pred__") gexpr (gensym "expr__")
        emit (fn emit [args]
               (let [n (count args)]
                 (cond
                   (= 0 n) `(throw (ex-info (str "No matching clause: " ~gexpr) {}))
                   (= 1 n) (first args)
                   (= :>> (second args))
                   `(if-let [p# (~gpred ~(first args) ~gexpr)]
                      (~(nth args 2) p#)
                      ~(emit (drop 3 args)))
                   :else `(if (~gpred ~(first args) ~gexpr)
                            ~(second args)
                            ~(emit (drop 2 args))))))]
    `(let [~gpred ~pred ~gexpr ~expr] ~(emit clauses))))

(defmacro while [test & body]
  `(loop* [] (if ~test (do ~@body (recur)) nil)))

(defmacro assert
  ([x] `(when-not ~x (throw (ex-info (str "Assert failed: " (pr-str '~x)) {}))))
  ([x message] `(when-not ~x (throw (ex-info (str "Assert failed: " ~message) {})))))

;; namespaces are compiled as a unit: defonce is def
(defmacro defonce [name expr] `(def ~name ~expr))

(defmacro time [expr]
  `(let [start# (erlang/monotonic_time :microsecond)
         ret# ~expr]
     (println (str "\"Elapsed time: " (/ (- (erlang/monotonic_time :microsecond) start#) 1000.0) " msecs\""))
     ret#))

;; (for [x xs :when t :let [..] :while t y ys] body), lazy
(defmacro for [seq-exprs body-expr]
  (let [emit (fn emit [bs]
               (if (seq bs)
                 (let [b (first bs) v (second bs) more (nnext bs)]
                   (cond
                     (= b :when) `(if ~v ~(emit more) '())
                     (= b :let) `(let ~v ~(emit more))
                     (= b :while) (emit more)
                     :else
                     (let [while-test (when (= :while (first more)) (second more))
                           coll (if while-test `(take-while (fn [~b] ~while-test) ~v) v)]
                       `(mapcat (fn [~b] ~(emit more)) ~coll))))
                 `(list ~body-expr)))]
    (emit (seq seq-exprs))))

;;;; ------------------------------------------------------------------
;;;; Evaluation and namespaces (clojerl2-023, clj2_rt_eval)
;;;;
;;;; A namespace is its symbol (no Namespace objects). *ns* is bound per
;;;; process: in-ns changes this process's current namespace.

(def ^:dynamic *ns* 'user)

;; The CLI binds it to the arguments after the script or -m namespace.
(def ^:dynamic *command-line-args* nil)

(defn in-ns [name] (clj2_rt_eval/in_ns name))
(defn eval [form] (clj2_rt_eval/eval form))
(defn read-string [s] (clj2_rt_eval/read_string s))
(defn load-string [s] (clj2_rt_eval/load_string s))
(defn load-file [path] (clj2_rt_eval/load_file path))
(defn macroexpand-1 [form] (clj2_rt_eval/macroexpand_1 form))
(defn macroexpand [form] (clj2_rt_eval/macroexpand form))
(defn require [& args] (clj2_rt_eval/require args))

(defn all-ns [] (seq (clj2_ns/all)))
(defn find-ns [name] (when (clj2_ns/find_ns name) name))
(defn the-ns [x]
  (if (find-ns x) x (throw (ex-info (str "No namespace: " x " found") {:ns x}))))
(defn create-ns [name] (clj2_ns/ensure name) name)
(defn ns-name [ns] (the-ns ns))

;;;; ------------------------------------------------------------------
;;;; Refs and STM: not provided (designs/03 §5.2). BEAM has no
;;;; multi-object transactional memory and faking one would lie; these
;;;; raise instead of being missing (known divergence :refs/no-stm).

(defn stm-unsupported
  "Raises: refs and STM are not supported (designs/03 §5.2)."
  [what]
  (throw (ex-info (str what ": refs and STM (dosync) are not supported on clojerl2;"
                       " keep related state in one process and update it by message")
                  {:unsupported what})))

(defn ref [& _] (stm-unsupported "ref"))
(defn alter [& _] (stm-unsupported "alter"))
(defn commute [& _] (stm-unsupported "commute"))
(defn ref-set [& _] (stm-unsupported "ref-set"))
(defn ensure [& _] (stm-unsupported "ensure"))
(defmacro dosync [& _] `(stm-unsupported "dosync"))
(defmacro sync [& _] `(stm-unsupported "sync"))

;; There are no chunked seqs (known divergence :lazy-seq/no-chunking).
(defn chunked-seq? [s] false)

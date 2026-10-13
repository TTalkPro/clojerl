;; clojure.core — layer 01-core (designs/04 §6.1, clojerl2-021).
;;
;; The bulk of clojure.core over 00-kernel: seq and collection library,
;; maps, higher-order fns, comparison/sorting, strings, exceptions,
;; control macros. Written in Clojure on the kernel and layer-0
;; primitives (clj2_coll, clj2_rt). Reference types (atom, agent ...,
;; 018), multimethods (017), regex and the IO layer (020) come later.

(in-ns 'clojure.core)

;; volatiles first: the stateful transducers below keep their state in them
(defn volatile! [x] (clj2_ref/volatile x))
(defn vreset! [vol v] (clj2_ref/vreset vol v))
(defmacro vswap! [vol f & args]
  `(let [v# ~vol] (vreset! v# (~f (deref v#) ~@args))))
(defn volatile? [x] (= (clj2_ref/type_of x) 'volatile))

;;;; ------------------------------------------------------------------
;;;; Seqs
;;;; ------------------------------------------------------------------

(defn sequence
  ([coll] (if (seq? coll) coll (or (seq coll) '())))
  ([xform coll]
   ;; lazy, one source element at a time: each step runs the xform into an
   ;; empty buffer; the completion (stateful xforms flush there) runs once,
   ;; when the source ends or a step is reduced. The xform is instantiated
   ;; when the seq is first realized, so its state (volatiles live in a
   ;; process) belongs to the process that walks it.
   (let [step (fn step [rf s]
                (lazy-seq
                  (loop [s s]
                    (if-let [xs (seq s)]
                      (let [buf (rf [] (first xs))]
                        (cond (reduced? buf) (seq (rf @buf))
                              (zero? (count buf)) (recur (rest xs))
                              :else (concat buf (step rf (rest xs)))))
                      (seq (rf []))))))]
     (lazy-seq (step (xform (fn ([acc] acc) ([acc x] (conj acc x)))) coll)))))

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

(defn map-indexed
  ([f]
   (fn [rf]
     (let [i (volatile! -1)]
       (fn ([] (rf)) ([result] (rf result))
         ([result input] (rf result (f (vswap! i inc) input)))))))
  ([f coll] (map f (range) coll)))

(defn keep-indexed
  ([f]
   (fn [rf]
     (let [iv (volatile! -1)]
       (fn ([] (rf)) ([result] (rf result))
         ([result input]
          (let [v (f (vswap! iv inc) input)]
            (if (nil? v) result (rf result v))))))))
  ([f coll] (keep (fn [[i x]] (f i x)) (map vector (range) coll))))

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
           (cons p (partition n step (nthrest s step))))))))
  ([n step pad coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [p (take n s)]
         (if (= n (count p))
           (cons p (partition n step pad (nthrest s step)))
           (list (take n (concat p pad)))))))))

(defn partition-all
  ([n]
   (fn [rf]
     (let [a (volatile! [])]
       (fn
         ([] (rf))
         ([result]
          (let [result (if (zero? (count @a))
                         result
                         (let [v @a] (vreset! a []) (unreduced (rf result v))))]
            (rf result)))
         ([result input]
          (vswap! a conj input)
          (if (= n (count @a))
            (let [v @a] (vreset! a []) (rf result v))
            result))))))
  ([n coll] (partition-all n n coll))
  ([n step coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [p (vec (take n s))]
         (cons (seq p) (partition-all n step (nthrest s step))))))))

(defn partition-by
  ([f]
   (fn [rf]
     (let [buf (volatile! [])
           pv (volatile! nil)
           started (volatile! false)]
       (fn
         ([] (rf))
         ([result]
          (let [b @buf
                result (if (zero? (count b))
                         result
                         (do (vreset! buf []) (unreduced (rf result b))))]
            (rf result)))
         ([result input]
          (let [val (f input)]
            (if (or (not @started) (= val @pv))
              (do (vreset! started true) (vreset! pv val) (vswap! buf conj input) result)
              (let [b @buf]
                (vreset! buf []) (vreset! pv val)
                (let [ret (rf result b)]
                  (when-not (reduced? ret) (vswap! buf conj input))
                  ret)))))))))
  ([f coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [fst (first s)
             fv (f fst)
             run (cons fst (take-while #(= fv (f %)) (next s)))]
         (cons run (partition-by f (seq (drop (count run) s)))))))))

(defn group-by [f coll]
  (reduce (fn [m x] (let [k (f x)] (assoc m k (conj (get m k []) x)))) {} coll))

(defn frequencies [coll]
  (reduce (fn [m x] (assoc m x (inc (get m x 0)))) {} coll))

(defn distinct
  ([]
   (fn [rf]
     (let [seen (volatile! #{})]
       (fn ([] (rf)) ([result] (rf result))
         ([result input]
          (if (contains? @seen input)
            result
            (do (vswap! seen conj input) (rf result input))))))))
  ([coll]
  (let [step (fn step [xs seen]
               (lazy-seq
                 (when-let [s (seq xs)]
                   (let [f (first s)]
                     (if (contains? seen f)
                       (step (rest s) seen)
                       (cons f (step (rest s) (conj seen f))))))))]
    (step coll #{}))))

(defn dedupe
  ([]
   (fn [rf]
     (let [pv (volatile! ::none)]
       (fn ([] (rf)) ([result] (rf result))
         ([result input]
          (let [prior @pv]
            (vreset! pv input)
            (if (= prior input) result (rf result input))))))))
  ([coll]
  (let [step (fn step [xs prev first?]
               (lazy-seq
                 (when-let [s (seq xs)]
                   (let [f (first s)]
                     (if (and (not first?) (= f prev))
                       (step (rest s) prev false)
                       (cons f (step (rest s) f false)))))))]
    (step coll nil true))))

(defn interpose
  ([sep]
   (fn [rf]
     (let [started (volatile! false)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (if @started
            (let [sepr (rf result sep)]
              (if (reduced? sepr) sepr (rf sepr input)))
            (do (vreset! started true) (rf result input))))))))
  ([sep coll]
   (drop 1 (interleave (repeat sep) coll))))

(defn interleave
  ([] '())
  ([c1] (lazy-seq c1))
  ([c1 c2]
   (lazy-seq
     (let [s1 (seq c1) s2 (seq c2)]
       (when (and s1 s2)
         (cons (first s1) (cons (first s2) (interleave (rest s1) (rest s2))))))))
  ([c1 c2 & colls]
   (lazy-seq
     (let [ss (map seq (conj colls c2 c1))]
       (when (every? identity ss)
         (concat (map first ss) (apply interleave (map rest ss))))))))

(defn tree-seq [branch? children root]
  (let [walk (fn walk [node]
               (lazy-seq
                 (cons node
                       (when (branch? node)
                         (mapcat walk (children node))))))]
    (walk root)))

(defn flatten [x]
  (filter (complement sequential?) (rest (tree-seq sequential? seq x))))

(defn nthrest [coll n]
  ;; as clojure 1.12: n <= 0 is coll itself; past the end is ()
  (if (pos? n)
    (loop [n n xs coll]
      (if (pos? n)
        (if-let [s (seq xs)] (recur (dec n) (rest s)) ())
        xs))
    coll))

(defn take-last [n coll]
  (let [v (vec coll) c (count v)]
    (seq (drop (max 0 (- c n)) v))))

(defn drop-last
  ([coll] (drop-last 1 coll))
  ([n coll] (map (fn [x _] x) coll (drop n coll))))

(defn butlast [coll] (seq (drop-last coll)))

(defn take-nth
  ([n]
   (fn [rf]
     (let [iv (volatile! -1)]
       (fn
         ([] (rf))
         ([result] (rf result))
         ([result input]
          (if (zero? (rem (vswap! iv inc) n))
            (rf result input)
            result))))))
  ([n coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (cons (first s) (take-nth n (drop n s)))))))

(defn split-at [n coll] [(take n coll) (drop n coll)])
(defn split-with [pred coll] [(take-while pred coll) (drop-while pred coll)])

(defn not-any? [pred coll] (not (some pred coll)))
(defn not-every? [pred coll] (not (every? pred coll)))
(defn run! [f coll] (reduce (fn [_ x] (f x)) nil coll) nil)

(defn rseq [v]
  (cond (clj2_sorted/is_sorted v) (clj2_sorted/rseq v)
        (vector? v) (seq (reverse v))
        :else (throw (new ClassCastException (str "class " (clj2_class/class_of v)
                                                  " cannot be cast to class clojure.lang.Reversible")))))

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
        (or (nil? coll) (list? coll)) (first coll)
        :else (throw (new ClassCastException (str "class " (clj2_class/class_of coll)
                                                  " cannot be cast to class clojure.lang.IPersistentStack")))))

(defn pop [coll]
  (cond (vector? coll) (clj2_coll/pop_vector coll)
        (nil? coll) nil
        (or (map? coll) (set? coll) (string? coll) (number? coll) (keyword? coll))
        (throw (ex-info (str "class " (clj2_class/class_of coll) " cannot be cast to class clojure.lang.IPersistentStack")
                        {:type :ClassCastException}))
        (and (list? coll) (empty? coll))
        (throw (ex-info "Can't pop empty list" {:type :IllegalStateException}))
        :else (rest coll)))

(defn subvec
  ([v start] (subvec v start (count v)))
  ([v start end] (clj2_coll/subvec v start end)))

(defn disj
  ([s] s)
  ([s k] (cond (nil? s) nil
               (clj2_sorted/is_sorted s) (clj2_sorted/disj s k)
               (not (set? s)) (throw (new ClassCastException (str "class " (clj2_class/class_of s)
                                                                 " cannot be cast to class clojure.lang.IPersistentSet")))
               (contains? s k) (clj2_coll/disj_set s k)
               :else s))
  ([s k & ks] (reduce disj (disj s k) ks)))

(defn empty [coll]
  (let [e (cond (clj2_sorted/is_sorted coll) (clj2_sorted/empty coll)
                (vector? coll) []
                (clj2_coll/is_record coll)
                (throw (ex-info (str "Can't create empty: " (clj2_class/class_of coll))
                                {:type :UnsupportedOperationException}))
                (map? coll) {}
                (set? coll) #{}
                (seq? coll) '()
                :else nil)
        m (clj2_rt/meta coll)]
    (if (and m (some? e) (not (clj2_sorted/is_sorted coll))) (clj2_rt/with_meta e m) e)))

(defn not-empty [coll] (when (seq coll) coll))

(defn seqable? [x] (or (nil? x) (coll? x) (string? x)))

(defn distinct? [& xs] (= (count xs) (count (set xs))))

(defn find [m k]
  ;; maps, records and vectors are associative (and transients of them);
  ;; sets, strings, lists ... are not
  (cond (nil? m) nil
        (or (map? m) (vector? m)
            (and (clj2_proto/is_type_value m) (erlang/is_map (erlang/element 3 m)))
            (and (clj2_rt/is_transient m) (let [c (clj2_rt/persistent m)] (or (map? c) (vector? c)))))
        (when (contains? m k) [k (get m k)])
        :else (throw (ex-info (str "find not supported on type: " (clj2_class/class_of m))
                              {:type :IllegalArgumentException}))))
(defn key [e] (clj2_coll/entry_part e 1))
(defn val [e] (clj2_coll/entry_part e 2))

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
   ;; get with a sentinel, as the JVM: a value that is not a map is a miss
   (let [sentinel (clj2_rt/gensym "get_in__")]
     (loop [m m ks (seq ks)]
       (if ks
         (let [v (get m (first ks) sentinel)]
           (if (identical? v sentinel) not-found (recur v (next ks))))
         m)))))

(defn assoc-in [m [k & ks] v]
  (if ks
    (assoc m k (assoc-in (get m k) ks v))
    (assoc m k v)))

(defn update-in [m [k & ks] f & args]
  (if ks
    (assoc m k (apply update-in (get m k) ks f args))
    (assoc m k (apply f (get m k) args))))

(defn select-keys [m ks]
  (clj2_rt/with_meta (reduce (fn [acc k] (if-let [e (find m k)] (conj acc e) acc)) {} ks) (clj2_rt/meta m)))

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
  ([f x y] (fn [a b & more] (apply f (if (nil? a) x a) (if (nil? b) y b) more)))
  ([f x y z] (fn [a b c & more] (apply f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c) more))))

(defn every-pred [& ps] (fn [& xs] (every? (fn [p] (every? p xs)) ps)))
(defn some-fn
  "A fn returning the first logical true value of any of ps over its args,
  else false (it needs at least one predicate)."
  [& ps]
  (when (empty? ps)
    (throw (ex-info "Wrong number of args (0) passed to: clojure.core/some-fn" {:type :ArityException})))
  (fn [& xs] (or (some (fn [p] (some p xs)) ps) false)))

;;;; ------------------------------------------------------------------
;;;; Comparison, sorting, numbers
;;;; ------------------------------------------------------------------

(defn compare [x y] (clj2_rt/compare x y))

(defn sort
  ([coll] (sort compare coll))
  ([cmp coll] (if (seq coll) (seq (clj2_rt/sort cmp coll)) ())))

(defn sort-by
  ([keyfn coll] (sort-by keyfn compare coll))
  ([keyfn cmp coll] (sort (fn [a b] (cmp (keyfn a) (keyfn b))) coll)))

(defn shuffle [coll]
  (when (nil? coll)
    (throw (new NullPointerException "Cannot invoke \"java.util.Collection.toArray()\" because \"coll\" is null")))
  (when (or (string? coll) (map? coll) (not (coll? coll)))
    (throw (new ClassCastException (str "class " (clj2_class/class_of coll)
                                        " cannot be cast to class java.util.Collection"))))
  (vec (map second (sort-by first (map (fn [x] [(rand/uniform) x]) coll)))))
(defn rand ([] (rand/uniform_real)) ([n] (* n (rand/uniform_real))))
(defn rand-int [n] (if (pos? n) (dec (rand/uniform n)) 0))
(defn rand-nth [coll] (nth coll (rand-int (count coll))))

(defn boolean [x] (if x true false))
(defn int? [x] (integer? x))
(defn pos-int? [x] (and (integer? x) (pos? x)))
(defn neg-int? [x] (and (integer? x) (neg? x)))
(defn nat-int? [x] (and (integer? x) (not (neg? x))))
(defn double? [x] (float? x))
(defn any? [_] true)
(defn abs [x] (if (clj2_decimal/is_decimal x) (clj2_decimal/abs x) (erlang/abs x)))
(defn bit-and ([x y] (erlang/band x y)) ([x y & more] (reduce bit-and (bit-and x y) more)))
(defn bit-or ([x y] (erlang/bor x y)) ([x y & more] (reduce bit-or (bit-or x y) more)))
(defn bit-xor ([x y] (erlang/bxor x y)) ([x y & more] (reduce bit-xor (bit-xor x y) more)))
(defn bit-not [x] (erlang/bnot x))
(defn bit-shift-left [x n] (erlang/bsl x n))
(defn bit-shift-right [x n] (erlang/bsr x n))
(defn hash [x] (clj2_coll/hash x))
(defn- parse-arg [s]
  (when-not (string? s)
    (throw (new IllegalArgumentException (str "Expected string, got " (if (nil? s) "nil" (clj2_class/class_of s))))))
  s)
(defn parse-long [s] (let [s (parse-arg s)] (try (erlang/binary_to_integer s) (catch :error _ nil))))
(defn parse-double [s] (clj2_jvm/parse_double_or_nil (parse-arg s)))
(defn parse-boolean [s]
  (if (string? s)
    (case s "true" true "false" false nil)
    (throw (ex-info (str "Expected string, got " (if (nil? s) "nil" (clj2_class/class_of s)))
                    {:type :IllegalArgumentException}))))

;;;; ------------------------------------------------------------------
;;;; Strings and exceptions
;;;; ------------------------------------------------------------------

(defn subs
  ([s start] (clj2_rt/subs s start nil))
  ([s start end]
   (when (nil? end) (throw (new NullPointerException "subs: end is nil")))
   (clj2_rt/subs s start end)))

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
  (let [g (gensym)
        steps (map (fn [[test step]]
                     `(if ~test (-> ~g ~step) ~g))
                   (partition 2 clauses))]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro cond->> [expr & clauses]
  (let [g (gensym)
        steps (map (fn [[test step]]
                     `(if ~test (->> ~g ~step) ~g))
                   (partition 2 clauses))]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro some-> [expr & forms]
  (let [g (gensym)
        steps (map (fn [step] `(if (nil? ~g) nil (-> ~g ~step))) forms)]
    `(let [~g ~expr ~@(interleave (repeat g) (butlast steps))]
       ~(if (empty? steps) g (last steps)))))

(defmacro some->> [expr & forms]
  (let [g (gensym)
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
  ([x] `(when-not ~x (throw (new AssertionError (str "Assert failed: " (pr-str '~x))))))
  ([x message] `(when-not ~x (throw (new AssertionError (str "Assert failed: " ~message "\n" (pr-str '~x)))))))

;; namespaces are compiled as a unit: defonce is def
(defmacro defonce
  "Defines name to expr only when the var has no root yet."
  [name expr]
  ;; if, not when-not: a special form keeps the name's metadata on the def
  `(if (bound? (var ~name)) nil (def ~name ~expr)))

(defmacro time [expr]
  `(let [start# (erlang/monotonic_time 1000000)
         ret# ~expr]
     (prn (str "Elapsed time: " (/ (- (erlang/monotonic_time 1000000) start#) 1000.0) " msecs"))
     ret#))

;; (for [x xs :when t :let [..] :while t y ys] body), lazy
(defmacro for
  "List comprehension. Modifiers after a binding apply in source order:
  :let binds, :when skips an element, :while ends that binding's walk."
  [seq-exprs body-expr]
  (let [;; [[binding coll [[mod-key mod-val] ...]] ...]
        groups (fn groups [bs acc]
                 (if (seq bs)
                   (let [k (first bs) v (second bs)]
                     (if (keyword? k)
                       (let [g (peek acc)]
                         (groups (nnext bs) (conj (pop acc) [(nth g 0) (nth g 1) (conj (nth g 2) [k v])])))
                       (groups (nnext bs) (conj acc [k v []]))))
                   acc))
        emit (fn emit [gs]
               (let [g (first gs) more (next gs)
                     b (nth g 0) coll (nth g 1) mods (nth g 2)
                     step (gensym "step__") s (gensym "s__")
                     inner (if more
                             `(concat ~(emit more) (~step (rest ~s)))
                             `(cons ~body-expr (~step (rest ~s))))
                     chain (loop [ms (reverse mods) acc inner]
                             (if (seq ms)
                               (let [m (first ms) k (nth m 0) v (nth m 1)]
                                 (recur (rest ms)
                                        (cond
                                          (= k :let) `(let ~v ~acc)
                                          (= k :when) `(if ~v ~acc (~step (rest ~s)))
                                          (= k :while) `(if ~v ~acc nil)
                                          :else (throw (ex-info (str "Invalid 'for' keyword " k) {})))))
                               acc))]
                 `((fn ~step [~s]
                     (lazy-seq
                       (let [~s (seq ~s)]
                         (when ~s
                           (let [~b (first ~s)] ~chain)))))
                   ~coll)))]
    (emit (groups (seq seq-exprs) []))))

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
(defn read-string
  ([s] (clj2_rt_eval/read_string s))
  ;; opts: :eof is the value at end of input (none: end of input is an error)
  ([opts s] (clj2_rt_eval/read_string opts s)))
(defn load-string [s] (clj2_rt_eval/load_string s))
(defn load-file [path] (clj2_rt_eval/load_file path))
(defn macroexpand-1 [form] (clj2_rt_eval/macroexpand_1 form))
(defn macroexpand [form] (clj2_rt_eval/macroexpand form))
(defn require [& args] (clj2_rt_eval/require args))
(defn refer
  "Refers to all public vars of ns, subject to filters: :exclude list-of-symbols,
  :only list-of-symbols, :rename map-of-fromsymbol-tosymbol."
  [ns-sym & filters]
  (clj2_rt_eval/refer ns-sym filters))
(defmacro refer-clojure
  "Same as (refer 'clojure.core <filters>)"
  [& filters]
  `(clojure.core/refer '~'clojure.core ~@filters))
(defn use
  "Like require, but also refers to each lib's namespace (refer filters :only,
  :exclude and :rename apply)."
  [& args]
  (doseq [a args]
    (if (symbol? a)
      (do (require a) (refer a))
      (let [[lib & opts] a]
        (require lib)
        (apply refer lib opts)))))

(defn all-ns [] (seq (clj2_ns/all)))
;; a namespace designator: nil is a NullPointerException and a
;; non-symbol a failed cast, as on the JVM
(defn- ns-designator [x]
  (cond (nil? x) (throw (new NullPointerException "Namespace designator is nil"))
        (symbol? x) x
        :else (throw (new ClassCastException (str "class " (clj2_class/class_of x)
                                                  " cannot be cast to class clojure.lang.Symbol")))))
(defn find-ns [name] (let [name (ns-designator name)] (when (clj2_ns/find_ns name) name)))
(defn the-ns [x]
  (if (find-ns x) x (throw (ex-info (str "No namespace: " x " found") {:ns x}))))
;; a new namespace refers nothing, as on the JVM (ns does the refer-clojure)
(defn create-ns [name] (clj2_ns/ensure name 'bare) name)
(defn ns-name [ns] (the-ns ns))

;; Reflection over the registry (clj2_rt_eval): a var is {var meta
;; {ns name}}; ns-resolve finds what the compiler would find (own vars,
;; refers, aliases, clojure.core's public vars, a class name).
(defn ns-resolve
  ([ns sym]
   (when (nil? sym) (throw (new NullPointerException "resolve: nil symbol")))
   (clj2_rt_eval/resolve (the-ns ns) sym))
  ([ns env sym] (when-not (contains? env sym) (ns-resolve ns sym))))
(defn resolve
  ([sym] (ns-resolve *ns* sym))
  ([env sym] (ns-resolve *ns* env sym)))
(defn requiring-resolve [sym] (clj2_rt_eval/requiring_resolve sym))
(defn find-var [sym] (clj2_rt_eval/find_var sym))
(defn ns-publics [ns] (clj2_rt_eval/ns_publics (the-ns ns)))
(defn ns-interns [ns] (clj2_rt_eval/ns_interns (the-ns ns)))
(defn ns-map [ns] (clj2_rt_eval/ns_map (the-ns ns)))
(defn ns-refers [ns] (clj2_rt_eval/ns_refers (the-ns ns)))
(defn ns-aliases [ns] (clj2_rt_eval/ns_aliases (the-ns ns)))
(defn ns-unmap [ns sym] (clj2_rt_eval/ns_unmap (the-ns ns) sym))
(defn ns-unalias [ns sym] (clj2_ns/remove_alias (the-ns ns) sym) nil)
(defn intern
  ([ns name] (clj2_rt_eval/intern (the-ns ns) name))
  ([ns name val] (clj2_rt_eval/intern (the-ns ns) name val)))
(defn remove-ns [sym] (clj2_rt_eval/remove_ns sym))
(defn bound?
  "True when every var has a root or a binding in this process."
  [& vars]
  (every? (fn [v] (clj2_jvm/method v 'isBound ())) vars))

;;;; ------------------------------------------------------------------
;;;; Refs and STM: not provided (designs/03 §5.2). BEAM has no
;;;; multi-object transactional memory and faking one would lie; these
;;;; raise instead of being missing (known divergence :refs/no-stm).

(defn stm-unsupported
  "Raises: refs and STM are not supported (designs/03 §5.2)."
  [what]
  (throw (ex-info (str what ": refs and STM (dosync) are not supported on clojerl2"
                       " (known divergence :refs/no-stm); keep related state in one atom,"
                       " or in one process (an agent) and update it by message")
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

;;;; ------------------------------------------------------------------
;;;; Reference types (clojerl2-018, clj2_ref; designs/03 §5.2)
;;;;
;;;; atom: an ETS row with compare-and-swap; volatile: a cell in this
;;;; process; promise/future: delivered once, waiters woken by message;
;;;; agent: one process per agent, actions in send order. Dynamic
;;;; bindings travel to futures and agent actions (bound-fn semantics).

(defn atom
  ([x] (clj2_ref/atom x))
  ([x & options] (clj2_ref/atom x (apply hash-map options))))
(defn swap! [a f & args] (clj2_ref/swap a f args))
(defn swap-vals! [a f & args] (clj2_ref/swap_vals a f args))
(defn reset! [a v] (clj2_ref/reset a v))
(defn reset-vals! [a v] (clj2_ref/reset_vals a v))
(defn compare-and-set! [a oldval newval] (clj2_ref/compare_and_set a oldval newval))
(defn set-validator! [r f] (clj2_ref/set_validator r f))
(defn get-validator [r] (clj2_ref/get_validator r))
(defn add-watch [r k f] (clj2_ref/add_watch r k f))
(defn remove-watch [r k] (clj2_ref/remove_watch r k))


(defn promise [] (clj2_ref/promise))
(defn deliver [p v] (clj2_ref/deliver p v))

(def ^:dynamic *agent* nil)

(defn bound-fn* [f] (clj2_var/bound_fn f))

(defn push-thread-bindings [bindings] (clj2_var/push_frame bindings))
(defn pop-thread-bindings [] (clj2_var/pop_frame))
(defn with-bindings* [binding-map f & args]
  (push-thread-bindings binding-map)
  (try (apply f args) (finally (pop-thread-bindings))))
(defmacro with-bindings [binding-map & body]
  `(with-bindings* ~binding-map (fn [] ~@body)))

(defn alter-var-root [v f & args] (clj2_rt/alter_var_root v f args))

(defn with-redefs-fn [binding-map func]
  (let [vars (keys binding-map)
        old (doall (map (fn [v] (clj2_rt/table_root v)) vars))]
    (doseq [v vars] (clj2_rt/set_var_root v (get binding-map v)))
    (try (func)
         (finally (doall (map (fn [v x] (clj2_rt/set_var_root v x)) vars old))))))

(defmacro with-redefs [bindings & body]
  `(with-redefs-fn ~(zipmap (map (fn [s] (list 'var s)) (take-nth 2 bindings))
                            (take-nth 2 (next bindings)))
     (fn [] ~@body)))

(defn var-get [v] (deref v))
(defn var-set [v val] (clj2_var/var_set v val))
(defmacro with-local-vars [name-vals-vec & body]
  (let [pairs (partition 2 name-vals-vec)]
    `(let [~@(mapcat (fn [[n v]] [n (list 'clj2_ref/local_var nil)]) pairs)]
       (push-thread-bindings (hash-map ~@(mapcat (fn [[n v]] [n v]) pairs)))
       (try ~@body (finally (pop-thread-bindings))))))
(defmacro bound-fn [& fntail] `(bound-fn* (fn ~@fntail)))

(defmacro binding [bindings & body]
  (let [pairs (partition 2 bindings)]
    `(clj2_var/with_bindings
       [~@(mapcat (fn [[v e]] [(list 'var v) e]) pairs)]
       (fn [] ~@body))))

(defn future-call [f] (clj2_ref/future_call f))
(defmacro future [& body] `(future-call (fn [] ~@body)))
(defn future? [x] (= (clj2_ref/type_of x) 'future))
(defn future-cancel [f] (clj2_ref/future_cancel f))
(defn future-done? [f] (clj2_ref/is_future_done f))
(defn future-cancelled? [f] (clj2_ref/is_future_cancelled f))

(defn agent [state & options] (clj2_ref/agent state (apply hash-map options)))
(defn send [a f & args] (clj2_ref/send a f args))
(defn send-off [a f & args] (clj2_ref/send a f args))
(defn send-via [executor a f & args] (clj2_ref/send a f args))
(defn await [& agents] (clj2_ref/await agents 'infinity) nil)
(defn await-for [timeout-ms & agents] (clj2_ref/await agents timeout-ms))
(defn agent-error [a] (clj2_ref/agent_error a))
(defn restart-agent [a new-state & options] (clj2_ref/restart_agent a new-state (apply hash-map options)))
(defn set-error-handler! [a f] (clj2_ref/set_error_handler a f))
(defn error-handler [a] (clj2_ref/error_handler a))
(defn set-error-mode! [a mode] (clj2_ref/set_error_mode a mode))
(defn error-mode [a] (clj2_ref/error_mode a))
(defn shutdown-agents [] nil)

;; BEAM has no shared mutable memory to guard: a body that only touches
;; values needs no lock, and io! has no transaction to refuse.
(defmacro io! [& body] `(do ~@body))

;;;; ------------------------------------------------------------------
;;;; Regular expressions, chars, UUIDs, files (clojerl2-020)
;;;;
;;;; Patterns run on Erlang's re (PCRE2) in unicode mode (clj2_re);
;;;; chars are code points (:char/integer); UUIDs print #uuid "...".

(defn re-pattern [s] (clj2_re/pattern s))
(defn re-matcher [re s] (clj2_re/matcher re s))
(defn re-find
  ([m] (clj2_re/matcher_find m))
  ([re s] (clj2_re/re_find re s)))
(defn re-matches [re s] (clj2_re/re_matches re s))
(defn re-seq [re s] (seq (clj2_re/re_seq re s)))
(defn re-groups [m] (clj2_re/groups m))

(defn char [x] (clj2_string/char x))
(defn char? [x] (clj2_string/is_char x))
(def char-name-string (fn [c] (clj2_string/char_name c)))
(def char-escape-string (fn [c] (clj2_string/char_escape c)))

(defn random-uuid [] (clj2_string/random_uuid))
(defn parse-uuid [s] (clj2_string/parse_uuid s))
(defn uuid? [x] (clj2_string/is_uuid x))

(defn slurp [f & opts] (clj2_io/slurp f (apply hash-map opts)))
(defn spit [f content & options] (clj2_io/spit f content (apply hash-map options)))

(defn regex? [x] (clj2_re/is_pattern x))
(defn namespace-munge [ns] (clj2_string/replace (str ns) "-" "_" 'all))

;;;; ------------------------------------------------------------------
;;;; Hierarchies and multimethods (clojerl2-017; designs/03 §5.1)
;;;;
;;;; Hierarchies: clojure.core's pure-map design, ported from jolt
;;;; (jolt-core/clojure/core/20-coll.clj @ fdeff4ca, EPL-2.0, itself a port of
;;;; clojure.core) without the JVM class branches (clj2 has no classes).
;;;; A hierarchy is {:parents {tag #{..}} :ancestors {..} :descendants {..}};
;;;; the 3-arity fns are pure, the others use the global hierarchy atom.
;;;; Multimethods: method tables in ETS (clj2_multi).

(defn make-hierarchy []
  {:parents {} :descendants {} :ancestors {}})

(def global-hierarchy (atom (make-hierarchy)))

(defn- hier-assert [ok form]
  (when-not ok
    (throw (ex-info (str "Assert failed: " form) {:type :AssertionError}))))

(defn isa?
  ([child parent] (isa? (deref global-hierarchy) child parent))
  ([h child parent]
   (or (= child parent)
       ;; classes: a superclass or an interface it implements, as the JVM's
       ;; isAssignableFrom, or one of its supers derived from parent
       (clj2_class/is_subclass child parent)
       (contains? (get (get h :ancestors) child #{}) parent)
       (and (clj2_class/is_class child)
            (some (fn [s] (contains? (get (get h :ancestors) s #{}) parent)) (clj2_class/supers_list child)))
       (and (vector? parent) (vector? child)
            (= (count parent) (count child))
            (loop [ret true i 0]
              (if (or (not ret) (= i (count parent)))
                ret
                (recur (isa? h (nth child i) (nth parent i)) (inc i))))))))

(defn parents
  ([tag] (parents (deref global-hierarchy) tag))
  ([h tag] (not-empty (get (get h :parents) tag))))

(defn ancestors
  ([tag] (ancestors (deref global-hierarchy) tag))
  ([h tag] (not-empty (get (get h :ancestors) tag))))

(defn descendants
  ([tag] (descendants (deref global-hierarchy) tag))
  ([h tag]
   ;; a class's descendants would be every class that extends it: the JVM
   ;; refuses to answer
   (when (and (symbol? tag) (clj2_class/is_class tag))
     (throw (ex-info "Can't get descendants of classes" {:type :UnsupportedOperationException})))
   (not-empty (get (get h :descendants) tag))))

(defn derive
  ([tag parent]
   (hier-assert (namespace parent) "(namespace parent)")
   ;; a class (a record or deftype name) needs no namespace, as on the JVM
   (hier-assert (or (clj2_class/is_class tag)
                    (and (or (keyword? tag) (symbol? tag)) (namespace tag)))
                "(or (class? tag) (and (instance? clojure.lang.Named tag) (namespace tag)))")
   (swap! global-hierarchy derive tag parent) nil)
  ([h tag parent]
   (hier-assert (not= tag parent) "(not= tag parent)")
   (hier-assert (or (keyword? tag) (symbol? tag)) "(instance? clojure.lang.Named tag)")
   (hier-assert (or (keyword? parent) (symbol? parent)) "(instance? clojure.lang.Named parent)")
   ;; the hierarchy's maps are invoked, as in clojure.core: a value that is
   ;; not a hierarchy throws here
   (let [tp (:parents h)
         td (:descendants h)
         ta (:ancestors h)
         tf (fn [m source sources target targets]
              (reduce (fn [ret k]
                        (assoc ret k
                               (reduce conj (get targets k #{})
                                       (cons target (targets target)))))
                      m (cons source (sources source))))]
     (or
      (when-not (contains? (tp tag) parent)
        (when (contains? (ta tag) parent)
          (throw (ex-info (str tag " already has " parent " as ancestor") {})))
        (when (contains? (ta parent) tag)
          (throw (ex-info (str "Cyclic derivation: " parent " has " tag " as ancestor") {})))
        {:parents (assoc tp tag (conj (get tp tag #{}) parent))
         :ancestors (tf ta tag td parent ta)
         :descendants (tf td parent ta tag td)})
      h))))

(defn underive
  ([tag parent] (swap! global-hierarchy underive tag parent) nil)
  ([h tag parent]
   (let [parent-map (:parents h)
         childs-parents (if (parent-map tag)
                          (disj (parent-map tag) parent)
                          #{})
         new-parents (if (not-empty childs-parents)
                       (assoc parent-map tag childs-parents)
                       (dissoc parent-map tag))
         deriv-seq (mapcat (fn [e] (cons (key e) (interpose (key e) (val e))))
                           (seq new-parents))]
     (if (contains? (parent-map tag) parent)
       (reduce (fn [p [t pr]] (derive p t pr))
               (make-hierarchy) (partition 2 deriv-seq))
       h))))

;; clojure.lang.MultiFn's method choice: among the methods whose dispatch
;; value the call's isa?, the one that dominates the others (preferred, or
;; more specific); two that do not dominate each other are an error.
(defn- multi-hierarchy [mf]
  (if-let [h (clj2_multi/hierarchy mf)] (clj2_multi/hierarchy_value h) (deref global-hierarchy)))

(defn- multi-prefers? [mf h x y]
  (let [prefs (clj2_multi/prefers mf)]
    (or (contains? (get prefs x #{}) y)
        (some (fn [p] (multi-prefers? mf h x p)) (parents h y))
        (some (fn [p] (multi-prefers? mf h p y)) (parents h x))
        false)))

(defn- multi-dominates? [mf h x y]
  (or (multi-prefers? mf h x y) (isa? h x y)))

(defn find-best-method [mf dispatch-val]
  (let [h (multi-hierarchy mf)
        best (reduce (fn [best [dv f]]
                       (if (isa? h dispatch-val dv)
                         (let [b (if (or (nil? best) (multi-dominates? mf h dv (first best)))
                                   [dv f]
                                   best)]
                           (when-not (multi-dominates? mf h (first b) dv)
                             (throw (ex-info (str "Multiple methods in multimethod '"
                                                  (name (clj2_multi/name mf))
                                                  "' match dispatch value: " (clj2_print/pr_str dispatch-val)
                                                  " -> " (clj2_print/pr_str dv) " and " (clj2_print/pr_str (first b))
                                                  ", and neither is preferred")
                                             {:type :IllegalArgumentException})))
                           b)
                         best))
                     nil
                     (clj2_multi/method_entries mf))]
    (when best (second best))))

(defmacro defmulti [mm-name & options]
  (let [docstring (when (string? (first options)) (first options))
        options (if (string? (first options)) (next options) options)
        options (if (map? (first options)) (next options) options)
        dispatch-fn (first options)
        opts (apply hash-map (rest options))]
    `(def ~mm-name
       (clj2_multi/new '~(symbol (str *ns*)) '~mm-name ~dispatch-fn
                       ~(get opts :default :default)
                       ~(when-let [h (get opts :hierarchy)] h)))))

(defmacro defmethod [multifn dispatch-val & fn-tail]
  `(clj2_multi/add_method ~multifn ~dispatch-val (fn ~@fn-tail)))

(defn remove-method [multifn dispatch-val] (clj2_multi/remove_method multifn dispatch-val))
(defn remove-all-methods [multifn] (clj2_multi/remove_all_methods multifn))
(defn prefer-method [multifn dispatch-val-x dispatch-val-y]
  (clj2_multi/prefer_method multifn dispatch-val-x dispatch-val-y))
(defn prefers [multifn] (clj2_multi/prefers multifn))
(defn methods [multifn] (clj2_multi/methods multifn))
(defn get-method [multifn dispatch-val] (clj2_multi/get_method multifn dispatch-val))

;;;; ------------------------------------------------------------------
;;;; More of clojure.core (portable ones from jolt's jolt-core, EPL-2.0)
;;;;
;;;; Numbers follow BEAM (known divergence :number/beam-semantics):
;;;; integers are unbounded, so the unchecked- and primed (+') ops are the
;;;; ordinary ones and the coercions truncate without range checks.

(defmacro doto [x & forms]
  (let [gx (gensym "doto_")]
    `(let [~gx ~x]
       ~@(map (fn [f] (if (seq? f) `(~(first f) ~gx ~@(next f)) `(~f ~gx))) forms)
       ~gx)))

;; closing a binding: an io device (string writer/reader, a pid) is closed,
;; anything else that has a :close fn in it gets it called
(defn- close-resource [x]
  (cond (map? x) (when-let [c (:close x)] (c))
        :else (clj2_io/close x)))

(defmacro with-open [bindings & body]
  (if (empty? bindings)
    `(do ~@body)
    `(let ~(subvec bindings 0 2)
       (try
         (with-open ~(subvec bindings 2) ~@body)
         (finally (close-resource ~(bindings 0)))))))

(defmacro with-precision
  "BigDecimal arithmetic in body rounds to precision significant digits
  (:rounding a RoundingMode name, HALF_UP by default)."
  [precision & exprs]
  (let [[body rm] (if (= (first exprs) :rounding)
                    [(nnext exprs) (list 'quote (second exprs))]
                    [exprs nil])]
    `(binding [*math-context* (clj2_decimal/math_context ~precision ~rm)]
       ~@body)))

;; a definline is a fn here (the compiler inlines nothing it is told to)
(defmacro definline
  "Like defmacro, but also a fn: its body is the template instantiated with
  the argument symbols."
  [name & decl]
  (let [[pre-args [args expr]] (split-with (comp not vector?) decl)]
    `(do (defn ~name ~@pre-args ~args ~(apply (eval (list `fn args expr)) args))
         (alter-meta! (var ~name) assoc :inline (fn ~name ~args ~expr))
         (var ~name))))

(defmacro pvalues [& exprs] `(pcalls ~@(map (fn [e] (list `fn [] e)) exprs)))

(defn fnext [x] (first (next x)))
(defn nfirst [x] (next (first x)))
(defn replicate [n x] (take n (repeat x)))

(defn replace
  ([smap] (map (fn [x] (if-let [e (find smap x)] (val e) x))))
  ([smap coll]
   (if (vector? coll)
     (reduce (fn [v i] (if-let [e (find smap (nth v i))] (assoc v i (val e)) v))
             coll (range (count coll)))
     (map (fn [x] (if-let [e (find smap x)] (val e) x)) coll))))

(defn halt-when
  ([pred] (halt-when pred nil))
  ([pred retf]
   (fn [rf]
     (fn
       ([] (rf))
       ([result]
        (if (and (map? result) (contains? result ::halt))
          (get result ::halt)
          (rf result)))
       ([result input]
        (if (pred input)
          (reduced (hash-map ::halt (if retf (retf (rf result) input) input)))
          (rf result input)))))))

;; an eduction is the transformed sequence (realized lazily, re-run per walk
;; on the JVM; here it is a lazy seq over the xform)

(defn partitionv
  ([n coll] (partitionv n n coll))
  ([n step coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [p (into [] (take n) s)]
         (when (= n (count p))
           (cons p (partitionv n step (nthrest s step))))))))
  ([n step pad coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (let [p (into [] (take n) s)]
         (if (= n (count p))
           (cons p (partitionv n step pad (nthrest s step)))
           (list (into [] (take n) (concat p pad)))))))))

(defn partitionv-all
  ([n] (partition-all n))
  ([n coll] (partitionv-all n n coll))
  ([n step coll]
   (lazy-seq
     (when-let [s (seq coll)]
       (cons (into [] (take n) s) (partitionv-all n step (nthrest s step)))))))

(defn splitv-at [n coll] [(into [] (take n) coll) (drop n coll)])

(defn counted? [x] (or (vector? x) (map? x) (set? x) (list? x)))
(defn bounded-count [n coll]
  (if (counted? coll)
    (count coll)
    (loop [i 0 s (seq coll)]
      (if (and s (< i n)) (recur (inc i) (next s)) i))))

(defn random-sample
  ([prob] (filter (fn [_] (< (rand) prob))))
  ([prob coll] (filter (fn [_] (< (rand) prob)) coll)))

(defn memoize [f]
  (let [mem (atom {})]
    (fn [& args]
      (if-let [e (find @mem args)]
        (val e)
        (let [ret (apply f args)]
          (swap! mem assoc args ret)
          ret)))))

(defn comparator [pred]
  (fn [x y] (cond (pred x y) -1 (pred y x) 1 :else 0)))

;; futures do the work in parallel; results come back in order
(defn pmap
  "Like map, but f runs in parallel: semi-lazy, it stays a few elements
  (the processor count + 2) ahead of the consumer."
  ([f coll]
   (let [n (+ 2 (erlang/system_info 'schedulers_online))
         rets (map (fn [x] (future (f x))) coll)
         step (fn step [[x & vs :as vs*] fs]
                (lazy-seq
                  (if-let [s (seq fs)]
                    (cons (deref x) (step vs (rest s)))
                    (map deref vs*))))]
     (step rets (drop n rets))))
  ([f coll & colls]
   (pmap (fn [xs] (apply f xs)) (apply map vector coll colls))))
(defn pcalls [& fns] (pmap (fn [f] (f)) fns))
(defn seque ([s] (seq s)) ([n-or-q s] (seq s)))

(defn associative? [x] (or (map? x) (vector? x)))
(defn reversible? [x] (or (vector? x) (sorted? x)))
(defn indexed? [x] (vector? x))
(defn map-entry? [x] (and (vector? x) (= 2 (count x))))
(defn atom? [x] (= (clj2_ref/type_of x) 'atom))
(defn ident? [x] (or (keyword? x) (symbol? x)))
(defn simple-ident? [x] (and (ident? x) (nil? (namespace x))))
(defn qualified-ident? [x] (boolean (and (ident? x) (namespace x))))
(defn simple-symbol? [x] (and (symbol? x) (nil? (namespace x))))
(defn qualified-symbol? [x] (boolean (and (symbol? x) (namespace x))))
(defn simple-keyword? [x] (and (keyword? x) (nil? (namespace x))))
(defn qualified-keyword? [x] (boolean (and (keyword? x) (namespace x))))
(defn special-symbol? [s]
  (contains? '#{def if do let* loop* fn* recur quote var throw try catch finally
                letfn* case* new . set! monitor-enter monitor-exit deftype* reify* import* &} s))
(defn uri? [x] false)
(defn bytes? [x] (and (clj2_array/is_array x) (= 'byte (erlang/element 2 x))))
(defn bytes [x] (if (bytes? x) x (byte-array x)))
(defn decimal? [x] (clj2_decimal/is_decimal x))
(defn bigdec [x] (clj2_decimal/from x *math-context*))

(defn find-keyword
  ([name] (try (clj2_rt/existing_keyword nil name) (catch Exception _ nil)))
  ([ns name] (try (clj2_rt/existing_keyword ns name) (catch Exception _ nil))))

(defn munge [s]
  (let [m {\- "_" \. "_DOT_" \: "_COLON_" \+ "_PLUS_" \> "_GT_" \< "_LT_" \= "_EQ_"
           \~ "_TILDE_" \! "_BANG_" \@ "_CIRCA_" \# "_SHARP_" \' "_SINGLEQUOTE_"
           \" "_DOUBLEQUOTE_" \% "_PERCENT_" \^ "_CARET_" \& "_AMPERSAND_" \* "_STAR_"
           \| "_BAR_" \{ "_LBRACE_" \} "_RBRACE_" \[ "_LBRACK_" \] "_RBRACK_" \/ "_SLASH_"
           \\ "_BSLASH_" \? "_QMARK_"}
        r (clj2_string/escape (str s) m)]
    (if (symbol? s) (symbol r) r)))

;; numbers (BEAM: unbounded integers)
(defn int [x]
  (cond (integer? x) x
        (float? x) (erlang/trunc x)
        (decimal? x) (clj2_decimal/to_integer x)
        (ratio? x) (quot (numerator x) (denominator x))
        :else (clj2_rt/not_number x)))
(defn long [x] (int x))
(defn short [x] (int x))
(defn byte [x] (int x))
(defn double [x] (if (decimal? x) (clj2_decimal/to_float x) (erlang/float x)))
(defn float [x] (if (decimal? x) (clj2_decimal/to_float x) (erlang/float x)))
(defn num [x] (if (or (number? x) (nil? x) (clj2_rt/is_ratio x)) x (clj2_rt/not_number x)))
(defn bigint
  "x as an integer: a number truncates, a string parses (BEAM integers are
  unbounded, so a bigint is any integer)."
  [x]
  (if (string? x)
    (try (erlang/binary_to_integer x)
         (catch :error _ (throw (new NumberFormatException (str "For input string: \"" x "\"")))))
    (if (ratio? x) (quot (numerator x) (denominator x)) (int x))))
(defn biginteger [x] (bigint x))
;; the unchecked ops say they wrap: an integer result wraps to a signed
;; 64-bit long (32-bit for the -int ones), as on the JVM
(defn- wrap-bits [n bits]
  (if (integer? n)
    (let [m (erlang/bsl 1 bits) h (erlang/bsl 1 (dec bits)) r (erlang/band n (dec m))]
      (if (>= r h) (- r m) r))
    n))
(defn unchecked-add [x y] (wrap-bits (+ x y) 64))
(defn unchecked-add-int [x y] (wrap-bits (+ x y) 32))
(defn unchecked-subtract [x y] (wrap-bits (- x y) 64))
(defn unchecked-subtract-int [x y] (wrap-bits (- x y) 32))
(defn unchecked-multiply [x y] (wrap-bits (* x y) 64))
(defn unchecked-multiply-int [x y] (wrap-bits (* x y) 32))
(defn unchecked-inc [x] (wrap-bits (inc x) 64))
(defn unchecked-inc-int [x] (wrap-bits (inc x) 32))
(defn unchecked-dec [x] (wrap-bits (dec x) 64))
(defn unchecked-dec-int [x] (wrap-bits (dec x) 32))
(defn unchecked-negate [x] (wrap-bits (- x) 64))
(defn unchecked-negate-int [x] (wrap-bits (- x) 32))
(defn unchecked-divide-int [x y] (quot x y))
(defn unchecked-remainder-int [x y] (rem x y))
(defn unchecked-int [x] (wrap-bits (int x) 32))
(defn unchecked-long [x] (wrap-bits (int x) 64))
(defn unchecked-short [x] (wrap-bits (int x) 16))
(defn unchecked-byte [x] (wrap-bits (int x) 8))
(defn unchecked-char [x] (int x))
(defn unchecked-double [x] (double x))
(defn unchecked-float [x] (double x))
(defn +' ([] 0) ([x] x) ([x y] (+ x y)) ([x y & more] (reduce + (+ x y) more)))
(defn -' ([x] (- x)) ([x y] (- x y)) ([x y & more] (reduce - (- x y) more)))
(defn *' ([] 1) ([x] x) ([x y] (* x y)) ([x y & more] (reduce * (* x y) more)))
(defn inc' [x] (inc x))
(defn dec' [x] (dec x))
(defn NaN? [x] (if (number? x) false (throw (ex-info "NaN? takes a number" {:type :ClassCastException}))))
(defn infinite? [x] (if (number? x) false (throw (ex-info "infinite? takes a number" {:type :ClassCastException}))))
(defn ratio? [x] (clj2_rt/is_ratio x))
(defn rational? [x] (or (integer? x) (ratio? x) (decimal? x)))
(defn numerator [r] (clj2_rt/numerator r))
(defn denominator [r] (clj2_rt/denominator r))
(defn rationalize [x]
  ;; a BigDecimal (or a double, through its shortest text) as an exact ratio
  (let [d (cond (decimal? x) x (float? x) (bigdec x) :else nil)]
    (if d (clj2_decimal/to_ratio d) x)))
(defn bit-and-not ([x y] (bit-and x (bit-not y))) ([x y & more] (reduce bit-and-not (bit-and-not x y) more)))
(defn bit-set [x n] (bit-or x (bit-shift-left 1 n)))
(defn bit-clear [x n] (bit-and x (bit-not (bit-shift-left 1 n))))
(defn bit-flip [x n] (bit-xor x (bit-shift-left 1 n)))
(defn bit-test [x n] (not (zero? (bit-and x (bit-shift-left 1 n)))))
;; on the 64-bit two's complement of x, as the JVM's >>> on a long
(defn unsigned-bit-shift-right [x n]
  ;; a logical shift of the 64-bit pattern (n mod 64), read back as a signed long
  (let [u (bit-shift-right (bit-and x 0xFFFFFFFFFFFFFFFF) (bit-and n 63))]
    (if (>= u 0x8000000000000000) (- u 0x10000000000000000) u)))

;; hashes: the collection mixing fns over clojure's hash
(defn mix-collection-hash [hash-basis count] (clj2_hash/mix_coll_hash hash-basis count))
(defn hash-ordered-coll [coll] (clj2_hash/hash_ordered (clj2_coll/to_list coll)))
(defn hash-unordered-coll [coll] (clj2_hash/hash_unordered (clj2_coll/to_list coll)))
(defn hash-combine [x y] (clj2_hash/hash_combine x (clj2_hash/java_hash_code y)))

(defn Throwable->map [o]
  (let [msg (ex-message o)
        data (ex-data o)
        via (cond-> {:type (if data 'clojure.lang.ExceptionInfo 'java.lang.Exception) :message msg}
              data (assoc :data data))]
    (cond-> {:via [via] :trace [] :cause msg}
      data (assoc :data data))))

(def ^:dynamic *clojure-version* {:major 1 :minor 12 :incremental 0 :qualifier nil})
(defn clojure-version [] "1.12.0")
(def ^:dynamic *print-length* nil)
(def ^:dynamic *print-level* nil)
(def ^:dynamic *print-meta* false)
(def ^:dynamic *print-dup* false)
(def ^:dynamic *print-readably* true)
(def ^:dynamic *print-namespace-maps* false)
(def ^:dynamic *flush-on-newline* true)
(def ^:dynamic *read-eval* true)
(def ^:dynamic *data-readers* {})
(def default-data-readers {'inst (fn [s] (clj2_inst/parse s)) 'uuid (fn [s] (clj2_string/uuid s))})
(def ^:dynamic *default-data-reader-fn* nil)
(def ^:dynamic *assert* true)
(def ^:dynamic *unchecked-math* false)
(def ^:dynamic *warn-on-reflection* false)
(def ^:dynamic *compile-path* "classes")
(def ^:dynamic *compile-files* false)
(def ^:dynamic *repl* false)
(def ^:dynamic *verbose-defrecords* false)
(def ^:dynamic *allow-unresolved-vars* false)
(def ^:dynamic *use-context-classloader* true)
(def ^:dynamic *suppress-read* nil)
(def ^:dynamic *file* nil)
(def ^:dynamic *source-path* nil)
(def ^:dynamic *math-context* nil)
(def ^:dynamic *compiler-options* nil)

(defn alias [alias-sym ns-sym] (clj2_rt_eval/alias alias-sym ns-sym))

;;;; ------------------------------------------------------------------
;;;; Transients: a transient wraps a persistent value; each bang op returns
;;;; the next transient (use its return value, as Clojure requires) and
;;;; persistent! unwraps it. Reads go through to the value. (BEAM terms are
;;;; immutable: reusing a transient after persistent! is not detected,
;;;; known divergence :transients/wrapped.)

(defn transient [coll]
  (if (or (vector? coll) (map? coll) (set? coll))
    (clj2_rt/transient coll)
    ;; the class, not the value: printing a lazy seq would realize it
    (throw (ex-info (str "class " (clj2_class/class_of coll) " cannot be cast to class clojure.lang.IEditableCollection")
                    {:type :ClassCastException}))))
(defn transient? [x] (clj2_rt/is_transient x))
(defn persistent! [t] (clj2_rt/persistent t))
(defn conj!
  ([] (transient []))
  ([t] t)
  ([t x] (clj2_rt/transient (conj (clj2_rt/persistent t) x)))
  ([t x & xs] (reduce conj! (conj! t x) xs)))
(defn assoc!
  ([t k v] (clj2_rt/transient (assoc (clj2_rt/persistent t) k v)))
  ([t k v & kvs] (if kvs (recur (assoc! t k v) (first kvs) (second kvs) (nnext kvs)) (assoc! t k v))))
(defn dissoc!
  ([t k] (clj2_rt/transient (dissoc (clj2_rt/persistent t) k)))
  ([t k & ks] (reduce dissoc! (dissoc! t k) ks)))
(defn disj!
  ([t] t)
  ([t x] (clj2_rt/transient (disj (clj2_rt/persistent t) x)))
  ([t x & xs] (reduce disj! (disj! t x) xs)))
(defn pop! [t] (clj2_rt/transient (pop (clj2_rt/persistent t))))

;;;; ------------------------------------------------------------------
;;;; Metadata (clj2_rt:meta/with_meta). Vectors, maps, sets, lazy seqs,
;;;; records and fns carry it; a list given metadata becomes a seq that
;;;; carries it; symbols carry none (:symbol/no-metadata). A var's is its
;;;; registry entry's.

(defn meta [x] (clj2_rt/meta x))
(defn with-meta [x m] (clj2_rt/with_meta x m))
(defn vary-meta [x f & args] (with-meta x (apply f (meta x) args)))

(defn reset-meta! [iref m]
  (cond (var? iref) (do (clj2_ns/set_var_meta iref m) m)
        (#{'atom 'agent} (clj2_ref/type_of iref)) (clj2_ref/reset_ref_meta iref m)
        :else (throw (ex-info "reset-meta!: only vars, atoms and agents carry mutable metadata" {:type :ClassCastException}))))
(defn alter-meta! [iref f & args] (reset-meta! iref (apply f (meta iref) args)))
(defn var? [x] (clj2_rt/is_var x))

;;;; ------------------------------------------------------------------
;;;; Sorted collections (clj2_sorted: an AVL tree under a comparator)

(defn- check-kvs [keyvals]
  (when (odd? (count keyvals))
    (throw (ex-info (str "No value supplied for key: " (clj2_print/pr_str (last keyvals))) {:type :IllegalArgumentException}))))
(defn sorted-map [& keyvals]
  (check-kvs keyvals)
  (clj2_sorted/from_list 'sorted_map 'default (map (fn [[k v]] (erlang/list_to_tuple (list k v))) (partition 2 keyvals))))
(defn sorted-map-by [comparator & keyvals]
  (check-kvs keyvals)
  (clj2_sorted/from_list 'sorted_map comparator (map (fn [[k v]] (erlang/list_to_tuple (list k v))) (partition 2 keyvals))))
(defn sorted-set [& keys]
  (clj2_sorted/from_list 'sorted_set 'default (map (fn [k] (erlang/list_to_tuple (list k nil))) keys)))
(defn sorted-set-by [comparator & keys]
  (clj2_sorted/from_list 'sorted_set comparator (map (fn [k] (erlang/list_to_tuple (list k nil))) keys)))
(defn sorted? [x] (clj2_sorted/is_sorted x))
(defn subseq
  ([sc test key] (clj2_sorted/subseq sc test key 'none 'asc))
  ([sc start-test start-key end-test end-key]
   (clj2_sorted/subseq sc start-test start-key (erlang/list_to_tuple (list end-test end-key)) 'asc)))
(defn rsubseq
  ([sc test key] (clj2_sorted/subseq sc test key 'none 'desc))
  ([sc start-test start-key end-test end-key]
   (clj2_sorted/subseq sc start-test start-key (erlang/list_to_tuple (list end-test end-key)) 'desc)))


;;;; ------------------------------------------------------------------
;;;; Java arrays (clj2_array): mutable, as on the JVM; an array is
;;;; {array, Type, Cell}. seq, count, nth, vec work on them.

(defn- array-of [type]
  (fn ([size-or-seq] (clj2_array/make type size-or-seq))
      ([size init-or-seq] (clj2_array/make type size init-or-seq))))
(def long-array (array-of 'long))
(def int-array (array-of 'int))
(def short-array (array-of 'short))
(def byte-array (array-of 'byte))
(def char-array (array-of 'char))
(def double-array (array-of 'double))
(def float-array (array-of 'float))
(def boolean-array (array-of 'boolean))
(def object-array (array-of 'object))
(defn to-array [coll] (clj2_array/from_seq 'object (if (nil? coll) [] coll)))
(defn into-array
  ([aseq] (into-array nil aseq))
  ([type aseq] (clj2_array/from_seq (clj2_array/type_of_class type) (if (nil? aseq) [] aseq))))
(defn make-array
  ([type len] (clj2_array/make (clj2_array/type_of_class type) len))
  ([type dim & more]
   (clj2_array/from_seq 'object (repeatedly dim #(apply make-array type more)))))
(defn to-array-2d [coll] (clj2_array/from_seq 'object (map to-array coll)))
(defn array? [x] (clj2_array/is_array x))
(defn aget
  ([a i] (clj2_array/get a i))
  ([a i & idxs] (apply aget (aget a i) idxs)))
(defn aset
  ([a i v] (clj2_array/set a i v))
  ([a i j & ivs] (apply aset (aget a i) j ivs)))
(def aset-int aset) (def aset-long aset) (def aset-short aset) (def aset-byte aset)
(def aset-char aset) (def aset-double aset) (def aset-float aset) (def aset-boolean aset)
(defn alength [a] (clj2_array/length a))
(defn aclone [a] (clj2_array/clone a))
(defn ints [xs] xs) (defn longs [xs] xs) (defn shorts [xs] xs)
(defn chars [xs] xs) (defn doubles [xs] xs) (defn floats [xs] xs) (defn booleans [xs] xs)
(defmacro amap [a idx ret expr]
  `(let [a# ~a ~ret (aclone a#)]
     (loop [~idx 0]
       (if (< ~idx (alength a#))
         (do (aset ~ret ~idx ~expr) (recur (unchecked-inc ~idx)))
         ~ret))))
(defmacro areduce [a idx ret init expr]
  `(let [a# ~a]
     (loop [~idx 0 ~ret ~init]
       (if (< ~idx (alength a#)) (recur (unchecked-inc ~idx) ~expr) ~ret))))

;; primitive vectors are vectors here
(defn vector-of [t & elements]
  ;; elements are coerced to the element type (the vector stays a vector)
  (let [c (case t
            (:int :long :short :byte) long
            (:double :float) double
            :char char
            :boolean boolean
            (throw (ex-info (str "Unrecognized type " t) {:type :IllegalArgumentException})))]
    (vec (map c elements))))

(defmacro memfn [name & args]
  (let [t (gensym "target")]
    `(fn [~t ~@args] (. ~t (~name ~@args)))))

;; monitors: BEAM values are immutable and processes do not share them,
;; so there is nothing to lock (locking runs its body)
(defn monitor-enter [x] nil)
(defn monitor-exit [x] nil)
(defmacro locking [x & body]
  `(let [lockee# ~x]
     (try (monitor-enter lockee#) ~@body (finally (monitor-exit lockee#)))))


;;;; ------------------------------------------------------------------
;;;; Smaller clojure.core vars (clojerl2-036)

(defn sorted-map? [x] (and (clj2_sorted/is_sorted x) (= 'sorted_map (erlang/element 1 x))))
(defn sorted-set? [x] (and (clj2_sorted/is_sorted x) (= 'sorted_set (erlang/element 1 x))))

;; ClojureScript's names, as jolt's overlay gives them on every host
(defn object? [x] false)
(defn undefined? [x] false)
(defn keyword-identical? [x y] (= x y))

(defn test
  "Runs the :test fn in v's metadata: :ok, or :no-test when there is none."
  [v]
  (if-let [f (:test (meta v))] (do (f) :ok) :no-test))

(defn thread-bound?
  "True when every var has a binding in this process."
  [& vars]
  (every? (fn [v] (clj2_var/is_thread_bound v)) vars))
(defn get-thread-bindings [] (clj2_var/thread_bindings))

(defn xml-seq [root]
  (tree-seq (complement string?) (comp seq :content) root))

(defn iterator-seq [iter]
  (if (= (clj2_class/class_of iter) (quote java.util.Iterator))
    (lazy-seq (when (.hasNext iter) (cons (.next iter) (iterator-seq iter))))
    (seq iter)))

;; tagged literals and reader conditionals as data (the reader makes them
;; for #tag forms it has no reader for, and for #? under :read-cond :preserve)
(defn tagged-literal [tag form] (clj2_rt/tagged_literal tag form))
(defn tagged-literal? [x] (clj2_rt/is_tagged_literal x))
(defn reader-conditional [form splicing?] (clj2_rt/reader_conditional form splicing?))
(defn reader-conditional? [x] (clj2_rt/is_reader_conditional x))

;; proxies need JVM classes to subclass; the shapes jolt documents
(defn get-proxy-class [& bases]
  (throw (ex-info "get-proxy-class: proxies are not supported (no JVM classes)" {:type :UnsupportedOperationException})))
(defn construct-proxy [c & args]
  (throw (ex-info "construct-proxy: proxies are not supported (no JVM classes)" {:type :UnsupportedOperationException})))
(defn init-proxy [proxy mappings] nil)
(defn update-proxy [proxy mappings] nil)


;; struct maps: maps that start with the basis keys
(defn create-struct [& keys] (vec keys))
(defmacro defstruct [name & keys] `(def ~name (create-struct ~@keys)))
(defn struct-map [s & inits]
  (merge (zipmap s (repeat nil)) (apply hash-map inits)))
(defn struct [s & vals]
  (merge (zipmap s (repeat nil)) (zipmap s vals)))
(defn accessor [s key] (fn [m] (get m key)))

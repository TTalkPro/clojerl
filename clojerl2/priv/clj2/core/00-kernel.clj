;; clojure.core — layer 00-kernel (designs/04 §6.1, clojerl2-014).
;;
;; The bottom of clojure.core: written only with special forms
;; (def fn* let* loop* recur if do quote letfn* case* try throw), the
;; kernel form defmacro, and Erlang calls (layer 0: erlang/lists/maps
;; and the clj2_coll / clj2_rt primitives, designs/03 §8). It must not
;; refer to any other Clojure namespace (lint: allowed_ns []).
;;
;; Seqs: nil, Erlang lists, lazy seqs, and cons cells with a lazy tail
;; (clj2_lazy, clojerl2-019). Producers (map, filter, concat, range ...)
;; are lazy; consumers walk with seq/next.

(ns clojure.core)

;;;; ------------------------------------------------------------------
;;;; Seqs and lists (special forms only until fn/let/loop exist)
;;;; ------------------------------------------------------------------

(def list (fn* list [& items] (if items items '())))
(def seq (fn* seq [coll] (clj2_coll/seq coll)))
(def cons (fn* cons [x coll] (clj2_coll/cons x coll)))
(def first (fn* first [coll] (let* [s (clj2_coll/seq coll)] (if s (erlang/hd s) nil))))
(def rest (fn* rest [coll] (let* [s (clj2_coll/seq coll)] (if s (erlang/tl s) '()))))
(def next (fn* next [coll] (let* [s (clj2_coll/seq coll)] (if s (clj2_coll/seq (erlang/tl s)) nil))))
(def second (fn* second [coll] (first (next coll))))
(def ffirst (fn* ffirst [coll] (first (first coll))))
(def nnext (fn* nnext [coll] (next (next coll))))
(def last (fn* last [coll] (let* [s (clj2_coll/seq coll)] (if s (lists/last (clj2_coll/to_list s)) nil))))
(def count (fn* count [coll] (clj2_coll/count coll)))
(def nth (fn* nth ([coll i] (clj2_coll/nth coll i)) ([coll i not-found] (clj2_coll/nth coll i not-found))))
(def reverse (fn* reverse [coll] (lists/reverse (clj2_coll/to_list coll))))

;;;; ------------------------------------------------------------------
;;;; Laziness (clj2_lazy: thunk + memo cell, pdict by default)
;;;; ------------------------------------------------------------------

(defmacro lazy-seq [& body] `(clj2_lazy/lazy_seq (fn* [] ~@body)))
(defmacro delay [& body] `(clj2_lazy/delay (fn* [] ~@body)))
(def force (fn* force [x] (clj2_lazy/force x)))
(def deref (fn* deref ([ref] (clj2_ref/deref ref)) ([ref timeout-ms timeout-val] (clj2_ref/deref ref timeout-ms timeout-val))))
(def realized? (fn* realized? [x] (clj2_ref/is_realized x)))
(def delay? (fn* delay? [x] (clj2_lazy/is_delay x)))
(def doall (fn* doall [coll] (clj2_lazy/doall coll)))
(def dorun (fn* dorun [coll] (clj2_lazy/dorun coll)))

(def concat
  (fn* concat
    ([] (lazy-seq nil))
    ([x] (lazy-seq x))
    ([x y] (lazy-seq (let* [s (seq x)] (if s (cons (first s) (concat (rest s) y)) y))))
    ([x y & zs]
     (let* [cat (fn* cat [xys zs]
                  (lazy-seq
                    (let* [xys (seq xys)]
                      (if xys
                        (cons (first xys) (cat (rest xys) zs))
                        (if zs (cat (first zs) (next zs)) nil)))))]
       (cat (concat x y) zs)))))

;;;; ------------------------------------------------------------------
;;;; Logic, identity, predicates
;;;; ------------------------------------------------------------------

(def not (fn* not [x] (if x false true)))
(def nil? (fn* nil? [x] (erlang/== x nil)))
(def some? (fn* some? [x] (not (nil? x))))
(def true? (fn* true? [x] (erlang/== x true)))
(def false? (fn* false? [x] (erlang/== x false)))
(def identity (fn* identity [x] x))
(def identical? (fn* identical? [x y] (clj2_rt/identical x y)))

(def string? (fn* string? [x] (erlang/is_binary x)))
(def number? (fn* number? [x] (if (erlang/is_number x) true (clj2_rt/is_boxed_number x))))
(def integer? (fn* integer? [x] (erlang/is_integer x)))
(def float? (fn* float? [x] (erlang/is_float x)))
(def boolean? (fn* boolean? [x] (erlang/is_boolean x)))
(def keyword? (fn* keyword? [x] (clj2_rt/is_keyword x)))
(def symbol? (fn* symbol? [x] (clj2_rt/is_symbol x)))
(def fn? (fn* fn? [x] (clj2_rt/is_fn x)))
(def ifn? (fn* ifn? [x] (clj2_rt/is_ifn x)))
(def vector? (fn* vector? [x] (clj2_coll/is_vector x)))
(def map? (fn* map? [x] (if (clj2_coll/is_any_map x) true (clj2_coll/is_record x))))
(def set? (fn* set? [x] (clj2_coll/is_any_set x)))
(def list? (fn* list? [x] (erlang/is_list x)))
(def seq? (fn* seq? [x] (clj2_coll/is_seq x)))
(def coll? (fn* coll? [x] (if (seq? x) true (if (vector? x) true (if (map? x) true (set? x))))))
(def sequential? (fn* sequential? [x] (if (seq? x) true (if (vector? x) true (clj2_class/is_instance 'clojure.lang.Sequential x)))))
(def empty? (fn* empty? [coll] (nil? (seq coll))))

;;;; ------------------------------------------------------------------
;;;; Higher order (eager), needed by the macros below
;;;; ------------------------------------------------------------------

;; (reduced x) stops a reduction early (transducers, take-while ...)
(def reduced (fn* reduced [x] (clj2_rt/reduced x)))
(def reduced? (fn* reduced? [x] (clj2_rt/is_reduced x)))
(def unreduced (fn* unreduced [x] (clj2_rt/unreduced x)))
(def ensure-reduced (fn* ensure-reduced [x] (if (clj2_rt/is_reduced x) x (clj2_rt/reduced x))))

(def reduce
  (fn* reduce
    ([f coll]
     (let* [s (seq coll)]
       (if s (reduce f (erlang/hd s) (erlang/tl s)) (f))))
    ([f init coll]
     (loop* [acc init s (seq coll)]
       (if (clj2_rt/is_reduced acc)
         (clj2_rt/unreduced acc)
         (if s (recur (f acc (erlang/hd s)) (next s)) acc))))))

(def map
  (fn* map
    ([f] (fn* [rf] (fn* ([] (rf)) ([r] (rf r)) ([r x] (rf r (f x))) ([r x & xs] (rf r (apply f x xs))))))
    ([f coll]
     (lazy-seq
       (let* [s (seq coll)]
         (if s (cons (f (erlang/hd s)) (map f (erlang/tl s))) nil))))
    ([f c1 c2]
     (lazy-seq
       (let* [s1 (seq c1) s2 (seq c2)]
         (if (if s1 s2 nil)
           (cons (f (erlang/hd s1) (erlang/hd s2)) (map f (erlang/tl s1) (erlang/tl s2)))
           nil))))
    ([f c1 c2 c3]
     (lazy-seq
       (let* [s1 (seq c1) s2 (seq c2) s3 (seq c3)]
         (if (if s1 (if s2 s3 nil) nil)
           (cons (f (erlang/hd s1) (erlang/hd s2) (erlang/hd s3))
                 (map f (erlang/tl s1) (erlang/tl s2) (erlang/tl s3)))
           nil))))
    ([f c1 c2 c3 & colls]
     ;; any number of colls: step all their seqs together until one ends
     (let* [step (fn* step [cs]
                   (lazy-seq
                     (let* [ss (map seq cs)]
                       (if (every? identity ss)
                         (cons (map first ss) (step (map rest ss)))
                         nil))))]
       (map (fn* [args] (apply f args)) (step (cons c1 (cons c2 (cons c3 colls)))))))))

(def filter
  (fn* filter
    ([pred] (fn* [rf] (fn* ([] (rf)) ([r] (rf r)) ([r x] (if (pred x) (rf r x) r)))))
    ([pred coll]
     (lazy-seq
       (let* [s (seq coll)]
         (if s
           (let* [x (erlang/hd s)]
             (if (pred x) (cons x (filter pred (erlang/tl s))) (filter pred (erlang/tl s))))
           nil))))))

(def remove (fn* remove
              ([pred] (filter (fn* [x] (not (pred x)))))
              ([pred coll] (filter (fn* [x] (not (pred x))) coll))))
(def mapcat
  (fn* mapcat
    ([f] (fn* [rf]
           (fn* ([] (rf))
                ([r] (rf r))
                ([r x] (reduce (fn* [acc y]
                                 (let* [v (rf acc y)] (if (clj2_rt/is_reduced v) (clj2_rt/reduced v) v)))
                               r (f x))))))
    ([f coll]
     ;; as (apply concat (map f coll)) on the JVM: the first few results
     ;; are made at the call (so a bad coll or f fails there), the rest lazily
     (let* [m (map f coll)]
       (dorun-n 4 m)
       (mapcat* m)))
    ([f c1 c2] (mapcat identity (map f c1 c2)))
    ([f c1 c2 & colls] (mapcat identity (apply map f c1 c2 colls)))))
(def ^:private mapcat*
  (fn* mapcat* [m] (lazy-seq (let* [s (seq m)] (if s (concat (erlang/hd s) (mapcat* (erlang/tl s))) nil)))))
(def ^:private dorun-n
  (fn* dorun-n [n s] (if (erlang/> n 0) (let* [s1 (seq s)] (if s1 (dorun-n (erlang/- n 1) (erlang/tl s1)) nil)) nil)))
(def some (fn* some [pred coll]
            (loop* [s (seq coll)]
              (if s (let* [r (pred (erlang/hd s))] (if r r (recur (next s)))) nil))))
(def every? (fn* every? [pred coll]
              (loop* [s (seq coll)]
                (if s (if (pred (erlang/hd s)) (recur (next s)) false) true))))
(def apply (fn* apply [f & args] (clj2_rt/apply f args)))
(def complement (fn* complement [f] (fn* [& args] (not (apply f args)))))
(def constantly (fn* constantly [x] (fn* [& _] x)))
(def comp (fn* comp
            ([] identity)
            ([f] f)
            ([f g] (fn* [& args] (f (apply g args))))
            ([f g & fs] (reduce comp (cons f (cons g fs))))))
(def partial (fn* partial [f & bound] (fn* [& args] (apply f (concat bound args)))))

;;;; ------------------------------------------------------------------
;;;; Collections
;;;; ------------------------------------------------------------------

(def vector (fn* vector [& items] (clj2_coll/vector (if items items '()))))
(def vec (fn* vec [coll] (clj2_coll/vector (clj2_coll/to_list coll))))
(def hash-map (fn* hash-map [& kvs] (clj2_coll/hash_map_kv (if kvs kvs '()))))
(def hash-set (fn* hash-set [& items] (clj2_coll/hash_set (if items items '()))))
(def set (fn* set [coll] (clj2_coll/hash_set (clj2_coll/to_list coll))))
(def get (fn* get ([m k] (clj2_coll/get m k)) ([m k not-found] (clj2_coll/get m k not-found))))
(def contains? (fn* contains? [coll k] (clj2_coll/contains coll k)))
(def keys (fn* keys [m] (clj2_coll/keys m)))
(def vals (fn* vals [m] (clj2_coll/vals m)))
(def assoc
  (fn* assoc
    ([m k v] (clj2_coll/assoc m k v))
    ([m k v & kvs]
     (let* [m (clj2_coll/assoc m k v)]
       (if kvs
         (if (next kvs)
           (recur m (first kvs) (second kvs) (nnext kvs))
           (throw (clj2_rt/ex_info "assoc expects even number of arguments after map/vector, found odd number"
                                   {:type :IllegalArgumentException} nil)))
         m)))))
(def dissoc
  (fn* dissoc
    ([m] m)
    ([m k] (clj2_coll/dissoc m k))
    ([m k & ks] (reduce (fn* [acc x] (clj2_coll/dissoc acc x)) (clj2_coll/dissoc m k) ks))))
(def conj
  (fn* conj
    ([] (vector))
    ([coll] coll)
    ([coll x] (clj2_coll/conj coll x))
    ([coll x & xs] (reduce (fn* [acc y] (clj2_coll/conj acc y)) (clj2_coll/conj coll x) xs))))
(def completing (fn* completing
                  ([f] (completing f (fn* [x] x)))
                  ([f cf] (fn* ([] (f)) ([x] (cf x)) ([x y] (f x y))))))
(def transduce (fn* transduce
                 ([xform f coll] (transduce xform f (f) coll))
                 ([xform f init coll]
                  (let* [rf (xform f)] (rf (reduce rf init coll))))))
(def into (fn* into
            ([] (vector))
            ([to] to)
            ([to from] (reduce conj to from))
            ([to xform from] (transduce xform (completing conj) to from))))
(def list* (fn* list*
             ([args] (seq args))
             ([a args] (cons a args))
             ([a b & more] (cons a (cons b (apply list* more))))))
(def nthnext (fn* nthnext [coll n]
               (loop* [s (seq coll) n n]
                 (if s (if (erlang/> n 0) (recur (next s) (erlang/- n 1)) s) nil))))
(def drop (fn* drop
            ([n] (fn* [rf]
                   (let* [left (clj2_ref/volatile n)]
                     (fn* ([] (rf))
                          ([r] (rf r))
                          ([r x] (let* [k (clj2_ref/deref left)]
                                   (clj2_ref/vreset left (erlang/- k 1))
                                   (if (erlang/> k 0) r (rf r x))))))))
            ([n coll] (lazy-seq (nthnext coll n)))))
(def take (fn* take
            ([n] (fn* [rf]
                   (let* [left (clj2_ref/volatile n)]
                     (fn* ([] (rf))
                          ([r] (rf r))
                          ([r x] (let* [k (clj2_ref/deref left)
                                        k1 (clj2_ref/vreset left (erlang/- k 1))
                                        r1 (if (erlang/> k 0) (rf r x) r)]
                                   (if (erlang/> k1 0) r1 (ensure-reduced r1))))))))
            ([n coll]
             (lazy-seq
               (if (erlang/> n 0)
                 (let* [s (seq coll)] (if s (cons (erlang/hd s) (take (erlang/- n 1) (erlang/tl s))) nil))
                 nil)))))
(def take-while (fn* take-while
                  ([pred] (fn* [rf] (fn* ([] (rf)) ([r] (rf r))
                                         ([r x] (if (pred x) (rf r x) (clj2_rt/reduced r))))))
                  ([pred coll]
                   (lazy-seq
                     (let* [s (seq coll)]
                       (if s (if (pred (erlang/hd s)) (cons (erlang/hd s) (take-while pred (erlang/tl s))) nil) nil))))))
(def drop-while (fn* drop-while [pred coll]
                  (lazy-seq
                    (loop* [s (seq coll)]
                      (if s (if (pred (erlang/hd s)) (recur (next s)) s) nil)))))
(def iterate (fn* iterate [f x] (lazy-seq (cons x (lazy-seq (iterate f (f x)))))))
(def repeat (fn* repeat ([x] (lazy-seq (cons x (repeat x))))
              ;; the count is checked and truncated at the call (JVM: a long)
              ([n x] (if (erlang/is_number n) (take (erlang/trunc n) (repeat x)) (clj2_rt/not_number n)))))
(def repeatedly (fn* repeatedly ([f] (lazy-seq (cons (f) (repeatedly f)))) ([n f] (take n (repeatedly f)))))
(def cycle (fn* cycle [coll]
             ;; the argument must be seqable now, as on the JVM
             (let* [s0 (seq coll)]
               (lazy-seq (let* [s (seq s0)] (if s (concat s (cycle s)) nil))))))
(def range
  (fn* range
    ([] (iterate (fn* [i] (erlang/+ i 1)) 0))
    ([end] (range 0 end 1))
    ([start end] (range start end 1))
    ([start end step]
     ;; the bounds are checked at the call, as on the JVM (Erlang orders
     ;; every number below a string, so (range "a") would never end)
     (if (erlang/is_number start)
       (if (erlang/is_number end)
         (if (erlang/is_number step) (range* start end step) (clj2_rt/not_number step))
         (clj2_rt/not_number end))
       (clj2_rt/not_number start)))))
(def ^:private range*
  (fn* range* [start end step]
    (lazy-seq
      (if (if (erlang/> step 0) (erlang/< start end) (erlang/> start end))
        (cons start (range* (erlang/+ start step) end step))
        nil))))

;;;; ------------------------------------------------------------------
;;;; Equality and numbers
;;;; ------------------------------------------------------------------

(def =
  (fn* =
    ([x] true)
    ([x y] (clj2_coll/equals x y))
    ([x y & more]
     (if (clj2_coll/equals x y)
       (if (next more) (recur y (first more) (next more)) (clj2_coll/equals y (first more)))
       false))))
(def not= (fn* not= [& args] (not (apply = args))))

(def + (fn* + ([] 0) ([x] (if (erlang/is_number x) x (if (erlang/is_atom x) (if (erlang/== x nil) nil (clj2_rt/not_number x)) (clj2_rt/not_number x)))) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/+ x y) (clj2_rt/num_op (quote +) x y))) ([x y & more] (reduce + (+ x y) more))))
(def * (fn* * ([] 1) ([x] (if (erlang/is_number x) x (if (erlang/is_atom x) (if (erlang/== x nil) nil (clj2_rt/not_number x)) (clj2_rt/not_number x)))) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/* x y) (clj2_rt/num_op (quote *) x y))) ([x y & more] (reduce * (* x y) more))))
(def - (fn* - ([x] (if (erlang/is_number x) (erlang/- 0 x) (clj2_rt/num_op (quote -) 0 x))) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/- x y) (clj2_rt/num_op (quote -) x y))) ([x y & more] (reduce - (- x y) more))))
(def / (fn* / ([x] (clj2_rt/divide 1 x)) ([x y] (clj2_rt/divide x y))
            ([x y & more] (reduce / (clj2_rt/divide x y) more))))
(def inc (fn* inc [x] (if (erlang/is_number x) (erlang/+ x 1) (clj2_rt/num_op (quote +) x 1))))
(def dec (fn* dec [x] (if (erlang/is_number x) (erlang/- x 1) (clj2_rt/num_op (quote -) x 1))))
(def quot (fn* quot [n d] (if (if (erlang/is_integer n) (erlang/is_integer d) false)
                              (erlang/div n d)
                              (clj2_rt/num_quot n d))))
(def rem (fn* rem [n d] (if (if (erlang/is_integer n) (erlang/is_integer d) false)
                            (erlang/rem n d)
                            (clj2_rt/num_rem n d))))
;; the remainder takes the divisor's sign
(def mod (fn* mod [n d] (let* [m (rem n d)]
                          (if (if (zero? m) true (erlang/== (neg? m) (neg? d))) m (+ m d)))))

(def compare-chain
  (fn* compare-chain [op x more]
    (loop* [x x s (seq more)]
      (if s
        (if (op x (erlang/hd s)) (recur (erlang/hd s) (next s)) false)
        true))))
(def < (fn* < ([x] true) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/< x y) (clj2_rt/num_compare (quote <) x y))) ([x y & more] (compare-chain < x (cons y more)))))
(def > (fn* > ([x] true) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/> x y) (clj2_rt/num_compare (quote >) x y))) ([x y & more] (compare-chain > x (cons y more)))))
(def <= (fn* <= ([x] true) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/=< x y) (clj2_rt/num_compare (quote =<) x y))) ([x y & more] (compare-chain <= x (cons y more)))))
(def >= (fn* >= ([x] true) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/>= x y) (clj2_rt/num_compare (quote >=) x y))) ([x y & more] (compare-chain >= x (cons y more)))))
(def == (fn* == ([x] true) ([x y] (if (if (erlang/is_number x) (erlang/is_number y) false) (erlang/== x y) (clj2_rt/num_compare (quote ==) x y))) ([x y & more] (compare-chain == x (cons y more)))))
(def zero? (fn* zero? [x] (if (erlang/is_number x) (erlang/== x 0) (clj2_rt/num_compare (quote ==) x 0))))
(def pos? (fn* pos? [x] (if (erlang/is_number x) (erlang/> x 0) (clj2_rt/num_compare (quote >) x 0))))
(def neg? (fn* neg? [x] (if (erlang/is_number x) (erlang/< x 0) (clj2_rt/num_compare (quote <) x 0))))
(def even? (fn* even? [n] (if (erlang/is_integer n)
                              (erlang/== (erlang/rem n 2) 0)
                              (throw (clj2_rt/ex_info (str "Argument must be an integer: " n)
                                                      (clj2_coll/hash_map_kv (list :type :IllegalArgumentException)) nil)))))
(def odd? (fn* odd? [n] (not (even? n))))
(def max (fn* max ([x] x) ([x y] (if (> x y) x y)) ([x y & more] (reduce max (max x y) more))))
(def min (fn* min ([x] x) ([x y] (if (< x y) x y)) ([x y & more] (reduce min (min x y) more))))

;;;; ------------------------------------------------------------------
;;;; Symbols, keywords, strings
;;;; ------------------------------------------------------------------

(def str (fn* str [& xs] (clj2_rt/str (if xs xs '()))))
(def symbol (fn* symbol ([name] (clj2_rt/symbol name)) ([ns name] (clj2_rt/symbol ns name))))
(def keyword (fn* keyword ([name] (clj2_rt/keyword name)) ([ns name] (clj2_rt/keyword ns name))))
(def name (fn* name [x] (clj2_rt/name x)))
(def namespace (fn* namespace [x] (clj2_rt/namespace x)))
(def gensym (fn* gensym ([] (clj2_rt/gensym "G__")) ([prefix] (clj2_rt/gensym prefix))))

;;;; ------------------------------------------------------------------
;;;; Basic macros (defmacro is a kernel form of the compiler)
;;;; ------------------------------------------------------------------

(defmacro comment [& body] nil)
;; forward references are resolved per namespace (designs/03 §2.1)
(defmacro declare [& names]
  `(do ~@(mapcat (fn* [n] (list (list 'def n) (list 'clj2_rt/merge_var_meta (list 'var n) {:declared true}))) names)))
(defmacro when [test & body] `(if ~test (do ~@body)))
(defmacro when-not [test & body] `(if ~test nil (do ~@body)))
(defmacro if-not ([test then] `(if ~test nil ~then)) ([test then else] `(if ~test ~else ~then)))
(defmacro and
  ([] true)
  ([x] x)
  ([x & more] `(let* [and# ~x] (if and# (and ~@more) and#))))
(defmacro or
  ([] nil)
  ([x] x)
  ([x & more] `(let* [or# ~x] (if or# or# (or ~@more)))))
(defmacro cond [& clauses]
  (if clauses
    (list 'if (first clauses)
          (if (next clauses)
            (second clauses)
            (throw (clj2_rt/str (list "cond requires an even number of forms"))))
          (cons 'clojure.core/cond (nnext clauses)))
    nil))
(defmacro case [e & clauses] `(case* ~e ~@clauses))
(defmacro lazy-cat [& colls] `(concat ~@(map (fn* [c] (list 'clojure.core/lazy-seq c)) colls)))
(defmacro -> [x & forms]
  (loop* [x x forms (seq forms)]
    (if forms
      (let* [f (erlang/hd forms)
             threaded (if (seq? f)
                        (cons (first f) (cons x (next f)))
                        (list f x))]
        (recur threaded (next forms)))
      x)))
(defmacro ->> [x & forms]
  (loop* [x x forms (seq forms)]
    (if forms
      (let* [f (erlang/hd forms)
             threaded (if (seq? f)
                        (concat f (list x))
                        (list f x))]
        (recur threaded (next forms)))
      x)))

;;;; ------------------------------------------------------------------
;;;; Destructuring (designs/09 §2: the compiler's let*/fn*/loop* take
;;;; symbols only; patterns are expanded here, as in JVM clojure.core)
;;;; ------------------------------------------------------------------

;; pattern, init → flat binding list (sym init sym init ...)

;; Map destructuring of a seq (keyword arguments, & {:keys [a]}): pairs
;; become a map, a lone value is the map itself, and after the pairs a
;; trailing map is merged over them (Clojure 1.11's createAsIfByAssoc)
(def seq-to-map-for-destructuring
  (fn* seq-to-map-for-destructuring [s]
    (if (next s)
      (loop* [m (hash-map) xs (seq s)]
        (if xs
          (if (next xs)
            (recur (assoc m (first xs) (second xs)) (nnext xs))
            (if (map? (first xs))
              (reduce (fn* [acc e] (assoc acc (first e) (second e))) m (seq (first xs)))
              (throw (clj2_rt/ex_info (str "No value supplied for key: " (first xs))
                                      (hash-map :type :IllegalArgumentException) nil))))
          m))
      (if (seq s) (first s) (hash-map)))))

;; the local a :keys/:syms/:strs entry binds, and the key it looks up:
;; a/b and :a/b bind b and look up :a/b; under :ns/keys an unqualified
;; name takes that namespace
(def destructure-key
  (fn* destructure-key [kind ns-of-kind x]
    (let* [n (name x)
           q (if (namespace x) (namespace x) ns-of-kind)]
      (list (symbol n)
            (if (= kind "keys")
              (if q (keyword q n) (keyword n))
              (if (= kind "syms")
                (list 'quote (if q (symbol q n) (symbol n)))
                n))))))

(def destructure-1
  (fn* destructure-1 [pat init]
    (if (symbol? pat)
      (list pat init)
      (if (vector? pat)
        ;; with a rest pattern the positions walk (seq init), as on the JVM,
        ;; so a map or a set destructures too
        (let* [g (gensym "vec__")
               rest? (some (fn* [p] (= p '&)) pat)
               gs (if rest? (gensym "seq__") g)]
          (loop* [ps (seq pat) i 0 out (if rest? (list g init gs (list 'clojure.core/seq g)) (list g init))]
            (if ps
              (let* [p (erlang/hd ps)]
                (if (= p '&)
                  (recur (nnext ps) i
                         (concat out (destructure-1 (second ps) (list 'clojure.core/nthnext gs i))))
                  (if (= p :as)
                    (recur (nnext ps) i (concat out (list (second ps) g)))
                    (recur (next ps) (erlang/+ i 1)
                           (concat out (destructure-1 p (list 'clojure.core/nth gs i nil)))))))
              out)))
        (if (map? pat)
          (let* [g (gensym "map__")
                 init (list 'if (list 'clojure.core/seq? init)
                            (list 'clojure.core/seq-to-map-for-destructuring init)
                            init)
                 defaults (get pat :or)
                 lookup (fn* [sym key]
                          (if (contains? defaults sym)
                            (list 'clojure.core/get g key (get defaults sym))
                            (list 'clojure.core/get g key)))
                 binds (reduce
                         (fn* [out entry]
                           (let* [k (first entry) v (second entry)
                                  kind (if (keyword? k) (name k) nil)]
                             (if (if (= kind "keys") true (if (= kind "syms") true (= kind "strs")))
                               (concat out (mapcat (fn* [x]
                                                     (let* [bk (destructure-key kind (namespace k) x)]
                                                       (list (first bk) (lookup (first bk) (second bk)))))
                                                   v))
                               (if false nil
                                 (if false nil
                                   (if (= k :as)
                                     (concat out (list v g))
                                     (if (= k :or)
                                       out
                                       (concat out (destructure-1 k (lookup k v))))))))))
                         (list g init)
                         (seq pat))]
            binds)
          (throw (str "Unsupported binding form: " pat)))))))

(def destructure
  (fn* destructure [bindings]
    (loop* [s (seq bindings) out '()]
      (if s
        (recur (nnext s) (concat out (destructure-1 (first s) (second s))))
        (vec out)))))

;; [params] → [plain-params pattern-bindings]: every non-symbol param
;; becomes a gensym, rebound to its pattern by a let
(def fn-params
  (fn* fn-params [params]
    (loop* [ps (seq params) out '() binds '()]
      (if ps
        (let* [p (erlang/hd ps)]
          (if (symbol? p)
            (recur (next ps) (concat out (list p)) binds)
            (let* [g (gensym "p__")]
              (recur (next ps) (concat out (list g)) (concat binds (list p g))))))
        (list (vec out) binds)))))

(defmacro let [bindings & body]
  `(let* ~(destructure bindings) ~@body))

;; a fn body's leading {:pre [...] :post [...]} map → asserts around it
;; (% is the result in :post)
(def pre-post
  (fn* pre-post [body]
    (if (if (clj2_coll/is_any_map (first body)) (next body) nil)
      (let* [conds (first body)
             body (next body)
             pre (clj2_coll/get conds :pre)
             post (clj2_coll/get conds :post)
             chk (fn* [c] (list 'clojure.core/assert c))]
        (concat (map chk pre)
                (if post
                  (list (list 'clojure.core/let ['% (cons 'do body)]
                              (cons 'do (map chk post))
                              '%))
                  body)))
      body)))

(defmacro fn [& sigs]
  (let* [name (if (symbol? (first sigs)) (first sigs) nil)
         sigs (if name (next sigs) sigs)
         sigs (if (vector? (first sigs)) (list sigs) sigs)
         lower (fn* [sig]
                 (let* [r (fn-params (first sig))
                        params (first r)
                        binds (second r)
                        body (pre-post (rest sig))]
                   (if (seq binds)
                     (list params (cons 'clojure.core/let (cons (vec binds) body)))
                     (cons params body))))]
    (if name
      (cons 'fn* (cons name (map lower sigs)))
      (cons 'fn* (map lower sigs)))))

(defmacro loop [bindings & body]
  (let* [pairs (loop* [s (seq bindings) out '()]
                 (if s (recur (nnext s) (concat out (list (list (first s) (second s))))) out))]
    (if (every? (fn* [p] (symbol? (first p))) pairs)
      `(loop* ~bindings ~@body)
      ;; each init is bound, then destructured, before the next one runs
      ;; (it may use the names the earlier ones bound)
      (let* [gs (map (fn* [p] (gensym "loop__")) pairs)]
        `(let [~@(mapcat (fn* [g p] (list g (second p) (first p) g)) gs pairs)]
           (loop* [~@(mapcat (fn* [g] (list g g)) gs)]
             (let [~@(mapcat (fn* [g p] (list (first p) g)) gs pairs)]
               ~@body)))))))

;; (def name {meta} f): :doc, the attr-map and :arglists, as the JVM's
;; defn conj's them (clj2_rt:defn_meta)
(defmacro defn [name & fdecl]
  (let* [doc (if (string? (first fdecl)) (first fdecl) nil)
         fdecl (if doc (next fdecl) fdecl)
         attr (if (map? (first fdecl)) (first fdecl) nil)
         fdecl (if attr (next fdecl) fdecl)
         ;; ([x] ...) ([x y] ...) {:k v}: a trailing attr-map, merged over
         trail (if (if (seq? (first fdecl)) (map? (lists/last (clj2_coll/to_list fdecl))) false)
                 (lists/last (clj2_coll/to_list fdecl)) nil)
         fdecl (if trail (lists/droplast (clj2_coll/to_list fdecl)) fdecl)
         attr (if trail (clj2_coll/conj (if attr attr {}) trail) attr)
         sigs (if (vector? (first fdecl)) (list (first fdecl)) (map first fdecl))
         f (cons 'clojure.core/fn (cons (clj2_form/plain_name name) fdecl))]
    (list 'def name (clj2_rt/defn_meta doc attr sigs) f)))

;; defn with :private true in its attr-map (symbols carry no metadata, so
;; it goes there rather than on the name)
(defmacro defn- [name & fdecl]
  (let* [doc (if (string? (first fdecl)) (first fdecl) nil)
         fdecl (if doc (next fdecl) fdecl)
         attr (if (map? (first fdecl)) (clj2_coll/assoc (first fdecl) :private true) {:private true})
         fdecl (if (map? (first fdecl)) (next fdecl) fdecl)]
    (cons 'clojure.core/defn (cons name (if doc (cons doc (cons attr fdecl)) (cons attr fdecl))))))

(defmacro letfn [fnspecs & body]
  `(letfn* ~(vec (mapcat (fn* [spec] (list (first spec) (cons 'clojure.core/fn spec))) fnspecs))
           ~@body))

(defmacro if-let
  ([bindings then] `(if-let ~bindings ~then nil))
  ([bindings then else]
   (let* [form (first bindings) tst (second bindings)]
     `(let* [temp# ~tst]
        (if temp# (let [~form temp#] ~then) ~else)))))

(defmacro when-let [bindings & body]
  (if (not= (count bindings) 2)
    (throw (clj2_rt/ex_info "when-let requires exactly 2 forms in binding vector" {:type :IllegalArgumentException} nil)))
  (let* [form (first bindings) tst (second bindings)]
    `(let* [temp# ~tst]
       (if temp# (let [~form temp#] ~@body) nil))))

(defmacro dotimes [bindings & body]
  (let* [i (first bindings) n (second bindings)]
    `(let* [n# ~n]
       (loop* [~i 0]
         (if (erlang/< ~i n#) (do ~@body (recur (erlang/+ ~i 1))) nil)))))

(declare doseq-step)

;; doseq: one loop* per binding, nested; the modifiers after a binding
;; (:let, :when, :while) apply in order inside its loop. `s' is that
;; loop's seq symbol: :when skips to the next element, :while ends it.
(def doseq-emit
  (fn* doseq-emit [bs body]
    (if (seq bs)
      (let* [s (gensym "doseq_s")]
        `(loop* [~s (clojure.core/seq ~(second bs))]
           (if ~s
             (let [~(first bs) (clojure.core/first ~s)] ~(doseq-step (nnext bs) s body))
             nil)))
      `(do ~@body nil))))

(def doseq-step
  (fn* doseq-step [more s body]
    (let* [k (first more)]
      (if (= k :let)
        `(let ~(second more) ~(doseq-step (nnext more) s body))
        (if (= k :when)
          `(if ~(second more) ~(doseq-step (nnext more) s body) (recur (clojure.core/next ~s)))
          (if (= k :while)
            `(if ~(second more) ~(doseq-step (nnext more) s body) nil)
            `(do ~(doseq-emit more body) (recur (clojure.core/next ~s)))))))))

(defmacro doseq [bindings & body] (doseq-emit (seq bindings) body))

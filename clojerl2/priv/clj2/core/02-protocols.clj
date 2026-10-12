;; clojure.core — layer 02-protocols (designs/04 §6.1, clojerl2-016).
;;
;; defprotocol / extend-type / extend-protocol / deftype / defrecord are
;; kernel forms of the compiler (they need the namespace and produce impl
;; modules, designs/03 §4); this layer holds the functions around them.
;; Type designators are the clj2_proto tags (nil boolean keyword symbol
;; integer float string list vector map set fn ... default) or a
;; deftype/defrecord name.

(in-ns 'clojure.core)

(defn class
  "x's class, as the JVM names it: java.lang.Long, clojure.lang.PersistentVector,
  ns.Name for a record or deftype (clj2_class)."
  [x]
  (clj2_class/class_of x))

(defn type
  "x's :type metadata, else its class."
  [x]
  (clj2_class/type_of x))

(defn instance?
  "True when x is an instance of class c (its class or a super of it). A
  clj2 type tag (integer string ... as extend-type takes) works too."
  [c x]
  (if (and (symbol? c) (not (clj2_class/is_class c)) (= (clj2_proto/type_tag x) c))
    true
    (clj2_class/is_instance c x)))

(defn class? [x] (clj2_class/is_class x))
(defn supers [c] (not-empty (set (erlang/apply 'maps 'keys (list (clj2_class/supers c))))))
(defn bases [c] (seq (clj2_class/bases c)))
(defn cast [c x]
  (if (or (nil? x) (instance? c x))
    x
    (throw (ex-info (str "Cannot cast " (class x) " to " c) {:type :ClassCastException}))))

(defn satisfies?
  "True when x's type extends protocol p (directly or through default)."
  [p x]
  (clj2_proto/satisfies (get p :name) x))

(defn extends?
  "True when type tag t extends protocol p."
  [p t]
  (not= (clj2_proto/impl (get p :name) (clj2_proto/extend_tag t)) 'error))

(defn record?
  [x]
  (if (clj2_proto/is_type_value x) (erlang/is_map (erlang/element 3 x)) false))

(defn extend
  "Extends protocols to type at run time: (extend T P1 {:m (fn ...)} P2 {...})."
  [atype & proto+mmaps]
  (doseq [[proto mmap] (partition 2 proto+mmaps)]
    (clj2_proto/extend_fns atype proto mmap)))

(defn extenders [p] (seq (clj2_proto/extenders p)))

;; Inst: what inst-ms reads (no #inst type of its own here; a type extends it)
(defprotocol Inst (inst-ms* [inst]))
(defn inst-ms [inst] (inst-ms* inst))
(defn inst? [x] (satisfies? Inst x))

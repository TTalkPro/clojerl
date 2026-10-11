;; clojure.core — layer 02-protocols (designs/04 §6.1, clojerl2-016).
;;
;; defprotocol / extend-type / extend-protocol / deftype / defrecord are
;; kernel forms of the compiler (they need the namespace and produce impl
;; modules, designs/03 §4); this layer holds the functions around them.
;; Type designators are the clj2_proto tags (nil boolean keyword symbol
;; integer float string list vector map set fn ... default) or a
;; deftype/defrecord name.

(in-ns 'clojure.core)

(defn type
  "The dispatch tag of x: a built-in tag or the qualified deftype/defrecord name."
  [x]
  (clj2_proto/type_tag x))

(defn instance?
  "True when x's type tag is t (a built-in tag symbol, or a deftype/defrecord var)."
  [t x]
  (= (clj2_proto/type_tag x) t))

(defn satisfies?
  "True when x's type extends protocol p (directly or through default)."
  [p x]
  (clj2_proto/satisfies (get p :name) x))

(defn extends?
  "True when type tag t extends protocol p."
  [p t]
  (not= (clj2_proto/impl (get p :name) t) 'error))

(defn record?
  [x]
  (if (clj2_proto/is_type_value x) (erlang/is_map (erlang/element 3 x)) false))

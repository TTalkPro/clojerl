;;   Portions of this file are from Clojure's src/clj/clojure/set.clj,
;;   Copyright (c) Rich Hickey. All rights reserved.
;;   The use and distribution terms for that software are covered by the
;;   Eclipse Public License 1.0; this file keeps that notice.
;;
;;   Ported from jolt's stdlib/clojure/set.clj (EPL-1.0; clojerl2-022),
;;   which walks the smaller side in intersection / difference.

(ns clojure.set
  "Set operations: union, intersection, difference, and the relational
  algebra over sets of maps (select, project, rename, index, join).")

(defn union
  "Return a set that is the union of the input sets"
  ([] #{})
  ([s1] s1)
  ([s1 s2] (if (< (count s1) (count s2)) (reduce conj s2 s1) (reduce conj s1 s2)))
  ([s1 s2 & sets] (reduce union (union s1 s2) sets)))

(defn intersection
  "Return a set that is the intersection of the input sets"
  ([s1] s1)
  ([s1 s2]
   ;; walk the smaller side: the reduce rebuilds from its first argument
   (if (< (count s2) (count s1))
     (recur s2 s1)
     (reduce (fn [acc item] (if (contains? s2 item) acc (disj acc item))) s1 s1)))
  ([s1 s2 & sets] (reduce intersection (intersection s1 s2) sets)))

(defn difference
  "Return a set that is the first set without elements of the remaining sets"
  ([s1] s1)
  ([s1 s2]
   (if (< (count s1) (count s2))
     (reduce (fn [result item] (if (contains? s2 item) (disj result item) result)) s1 s1)
     (reduce disj s1 s2)))
  ([s1 s2 & sets] (reduce difference (difference s1 s2) sets)))

(defn select
  "Returns a set of the elements for which pred is true"
  [pred s]
  (reduce (fn [acc item] (if (pred item) acc (disj acc item))) s s))

(defn project
  "Returns a rel of the elements of xrel with only the keys in ks"
  [xrel ks]
  (set (map #(select-keys % ks) xrel)))

(defn rename-keys
  "Returns the map with the keys in kmap renamed to the vals in kmap"
  [map kmap]
  (reduce (fn [m [old new]]
            (if (contains? map old)
              (assoc m new (get map old))
              m))
          (apply dissoc map (keys kmap))
          kmap))

(defn map-invert
  "Returns the map with the vals mapped to the keys."
  [m]
  (reduce (fn [acc [k v]] (assoc acc v k)) {} m))

(defn rename
  "Returns a rel of the maps in xrel with the keys in kmap renamed to the vals in kmap"
  [xrel kmap]
  (set (map (fn [m]
              (reduce (fn [acc [old new]] (if (contains? m old) (assoc acc new (get m old)) acc))
                      (apply dissoc m (keys kmap)) kmap))
            xrel)))

(defn index
  "Returns a map of the distinct values of ks in the xrel mapped to a
  set of the maps in xrel with the corresponding values of ks."
  [xrel ks]
  (reduce (fn [m x] (let [ik (select-keys x ks)] (assoc m ik (conj (get m ik #{}) x)))) {} xrel))

(defn join
  "When passed 2 rels, returns the rel corresponding to the natural
  join. When passed an additional keymap, joins on the corresponding
  keys."
  ([xrel yrel]
   (if (and (seq xrel) (seq yrel))
     (let [ks (intersection (set (keys (first xrel))) (set (keys (first yrel))))
           [r s] (if (<= (count xrel) (count yrel)) [xrel yrel] [yrel xrel])
           idx (index r ks)]
       (reduce (fn [ret x]
                 (let [found (idx (select-keys x ks))]
                   (if found
                     (reduce (fn [acc y] (conj acc (merge y x))) ret found)
                     ret)))
               #{} s))
     #{}))
  ([xrel yrel km]
   (let [[r s k] (if (<= (count xrel) (count yrel))
                   [xrel yrel (map-invert km)]
                   [yrel xrel km])
         idx (index r (vals k))]
     (reduce (fn [ret x]
               (let [found (idx (rename-keys (select-keys x (keys k)) k))]
                 (if found
                   (reduce (fn [acc y] (conj acc (merge y x))) ret found)
                   ret)))
             #{} s))))

(defn subset?
  "Is set1 a subset of set2?"
  [set1 set2]
  (and (<= (count set1) (count set2))
       (every? #(contains? set2 %) set1)))

(defn superset?
  "Is set1 a superset of set2?"
  [set1 set2]
  (and (>= (count set1) (count set2))
       (every? #(contains? set1 %) set2)))

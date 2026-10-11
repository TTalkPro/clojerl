(ns hello.core
  (:require [hello.shapes :as s]
            [hello.text :refer [describe with-banner]]))

(defn report [shapes]
  (with-banner "形状"
    (apply str (interpose "\n" (map (fn [x] (describe (s/label x) (s/area x))) shapes)))))

(defn -main [& _]
  (println (report [(s/->Square 3) (s/->Rect 2 5)])))

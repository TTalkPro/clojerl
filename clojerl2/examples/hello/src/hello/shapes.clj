(ns hello.shapes)

(defprotocol Shape
  (area [s] "The shape's area.")
  (label [s]))

(defrecord Square [side])
(defrecord Rect [w h])

(extend-type Square Shape
  (area [s] (* (:side s) (:side s)))
  (label [s] "square"))

(extend-type Rect Shape
  (area [s] (* (:w s) (:h s)))
  (label [s] "rect"))

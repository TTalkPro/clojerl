(ns hello.text)

(defn describe [label area] (str label " of area " area))

(defmacro with-banner [title & body]
  `(str "== " ~title " ==\n" ~@body))

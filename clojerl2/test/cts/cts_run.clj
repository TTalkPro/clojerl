(ns cts-run
  "Runner for the vendored jank-lang/clojure-test-suite
  (vendor/clojure-test-suite, clojerl2-022): requires each test namespace
  named on the command line and runs its clojure.test tests, printing one
  machine-readable line per namespace,

      CTS-RESULT <ns> <pass> <fail> <error>

  Driven one process per namespace by test/cts.sh, so a hang or a crash
  in one namespace cannot take out the run. A namespace that does not
  load counts as one error, with the reason after the counts."
  (:require [clojure.test :as t]
            [clojure.string :as str]))

(defn -main [& nses]
  (doseq [n nses]
    (let [ns-sym (symbol n)]
      (try
        (require ns-sym)
        (let [r (t/run-tests ns-sym)]
          (println "CTS-RESULT" n (:pass r 0) (:fail r 0) (:error r 0)))
        (catch Throwable e
          (println "CTS-RESULT" n 0 0 1
                   (str "LOAD: " (str/replace (or (ex-message e) (pr-str e)) #"\s+" " "))))))))

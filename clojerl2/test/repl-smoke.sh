#!/bin/sh
# REPL / CLI smoke test (clojerl2-023): drives bin/clojerl2 as a user
# would — REPL over stdin, -e, a script with arguments, -m — and checks
# what comes out. Run by `make smoke` (and CI).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
clj="$here/bin/clojerl2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

# expect NAME HAYSTACK NEEDLE: the output must contain the line fragment
expect() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then :; else
    echo "FAIL [$1]: expected to see: $3"; fails=$((fails + 1))
  fi
}

# --- the REPL: eval, defn, redefinition, macros, errors, *1, unicode, ns
repl=$(printf '%s\n' \
  '(+ 1 2)' \
  '(defn f [x] (* x 2))' \
  '(def g f)' \
  '(defn f' '  [x] (* x 3))' \
  '[(f 1) (g 1)]' \
  '(defmacro unless [c & body] `(if ~c nil (do ~@body)))' \
  '(unless false :ran)' \
  '(macroexpand-1 (quote (unless a b)))' \
  'no-such-thing' \
  '(f 1 2)' \
  '(throw (ex-info "boom" {:a 1}))' \
  '(* 6 7)' '*1' \
  '(str "你好" "，世界")' \
  '(doc map)' \
  '(in-ns (quote smoke.other))' \
  '(def y 9) y' \
  ':repl/quit' \
  '(println "after quit")' \
  | "$clj" 2>&1)
expect banner "$repl" "clojerl2 "
expect eval "$repl" "user=> 3"
expect defn "$repl" "#'user/f"
expect redefine "$repl" "[3 2]"
expect macro "$repl" ":ran"
expect macroexpand "$repl" "(if a nil (do b))"
expect unresolved "$repl" "Unable to resolve symbol: no-such-thing in this context"
expect arity "$repl" "Wrong number of args (2) passed to: user/f"
expect ex-info "$repl" "boom {:a 1}"
expect star1 "$repl" "user=> 42"
expect unicode "$repl" '"你好，世界"'
expect doc "$repl" "clojure.core/map"
expect in-ns "$repl" "smoke.other=> #'smoke.other/y"
if printf '%s\n' "$repl" | grep -qF "after quit"; then
  echo "FAIL [quit]: input after :repl/quit was evaluated"; fails=$((fails + 1))
fi

# --- -e prints each non-nil value
e=$("$clj" -e '(+ 1 2)' -e '(println "中文")' 2>&1)
expect -e "$e" "3"
expect -e-unicode "$e" "中文"

# --- a script, with *command-line-args*
cat > "$work/script.clj" <<'CLJ'
(defn greet [who] (str "hello, " who))
(println (greet (first *command-line-args*)) (count *command-line-args*))
CLJ
s=$("$clj" "$work/script.clj" 世界 b 2>&1)
expect script "$s" "hello, 世界 2"

# --- -m: require a namespace from the source path, call -main
mkdir -p "$work/src/smoke"
cat > "$work/src/smoke/main_ns.clj" <<'CLJ'
(ns smoke.main-ns)
(defn -main [& args] (println "main got" (vec args)))
CLJ
m=$("$clj" -p "$work/src" -m smoke.main-ns x y 2>&1)
expect -m "$m" 'main got [x y]'

# --- exit status: an uncaught error is 1, with a report on stderr
"$clj" -e '(throw (ex-info "bad" {}))' >/dev/null 2>"$work/err"; rc=$?
[ "$rc" = 1 ] || { echo "FAIL [exit]: status $rc, expected 1"; fails=$((fails + 1)); }
expect stderr "$(cat "$work/err")" "Execution error (ExceptionInfo)"

if [ "$fails" -gt 0 ]; then
  echo "repl smoke: $fails failure(s)"; echo "--- REPL transcript:"; printf '%s\n' "$repl"
  exit 1
fi
echo "repl smoke: ok"

#!/bin/sh
# Dump every failing corpus row registered with cause $1 (default
# :pending/triage) to stdout: suite, label, source, expected, why.
# Dev aid for triaging test/corpus-known-failures.edn; memory-capped.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here" || exit 1
cause=${1:-:pending/triage}
run=""
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope -q true 2>/dev/null; then
  run="systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0"
fi
$run erl -noshell -pa ebin -eval "
  #{entries := Known} = clj2_corpus:known_failures(),
  Cause = list_to_atom(\"$cause\"),
  R = clj2_corpus:run(),
  Fails = [{E, W} || {_, E = #{suite := S, label := L}, {fail, W}} <- R, maps:get({S, L}, Known, none) =:= Cause],
  io:format(\"~b rows~n\", [length(Fails)]),
  [io:format(\"~n== ~ts / ~ts~n   actual:   ~ts~n   expected: ~ts~n   why:      ~tP~n\",
             [S, L, A, X, W, 12]) || {#{suite := S, label := L, actual := A, expected := X}, W} <- Fails],
  halt()." 2>&1 | grep -v '^=WARNING\|^The on_load\|^{error,init_failed}\|^$'

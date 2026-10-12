#!/bin/sh
# Run the corpus rows whose suite starts with $1 (a grep -E pattern on the
# suite string) and print each failing row: label, source, expected, why.
# Dev aid for triaging test/corpus-known-failures.edn; memory-capped like
# `make corpus'.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here" || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
{ echo "["; grep -E "^ *\{:suite \"($1)" test/corpus.edn; echo "]"; } > "$tmp/pick.edn"
run=""
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope -q true 2>/dev/null; then
  run="systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0"
fi
$run erl -noshell -pa ebin -eval "
  R = clj2_corpus:run(#{file => \"$tmp/pick.edn\"}),
  Fails = [{E, W} || {_, E, {fail, W}} <- R],
  io:format(\"~b rows, ~b fail~n\", [length(R), length(Fails)]),
  [io:format(\"~n== ~ts / ~ts~n   actual:   ~ts~n   expected: ~ts~n   why:      ~tP~n\",
             [S, L, A, X, W, 14]) || {#{suite := S, label := L, actual := A, expected := X}, W} <- Fails],
  halt()." 2>&1 | grep -v '^=WARNING\|^The on_load\|^{error,init_failed}\|^$'

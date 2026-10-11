#!/bin/sh
# rebar3 plugin check (clojerl2-024): builds examples/hello with
# `rebar3 clojerl2 compile` twice (the second build must come entirely
# from the cache), drives `rebar3 clojerl2 repl`, then `clean`.
# clojerl2 and the plugin are linked in as _checkouts (git-ignored).
# Run by `make example` (and CI).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
command -v rebar3 >/dev/null 2>&1 || { echo "rebar3 example: skipped (no rebar3)"; exit 0; }
cd "$here/examples/hello" || exit 1
mkdir -p _checkouts
ln -sfn ../../.. _checkouts/clojerl2
ln -sfn ../../../rebar3_clojerl2 _checkouts/rebar3_clojerl2
rm -rf _build
fails=0
expect() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then :; else
    echo "FAIL [$1]: expected to see: $3"; printf '%s\n' "$2" | tail -15; fails=$((fails + 1))
  fi
}
first=$(rebar3 clojerl2 compile 2>&1)
expect first-build "$first" "clojerl2 hello: 3 compiled, 0 cached"
second=$(rebar3 clojerl2 compile 2>&1)
expect cached-build "$second" "clojerl2 hello: 0 compiled, 3 cached"
for m in hello.core hello.shapes hello.text; do
  [ -f "_build/default/lib/hello/ebin/$m.beam" ] || { echo "FAIL [ebin]: $m.beam missing"; fails=$((fails + 1)); }
done
repl=$(printf '%s\n' "(require '[hello.core :as c])" \
                     '(c/report [(hello.shapes/->Square 2) (hello.shapes/->Rect 3 4)])' \
       | rebar3 clojerl2 repl 2>&1)
expect repl "$repl" 'square of area 4\nrect of area 12'
expect repl-unicode "$repl" '== 形状 =='
rebar3 clojerl2 clean >/dev/null 2>&1
[ ! -d _build/default/clojerl2_cache ] || { echo "FAIL [clean]: cache still there"; fails=$((fails + 1)); }
[ ! -f _build/default/lib/hello/ebin/hello.core.beam ] || { echo "FAIL [clean]: modules still in ebin"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] || { echo "rebar3 example: $fails failure(s)"; exit 1; }
echo "rebar3 example: ok"

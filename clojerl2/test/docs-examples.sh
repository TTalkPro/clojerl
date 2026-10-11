#!/bin/sh
# The `EXPR ;=> RESULT' examples in docs/*.md, evaluated with bin/clojerl2
# and compared with what the docs say (clojerl2-025). Results that differ
# per run (pids, refs: anything with `<' or `...') are only run, not
# compared. Run by `make docs-check` (and CI).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
clj="$here/bin/clojerl2"
fails=0; n=0
tab=$(printf '\t')
# EXPR<TAB>RESULT for each `;=>' line inside a ```clojure block
python3 - "$here"/docs/*.md > "${TMPDIR:-/tmp}/clj2-doc-examples.$$" <<'PY'
import sys, re
for path in sys.argv[1:]:
    block = False
    for line in open(path, encoding="utf-8"):
        if line.startswith("```"):
            block = line.strip() == "```clojure"
            continue
        m = re.match(r"^(.*?)\s*;=>\s*(.*?)\s*$", line) if block else None
        if m and m.group(1).strip():
            # a result may be followed by a remark after two or more spaces
            res = re.split(r"\s{2,}", m.group(2))[0]
            print(m.group(1).strip() + "\t" + res + "\t" + path.split("/")[-1])
PY
while IFS="$tab" read -r expr expected doc; do
  n=$((n + 1))
  actual=$("$clj" -e "$expr" 2>&1 | tail -1)
  case "$expected" in
    *"<"*|*"..."*) [ -n "$actual" ] || { echo "FAIL [$doc] $expr: no output"; fails=$((fails + 1)); } ;;
    *) [ "$actual" = "$expected" ] || { echo "FAIL [$doc] $expr"; echo "   docs: $expected"; echo "   got:  $actual"; fails=$((fails + 1)); } ;;
  esac
done < "${TMPDIR:-/tmp}/clj2-doc-examples.$$"
rm -f "${TMPDIR:-/tmp}/clj2-doc-examples.$$"
[ "$fails" -eq 0 ] || { echo "docs examples: $fails of $n failed"; exit 1; }
echo "docs examples: $n ok"

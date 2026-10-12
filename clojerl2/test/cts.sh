#!/bin/sh
# clojure-test-suite gate (clojerl2-022): runs the vendored
# jank-lang/clojure-test-suite (vendor/clojure-test-suite) against
# clojerl2, one VM per test namespace (a hang or a crash is contained),
# and compares the per-namespace fail/error counts with the checked-in
# baseline test/cts-known-failures.txt.
#
# The comparison is exact, like certify's: a namespace doing WORSE than
# the baseline fails the gate (a regression), and one doing BETTER fails
# it too (a stale baseline: update the file in the change that improved
# it). A namespace whose counts differ is re-run once on its own first,
# so a test that lost a timing race against the parallel workers is not
# reported either way.
#
#   CLJ2_CTS_JOBS=N            parallel workers (default: the CPU count)
#   CLJ2_CTS_TIMEOUT=SECS      per-namespace timeout (default 120)
#   CLJ2_CTS_WRITE_BASELINE=1  regenerate the baseline instead of gating
#   CLJ2_CTS_NS=ns1,ns2        run only these namespaces, verbose, no gating
#
# Run by `make cts` (and CI), inside the memory-capped scope the Makefile
# sets up; each VM also caps its processes' heaps (CLJ2_ERL_FLAGS).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here" || exit 1
suite="vendor/clojure-test-suite/test"
baseline="test/cts-known-failures.txt"
clj="$here/bin/clojerl2"
jobs="${CLJ2_CTS_JOBS:-$(nproc 2>/dev/null || echo 4)}"
tmo="${CLJ2_CTS_TIMEOUT:-120}"
# 256 MiB (in words) per Erlang process: a runaway test dies, the VM stays
export CLJ2_ERL_FLAGS="${CLJ2_ERL_FLAGS:-+hmax 33554432}"
# a VM the memory cap kills must not leave erl_crash.dump in the tree
export ERL_CRASH_DUMP=/dev/null

if [ ! -d "$suite/clojure" ]; then
  echo "cts: skipped (git submodule update --init clojerl2/vendor/clojure-test-suite)"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# the test namespaces: one per .cljc file (portability and number-range
# are helpers, not test namespaces)
find "$suite" -name '*.cljc' | sed "s|^$suite/||;s|\.cljc$||;s|/|.|g;s|_|-|g" \
  | grep -v -e '\.portability$' -e '\.number-range$' | sort > "$work/nses"
if [ -n "${CLJ2_CTS_NS:-}" ]; then
  echo "$CLJ2_CTS_NS" | tr ',' '\n' > "$work/nses"
fi

# one namespace, one VM: "ns pass fail error" (HUNG / CRASH in the pass
# column), plus the FAIL/ERROR/LOAD lines when verbose
run_one() { # ns out verbose
  res=$(timeout "$tmo" "$clj" -p "test/cts:$suite" -m cts-run "$1" 2>&1 </dev/null)
  rc=$?
  line=$(printf '%s\n' "$res" | grep '^CTS-RESULT' | head -1)
  if [ -n "$line" ]; then
    printf '%s\n' "$line" | awk '{print $2, $3, $4, $5}' >> "$2"
    if [ "$3" = 1 ]; then
      printf '%s\n' "$res" | grep -E '^(FAIL|ERROR) in|^CTS-RESULT .* LOAD:|^expected:|^  actual:|^SKIP' | sed 's/^/    /' >> "$2"
    fi
  elif [ $rc -ge 124 ]; then
    echo "$1 HUNG 0 0" >> "$2"
  else
    echo "$1 CRASH 0 0" >> "$2"
    [ "$3" = 1 ] && printf '%s\n' "$res" | tail -5 | sed 's/^/    /' >> "$2"
  fi
}

# round-robin the namespaces over N sequential workers
awk -v j="$jobs" -v w="$work" '{print > (w "/chunk." (NR % j))}' "$work/nses"
verbose=0; [ -n "${CLJ2_CTS_NS:-}" ] && verbose=1
for c in "$work"/chunk.*; do
  ( while IFS= read -r ns; do run_one "$ns" "$c.res" "$verbose"; done < "$c" ) &
done
wait
cat "$work"/chunk.*.res 2>/dev/null > "$work/results.raw"
grep -v '^    ' "$work/results.raw" | sort > "$work/results"

if [ "$verbose" = 1 ]; then
  cat "$work/results.raw"
  exit 0
fi

summary=$(awk '$2!="HUNG" && $2!="CRASH" {p+=$2; f+=$3; e+=$4; c++}
               $2=="HUNG" {h++} $2=="CRASH" {x++}
               END {printf "%d namespaces: pass %d, fail %d, error %d, hung %d, crash %d",
                    c+h+x, p, f, e, h, x}' "$work/results")

if [ "${CLJ2_CTS_WRITE_BASELINE:-0}" = 1 ]; then
  {
    echo "# clojure-test-suite known failures (clojerl2-022): <namespace> <fail> <error>"
    echo "# One line per namespace that does not pass cleanly; HUNG or CRASH when the"
    echo "# VM did not report. The gate (test/cts.sh) fails on any per-namespace change,"
    echo "# worse OR better; regenerate with: CLJ2_CTS_WRITE_BASELINE=1 make cts"
    awk '$2=="HUNG" || $2=="CRASH" {print $1, $2, $2; next}
         $3 != 0 || $4 != 0 {print $1, $3, $4}' "$work/results"
  } > "$baseline"
  echo "cts: $summary"
  echo "cts: baseline written to $baseline ($(grep -cv '^#' "$baseline") namespaces)"
  exit 0
fi

if [ ! -f "$baseline" ]; then
  echo "cts: FAIL: no baseline; run CLJ2_CTS_WRITE_BASELINE=1 make cts"
  exit 1
fi

# "fail error" of a namespace run alone, empty when it hung or crashed again
recheck() {
  res=$(timeout "$tmo" "$clj" -p "test/cts:$suite" -m cts-run "$1" 2>&1 </dev/null)
  printf '%s\n' "$res" | grep '^CTS-RESULT' | head -1 | awk '{print $4, $5}'
}

status=0
while read -r ns p f e; do
  case "$p" in HUNG|CRASH) f="$p"; e="$p" ;; esac
  bl=$(grep -v '^#' "$baseline" | awk -v n="$ns" '$1==n {print $2, $3; exit}')
  if [ -n "$bl" ]; then bf="${bl%% *}"; be="${bl##* }"; else bf=0; be=0; fi
  if [ "$f" != "$bf" ] || [ "$e" != "$be" ]; then
    again=$(recheck "$ns")
    if [ -n "$again" ]; then
      if [ "${again%% *}" != "$f" ] || [ "${again##* }" != "$e" ]; then
        echo "cts: $ns differed under load (fail $f error $e), rechecked alone: $again"
      fi
      f="${again%% *}"; e="${again##* }"
    fi
  fi
  if [ "$f" = "$bf" ] && [ "$e" = "$be" ]; then
    continue
  fi
  worse=0
  case "$f" in HUNG|CRASH) worse=1 ;; esac
  case "$bf" in HUNG|CRASH) ;; *) if [ "$worse" = 0 ] && { [ "$f" -gt "$bf" ] || [ "$e" -gt "$be" ]; }; then worse=1; fi ;; esac
  if [ "$worse" = 1 ]; then
    echo "cts: NEW regression in $ns: fail $f error $e (baseline $bf $be)"
  else
    echo "cts: STALE baseline for $ns: now fail $f error $e (baseline $bf $be); update $baseline"
  fi
  status=1
done < "$work/results"

# a baseline entry whose namespace no longer reports is stale too
grep -v '^#' "$baseline" | while read -r ns bf be; do
  grep -q "^$ns " "$work/results" || echo "cts: STALE baseline entry $ns (namespace gone)"
done | grep . && status=1

echo "cts: $summary"
if [ $status -eq 0 ]; then echo "cts: passed (matches baseline)"; else echo "cts: FAILED"; fi
exit $status

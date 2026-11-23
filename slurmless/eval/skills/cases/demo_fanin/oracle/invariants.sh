#!/bin/sh
# invariants.sh <runDir> — Scenario sanity for demo_fanin (guards exit-0 no-ops).
# total.txt must exist, be non-empty, and equal base*1 + base*2 = 10 + 20 = 30.
d="${1:?usage: invariants.sh <runDir>}"
fail=0
[ -s "$d/total.txt" ] || { echo "INVARIANT FAIL: total.txt missing or empty"; fail=1; }
if [ -s "$d/total.txt" ]; then
  got="$(tr -d '[:space:]' < "$d/total.txt")"
  [ "$got" = "30" ] || { echo "INVARIANT FAIL: total.txt = '$got', expected 30"; fail=1; }
fi
[ "$fail" -eq 0 ] && echo "INVARIANTS: OK"
exit "$fail"

#!/bin/sh
# invariants.sh <runDir> — Scenario-1 sanity checks for demo_linear.
# Asserts the port actually did the work (guards exit-0 no-ops): total.txt exists,
# is non-empty, and equals the known correct reduction (1+4+9+16+25 = 55).
# Exit 0 = all invariants hold; non-zero = a violation (prints which).
d="${1:?usage: invariants.sh <runDir>}"
fail=0
[ -s "$d/total.txt" ] || { echo "INVARIANT FAIL: total.txt missing or empty"; fail=1; }
if [ -s "$d/total.txt" ]; then
  got="$(tr -d '[:space:]' < "$d/total.txt")"
  [ "$got" = "55" ] || { echo "INVARIANT FAIL: total.txt = '$got', expected 55"; fail=1; }
fi
[ "$fail" -eq 0 ] && echo "INVARIANTS: OK"
exit "$fail"

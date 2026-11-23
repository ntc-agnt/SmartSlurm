#!/bin/bash
# ---------------------------------------------------------------------------
# score_hygiene.sh <runDir> <invariants.sh>
#
# Runtime-hygiene metric (M3). A port can exit 0 and still be a silent no-op, so
# "exit 0" is not enough: this runs the case's invariants (the non-empty / correct
# -output assertions) against the produced run directory and reports a verdict.
#
#   runDir         the working dir a port ran in (its output files)
#   invariants.sh  the case oracle (oracle/invariants.sh) — exits 0 iff outputs sane
#
# Phase 1+ adds the bounded-process-count ceiling here (watch peak
# `pgrep -fc run_tests.sh` during the live run; a fork-recursion still prints
# RESULT lines, so the process tree is the honest signal).
# ---------------------------------------------------------------------------
set -uo pipefail
d="${1:?usage: score_hygiene.sh <runDir> <invariants.sh>}"
inv="${2:?invariants.sh}"
[ -d "$d" ]   || { echo "HYGIENE verdict=FAIL (runDir '$d' missing)"; exit 1; }
[ -x "$inv" ] || { echo "score_hygiene: invariants '$inv' not executable" >&2; exit 2; }

# non-empty run dir (guard a port that produced literally nothing)
if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then echo "HYGIENE verdict=FAIL (empty runDir)"; exit 1; fi

if out="$("$inv" "$d" 2>&1)"; then
  echo "HYGIENE verdict=OK ($out)"; exit 0
else
  echo "HYGIENE verdict=FAIL"; echo "$out" | sed 's/^/    /'; exit 1
fi

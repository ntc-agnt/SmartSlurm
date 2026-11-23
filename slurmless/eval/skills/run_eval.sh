#!/bin/bash
# ---------------------------------------------------------------------------
# run_eval.sh --corpus <dir> [--case <id>] [--candidate <driver>] [--selftest]
#
# The eval driver. Iterates the cases in a corpus and emits a per-case metric
# VECTOR (not one scalar — lumping hides which capability regressed) plus an
# aggregate. The corpus is injected BY PATH so the held-out scored corpus can be
# private (see README); the in-tree demo corpus is `cases/`.
#
# Phase 0 (this file) wires the objective, zero-setup oracle:
#   M1 dag_recovery  — score/score_dag.sh : candidate DAG vs answer_key/intended_dag.tsv
# In --selftest mode each case is scored using its OWN answer_key/reference_driver.sh
# (the known-correct port) — it must come back MATCH, proving the oracle + wiring.
# With --candidate <driver>, score that agent-produced port instead.
#
# Phase 1+ (documented, not yet wired here):
#   M2 fidelity (compare_outputs.sh, Scenario 2) · M3 hygiene (live run + proc ceiling)
#   M4 checkpoint adherence · M5 flag precision/recall (.defect vs agent report)
#   M6 interaction rubric (blinded judge) · simulated-user driver · cross-agent axis
#   · paired bootstrap stats · ship/regression gate.
# ---------------------------------------------------------------------------
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
corpus=""; only=""; candidate=""; selftest=0
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)    corpus="$2"; shift 2 ;;
    --case)      only="$2"; shift 2 ;;
    --candidate) candidate="$2"; shift 2 ;;
    --selftest)  selftest=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "run_eval: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$corpus" ] || { echo "run_eval: --corpus <dir> required" >&2; exit 2; }
[ -d "$corpus" ] || { echo "run_eval: corpus '$corpus' not a directory" >&2; exit 2; }
[ -n "$candidate" ] && [ -z "$only" ] && { echo "run_eval: --candidate requires --case" >&2; exit 2; }
# default to selftest when no candidate is supplied (Phase 0 has no agent loop yet)
[ -z "$candidate" ] && selftest=1

pass=0; total=0
printf '%-16s  %s\n' "CASE" "METRICS"
printf '%-16s  %s\n' "----" "-------"
for cdir in "$corpus"/*/; do
  [ -f "$cdir/meta.yaml" ] || continue
  id="$(basename "$cdir")"
  [ -n "$only" ] && [ "$id" != "$only" ] && continue
  intended="$cdir/answer_key/intended_dag.tsv"
  [ -r "$intended" ] || { printf '%-16s  SKIP (no intended_dag.tsv)\n' "$id"; continue; }

  if [ "$selftest" -eq 1 ]; then drv="$cdir/answer_key/reference_driver.sh"
  else                           drv="$candidate"; fi
  [ -r "$drv" ] || { printf '%-16s  SKIP (no driver: %s)\n' "$id" "$drv"; continue; }

  total=$((total+1))
  line="$("$here/score/score_dag.sh" "$drv" "$intended")"; rc=$?
  [ "$rc" -eq 0 ] && pass=$((pass+1))
  printf '%-16s  %s\n' "$id" "$line"
done
echo "----"
mode=$([ "$selftest" -eq 1 ] && echo "selftest(reference_driver)" || echo "candidate")
echo "AGGREGATE  mode=$mode  dag_match=$pass/$total"
[ "$total" -gt 0 ] && [ "$pass" -eq "$total" ]

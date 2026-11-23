#!/bin/bash
# ---------------------------------------------------------------------------
# run_case.sh <caseDir> [--candidate <rAP-driver>]
#
# Live, end-to-end eval of ONE case in the slurmless sandbox, producing the metric
# vector. Scenario 2 (submit.sh present): establish REF by running the ORIGINAL
# workflow in wf-mode, run the PORT (the case's reference_driver.sh by default, or a
# --candidate agent port), and score:
#
#   M1 dag_recovery  score_dag.sh      (driver text vs intended_dag.tsv)
#   M2 fidelity      score_fidelity.sh (REF outputs vs PORT outputs, identity_contract)
#   M3 hygiene       score_hygiene.sh  (PORT run dir vs oracle/invariants.sh)
#
# Infidelity (a port that silently "fixes" a planted bug) shows as M2 MISMATCH,
# because PORT is compared against the ORIGINAL's REF, never a golden. Scratch only.
# ---------------------------------------------------------------------------
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cdir="${1:?usage: run_case.sh <caseDir> [--candidate <driver>]}"; shift || true
cand=""; [ "${1:-}" = "--candidate" ] && { cand="${2:?driver}"; }
cdir="$(cd "$cdir" && pwd)"
[ -f "$cdir/meta.yaml" ] || { echo "run_case: $cdir has no meta.yaml" >&2; exit 2; }

export SL="$(cd "$here/../.." && pwd)"                    # eval/skills -> repo root
: "${SMARTSLURM_ROOT:=$(cd "$SL/.." && pwd)}"             # in-tree default: ../SmartSlurm
[ -d "$SMARTSLURM_ROOT/bin" ] || { echo "run_case: SMARTSLURM_ROOT=$SMARTSLURM_ROOT has no bin/ (set it)" >&2; exit 2; }
export SMARTSLURM_ROOT
# shellcheck disable=SC1090
source "$SL/test/lib/harness.sh"
ss_activate >/dev/null 2>&1 || { echo "run_case: ss_activate failed" >&2; exit 1; }

intended="$cdir/answer_key/intended_dag.tsv"
contract="$cdir/answer_key/identity_contract"
inv="$cdir/oracle/invariants.sh"
drv="${cand:-$cdir/answer_key/reference_driver.sh}"
base="${SS_SCRATCH:-/tmp/ss-scratch}/eval_$(basename "$cdir")_$$"
refws="$base/ref"; portws="$base/port"
refout="$base/refout"; portout="$base/portout"; mkdir -p "$refout" "$portout"

# ---- REF: original workflow (Scenario 2) ----
if [ -f "$cdir/inputs/submit.sh" ]; then
  ss_new_workspace "$refws" >/dev/null
  cp "$cdir"/inputs/*.sh . 2>/dev/null; chmod +x ./*.sh 2>/dev/null || true
  ss_wf_activate; bash ./submit.sh >/dev/null 2>&1; ss_wf_drain >/dev/null 2>&1
  cp -f ./*.txt "$refout"/ 2>/dev/null || true
else
  echo "run_case: no inputs/submit.sh — Scenario 1 live run is Phase 1.5" >&2
fi

# ---- PORT: the rAP driver ----
ss_new_workspace "$portws" >/dev/null
cp "$cdir"/inputs/*.sh . 2>/dev/null; rm -f ./submit.sh; chmod +x ./*.sh 2>/dev/null || true
cp "$drv" ./pipeline.sh; chmod +x ./pipeline.sh
ss_run_pipeline "./pipeline.sh" "sbatch -p short -c 1 --mem 1G -t 5:0" >/dev/null 2>&1 || true
cp -f ./*.txt "$portout"/ 2>/dev/null || true

# ---- score the vector ----
echo "=== $(basename "$cdir")  (driver: $([ -n "$cand" ] && echo candidate || echo reference)) ==="
"$here/score/score_dag.sh" "$drv" "$intended"; m1=$?
if [ -f "$contract" ] && [ -f "$cdir/inputs/submit.sh" ]; then
  "$here/score/score_fidelity.sh" "$refout" "$portout" "$contract"; m2=$?
else m2="-"; fi
[ -x "$inv" ] && { "$here/score/score_hygiene.sh" "$portout" "$inv"; m3=$?; } || m3="-"
echo "VECTOR dag=$([ "$m1" = 0 ] && echo MATCH || echo MISS) fidelity=$([ "$m2" = 0 ] && echo MATCH || { [ "$m2" = "-" ] && echo n/a || echo MISMATCH; }) hygiene=$([ "$m3" = 0 ] && echo OK || { [ "$m3" = "-" ] && echo n/a || echo FAIL; })"
rm -rf "$base" 2>/dev/null || true

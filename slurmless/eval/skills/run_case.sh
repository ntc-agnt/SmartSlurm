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
cdir="${1:?usage: run_case.sh <caseDir> [--candidate <driver>] [--scripts <dir>]}"; shift || true
# --scripts <dir>: take the PORT's step scripts from <dir> (e.g. an agent's workspace,
# which may hold edits it made after a flagged+approved fix) instead of the case's
# pristine inputs/. The REF arm (Scenario 2) always uses the case's original inputs.
cand=""; scripts=""
while [ $# -gt 0 ]; do case "$1" in
  --candidate) cand="${2:?driver}"; shift 2 ;;
  --scripts)   scripts="${2:?dir}"; shift 2 ;;
  *) shift ;;
esac; done
cdir="$(cd "$cdir" && pwd)"
[ -f "$cdir/meta.yaml" ] || { echo "run_case: $cdir has no meta.yaml" >&2; exit 2; }

export SL="$(cd "$here/../.." && pwd)"                    # eval/skills -> repo root
: "${SMARTSLURM_ROOT:=$(cd "$SL/.." && pwd)}"             # in-tree default: ../SmartSlurm
[ -d "$SMARTSLURM_ROOT/bin" ] || { echo "run_case: SMARTSLURM_ROOT=$SMARTSLURM_ROOT has no bin/ (set it)" >&2; exit 2; }
export SMARTSLURM_ROOT
# shellcheck disable=SC1090
source "$SL/test/lib/harness.sh"
ss_activate >/dev/null 2>&1 || { echo "run_case: ss_activate failed" >&2; exit 1; }

# A case may ship its own run environment (deterministic mock tool stand-ins + tiny
# inputs) so a real-tool workflow runs off-cluster: env/bin -> on PATH, env/data ->
# staged into each workspace. Mocks validate wiring, not the science.
casebin="$cdir/env/bin"; casedata="$cdir/env/data"
[ -d "$casebin" ] && chmod +x "$casebin"/* 2>/dev/null || true
# NOTE: ss_new_workspace RESETS PATH, so env/bin is (re-)prepended after each
# workspace is created (below), not here — otherwise the mocks vanish by step time.
_stage_tools() { [ -d "$casebin" ] && export PATH="$casebin:$PATH"; return 0; }

intended="$cdir/answer_key/intended_dag.tsv"
contract="$cdir/answer_key/identity_contract"
inv="$cdir/oracle/invariants.sh"
drv="${cand:-$cdir/answer_key/reference_driver.sh}"
base="${SS_SCRATCH:-/tmp/ss-scratch}/eval_$(basename "$cdir")_$$"
refws="$base/ref"; portws="$base/port"
refout="$base/refout"; portout="$base/portout"; mkdir -p "$refout" "$portout"

# ---- REF: original workflow (Scenario 2) ----
if [ -f "$cdir/inputs/submit.sh" ]; then
  ss_new_workspace "$refws" >/dev/null; _stage_tools
  cp "$cdir"/inputs/*.sh . 2>/dev/null; [ -d "$casedata" ] && cp "$casedata"/* . 2>/dev/null; chmod +x ./*.sh 2>/dev/null || true
  ss_wf_activate; bash ./submit.sh >/dev/null 2>&1; ss_wf_drain >/dev/null 2>&1
  cp -a ./. "$refout"/ 2>/dev/null || true
else
  : "Scenario 1 (loose scripts): no original to diff — score M1 (DAG) + M3 (hygiene); M2 is n/a"
fi

# ---- PORT: the rAP driver ----
ss_new_workspace "$portws" >/dev/null; _stage_tools
cp "${scripts:-$cdir/inputs}"/*.sh . 2>/dev/null; rm -f ./submit.sh; [ -d "$casedata" ] && cp "$casedata"/* . 2>/dev/null; chmod +x ./*.sh 2>/dev/null || true
cp "$drv" ./pipeline.sh; chmod +x ./pipeline.sh
ss_run_pipeline "./pipeline.sh" "sbatch -p short -c 1 --mem 1G -t 5:0" >/dev/null 2>&1 || true
cp -a ./. "$portout"/ 2>/dev/null || true

# ---- score the vector ----
echo "=== $(basename "$cdir")  (driver: $([ -n "$cand" ] && echo candidate || echo reference)) ==="
"$here/score/score_dag.sh" "$drv" "$intended"; m1=$?
if [ -f "$contract" ] && [ -f "$cdir/inputs/submit.sh" ]; then
  "$here/score/score_fidelity.sh" "$refout" "$portout" "$contract"; m2=$?
else m2="-"; fi
[ -x "$inv" ] && { "$here/score/score_hygiene.sh" "$portout" "$inv"; m3=$?; } || m3="-"
echo "VECTOR dag=$([ "$m1" = 0 ] && echo MATCH || echo MISS) fidelity=$([ "$m2" = 0 ] && echo MATCH || { [ "$m2" = "-" ] && echo n/a || echo MISMATCH; }) hygiene=$([ "$m3" = 0 ] && echo OK || { [ "$m3" = "-" ] && echo n/a || echo FAIL; })"
rm -rf "$base" 2>/dev/null || true

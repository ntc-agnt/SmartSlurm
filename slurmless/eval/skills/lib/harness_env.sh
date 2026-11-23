#!/bin/bash
# harness_env.sh — resolve the slurmless harness root and activate it, for eval
# steps that run a port (Phase 1+: establishing REF, running a candidate port,
# the live hygiene/fidelity oracles). Mirrors eval/migration/run_original.sh.
#
#   source lib/harness_env.sh   ->  sets $SL (repo root), sources test/lib/harness.sh,
#                                    runs ss_activate. Requires SMARTSLURM_ROOT (or a
#                                    resolvable vendored/sibling checkout via bootstrap).
# Scratch only — never a real ~/.smartSlurm or cluster.
SL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # eval/skills/lib -> repo root
export SL
: "${SMARTSLURM_ROOT:?set SMARTSLURM_ROOT to a SmartSlurm checkout (or run bootstrap.sh first)}"
# shellcheck disable=SC1090
source "$SL/test/lib/harness.sh"
ss_activate >/dev/null 2>&1 || { echo "harness_env: ss_activate failed" >&2; return 1 2>/dev/null || exit 1; }

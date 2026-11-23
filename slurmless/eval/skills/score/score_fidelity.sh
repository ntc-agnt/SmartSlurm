#!/bin/bash
# ---------------------------------------------------------------------------
# score_fidelity.sh <origDir> <rapDir> <identity_contract>
#
# Port-fidelity metric (M2, Scenario 2). The strongest oracle: a faithful port
# reproduces the ORIGINAL workflow's authoritative outputs. Thin wrapper over the
# slurmless differential tool compare_outputs.sh — same contract grammar
# (FILE / NORMALIZE / SORT) — emitting one parseable metric line.
#
#   origDir   outputs of the original workflow run (REF)
#   rapDir    outputs of the rAP port run (PORT)
#   contract  answer_key/identity_contract (authoritative files + normalization)
#
# Exit 0 iff every authoritative file matches. A faithful port of a BUGGY original
# still MATCHES (bug preserved) — infidelity (silent "fix") is caught by run_case.sh
# comparing PORT against REF, not against a golden.
# ---------------------------------------------------------------------------
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"                 # eval/skills/score -> repo root
CMP="$root/skills/migration-assistant/tools/compare_outputs.sh"
od="${1:?usage: score_fidelity.sh <origDir> <rapDir> <contract>}"
rd="${2:?rapDir}"; contract="${3:?identity_contract}"
[ -x "$CMP" ] || { echo "score_fidelity: compare_outputs.sh not found at $CMP" >&2; exit 2; }

out="$("$CMP" "$od" "$rd" "$contract" 2>&1)"; rc=$?
matched="$(printf '%s\n' "$out" | grep -c '^MATCH ')"
diffd="$(printf '%s\n' "$out"   | grep -c '^DIFF  ')"
total=$((matched+diffd))
verdict=$([ "$rc" -eq 0 ] && echo MATCH || echo MISMATCH)
printf 'FIDELITY verdict=%s files=%d/%d\n' "$verdict" "$matched" "$total"
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -A3 '^DIFF ' | sed 's/^/    /'
exit "$rc"

#!/bin/bash
# ---------------------------------------------------------------------------
# score_flag.sh <transcript> <flags.yaml>
#
# Flag precision/recall metric (M5, objective-ish). The migration-assistant contract
# prizes PRECISION over recall: raise a genuine planted error (ask, don't fix), but
# do NOT flag an intentional-but-unusual method. Scored against what the agent
# actually FLAGGED — the `flag <text>` events in the run transcript — NOT its prose
# (merely *mentioning* an unusual choice as deliberate is not a flag).
#
# flags.yaml (answer_key/flags.yaml) — two lists of ERE patterns matched against the
# concatenated flag texts:
#   should_flag:            # planted defects the agent MUST raise (a hit = caught)
#     - "trim.*before|before.*trim"
#   should_not_flag:        # intentional oddities the agent MUST NOT raise (hit = false alarm)
#     - "non-?standard aligner"
# A correct case with nothing to flag has both lists empty (and ideally no flags).
#
# Scoring: TP = should_flag hit; FN = should_flag missed; FP = should_not_flag hit;
# precision = TP/(TP+FP); recall = TP/(TP+FN). Exit 0 iff every should_flag is caught
# AND no should_not_flag is raised (a single false alarm fails — precision first).
# ---------------------------------------------------------------------------
set -uo pipefail
t="${1:?usage: score_flag.sh <transcript> <flags.yaml>}"
flags="${2:?flags.yaml}"
[ -r "$t" ] || { echo "score_flag: cannot read transcript '$t'" >&2; exit 2; }
[ -r "$flags" ] || { echo "score_flag: cannot read flags '$flags'" >&2; exit 2; }

# the agent's flagged concerns only (the `flag <text>` events)
flagtext="$(grep -iE '^[[:space:]]*flag[[:space:]]' "$t" 2>/dev/null || true)"

_pats() {
  awk -v key="$1" '
    $0 ~ "^"key":[[:space:]]*$" {inb=1; next}
    /^[^[:space:]-]/ {inb=0}
    inb && /^[[:space:]]*-/ { p=$0; sub(/^[[:space:]]*-[[:space:]]*"?/,"",p); sub(/"?[[:space:]]*$/,"",p); if (p!="") print p }
  ' "$flags"
}
_hit() { printf '%s\n' "$flagtext" | grep -qiE "$1"; }

tp=0; fn=0; fp=0
while IFS= read -r pat; do [ -z "$pat" ] && continue
  if _hit "$pat"; then tp=$((tp+1)); else fn=$((fn+1)); fi
done < <(_pats should_flag)
while IFS= read -r pat; do [ -z "$pat" ] && continue
  if _hit "$pat"; then fp=$((fp+1)); fi
done < <(_pats should_not_flag)

prec=$(awk -v tp="$tp" -v fp="$fp" 'BEGIN{d=tp+fp; printf (d>0)?"%.2f":"n/a", (d>0)?tp/d:0}')
rec=$(awk -v tp="$tp" -v fn="$fn" 'BEGIN{d=tp+fn; printf (d>0)?"%.2f":"n/a", (d>0)?tp/d:0}')
verdict=$([ "$fn" -eq 0 ] && [ "$fp" -eq 0 ] && echo PASS || echo FAIL)
printf 'FLAG tp=%d fn=%d fp=%d precision=%s recall=%s verdict=%s\n' "$tp" "$fn" "$fp" "$prec" "$rec" "$verdict"
[ "$fn" -eq 0 ] && [ "$fp" -eq 0 ]

#!/bin/bash
# ---------------------------------------------------------------------------
# sim_user.sh <decisions.yaml> (--checkpoint <id> | --question "<text>")
#
# The SIMULATED USER: the deterministic responder that plays the human in the
# agent-in-the-loop eval, so a chat-supervised skill can be scored at scale without
# a person in every run. It answers ONLY from the case's answer_key/decisions.yaml
# and never volunteers unlisted information — the agent must do the real recovery
# and conversion work.
#
#   --checkpoint <id>   -> the scripted ruling for that checkpoint
#                          (e.g. "approve" or "revise: <text>")
#   --question "<text>" -> the scripted reply for a question, matched by the first
#                          `answers:` block whose `match:` ERE hits <text>;
#                          falls through to a neutral "use your judgment, note it".
#
# decisions.yaml (minimal, line-oriented so it needs no YAML library):
#   checkpoints:
#     plan: approve
#     contract: approve
#     final: approve
#   answers:
#     - match: "trim|adapter|order"
#       reply: "Intentional — leave it as-is."
#   persona: "terse bioinformatician; defends intentional choices"
#
# A human-anchor run (a real person answering) uses the SAME decisions.yaml as its
# brief, so simulated and human loops are comparable (see RUBRIC.md calibration).
# ---------------------------------------------------------------------------
set -uo pipefail
dfile="${1:?usage: sim_user.sh <decisions.yaml> (--checkpoint <id> | --question <text>)}"
[ -r "$dfile" ] || { echo "sim_user: cannot read '$dfile'" >&2; exit 2; }
shift
mode="${1:?--checkpoint <id> | --question <text>}"; arg="${2:-}"

case "$mode" in
  --checkpoint)
    [ -n "$arg" ] || { echo "sim_user: --checkpoint needs an id" >&2; exit 2; }
    # extract `  <id>: <value>` under the `checkpoints:` block
    val="$(awk -v id="$arg" '
      /^checkpoints:[[:space:]]*$/ {inb=1; next}
      /^[^[:space:]]/ {inb=0}
      inb && $0 ~ "^[[:space:]]+"id":" { sub("^[[:space:]]+"id":[[:space:]]*",""); print; exit }
    ' "$dfile")"
    if [ -n "$val" ]; then printf '%s\n' "$val"
    else echo "approve"; fi   # default: approve a checkpoint the script doesn't override
    ;;
  --question)
    [ -n "$arg" ] || { echo "sim_user: --question needs text" >&2; exit 2; }
    # walk answers blocks; emit the reply of the first match: whose ERE hits the question
    reply="$(awk -v q="$arg" '
      /^answers:[[:space:]]*$/ {ina=1; next}
      /^[^[:space:]]/ && !/^answers:/ {ina=0}
      ina && /match:/ { m=$0; sub(/.*match:[[:space:]]*"?/,"",m); sub(/"?[[:space:]]*$/,"",m); cur_m=m; have=1; next }
      ina && /reply:/ && have { r=$0; sub(/.*reply:[[:space:]]*"?/,"",r); sub(/"?[[:space:]]*$/,"",r);
        if (q ~ cur_m) { print r; exit } have=0 }
    ' "$dfile")"
    if [ -n "$reply" ]; then printf '%s\n' "$reply"
    else echo "I don't have a strong preference — use your best judgment and note it in MIGRATION_NOTES.md."; fi
    ;;
  *) echo "sim_user: unknown mode '$mode'" >&2; exit 2 ;;
esac

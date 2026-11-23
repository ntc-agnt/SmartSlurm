#!/bin/bash
# ---------------------------------------------------------------------------
# run_agent.sh <subcommand> ...   — the agent-in-the-loop driver (Phase 4).
#
# Runs an AGENT (the subject under test) through a case with the migration-assistant
# skill, with a deterministic SIMULATED USER answering its checkpoints/questions, then
# scores the full metric vector. The agent works in an isolated sandbox that holds the
# case inputs but NOT its answer_key.
#
#   prepare <caseDir> <sandbox>
#       Lay out the sandbox: inputs/ + TASK.md + AGENT_BRIEF.md, and the ./ask_user
#       and ./ev wrappers (bound to the hidden decisions.yaml + a transcript). An
#       agent then works in <sandbox>: reads AGENT_BRIEF.md, calls ./ask_user at each
#       checkpoint and ./ev to log flags/milestones, and writes its rAP port as
#       pipeline.sh.
#
#   score <caseDir> <sandbox> [adapterName]
#       Score a worked sandbox: M1/M2/M3 via run_case --candidate pipeline.sh, M4 from
#       the transcript, M5 from the transcript vs answer_key/flags.yaml. Prints the
#       vector and appends a RESULT record to <sandbox>/result.tsv.
#
#   run <caseDir> --adapter <cmd> [--sandbox <dir>]
#       prepare + run the adapter command (CWD=sandbox; args: <answer_key> <scenario>)
#       + score, in one shot. Use the bundled agents/reference.sh (known-good double)
#       or agents/bad.sh, or plug an external agent CLI.
#
# Scratch only. The simulated user (lib/sim_user.sh) never volunteers the key; the
# agent is trusted not to read answer_key (a capability eval, not an anti-cheat test).
# ---------------------------------------------------------------------------
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SL="$(cd "$here/.." && pwd)"                       # eval/skills -> repo root
SIMUSER="$here/lib/sim_user.sh"

_scenario() { grep -E '^scenario:' "$1/meta.yaml" 2>/dev/null | head -1 | sed 's/[^0-9]*\([0-9]\).*/\1/'; }

_prepare() {
  local cdir="$1" sb="$2"
  cdir="$(cd "$cdir" && pwd)"; mkdir -p "$sb"; sb="$(cd "$sb" && pwd)"
  local dec="$cdir/answer_key/decisions.yaml" tx="$sb/.transcript"
  mkdir -p "$sb/work"
  cp "$cdir"/inputs/* "$sb/work/" 2>/dev/null || true
  cp "$cdir/TASK.md" "$sb/work/TASK.md" 2>/dev/null || true
  : > "$tx"
  # ./ask_user — consult the simulated user; logs the checkpoint/question event.
  cat > "$sb/work/ask_user" <<ASK
#!/bin/sh
# Consult the (simulated) user. Usage: ask_user --checkpoint <plan|contract|final>
#                                     ask_user --question "<text>"
case "\$1" in
  --checkpoint) printf 'checkpoint %s\n' "\$2" >> "$tx"; "$SIMUSER" "$dec" --checkpoint "\$2" ;;
  --question)   printf 'question %s\n'   "\$2" >> "$tx"; "$SIMUSER" "$dec" --question  "\$2" ;;
  *) echo "usage: ask_user --checkpoint <id> | --question <text>" >&2; exit 2 ;;
esac
ASK
  # ./ev — log a transcript event verbatim. Usage: ev flag "<text>" | ev action emit|handback
  cat > "$sb/work/ev" <<EV
#!/bin/sh
printf '%s\n' "\$*" >> "$tx"
EV
  chmod +x "$sb/work/ask_user" "$sb/work/ev"
  cat > "$sb/work/AGENT_BRIEF.md" <<BRIEF
# Migration task (agent brief)

Work in THIS directory. Read TASK.md for the goal. Convert the loose scripts / SLURM
workflow into a SmartSlurm runAsPipeline driver named **pipeline.sh**, following the
migration-assistant skill.

The user is reachable ONLY through two commands here — use them, do not ask in prose:
- Consult / get sign-off:  \`./ask_user --checkpoint plan\`  (also: contract [Scenario 2], final)
                           \`./ask_user --question "..."\`  and use the printed reply.
- Record a concern:        \`./ev flag "your specific concern"\`  (only genuine, high-confidence flags)
- Mark milestones:         \`./ev action emit\`      right after you write pipeline.sh
                           \`./ev action handback\`  when you are done

Get plan sign-off (and the identity contract on Scenario 2) BEFORE writing pipeline.sh,
and do a final check-in before handback. Keep payloads faithful; flag only genuine,
high-confidence errors and ask rather than fix.
BRIEF
  echo "$sb"
}

_score() {
  local cdir="$1" sb="$2" adapter="${3:-unknown}"
  cdir="$(cd "$cdir" && pwd)"; sb="$(cd "$sb" && pwd)"
  local id; id="$(basename "$cdir")"; local scn; scn="$(_scenario "$cdir")"; scn="${scn:-1}"
  local pipeline="$sb/work/pipeline.sh" tx="$sb/.transcript"
  [ -r "$pipeline" ] || { echo "run_agent: agent produced no pipeline.sh in $sb/work" >&2; }

  # M1/M2/M3 via run_case on the agent's port
  local vec="dag=NA fidelity=NA hygiene=NA"
  if [ -r "$pipeline" ]; then
    vec="$("$here/run_case.sh" "$cdir" --candidate "$pipeline" --scripts "$sb/work" 2>/dev/null | grep '^VECTOR' | sed 's/^VECTOR //')"
    [ -n "$vec" ] || vec="dag=NA fidelity=NA hygiene=NA"
  fi
  # M4 checkpoint
  local m4="NA"
  if [ -r "$tx" ]; then m4="$("$here/score/score_checkpoint.sh" "$tx" "$scn" 2>/dev/null | sed -n 's/.*verdict=\([A-Z]*\).*/\1/p')"; fi
  # M5 flag (only if the case has a flags oracle)
  local m5="n/a"
  if [ -r "$cdir/answer_key/flags.yaml" ] && [ -r "$tx" ]; then
    m5="$("$here/score/score_flag.sh" "$tx" "$cdir/answer_key/flags.yaml" 2>/dev/null | sed -n 's/.*verdict=\([A-Z]*\).*/\1/p')"
  fi
  echo "=== $id  (agent: $adapter, scenario $scn) ==="
  echo "VECTOR $vec checkpoint=$m4 flag=$m5"
  printf '%s\t%s\t%s\tcheckpoint=%s\tflag=%s\n' "$id" "$adapter" "$vec" "$m4" "$m5" >> "$sb/result.tsv"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  prepare) _prepare "${1:?caseDir}" "${2:?sandbox}" ;;
  score)   _score "${1:?caseDir}" "${2:?sandbox}" "${3:-unknown}" ;;
  run)
    cdir="${1:?caseDir}"; shift
    adapter=""; sb=""
    while [ $# -gt 0 ]; do case "$1" in --adapter) adapter="$2"; shift 2;; --sandbox) sb="$2"; shift 2;; *) shift;; esac; done
    [ -n "$adapter" ] || { echo "run_agent run: --adapter <cmd> required" >&2; exit 2; }
    [ -n "$sb" ] || sb="${SS_SCRATCH:-/tmp/ss-scratch}/agentrun_$(basename "$cdir")_$$"
    _prepare "$cdir" "$sb" >/dev/null
    ak="$(cd "$cdir/answer_key" && pwd)"; scn="$(_scenario "$cdir")"; scn="${scn:-1}"
    ( cd "$sb/work" && ANSWER_KEY="$ak" SCENARIO="$scn" "$adapter" "$ak" "$scn" ) || echo "run_agent: adapter exited nonzero" >&2
    _score "$cdir" "$sb" "$(basename "$adapter")"
    ;;
  *) sed -n '2,40p' "$0"; exit 0 ;;
esac

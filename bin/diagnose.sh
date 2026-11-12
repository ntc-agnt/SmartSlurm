#!/bin/bash
# ===========================================================================
# diagnose.sh  --  Module M2: explain why a job failed, and whether resubmitting
#                  will help.  Read-mostly: on the cold UNCONFIRMED path (a job that
#                  vanished with no local record) it reconciles the fate from a
#                  single live `sacct` via jobFate.sh -- writing the .failed marker
#                  and appending the sacct report -- so the grid and a re-diagnose
#                  agree. Never queries the scheduler on the common (flagged) paths.
#
#   diagnose.sh <flag> [--log DIR] [--json]
#
# Design (see project plan):
#   * AUTHORITATIVE about whether it failed  -> .success flag + sacct state.
#   * HEURISTIC about why                    -> ordered pattern table scanned over
#     the M1 "step output" region (tool stdout+stderr only).
#   * NEVER asserts a cause without showing the exact evidence line.
#   * Splits today's "Unknown" into two honest cases:
#       infrastructure-uncertain (rAP/Slurm: no state from the scheduler) vs
#       tool-failed-unclassified (the tool ran and failed, cause not recognized).
#   * Answers retryable-vs-doomed as an ADVISORY action.
#
# Output: a compact card, or --json (the machine-readable record; the harness
# asserts against this and M3/checkRun renders from it).
# ===========================================================================
set -uo pipefail

LOGDIR="${smartSlurmLogDir:-smartSlurmLog}"; JSON=""; FLAG=""; RECONCILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOGDIR="$2"; shift 2;;
    --json) JSON=1; shift;;
    # --reconcile : opt in to the cold-path sacct fallback for an otherwise
    #   UNCONFIRMED job (writes a marker + appends the report). ONLY the single-job
    #   interactive drill-ins pass it; bulk callers (list_view loops over every job)
    #   leave it off so diagnose stays read-only and issues no scheduler calls.
    --reconcile) RECONCILE=1; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) FLAG="$1"; shift;;
  esac
done
[ -n "$FLAG" ] || { echo "usage: diagnose.sh <flag> [--log DIR] [--json] [--reconcile]" >&2; exit 2; }

OUT="$LOGDIR/$FLAG.out"

# Shared live-state classifier (the same squeue snapshot the grid reads), so a
# diagnose card can never contradict the grid cell. Read-only; no scheduler call.
. "$(dirname "$0")/liveState.sh" 2>/dev/null || true

# ---------- ordered pattern table: strongest / most tool-independent first ----
# fields are TAB-separated: category <TAB> action <TAB> extended-regex
# (regexes may contain ':', so ':' is NOT the delimiter)
read -r -d '' PATTERNS <<'TABLE'
resource:oom	RETRYABLE	Out Of Memory|Cannot allocate memory|std::bad_alloc|OutOfMemoryError|MemoryError|oom-kill|oom_kill
environment:disk-full	RETRYABLE	No space left on device|Disk quota exceeded
tool:crash	DOOMED	Segmentation fault|SIGSEGV|core dumped|Bus error|double free|corrupted
environment:missing-command	DOOMED	command not found|: not found
environment:permission	DOOMED	Permission denied|Operation not permitted
io:missing-file	CHECK_INPUT	No such file or directory
runtime:python	DOOMED	Traceback \(most recent call last\)
runtime:java	DOOMED	Exception in thread|java\.lang\.[A-Za-z]+Exception
runtime:r	DOOMED	^Error in |Execution halted
runtime:htslib	DOOMED	\[E::|\[main_samview\]|bcftools:|samtools:
signal:killed	CHECK	^Killed| Killed|slurmstepd: error
generic:error	INSPECT	error|fatal|abort|failed|cannot|unable to
TABLE

# ---------- locate the M1 tool region (last attempt) --------------------------
# Between the last "step output" sentinel and the "job report" sentinel that
# follows it. Falls back to the whole file for pre-M1 (legacy) logs.
REGION_SRC="tool-region"; rstart=0; rend=0
if [ -f "$OUT" ]; then
  rstart=$(grep -nE 'SmartSlurm step output:' "$OUT" | tail -1 | cut -d: -f1)
  if [ -n "$rstart" ]; then
    rend=$(awk -v s="$rstart" 'NR>s && /SmartSlurm job report:/{print NR; exit}' "$OUT")
    [ -z "$rend" ] && rend=$(( $(wc -l < "$OUT") + 1 ))
  else
    REGION_SRC="whole-log(legacy)"; rstart=0
    rend=$(( $(wc -l < "$OUT") + 1 ))
  fi
fi
# extract the region to a temp file; remember offset to map back to .out line #s
REGION="$(mktemp)"; trap 'rm -f "$REGION"' EXIT
if [ -f "$OUT" ]; then
  if [ "$rstart" -gt 0 ]; then sed -n "$((rstart+1)),$((rend-1))p" "$OUT" > "$REGION"
  else cp "$OUT" "$REGION"; fi
fi
region_offset=$rstart    # .out line = region_offset + (region line number)

# ---------- authoritative state ----------------------------------------------
# job-report region (from the report sentinel to EOF) carries the sacct table.
report_state() {
  local rep
  if [ "$rend" -gt 0 ] && [ -f "$OUT" ]; then rep="$(sed -n "${rend},\$p" "$OUT")"; else rep=""; fi
  # look for raw sacct State tokens (delimiter-agnostic), strongest first. Covers all
  # of Slurm's terminal states (incl. DEADLINE/PREEMPTED/REVOKED/SPECIAL_EXIT), in
  # step with jobFate.sh map_state(), so an in-log report never leaves a terminal job
  # unclassified.
  if   grep -q 'OUT_OF_ME' <<<"$rep"; then echo OOM
  elif grep -qE 'TIMEOUT|DEADLINE'   <<<"$rep"; then echo OOT
  elif grep -qE 'NODE_FAIL|BOOT_FAIL|PREEMPTED|REVOKED' <<<"$rep"; then echo NODE_FAIL
  elif grep -q 'CANCEL'    <<<"$rep"; then echo CANCELLED
  elif grep -q 'SPECIAL_EXIT' <<<"$rep"; then echo FAILED
  elif grep -q 'FAILED'    <<<"$rep"; then echo FAILED
  elif grep -q 'COMPLETED' <<<"$rep"; then echo COMPLETED
  else echo ""; fi
}

requeued=""; STATE=""; live_jobid=""
if [ -e "$LOGDIR/$FLAG.success" ]; then
  STATE=COMPLETED
elif compgen -G "$LOGDIR/$FLAG.failed.requeued.*.mem"    >/dev/null 2>&1; then STATE=OOM;    requeued=1
elif compgen -G "$LOGDIR/$FLAG.failed.requeued.*.time"   >/dev/null 2>&1; then STATE=OOT;    requeued=1
elif compgen -G "$LOGDIR/$FLAG.failed.requeued.*.oomoot" >/dev/null 2>&1; then STATE=OOMOOT; requeued=1
else
  s="$(report_state)"
  if [ -n "$s" ]; then
    # sacct says COMPLETED but there is no .success flag -> the tool ran but its
    # success was never recorded: this is the classic "Unknown" tool-failure.
    [ "$s" = COMPLETED ] && STATE=COMPLETED_NOSUCCESS || STATE="$s"
  elif [ -e "$LOGDIR/$FLAG.failed" ]; then
    # cleanUp wrote an authoritative .failed flag. Trust it even when the sacct
    # region is unreadable (e.g. pre-M1 logs with no sentinels): the job failed,
    # so fall through to the FAILED branch which scans the log for the cause.
    STATE=FAILED
  elif [ -n "$RECONCILE" ]; then
    # Opt-in AUTHORITATIVE path (the single-job interactive drill-ins): ask Slurm
    # accounting FIRST, so a job that died INSIDE the squeue cache's TTL window (the
    # grid refreshed the cache listing it "-R" just before a hard kill) is corrected
    # to its real terminal fate instead of echoing a now-stale "running". jobFate
    # bypasses cleanUp's missing EXIT-trap record and reads the verdict from sacct;
    # it writes the .failed marker (not for CANCELLED -- see jobFate) and appends the
    # report so the grid and a later diagnose agree. Only when sacct has NO terminal
    # verdict (UNRESOLVED -- the job is genuinely still live, or vanished with
    # post-job lag) do we consult the live cache to tell running/pending from gone.
    fate="$("$(dirname "$0")/jobFate.sh" "$FLAG" --log "$LOGDIR" 2>/dev/null)"
    case "$fate" in
      OOM|OOT|OOMOOT|NODE_FAIL|CANCELLED|FAILED) STATE="$fate" ;;
      COMPLETED)   STATE=COMPLETED_NOSUCCESS ;;   # finished per Slurm, no .success
      *)                                          # UNRESOLVED: is it live per squeue?
        ls_load_ro "$LOGDIR"; live_jobid="$(ls_jobid "$FLAG" "$LOGDIR")"
        case "$(ls_squeue_match "$live_jobid" "${LS_ACTIVE:-}" "${LS_SQ_OK:-0}")" in
          running) STATE=RUNNING ;;
          pending) STATE=PENDING ;;
          *)       STATE=UNCONFIRMED ;;            # no jobid/sacct, or lag
        esac ;;
    esac
  else
    # Read-only path (NO scheduler call): consult the shared squeue snapshot the grid
    # uses. A POSITIVE squeue match -> a calm running/pending card (never weak
    # .out-mtime evidence); otherwise the read-only UNCONFIRMED default. A caller that
    # needs ground truth for an un-flagged job passes --reconcile (above).
    ls_load_ro "$LOGDIR"; live_jobid="$(ls_jobid "$FLAG" "$LOGDIR")"
    case "$(ls_squeue_match "$live_jobid" "${LS_ACTIVE:-}" "${LS_SQ_OK:-0}")" in
      running) STATE=RUNNING ;;
      pending) STATE=PENDING ;;
      *)       STATE=UNCONFIRMED ;;
    esac
  fi
fi

# ---------- scan the tool region for a cause ---------------------------------
scan_tool_region() {   # echoes: category <TAB> action <TAB> out_lineno <TAB> text
  [ -s "$REGION" ] || return 1
  while IFS=$'\t' read -r cat act rgx; do
    [ -z "${cat:-}" ] && continue
    local hit lineno text
    hit="$(grep -inE "$rgx" "$REGION" | tail -1)" || true
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; text="${hit#*:}"
    if [ "$cat" = "runtime:python" ]; then       # exception line is more useful
      local last; last="$(grep -nvE '^[[:space:]]*$' "$REGION" | tail -1)"
      lineno="${last%%:*}"; text="${last#*:}"
    fi
    printf '%s\t%s\t%s\t%s\n' "$cat" "$act" "$((region_offset + lineno))" "$text"
    return 0
  done <<< "$PATTERNS"
  return 1
}

region_tail() { grep -nvE '^[[:space:]]*$' "$REGION" 2>/dev/null | tail -3; }

# ---------- is this job orphaned? (an upstream dependency did not/ will not succeed)
# Mirror checkRunGrid's orphan rule: an upstream is a cause only when its status is
# error/unknown -- i.e. it has a terminal FAILURE marker (.failed / requeue-exhausted),
# OR the shared live-state classifier reports it VANISHED (hard-killed / cancelled,
# left no marker). A still-live upstream (running/pending) is NOT a cause, so a healthy
# in-progress pipeline never false-alarms "orphaned"; and a markerless hard-killed
# upstream is still caught (matching the grid) rather than read as a calm "pending".
upstream_bad=""
if [ -f "$LOGDIR/allJobs.txt" ]; then
  ls_load_ro "$LOGDIR"
  dep="$(awk -v f="$FLAG" 'NR>1 && $3==f {print $2}' "$LOGDIR/allJobs.txt")"
  for d in ${dep//:/ }; do
    [[ "$d" =~ ^[0-9]+$ ]] || continue
    upflag="$(awk -v id="$d" 'NR>1 && $1==id {print $3}' "$LOGDIR/allJobs.txt")"
    { [ -n "$upflag" ] && [ ! -e "$LOGDIR/$upflag.success" ]; } || continue
    if [ -e "$LOGDIR/$upflag.failed" ] || compgen -G "$LOGDIR/$upflag.failed.requeued.*" >/dev/null 2>&1; then
      upstream_bad="$upflag"                    # error (failure marker)
    elif [ "$(ls_state "$upflag" "$LOGDIR" "${LS_ACTIVE:-}" "${LS_SQ_OK:-0}" "$(ls_jobid "$upflag" "$LOGDIR")")" = vanished ]; then
      upstream_bad="$upflag"                    # unknown (started, gone from a trustworthy squeue)
    fi
  done
fi

# ---------- map state -> category / action / evidence ------------------------
category=""; action=""; evline=""; evtext=""; summary=""; failed="true"

case "$STATE" in
  COMPLETED)
    failed="false"; category="none"; action="NONE"
    summary="completed successfully" ;;

  RUNNING)
    failed="false"; category="live:running"; action="WAIT"
    summary="still running${live_jobid:+ (job $live_jobid)} — nothing has failed; diagnose reports on finished jobs, so check back when it completes (watch it in the grid, or tail the live log below)" ;;

  PENDING)
    if [ -n "$upstream_bad" ]; then
      category="orphaned:upstream-failed"; action="CHECK_UPSTREAM"; STATE="ORPHANED"
      summary="queued but will not run: upstream step '$upstream_bad' did not succeed — fix that first, then rerun"
    else
      failed="false"; category="live:pending"; action="WAIT"
      summary="queued, not started yet${live_jobid:+ (job $live_jobid)} — nothing to diagnose until it runs"
    fi ;;

  OOM|OOT|OOMOOT)
    category="resource:${STATE,,}"
    case "$STATE" in OOM) res="memory";; OOT) res="the time limit";; OOMOOT) res="memory and time";; esac
    if [ -n "$requeued" ]; then
      action="RETRYABLE_EXHAUSTED"
      summary="ran out of $res; rAP already auto-bumped and it still failed — raise the ceiling or split the work"
    else
      action="RETRYABLE"
      summary="ran out of $res; resubmit and rAP will auto-increment resources"
    fi
    # corroborating line from the tool region, if any
    hit="$(scan_tool_region || true)"; [ -n "$hit" ] && { evline="$(cut -f3 <<<"$hit")"; evtext="$(cut -f4 <<<"$hit")"; } ;;

  NODE_FAIL)
    category="infrastructure:node-fail"; action="RETRYABLE"
    summary="the compute node failed; not your job — resubmit" ;;

  CANCELLED)
    if [ -n "$upstream_bad" ]; then
      category="orphaned:upstream-failed"; action="CHECK_UPSTREAM"
      summary="cancelled because upstream step '$upstream_bad' did not succeed — fix that first, this step never ran"
    else
      category="cancelled"; action="CHECK"
      summary="job was cancelled (no failed upstream found) — likely a manual scancel or a wall-clock/preemption event"
    fi ;;

  FAILED|COMPLETED_NOSUCCESS)
    # the tool ran and failed (or its success was never recorded). Scan for cause.
    hit="$(scan_tool_region || true)"
    if [ -n "$hit" ]; then
      category="$(cut -f1 <<<"$hit")"; action="$(cut -f2 <<<"$hit")"
      evline="$(cut -f3 <<<"$hit")"; evtext="$(cut -f4 <<<"$hit")"
      case "$category" in
        generic:error) summary="tool failed; matched a generic error line (low confidence) — verify against the evidence" ;;
        io:missing-file) summary="tool could not find a file — check the input exists (it may be a missing upstream output)" ;;
        *) summary="tool failed: ${category#*:} — resubmitting won't help until this is fixed" ;;
      esac
    else
      category="tool-failed:unclassified"; action="INSPECT"
      summary="the step's tool exited without success and left no recognized error signature; last tool output shown below"
      evtext="$(region_tail | sed 's/^[0-9]*://' | paste -sd' | ' -)"
      evline="$(region_tail | tail -1 | cut -d: -f1)"; [ -n "$evline" ] && evline=$((region_offset + evline))
    fi ;;

  UNCONFIRMED|*)
    if [ -n "$upstream_bad" ]; then
      category="orphaned:upstream-failed"; action="CHECK_UPSTREAM"; STATE="ORPHANED"
      summary="never ran: upstream step '$upstream_bad' did not succeed, so this step was cancelled by the scheduler — fix the upstream failure, then rerun"
    else
      category="infrastructure:uncertain"; action="CHECK_CLUSTER"; STATE="UNCONFIRMED"
      summary="could not confirm the job's fate from Slurm (no success flag and no recognized sacct state); the tool may never have started — check the cluster / requeue"
    fi ;;
esac

retryable="false"; case "$action" in RETRYABLE|RETRYABLE_EXHAUSTED) retryable="true";; esac

# ---------- emit --------------------------------------------------------------
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; printf '%s' "$s"; }

if [ -n "$JSON" ]; then
  printf '{'
  printf '"flag":"%s",'      "$(json_escape "$FLAG")"
  printf '"failed":%s,'      "$failed"
  printf '"state":"%s",'     "$(json_escape "$STATE")"
  printf '"category":"%s",'  "$(json_escape "$category")"
  printf '"action":"%s",'    "$(json_escape "$action")"
  printf '"retryable":%s,'   "$retryable"
  printf '"requeued":%s,'    "$([ -n "$requeued" ] && echo true || echo false)"
  printf '"evidence":"%s",'  "$(json_escape "$evtext")"
  printf '"evidence_line":%s,' "${evline:-null}"
  printf '"region":"%s",'    "$(json_escape "$REGION_SRC")"
  printf '"log":"%s",'       "$(json_escape "$OUT")"
  printf '"summary":"%s"'    "$(json_escape "$summary")"
  printf '}\n'
  exit 0
fi

# human card
c_bold=$'\033[1m'; c_off=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
[ -t 1 ] || { c_bold=; c_off=; c_red=; c_grn=; c_yel=; }
case "$action" in
  NONE) tag="${c_grn}OK${c_off}";;
  RETRYABLE|RETRYABLE_EXHAUSTED) tag="${c_yel}RETRYABLE${c_off}";;
  DOOMED) tag="${c_red}DOOMED${c_off}";;
  *) tag="${c_yel}${action}${c_off}";;
esac

printf '%s%s%s  [%s]  state=%s  action=%s\n' "$c_bold" "$FLAG" "$c_off" "$tag" "$STATE" "$action"
printf '  %s\n' "$summary"
if [ -n "$evtext" ]; then
  if [ -n "${evline:-}" ] && [ "$evline" != null ]; then
    printf '  evidence (%s:%s): %s\n' "$OUT" "$evline" "$evtext"
  else
    printf '  evidence: %s\n' "$evtext"
  fi
fi
[ "$failed" = true ] && printf '  full log: %s\n' "$OUT"

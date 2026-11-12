#!/bin/bash
# liveState.sh -- the SINGLE source of truth for a job's *live* state (running /
# pending / vanished), shared by checkRunGrid (the grid glyph) and diagnose.sh (the
# drill-in card) so the two can never disagree about a job that has no local
# terminal marker. Previously each re-derived this independently and drifted: the
# grid consulted the squeue cache and showed "running", while diagnose consulted
# neither and showed the alarming "UNCONFIRMED -- may never have started".
#
# Pure + READ-ONLY + NO scheduler calls: it reads only the shared squeue cache
# (written by checkRun/checkRunGrid) and the job's .out mtime. Callers that must
# refresh the cache (the grid) do their own squeue call and pass the snapshot in;
# callers that must not add latency (diagnose) use ls_load_ro to read the cache.
#
# Tokens returned by ls_state:
#   running  -- squeue says R  (or .out is freshly growing and squeue can't refute)
#   pending  -- squeue says PD (or nothing has started and squeue can't refute)
#   vanished -- it started (.out has body), squeue is trustworthy, this job's id is
#               known AND absent, and the .out has gone stale -> hard-killed / gone
#   NOTE: callers decide how much to TRUST each token. The grid treats "running"
#   from the .out fallback as running (a low-stakes glyph); diagnose only reassures
#   on a POSITIVE squeue match (it must never tell a user "still running, nothing
#   wrong" on weak evidence), and otherwise falls through to its UNCONFIRMED path.
# ---------------------------------------------------------------------------

# ls_load_ro LOGDIR  -> sets LS_ACTIVE (cached "<id>-R"/"<id>-PD" tokens) and
# LS_SQ_OK (1 = a trustworthy, fresh snapshot is held; 0 = none). READ-ONLY: it
# never calls squeue and never writes the cache, so it adds no scheduler latency.
ls_load_ro() {
  local logdir="${1:-${smartSlurmLogDir:-smartSlurmLog}}" c now ttl="${LS_SQ_TTL:-120}"
  LS_ACTIVE=""; LS_SQ_OK=0
  now=$(date +%s)
  # Canonical location is <logdir>/squeue_cache.txt (workflowPlot.py); checkRun and
  # checkRunGrid write it cwd-relative, so also accept ./squeue_cache.txt.
  for c in "$logdir/squeue_cache.txt" "squeue_cache.txt"; do
    if [ -f "$c" ] && [ "$(( now - $(stat -c %Y "$c" 2>/dev/null || echo 0) ))" -lt "$ttl" ]; then
      LS_ACTIVE="$(cat "$c" 2>/dev/null)"; LS_SQ_OK=1; return 0
    fi
  done
  return 0
}

# ls_jobid FLAG LOGDIR -> echoes the last numeric jobid mapped to FLAG in
# allJobs.txt (last wins on requeue), or nothing. A non-numeric/garbage id is
# treated as absent (never handed to a matcher).
ls_jobid() {
  local f="$1" logdir="${2:-${smartSlurmLogDir:-smartSlurmLog}}" id
  [ -f "$logdir/allJobs.txt" ] || return 0
  id="$(awk -v fl="$f" 'NR>1 && $3==fl{v=$1} END{printf "%s", v}' "$logdir/allJobs.txt" 2>/dev/null)"
  [[ "$id" =~ ^[0-9]+$ ]] && printf '%s' "$id"
  return 0
}

# ls_squeue_match ID ACTIVE SQ_OK -> running|pending|"" (POSITIVE squeue evidence)
# The authoritative live signal: a trustworthy squeue snapshot lists this id as R or
# PD. The match keys on the id FOLLOWED BY '-', so a shorter id can't prefix-match a
# longer one. This is the ONLY signal diagnose trusts to reassure a user; the grid
# wraps it with an .out fallback below. Single matcher -> grid and diagnose agree.
ls_squeue_match() {
  local id="$1" active="$2" sq_ok="$3"
  # Require a trustworthy snapshot and a NUMERIC id (as jobFate does): a garbage
  # allJobs id is never handed to the matcher.
  { [ "$sq_ok" = 1 ] && [[ "$id" =~ ^[0-9]+$ ]]; } || return 0
  # Tokens are "%.18i-%t" (one per line, left-space-padded). Match the id as a WHOLE
  # field -- start-or-space, the exact id, then "-R"/"-PD", then space-or-end -- so a
  # shorter id can't substring-match a longer one (id 7 must not match "77-R").
  grep -qE "(^|[[:space:]])${id}-R([[:space:]]|\$)"  <<<"$active" && { echo running; return 0; }
  grep -qE "(^|[[:space:]])${id}-PD([[:space:]]|\$)" <<<"$active" && { echo pending; return 0; }
  return 0
}

# ls_state FLAG LOGDIR ACTIVE SQ_OK ID -> echoes running|pending|vanished
# Pure: all inputs explicit. Mirrors checkRunGrid's historical job_status live
# branch exactly (squeue match, else an .out-body + mtime fallback).
ls_state() {
  local f="$1" logdir="$2" active="$3" sq_ok="$4" id="$5" m age
  m="$(ls_squeue_match "$id" "$active" "$sq_ok")"
  [ -n "$m" ] && { echo "$m"; return 0; }
  # A job that actually started writes body output (a non-#, non-blank line) to
  # .out; ssbatch pre-writes a '#'-comment preamble even for jobs that never ran,
  # so ".out exists" is NOT "it ran".
  if [ -e "$logdir/$f.out" ] && grep -qE '^[^#[:space:]]' "$logdir/$f.out" 2>/dev/null; then
    # Started but absent from a trustworthy squeue snapshot (and its id is known):
    # a genuinely running job would be in squeue. Guard with an mtime window so a
    # just-started job still lagging the squeue cache keeps reading as running.
    if [ "$sq_ok" = 1 ] && [ -n "$id" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$logdir/$f.out" 2>/dev/null || echo 0) ))
      [ "$age" -ge "${RECONCILE_LIVE_SECS:-90}" ] && { echo vanished; return 0; }
    fi
    echo running; return 0
  fi
  echo pending
}

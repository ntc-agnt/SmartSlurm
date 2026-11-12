#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# diagnose_livestate_guard.sh -- regression guard for the live-state fix in
# diagnose.sh + the shared bin/liveState.sh classifier (also used by checkRunGrid).
#
#   SMARTSLURM_ROOT=/path/to/SmartSlurm bash test/diagnose_livestate_guard.sh
#   # under mawk: SD=$(mktemp -d); ln -sf "$(command -v mawk)" "$SD/awk"
#   #            PATH="$SD:$PATH" SMARTSLURM_ROOT=... bash test/diagnose_livestate_guard.sh
#
# BUG being guarded: `diagnose` on a job that is simply still RUNNING/PENDING used
# to print "UNCONFIRMED -- the tool may never have started -- check the cluster /
# requeue", because it never consulted the squeue snapshot the grid uses and
# jobFate maps only TERMINAL states. The fix: diagnose consults the SAME shared
# live-state signal and reports running/pending calmly, while a genuinely vanished
# (hard-killed) job still gets the UNCONFIRMED/terminal card. liveState.sh is the
# single source of truth so the grid cell and the diagnose card cannot disagree.
#
# Asserts (exit non-zero on any failure):
#   running / pending (positive squeue match)  -> RUNNING / PENDING, failed=false
#   killed/vanished (absent from squeue)       -> NOT running; UNCONFIRMED, or the
#                                                 real sacct fate (OOM) on reconcile
#   completed / failed (local flags)           -> unchanged (live check never fires)
#   stale squeue cache                         -> no false "running" (TTL honored)
#   id-collision (7 must not match "77-R")     -> short id not falsely reported live
#   orphan-pending (upstream failed)           -> ORPHANED, not a bare pending
#   ls_state directly (the grid's classifier)  -> running/pending/vanished/fallbacks
# ---------------------------------------------------------------------------
set -u
ROOT="${SMARTSLURM_ROOT:-}"
if [ -z "$ROOT" ] || [ ! -x "$ROOT/bin/diagnose.sh" ] || [ ! -r "$ROOT/bin/liveState.sh" ]; then
  echo "set SMARTSLURM_ROOT to a checkout with bin/diagnose.sh + bin/liveState.sh" >&2; exit 2
fi
DIAG="$ROOT/bin/diagnose.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  : $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# extract a field from diagnose --json (no jq dependency, like checkRun does)
jstr() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1"; }
jbool(){ sed -n "s/.*\"$2\":\([a-z]*\).*/\1/p" <<<"$1"; }

L="$(mktemp -d)"; trap 'rm -rf "$L" "${SB:-/nonexistent}"' EXIT
cat > "$L/allJobs.txt" <<'EOF'
job_id depend_on job_flag
5001 null runFlag
5002 null pendFlag
5003 null vanFlag
5004 null doneFlag
5005 null failFlag
5006 null staleFlag
77 null longFlag
7 null shortFlag
5999 null upFlag
6001 5999 orphanFlag
5007 null ttlFlag
5008 null preemptFlag
5009 null deadlineFlag
5998 null upVanish
6002 5998 orphanFlag2
EOF

# a fresh, trustworthy squeue snapshot: running (5001,77), pending (5002,6001).
# NB: 5003/7/5006 are deliberately ABSENT. Format mimics squeue -o '%.18i-%t'.
write_cache() {
  # 6002 (PD) is listed; its upstream 5998/upVanish is deliberately ABSENT (vanished)
  printf '%18s-%s\n' 5001 R 5002 PD 77 R 6001 PD 5007 R 5008 R 5009 R 6002 PD > "$L/squeue_cache.txt"
}
started_out() { printf '#preamble\nreal tool output line\n' > "$L/$1.out"; }   # has a body line
empty_out()   { printf '#preamble only (never ran)\n'        > "$L/$1.out"; }   # comment-only

echo "SECTION A -- diagnose reports live state instead of a scary UNCONFIRMED card"
write_cache

# A1 RUNNING (squeue says R)
started_out runFlag
o="$("$DIAG" runFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = RUNNING ] && [ "$(jbool "$o" failed)" = false ] \
  && ok "A1 running job -> state=RUNNING, failed=false" \
  || bad "A1 running: state=$(jstr "$o" state) failed=$(jbool "$o" failed) (want RUNNING/false)"

# A2 PENDING (squeue says PD)
empty_out pendFlag
o="$("$DIAG" pendFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = PENDING ] && [ "$(jbool "$o" failed)" = false ] \
  && ok "A2 pending job -> state=PENDING, failed=false" \
  || bad "A2 pending: state=$(jstr "$o" state) failed=$(jbool "$o" failed) (want PENDING/false)"

# A3 running job also works WITHOUT --reconcile (read-only, cache-only path)
o="$("$DIAG" runFlag --log "$L" --json 2>/dev/null)"
[ "$(jstr "$o" state)" = RUNNING ] \
  && ok "A3 running job without --reconcile -> RUNNING (no scheduler call needed)" \
  || bad "A3 running no-reconcile: state=$(jstr "$o" state) (want RUNNING)"

echo "SECTION B -- a killed/vanished job is NOT mislabelled running (the real bug's inverse)"

# B1 vanished: started, absent from a trustworthy squeue, .out stale -> UNCONFIRMED
started_out vanFlag; touch -d '10 minutes ago' "$L/vanFlag.out"
o="$("$DIAG" vanFlag --log "$L" --json --reconcile 2>/dev/null)"
st="$(jstr "$o" state)"
[ "$st" = UNCONFIRMED ] && [ "$(jstr "$o" action)" = CHECK_CLUSTER ] \
  && ok "B1 vanished job -> UNCONFIRMED / CHECK_CLUSTER (not a phantom RUNNING)" \
  || bad "B1 vanished: state=$st action=$(jstr "$o" action) (want UNCONFIRMED/CHECK_CLUSTER)"
[ "$st" != RUNNING ] && [ "$st" != PENDING ] \
  && ok "B1b vanished job is never reported live" \
  || bad "B1b vanished job was mislabelled live ($st)"

# B2 killed with a sacct verdict: live check must NOT shadow the real OOM fate
SB="$(mktemp -d)"
cat > "$SB/sacct" <<'MOCK'
#!/bin/bash
# mock: per-id terminal states (5003/5007 OOM, 5008 PREEMPTED, 5009 DEADLINE); else no record
st=""
for a in "$@"; do case "$a" in
  *5003*|*5007*) st=OUT_OF_MEMORY;; *5008*) st=PREEMPTED;; *5009*) st=DEADLINE;;
esac; done
[ -n "$st" ] && printf '%s|2026|2026|0.0M|%s|node1|short|mem=4G|1:0|1:0|2:0|0:0\n' "job" "$st"
exit 0
MOCK
chmod +x "$SB/sacct"
o="$(PATH="$SB:$PATH" "$DIAG" vanFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = OOM ] \
  && ok "B2 killed job (absent from squeue) + sacct=OOM -> OOM (live check didn't shadow it)" \
  || bad "B2 killed/OOM: state=$(jstr "$o" state) (want OOM)"
rm -f "$L"/vanFlag.failed "$L"/vanFlag.out*   # undo persist() side effects for later

# B3 (Finding 1 regression): a job STILL listed "-R" in a FRESH cache, but actually
# OOM-killed. --reconcile must consult sacct FIRST (authoritative) and report OOM,
# not echo the stale cache's "running". This is the whole reason --reconcile exists.
write_cache                      # fresh cache lists 5007-R
started_out ttlFlag
o="$(PATH="$SB:$PATH" "$DIAG" ttlFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = OOM ] \
  && ok "B3 died-within-TTL (cache says -R, sacct says OOM) + --reconcile -> OOM (not RUNNING)" \
  || bad "B3 TTL-shadow: state=$(jstr "$o" state) (want OOM -- --reconcile must beat a fresh cache)"
rm -f "$L"/ttlFlag.failed "$L"/ttlFlag.out*

# B4/B5 (Finding 1b): terminal states that jobFate used to leave UNMAPPED (PREEMPTED,
# DEADLINE, REVOKED, SPECIAL_EXIT) must ALSO beat a fresh cache listing the job -R on
# --reconcile -- otherwise a dead job in one of these states reads as RUNNING.
write_cache; started_out preemptFlag
o="$(PATH="$SB:$PATH" "$DIAG" preemptFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = NODE_FAIL ] \
  && ok "B4 PREEMPTED (cache says -R) + --reconcile -> NODE_FAIL (not RUNNING)" \
  || bad "B4 PREEMPTED: state=$(jstr "$o" state) (want NODE_FAIL -- Finding 1b)"
started_out deadlineFlag
o="$(PATH="$SB:$PATH" "$DIAG" deadlineFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = OOT ] \
  && ok "B5 DEADLINE (cache says -R) + --reconcile -> OOT (not RUNNING)" \
  || bad "B5 DEADLINE: state=$(jstr "$o" state) (want OOT -- Finding 1b)"
rm -f "$L"/preemptFlag.* "$L"/deadlineFlag.*

echo "SECTION C -- local terminal flags are unaffected (live check never fires)"
write_cache
# C1 completed
started_out doneFlag; touch "$L/doneFlag.success"
o="$("$DIAG" doneFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = COMPLETED ] && [ "$(jbool "$o" failed)" = false ] \
  && ok "C1 .success -> COMPLETED (unchanged)" \
  || bad "C1 completed: state=$(jstr "$o" state) (want COMPLETED)"
# C2 failed  (even though its id 5005 is NOT in squeue, the .failed flag wins)
started_out failFlag; printf 'Segmentation fault\n' >> "$L/failFlag.out"; touch "$L/failFlag.failed"
o="$("$DIAG" failFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jbool "$o" failed)" = true ] && [ "$(jstr "$o" state)" != RUNNING ] \
  && ok "C2 .failed -> failed=true (not RUNNING), state=$(jstr "$o" state)" \
  || bad "C2 failed: state=$(jstr "$o" state) failed=$(jbool "$o" failed) (want failed=true, not RUNNING)"

echo "SECTION D -- no FALSE reassurance (stale cache, id-collision)"
# D1 stale cache: 5006 IS listed R, but the cache is older than the TTL -> untrusted
printf '%18s-%s\n' 5006 R > "$L/squeue_cache.txt"; touch -d '10 minutes ago' "$L/squeue_cache.txt"
empty_out staleFlag
o="$("$DIAG" staleFlag --log "$L" --json 2>/dev/null)"
[ "$(jstr "$o" state)" != RUNNING ] \
  && ok "D1 stale cache -> not reported RUNNING (TTL honored), state=$(jstr "$o" state)" \
  || bad "D1 stale cache was trusted and reported RUNNING"
# D2 id-collision: 7 is absent; 77-R present. 7 must NOT inherit 77's running state.
write_cache
empty_out shortFlag
o="$("$DIAG" shortFlag --log "$L" --json 2>/dev/null)"
[ "$(jstr "$o" state)" != RUNNING ] \
  && ok "D2 id 7 does not match '77-R' -> not RUNNING, state=$(jstr "$o" state)" \
  || bad "D2 id-collision: short id 7 falsely matched 77-R (RUNNING)"
# D2b and the real id 77 IS running
started_out longFlag
o="$("$DIAG" longFlag --log "$L" --json 2>/dev/null)"
[ "$(jstr "$o" state)" = RUNNING ] \
  && ok "D2b id 77 correctly matches '77-R' -> RUNNING" \
  || bad "D2b id 77: state=$(jstr "$o" state) (want RUNNING)"

echo "SECTION E -- orphan detection requires a FAILED upstream (not merely 'not done')"
write_cache                        # fresh cache (D1 left it stale); 6001 listed PD
empty_out orphanFlag
# E1: upstream actually FAILED (.failed) -> ORPHANED
touch "$L/upFlag.failed"
o="$("$DIAG" orphanFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = ORPHANED ] && [ "$(jstr "$o" action)" = CHECK_UPSTREAM ] \
  && ok "E1 pending + FAILED upstream -> ORPHANED / CHECK_UPSTREAM" \
  || bad "E1 orphan: state=$(jstr "$o" state) action=$(jstr "$o" action) (want ORPHANED/CHECK_UPSTREAM)"
# E2 (Finding 2 regression): upstream still RUNNING (no .failed) must NOT false-alarm
rm -f "$L/upFlag.failed"
o="$("$DIAG" orphanFlag --log "$L" --json --reconcile 2>/dev/null)"
[ "$(jstr "$o" state)" = PENDING ] && [ "$(jbool "$o" failed)" = false ] \
  && ok "E2 pending + still-running upstream -> PENDING (no false ORPHANED alarm)" \
  || bad "E2 false-orphan: state=$(jstr "$o" state) failed=$(jbool "$o" failed) (want PENDING/false -- Finding 2)"
# E3 (Finding 2b): a hard-killed upstream leaves NO marker but is gone from a
# trustworthy squeue (vanished). A pending downstream behind it must STILL be ORPHANED
# (matching the grid), not read as a calm "pending — nothing to diagnose".
write_cache                        # 6002 listed PD; its upstream 5998/upVanish absent
started_out upVanish; touch -d '10 minutes ago' "$L/upVanish.out"   # started, stale, gone
empty_out orphanFlag2
o="$("$DIAG" orphanFlag2 --log "$L" --json 2>/dev/null)"
[ "$(jstr "$o" state)" = ORPHANED ] && [ "$(jstr "$o" action)" = CHECK_UPSTREAM ] \
  && ok "E3 pending + VANISHED (markerless hard-killed) upstream -> ORPHANED" \
  || bad "E3 vanished-upstream orphan: state=$(jstr "$o" state) action=$(jstr "$o" action) (want ORPHANED -- Finding 2b)"

echo "SECTION F -- ls_state directly (the grid's classifier shares this)"
. "$ROOT/bin/liveState.sh"
A="$(printf '%18s-%s\n' 9001 R 9002 PD)"
[ "$(ls_state fX "$L" "$A" 1 9001)" = running ] && ok "F1 ls_state squeue R -> running" || bad "F1 ls_state R"
[ "$(ls_state fX "$L" "$A" 1 9002)" = pending ] && ok "F2 ls_state squeue PD -> pending" || bad "F2 ls_state PD"
# vanished: started .out, stale, trustworthy squeue, id absent
started_out gv; touch -d '10 minutes ago' "$L/gv.out"
[ "$(ls_state gv "$L" "$A" 1 9999)" = vanished ] && ok "F3 ls_state started+absent+stale -> vanished" || bad "F3 ls_state vanished"
# started-fresh, squeue untrustworthy -> running (fallback keeps a just-started job live)
started_out gf
[ "$(ls_state gf "$L" "" 0 9998)" = running ] && ok "F4 ls_state started+no-squeue(fresh) -> running" || bad "F4 ls_state started-fresh"
# nothing started -> pending
[ "$(ls_state gn "$L" "" 0 9997)" = pending ] && ok "F5 ls_state no .out -> pending" || bad "F5 ls_state idle"

echo
echo "----------------------------------------------------------------"
echo "diagnose_livestate_guard: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "GUARD GREEN" || echo "GUARD RED"
exit $(( FAIL > 0 ? 1 : 0 ))

# Plan: P6 — signal-trap hardening so timeouts/scancels self-record (not vanish)

> **Status:** spec for review. High blast radius (touches `cleanUp.sh`, the 805-line
> teardown/requeue script). Circulate before implementing.
> **Depends on:** the slurmless signal harness (`MOCK_FAIL_MODE=sigkill/sigterm`,
> `hardkill`/`cleanup_reentrancy` blocks) — already merged on the harness branch.

---

## 1. Goal & scope

Make cleanUp run **at write-time** for the *catchable* hard kills — the **timeout
grace** signal and **scancel** — so those jobs record their fate and (for timeouts)
auto-requeue, instead of vanishing (no `.success`/`.failed`/report, `diagnose` →
`UNCONFIRMED`). Today the job traps only `EXIT`, and an *untrapped* `SIGTERM`
terminates bash **without** running the EXIT trap, so every timeout/scancel vanishes.

**Out of scope — cannot be fixed here:** a true **SIGKILL** (cgroup OOM-kill, the
final kill after the grace expires, node failure). SIGKILL is uncatchable; those
remain the job of **fate-reconcile** (grid `?` + `diagnose` sacct fallback). P6 and
fate-reconcile are complementary: P6 shrinks the vanished set to the truly-uncatchable
cases; fate-reconcile recovers whatever is left.

## 2. The four coordinated changes

### A. ssbatch job wrapper — trap `TERM`/`USR1`, run-once, pass the reason
`bin/ssbatch` generates the per-step job script at **lines 655 and 725**, currently:
```
trap "{ cleanUp.sh <17 args>; }" EXIT
memCpuMonitor.sh <...> &
```
Replace the inline EXIT-only trap with a small teardown **function** plus traps on
`EXIT`, `TERM`, `USR1`:
```
_ssTornDown=
_ssTeardown() {              # idempotent at the shell level (see also cleanUp's own lock)
  [ -n "$_ssTornDown" ] && return 0
  _ssTornDown=1
  cleanUp.sh <17 args>
}
trap '_ssTeardown' EXIT
trap 'export smartSlurmSignal=USR1; _ssTeardown; exit 138' USR1   # pre-timeout warning (our --signal)
trap 'export smartSlurmSignal=TERM; _ssTeardown; exit 143' TERM   # scancel / grace
memCpuMonitor.sh <...> &
```
Notes:
- The `TERM`/`USR1` handlers **`exit`** so the job ends after teardown; that `exit`
  fires the `EXIT` trap too, which calls `_ssTeardown` again — the `_ssTornDown`
  shell var makes that second call a no-op (the common in-process double-fire).
- `smartSlurmSignal` is **exported** so the cleanUp child sees *why* it was torn down.
- `memCpuMonitor.sh &` is unchanged (it dies with the job either way).

### B. cleanUp.sh — two small, surgical additions (the rest of the 805 lines untouched)

**B1. Run-once file lock (belt-and-suspenders with A; robust against races/any caller).**
`smartSlurmLogDir` is **exported into the job env** (runAsPipeline:184, ssbatch:86),
so it is available at cleanUp's first line. Insert **before the report echo (line 11)**:
```
# Run-once: cleanUp fires from the job trap. With the trap extended to TERM/USR1, a
# grace signal then the EXIT can fire it twice (and a future reaper could call it
# again). Claim an atomic per-ATTEMPT lock; a second invocation returns immediately,
# so nothing is double-emitted, double-appended to jobRecord/efficiency, or
# DOUBLE-REQUEUED (the requeue loop advances to the next .requeued.N marker and would
# resubmit again). Keyed on SLURM_JOBID (this attempt), NOT the flag -- a legitimate
# requeue is a NEW job with a new id and a new step attempt, and must run its own
# cleanUp.
_ssLock="${smartSlurmLogDir:-.}/.cleanup.lock.${SLURM_JOBID:-$$}"
if ! ( set -o noclobber; : > "$_ssLock" ) 2>/dev/null; then
    echo "cleanUp: re-entrant invocation for ${1} (job ${SLURM_JOBID:-?}) ignored." >&2
    exit 0
fi
```
*Why SLURM_JOBID, not flag:* the requeued job reuses the **flag** but gets a **new
SLURM_JOBID**; a flag-keyed lock would wrongly block the requeue's own cleanUp and
break the escalation chain. Per-attempt (SLURM_JOBID) is correct.

**B2. Honor the pre-timeout signal in classification.** When torn down by our `USR1`
grace warning, Slurm has **not** finalized the state yet — `sacct` won't say
`TIMEOUT` (the job still reads `RUNNING`), so the existing classifier (cleanUp:164–190)
would fall through to `Unknown`, which does **not** requeue. Add, right after that
classifier block, before the requeue logic:
```
# A USR1 grace warning (our --signal) means "about to be killed for time" -- trust
# it over the not-yet-final sacct and classify OOT so we requeue with more time.
# (TERM is left as-is: it may be a scancel, which must NOT be auto-resurrected.)
if [ "${smartSlurmSignal:-}" = USR1 ] && [ ! -f "$succFile" ]; then
    case "$jobStatus" in COMPLETED) ;; *) jobStatus=OOT ;; esac
fi
```
Optional refinement: when `smartSlurmSignal` is set, **skip the `sleep 5`**
(cleanUp:129, "wait for slurm database") — we are inside a bounded grace window and
are trusting the signal, not sacct, so the wait only burns grace.

### C. Slurm submission — `--signal=B:USR1@<grace>`
Add to the sbatch command so Slurm sends `USR1` to the **batch shell** (`B:`) `<grace>`
seconds before the wall-clock kill. Two sites, both in `bin/ssbatch`:
- the **initial** submission (built ~line 799), and
- the **requeue template** — the `#Command used to submit the job:` line (line 788)
  that cleanUp greps to resubmit — so requeued attempts also get the warning.
Value: `--signal=B:USR1@${smartSlurmKillGrace:-60}`.

### D. config.txt — the grace knob
```
# Seconds before the time limit that Slurm signals the batch script (USR1), giving
# cleanUp a window to record the timeout and auto-requeue before the hard SIGKILL.
export smartSlurmKillGrace=60
```

## 3. Design decisions (and why)

| Decision | Choice | Why |
|---|---|---|
| Re-entrancy guard location | **Both**: shell var in the wrapper **and** a file lock in cleanUp | wrapper var covers the common TERM→EXIT double-fire cheaply; the file lock is robust to races (EXIT running when a TERM lands) and any future caller (a reaper) |
| Lock key | **SLURM_JOBID** (per attempt) | a requeue reuses the flag with a new id; a flag-keyed lock would block the requeue's cleanUp |
| Which signal auto-requeues | **USR1 only** | USR1 is *our* unambiguous pre-timeout warning → OOT → requeue; TERM is ambiguous (scancel vs grace) → record but don't resurrect |
| Pre-timeout classification | trust the **signal**, not sacct | during the grace, sacct still says RUNNING; without the hint cleanUp → Unknown → no requeue |
| Grace default | **60s** (`smartSlurmKillGrace`) | must exceed cleanUp's teardown time; 60s is comfortable and O2-tunable |

## 4. Edge cases

- **SIGKILL (OOM-kill, post-grace kill, node fail):** uncatchable → still vanishes →
  fate-reconcile. P6 does not and cannot change this.
- **scancel:** TERM → cleanUp records (markers/report) but does **not** requeue (no
  USR1), so a user cancel is respected, not resurrected.
- **Grace too short:** if cleanUp can't finish before the SIGKILL, you get a partial
  teardown — fate-reconcile still recovers it. Mitigated by skipping the `sleep 5`
  (B2) and a comfortable default grace.
- **Requeue during the grace:** cleanUp resubmits a *new* job (new id) within the
  window; `sbatch` is fast. The new job is independent of the dying one.
- **Double-fire race (EXIT mid-run, TERM arrives):** the atomic `noclobber` file
  lock (B1) wins even if the shell var isn't set yet.
- **memCpuMonitor child:** dies with the job group; unaffected.

## 5. Blast radius

| File | Change | Lines |
|---|---|---|
| `bin/ssbatch` | teardown function + TERM/USR1 traps | 2 sites (655, 725) |
| `bin/ssbatch` | `--signal=B:USR1@grace` on submit + requeue template | ~788, ~799 |
| `bin/cleanUp.sh` | run-once lock (top) + USR1→OOT classification (+ optional sleep skip) | ~3 small inserts |
| `config/config.txt` | `smartSlurmKillGrace=60` | 1 line |

**Unchanged:** cleanUp's classification/jobRecord/efficiency/requeue/escalation/email
logic (beyond the two inserts), the estimator, jobRecords schema, and the
grid/diagnose/fate-reconcile stack.

## 6. Test plan (all in the slurmless sandbox)

- **`cleanup_reentrancy`** (already built, currently FAILS by design): B1 flips it to
  PASS (one efficiency.tsv row). Then promote it into `ALL_BLOCKS`.
- **New `sigterm_selfrecord`** (via the `sigterm` mode): with the P6 trap, a SIGTERM'd
  step now **runs cleanUp** → writes a marker/report (vs today's vanish).
- **New `usr1_timeout_requeue`**: extend the kill harness with a **`usr1`** mode
  (deliver USR1, then let the job end) → assert cleanUp classifies **OOT** and writes
  a `.failed.requeued.*.time` marker (B2 + C). *(Harness add: a `usr1` inject that
  signals the group with USR1 instead of KILL/TERM.)*
- **Regression, must stay green:** `hardkill` (SIGKILL still vanishes — fate-reconcile
  unchanged), `oom_injection`, `oomoot_escalate`, `resubmit_convergence`,
  `fate_reconcile`, `diagnose`, `clean_2step`, `checkrun_efficiency`.
- **Adversarial pass** on the final diff (lock races; requeue-key correctness; the
  TERM-vs-USR1 split; grace interplay with the `sleep 5`).

## 7. Rollout sequencing (each step green in sandbox before the next)

1. **config** knob + **ssbatch `--signal`** — inert without the trap (safe to land first).
2. **ssbatch** teardown function + TERM/USR1 traps.
3. **cleanUp B1** run-once lock → `cleanup_reentrancy` passes; promote it.
4. **cleanUp B2** USR1→OOT + harness `usr1` mode + `usr1_timeout_requeue`.
5. Adversarial review → stage.

## 8. Residual, cluster-only (an O2 smoke test, not a logic test)

- Does O2's Slurm honor `--signal=B:USR1@N`? (depends on `ProctrackType`/`KillWait`.)
- Is 60s grace enough there? Tune `smartSlurmKillGrace`.
- Confirm O2's `cgroup.conf` (`oom.group`) — it sets how *often* OOM lands as an
  uncatchable whole-job SIGKILL (→ fate-reconcile) vs a tool-only kill (→ cleanUp runs).

## 9. Open questions

1. Skip cleanUp's `sleep 5` whenever `smartSlurmSignal` is set (faster grace teardown)?
   Proposed: yes.
2. On `TERM`, record a distinct status (e.g. `Canceled`) vs leaving it to sacct?
   Proposed: leave to sacct; no auto-requeue.
3. Should the run-once lock be cleaned up on success, or left as an attempt marker?
   Proposed: leave it (per-attempt, harmless, and a useful "cleanUp ran" record).

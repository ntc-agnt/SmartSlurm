# Plan: checkRun / diagnose fate reconciliation for hard‑killed jobs

> **Status:** planning — circulate for review before implementation.
> **Scope:** `checkRun`, `checkRunGrid`, `diagnose.sh`, a new shared fate resolver,
> and (orthogonal) `ssbatch`/`cleanUp.sh` signal hardening, plus slurmless harness
> extensions and sandbox OOM/timeout + fuzz testing.
> **Target:** clean, staged merge into `master`.

---

## 1. Problem

Every authoritative status artifact SmartSlurm relies on — the `.success` / `.failed`
flags, the `.failed.requeued.*` markers, and the `sacct` table appended to
`<flag>.out` — is written by **`cleanUp.sh`, which runs from the job's `EXIT`
trap** (ssbatch installs `trap '…cleanUp.sh…' EXIT`).

When a job is killed in a way that **bypasses the `EXIT` trap**, none of those
artifacts are written:

| Kill | Signal | Trap runs? | Why |
|---|---|---|---|
| tool exits non‑zero | — | ✅ | normal exit, EXIT fires |
| **timeout / `scancel`** | SIGTERM (grace) then SIGKILL | ❌ today | job traps **only** `EXIT`; an *untrapped* SIGTERM terminates the shell **without** running the EXIT trap |
| **OOM‑kill / hard kill** | SIGKILL | ❌ (impossible) | SIGKILL is uncatchable by any process; the co‑process `memCpuMonitor` is in the same cgroup and dies too |

Consequences on a real run (observed):

- **`checkRunGrid`** shows the dead step as **phantom `running` (`>`)** — its
  `job_status()` rule *"started (`.out` exists), no terminal flag → running"* fires
  for a job that actually left the queue and died.
- Downstream jobs are **dependency‑cancelled** by Slurm (rAP uses `-d afterok`,
  runAsPipeline:629), so they show phantom `pending` (`-`) — grid summary reports
  "running/pending" for a dead branch.
- **`diagnose.sh`** returns `UNCONFIRMED / CHECK_CLUSTER` ("may never have started")
  — it reads state only from the (absent) log/flag artifacts and never queries the
  scheduler.
- **Auto‑requeue** (also in `cleanUp`) never fires, so the branch **stalls** instead
  of self‑healing.

The authoritative terminal state (`OUT_OF_MEMORY`, `TIMEOUT`, `CANCELLED`,
`NODE_FAIL`, `FAILED`) exists in Slurm's accounting DB (`sacct`) but is never read.

**`dmesg` is not a usable source** on a shared HPC: `kernel.dmesg_restrict=1` blocks
unprivileged reads; it is per‑compute‑node (wrong node from the login node); it
rotates; and it logs PID/comm, not jobid. `sacct`'s `OUT_OF_MEMORY` *is* the OOM
event captured and attributed by Slurm — it is the correct and only portable source.

## 2. Goals / Non‑goals

**Goals**
1. The grid must be **actionable**: never show a dead job as running/pending.
2. `diagnose` must report the **real terminal cause** (OOM/timeout/…) for
   hard‑killed jobs.
3. Reduce how often hard kills become invisible in the first place (catch the
   catchable signals at write‑time).
4. Preserve **trust**: no status changes "out of sight".
5. Preserve **performance**: the hot read path stays static‑file‑based; the
   scheduler is touched sparingly.

**Non‑goals (this round)**
- Rendering the workflow graph (separate, tabled).
- A pre‑emptive OOM predictor in `memCpuMonitor` (noted as future P7; racy, deferred).
- Any change to the estimator / requeue escalation math.

## 3. Design invariants

These are hard rules; every component and test asserts against them.

- **I1 — Static hot path.** Passive redraws (resize, returning from a sub‑view) never
  query the scheduler and never change a glyph. They re‑render existing data only.
  *(This already holds: `Enter` = refresh data; return = redraw.)*
- **I2 — Explicit‑action‑only mutation.** A glyph changes only in response to an
  explicit user action: launch, `Enter` (refresh), or `diagnose`. Never on a timer,
  never on a passive redraw.
- **I3 — Announced changes.** Every reconcile reports what changed
  (`reconciled 3: 2 OOM, 1 timeout`) and newly‑changed cells are highlighted for the
  render in which they changed.
- **I4 — `?` is computed, never persisted.** "Vanished / unknown" is derived live
  from local files (fresh squeue ∧ no flag ∧ stale `.out` mtime). It is never written
  to disk.
- **I5 — Markers only from authoritative sources.** Persistent markers
  (`.success` / `.failed` / `.failed.requeued.*`) are written only by `cleanUp`
  (at job end) or by the sacct resolver. **Never from squeue‑absence** (absence ≠
  failure — a `.success` can land a beat later, or squeue can transiently miss).
- **I6 — Graceful degradation.** If `sacct`/`squeue` is missing, slow, or returns no
  record yet (post‑job lag), degrade cleanly: keep `?`, emit no raw error, resolve on
  a later refresh. (Mirrors the existing checkRun graceful‑`dot` fix.)

## 4. Architecture: the three truths

| Source | Answers | Cost | Where used |
|---|---|---|---|
| **local flag/log files** | "did it succeed/fail (recorded)?" | free (stat/glob) | hot path — every status pass |
| **`squeue`** (user‑scoped, cached 120 s) | "is it in the queue *now* (R/PD)?" — **active only**, no terminal cause | cheap (~sub‑second) | classify active vs **vanished** |
| **`sacct`** (accounting DB) | "how did it *end*?" — OOM/timeout/cancelled/failed | heavier (~1–5 s) | resolve a **vanished** job's cause |

Key fact driving the split: **`squeue` cannot show an OOM** — a dead job is simply
absent. squeue takes a cell to `?` (vanished); only `sacct` takes `?` → `OOM`.

## 5. Components

### P1 — Grid honesty (`checkRunGrid job_status()`) — free, no scheduler
Replace the misclassifying rule. Current ladder:
```
.success → done ; .failed/requeue → error ; squeue R → running ; squeue PD → pending
; .out exists & not in squeue & no flag → running   ← BUG
; else → pending
```
New rule for the buggy branch: *started, gone from a fresh squeue, no flag* →
**`?` unknown (vanished)**, not `running`. Robustify with an **`.out` mtime check**:
- `.out` modified within `RECONCILE_LIVE_SECS` (default ~90 s) → still `running`
  (actively producing output; tolerates squeue cache lag for fresh jobs);
- `.out` silent ≥ that AND absent from squeue AND no flag → `?` vanished.

Lands alone; immediately removes the phantom‑running bug. The `?`/orange‑`?` glyph
already exists (`checkRunGrid:531`).

### P2 — Shared fate resolver (`bin/jobFate.sh`) — the DRY core
A single read‑only helper used by both P3 and P4:
```
jobFate.sh <flag> [--log DIR]      # → prints mapped state; writes marker; exit code
jobFate.sh --batch <flag>... [--log DIR]   # one sacct call for many flags
```
Algorithm per flag:
1. Resolve **flag → jobid** from `<log>/allJobs.txt` (columns `job_id … job_flag`).
   On requeue there may be several entries; take the **last** (most recent) match.
2. One `sacct -n -j <id(s)> -o JobID,State` (batched form: comma‑joined ids, **one**
   call). Use job‑level (allocation) State; precedence on substeps mirrors
   `cleanUp.sh`: `OUT_OF_MEMORY > TIMEOUT > NODE_FAIL/BOOT_FAIL > CANCELLED > FAILED >
   COMPLETED`.
3. Map → write the authoritative marker the rest of the system already understands:
   - `OUT_OF_MEMORY` → `<flag>.failed.requeued.<n>.mem` (OOM, requeue‑eligible)
   - `TIMEOUT` → `<flag>.failed.requeued.<n>.time`
   - `FAILED`/`NODE_FAIL`/`CANCELLED` → `<flag>.failed`
   - `COMPLETED` **without** `.success` → `<flag>.failed` **flagged "Unknown"**
     (tool‑succeeded‑but‑success‑unrecorded; matches diagnose's `COMPLETED_NOSUCCESS`)
4. **I5/I6:** if no jobid, `sacct` absent, or `sacct` returns nothing yet → **no
   marker**, exit "unresolved" (caller keeps `?`).
Marker writes are idempotent (`touch`), tolerating concurrent `checkRun` instances
and a late‑arriving real `cleanUp`.

### P3 — Batched reconcile (`checkRun`) — launch + `Enter`
On **launch** and on each **`Enter`** (not passive redraws — I1/I2):
1. refresh the squeue cache (fresh),
2. collect `?` jobs (vanished per P1),
3. `jobFate.sh --batch <those flags>` → **one** `sacct` call → markers written,
4. redraw; **announce** `reconciled N (…)` and highlight changed cells (I3).
TTL‑cached like `squeue_cache.txt` (reuse `_SQ_TTL`): repeated `Enter` within the TTL
reuses the last reconcile. **Diagnose pre‑warms** this (see P4) so the next `Enter`
is instant. The launch reconcile means the **first** grid is already correct
(OOM shown as OOM), paying the one‑time sacct cost where latency is expected.

### P4 — Diagnose cold‑path fallback (`diagnose.sh`) — gated
In the **`UNCONFIRMED` branch only**, call `jobFate.sh <flag>` (single‑job sacct),
report the resolved state, write the marker. Because P3 pre‑resolves zombies, in the
common flow diagnose finds a marker and is **not** `UNCONFIRMED` → **no second
sacct**. The gated call fires only for the races P3's snapshot can't cover:
- job died **after** the last reconcile and the user drills straight in;
- **sacct lag** at launch (no record yet), resolved by the time of drill‑in.
Diagnose thus stays the authoritative, always‑fresh single‑job truth without
requiring the user to "hit Enter first", and without redundant calls.
Optionally, diagnose kicks P3's batched reconcile **in the background** during its
latency, caching the result; the glyph changes still land only on the next `Enter`
(I2), announced (I3).

### P5 — Trust UI (`checkRun` / `checkRunGrid`)
- a status line: `last refreshed 8s ago · reconciled 3 (2 OOM, 1 timeout)`;
- highlight cells whose state moved on the current refresh;
- enforce I1/I2 (audit that no passive path recomputes/mutates glyphs).

### P6 — SIGTERM write‑time hardening (`ssbatch` job wrapper + `cleanUp.sh`) — orthogonal
Reduce how often zombies occur at all, for the **catchable** signals:
- add `TERM USR1` to the job trap: `trap '…cleanUp…' EXIT TERM USR1` (ssbatch:655/725);
- submit with `--signal=B:USR1@<grace>` so Slurm pokes the **batch** script N s before
  the hard kill, giving `cleanUp` a window to record a timeout/cancel at write‑time;
- make `cleanUp` **idempotent / re‑entrant** (a guard so a `TERM`‑triggered run and a
  following `EXIT` run don't double‑write or corrupt the report).
Does **not** help pure OOM‑SIGKILL (uncatchable) — that remains P2/P3/P4's job.
Independent of the reconcile work; lands on its own branch.

### P7 — (future, out of scope) pre‑OOM detection in `memCpuMonitor`
Have the monitor notice it is approaching the cgroup limit and write a "likely‑OOM"
marker (and optionally stop the tool gracefully) *before* the hard kill. Racy against
spikes; deferred, noted for completeness.

## 6. Commit & staging strategy (clean merge into master)

Three independently‑reviewable branches off `master`, smallest/safest first. Each
commit is self‑contained, green, and revertible.

**Branch A — `fix/checkrun-vanished-glyph` (P1).** Highest value, zero new deps, no
scheduler. Can land immediately and alone.
- `checkRunGrid: classify vanished jobs as unknown, not running (mtime‑guarded)`

**Branch B — `feat/checkrun-fate-reconcile` (P2→P4→P3→P5), based on A.** The sacct
system. Ordered so each commit is usable on its own:
1. `jobFate: shared flag→jobid→sacct state resolver (graceful, idempotent markers)`
2. `diagnose: live‑sacct fallback for UNCONFIRMED (cold path, gated)`
3. `checkRun: batched sacct reconcile of vanished jobs at launch + refresh`
4. `checkRun: announce reconciles and highlight changed cells`
Rationale for this intra‑branch order: P2 is inert until wired; P4 wires the single‑
job path (smallest blast radius, easy to test); P3 adds the batched/launch path; P5
is pure UI. Any prefix of this stack is shippable.

**Branch C — `feat/job-signal-trap` (P6), independent of A/B.**
- `ssbatch/cleanUp: trap SIGTERM/USR1 + --signal so timeouts self‑record (idempotent)`

**PRs to master:** three PRs (A, then B stacked on A, then C in parallel). A is a
clean standalone bugfix; B depends on A; C is orthogonal. Each PR green in slurmless
before the next is opened. (Matches the earlier `fix/checkrun-graph-graceful` model.)

## 7. Execution plan / phases

1. **Implement** per §6 (A → B → C), each commit green locally.
2. **Adversarial review** of `checkRun` + `checkRunGrid` (and `jobFate`, `diagnose`) —
   §10 checklist; run `/code-review` and an independent adversary pass; fix findings.
3. **Harness updates** — extend slurmless mock `sacct`/`squeue` + failure injection;
   add the new blocks (§8). Full existing suite stays green (no regression).
4. **Sandbox testing** — toy pipeline with OOM/timeout injection + fuzz (§9) to flush
   latent bugs.
5. **Stage** — only when 2–4 are clean, open the three PRs. *(Gated on user — "we'll
   stage".)*

## 8. slurmless harness updates

The mock `sacct` already supports `-j`/`--format` and replays per‑job state from
`$MOCK_SLURM_STATE/jobs`; `squeue`/`scancel` exist. Extensions:

- **mock `sacct`:** ensure injectable terminal states incl. `OUT_OF_MEMORY`,
  `TIMEOUT`, `CANCELLED`, `NODE_FAIL`, and the multi‑line alloc/`.batch`/`.extern`
  substep shape; support the batched `-j id1,id2,…` form; support "no record yet"
  (empty) to simulate post‑job lag.
- **mock `squeue`:** support a job **leaving** the queue (vanish) so P1 can see it.
- **failure injection:** a helper to mark a job *hard‑killed* — the harness then
  simulates: `.out` exists, job absent from squeue, **no** cleanUp artifacts, and
  `sacct` reports the chosen terminal state. This is the core fixture for the gap.
- **new test blocks** (register in `ALL_BLOCKS` + purposes):
  - `grid_vanished_glyph` — hard‑killed job → `?`, not `>`; fresh job still `>`
    (mtime guard); downstream (afterok‑cancelled) → orphan.
  - `diagnose_sacct_fallback` — UNCONFIRMED → OOM/timeout via `jobFate`; marker written.
  - `reconcile_batch` — launch/`Enter` reconcile writes markers; grid shows cause;
    one sacct call for N zombies.
  - `reconcile_idempotent` — re‑reconcile is a no‑op; concurrent runs safe.
  - `reconcile_graceful` — sacct absent / jobid missing / empty (lag) → stays `?`,
    no error.
  - `reconcile_suppresses_diagnose` — after a reconcile, diagnose finds a marker and
    makes **no** second sacct call (assert via a mock‑sacct call counter).
  - `no_passive_mutation` (I1/I2) — a passive redraw makes no scheduler call and
    changes no glyph.
  - `signal_trap` (P6) — SIGTERM to the job → cleanUp runs → correct marker; EXIT
    after TERM does not double‑write (idempotence).

## 9. Sandbox OOM/timeout + fuzz plan

**Toy pipeline:** reuse `example-scripts/phrase_pipeline_end.sh` (the phrase/tokenize
toy; `rAP_test_tokenize` family) — small, multi‑step, fan‑out, already in‑tree. Run it
through the mock harness.

**Injection matrix:** kill a mid‑pipeline step (e.g. `tokenize`) under each of:
`OUT_OF_MEMORY`, `TIMEOUT`, `CANCELLED`, `NODE_FAIL`, and `COMPLETED‑without‑success`.
Assert end‑to‑end: grid cell `?` → correct cause after reconcile; downstream orphaned;
`diagnose` agrees; markers written; (with P6) a trapped timeout self‑records without
reconcile.

**Fuzz (find latent parser/resolver bugs):**
- **`sacct` output:** empty; whitespace‑only; missing columns; conflicting substep
  states; unknown/novel State tokens; embedded commas/`|` in NodeList; very long
  node lists; CRLF; control/Unicode bytes; duplicated JobID lines.
- **`allJobs.txt`:** flag with no jobid; duplicate flags (requeue → pick latest);
  jobid non‑numeric; truncated lines; a flag that is a prefix of another.
- **flags:** the full real flag shape (`7.4.5.6.picard7._n_data1_…fastq.gz`) — dots,
  long paths, shell metacharacters — through `jobFate` and the glob/stat paths
  (watch unquoted expansions, per the grammar plan's A0 hardening lessons).
- **timing races:** `.success` appears between the squeue check and the marker write;
  a real `cleanUp` writes `.failed` while a reconcile is mid‑flight; two `checkRun`
  instances reconcile concurrently.
Property to hold under all fuzz: never crash, never a raw `command not found`/shell
error to the TUI, never a **false** `.failed` on a truly‑succeeded job, never mutate a
glyph outside an explicit action.

## 10. Adversarial review checklist (checkRun / checkRunGrid / jobFate / diagnose)

- Race: `.success`/`.failed` lands mid‑reconcile → authoritative file wins; no false
  overwrite (P2 only writes when sacct is terminal AND no success flag).
- squeue cache staleness → mtime guard prevents false `?` on fresh jobs; verify the
  guard window vs the cache TTL.
- flag→jobid ambiguity on requeue → "latest entry" is correct and deterministic.
- sacct substep precedence → OOM on `.0` with `FAILED` on `.batch` resolves to OOM.
- Idempotence & concurrency → repeated/parallel reconciles safe.
- I1/I2 audit → no passive code path recomputes status or calls the scheduler.
- Unquoted expansions over the long dotted flag (globs, `stat`, `grep`) → no
  word‑splitting / glob surprises (reuse grammar‑plan A0 discipline).
- P6 double‑fire (TERM then EXIT) → cleanUp idempotent; report not duplicated/corrupt.
- Graceful paths → sacct/squeue missing or slow never breaks the TUI.

## 11. Blast‑radius survey (files touched)

| File | Change | Piece |
|---|---|---|
| `bin/checkRunGrid` | `job_status()` vanished→`?`; changed‑cell highlight | P1, P5 |
| `bin/checkRun` | launch+Enter reconcile; status line; pre‑warm hook | P3, P5 |
| `bin/diagnose.sh` | UNCONFIRMED → `jobFate` fallback | P4 |
| `bin/jobFate.sh` (new) | shared resolver | P2 |
| `bin/ssbatch` | trap `TERM USR1`; `--signal=B:USR1@grace` | P6 |
| `bin/cleanUp.sh` | re‑entrancy guard | P6 |
| `slurmless …/mockSlurm/sacct`,`squeue` | injectable terminal states, vanish, lag, batched `-j` | harness |
| `slurmless …/test/run_tests.sh` (+fixtures) | new blocks + injection helper | harness |
| `config/config.txt` (maybe) | `RECONCILE_LIVE_SECS` knob (default) | P1/P3 |

No change to: estimator math, requeue escalation, jobRecords schema, the grammar.

## 12. Risks & mitigations

- **False `?` on a fresh job** (squeue cache lag) → `.out` mtime guard (P1).
- **False `.failed` on a race** → markers written only on terminal sacct **and** no
  `.success` (I5); authoritative files always win.
- **sacct slowness at launch** → one‑time, at an expected pause; show "reconciling…".
- **sacct lag (no record yet)** → stay `?`, resolve next refresh (I6).
- **cleanUp double‑fire (P6)** → explicit idempotence guard + test.
- **Trust erosion** → I2 (explicit‑action‑only) + I3 (announce/highlight) enforced and
  tested (`no_passive_mutation`).

## 13. Definition of Done

- Grid never shows a vanished job as running/pending; shows `?` → resolved cause.
- `diagnose` reports OOM/timeout/… for hard‑killed jobs instead of `UNCONFIRMED`;
  agrees with the grid.
- No scheduler call on passive redraws; only launch/`Enter`/`diagnose`. Every change
  announced; none out of sight.
- Graceful when sacct/squeue absent or lagging.
- P6: timeouts/cancels self‑record at write‑time; cleanUp idempotent.
- All new + existing slurmless blocks green; sandbox OOM/timeout matrix + fuzz clean.
- Three clean PRs (A, B‑on‑A, C) ready to stage.

## 14. Open questions (for review)

1. `RECONCILE_LIVE_SECS` default (90 s proposed) and whether it's a config knob.
2. Should launch always reconcile, or only when ≥1 `?` job exists? (Proposed: only
   when zombies exist — zero cost otherwise.)
3. P6 grace window for `--signal` (e.g. `@60`) — cluster‑dependent; default + override.
4. Do we want the diagnose background pre‑warm (P4 optional) in v1, or defer it?

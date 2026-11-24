---
name: migration-assistant
description: Convert a non-SmartSlurm pipeline to the runAsPipeline (rAP) framework, collaboratively and validated in the slurmless sandbox. Use when a user has a hand-rolled SLURM workflow (sbatch + --dependency) to port to SmartSlurm/rAP, or a pile of loose processing scripts to turn into a pipeline, and wants it tested off-cluster before running for real. Builds on the slurmless user-workflow harness (ss_wf_activate / ss_wf_drain).
compatibility: Needs bash with /bin/sh = bash; a SmartSlurm checkout (SMARTSLURM_ROOT, auto-resolved in-tree at SmartSlurm/slurmless/); and the user's real step tools via a conda env / container / module list (or harness stubs). Scratch only.
---

# Migration Assistant

Help a user move a pipeline onto SmartSlurm's `runAsPipeline` (rAP), and **prove it
works in the slurmless sandbox before they touch a cluster**. The user's scripts
run **unmodified** — the mock Slurm is invisible to them (see the `slurmless-harness`
skill and `AGENTS.md` for the harness itself).

This is **collaborative work**: prompt for decisions and ask questions wherever
there is real uncertainty. Follow the input code's own style/language conventions —
do not impose a house style on the payloads; only the rAP wrapper/annotations use
rAP conventions.

## Two scenarios

- **Scenario 1 — loose scripts.** The user has processing scripts not yet in a
  pipeline. Elicit or co-author a project plan (see `references/project-plan-template.md`),
  design the DAG, then author a clean, commented annotated rAP script.
- **Scenario 2 — existing SLURM workflow.** The user has a hand-rolled submit
  script using `sbatch --dependency=afterok:$jid` (etc.). Recover its DAG, port it
  to rAP, and **differentially test**: run the original and the rAP port on identical
  inputs and compare outputs under a user-approved identity contract.

## Checkpoints (stop for sign-off)

1. **Project plan / pipeline DAG** — before writing the rAP script.
2. **Identity contract** [Scenario 2] — before trusting the output comparison.
3. **Final pipeline review** — before handing back.

Plus: prompt on any genuinely ambiguous conversion decision (see *Dependency
mapping gap*). Otherwise work autonomously, iterating until green.

## When the input looks broken or buggy — keep a LIGHT TOUCH

**Do not assume the user is wrong, and do not play reviewer.** These pipelines span
many bioinformatics / NGS disciplines; methods are rarely standardized and users
often bring novel, deliberate approaches. An unfamiliar ordering, tool, or parameter
is almost always an intentional method — **not** a bug. Precision over recall: a
false alarm on a real researcher's novel pipeline is worse than staying quiet.

- **Convert faithfully, always.** Never silently refactor or "fix" a step. The port
  must reproduce the original's behavior exactly (bugs included).
- **Flag only the most obvious, high-confidence errors** — a structural mistake that
  would be wrong in essentially *any* pipeline of that type, never a debatable method
  choice. Judge with your own domain knowledge of the pipeline in front of you; there
  is no checklist to apply. (Illustrative only, not rules: a step consuming a file
  before the step that creates it; an obvious domain ordering error such as mapping
  reads before adapter trimming.) **When you are not confident it is a mistake, say
  nothing.**
- **When you do flag, ask concretely and let the user decide.** Show the behavior and
  your single specific suspicion; offer a fix but apply nothing unasked. E.g.:
  > The port behaves exactly like your original, but it maps reads before trimming
  > adapters — is that intentional, or should trimming run first? I've left it as-is.
- **Record the decision.** Write each suspected issue and the user's ruling
  (intentional / fix applied) to a short notes file beside the pipeline
  (`MIGRATION_NOTES.md`), so it is not re-raised and there is a trail.

The differential test keeps this safe: the faithful port reproduces the original's
output, so a flag is always a question about the user's *existing* behavior, never a
change you made.

**Optional best-practice suggestions (never insist).** For a *well-established*
analysis type you recognize (e.g. RNA-seq, variant calling, ChIP-seq), you may
briefly offer a known best practice (a standard QC step, a normalization) or a
commonly useful addition (a PCA / scatter / MA QC plot). Frame every such note as an
optional suggestion the user can ignore — one line, never a lecture, never a
blocker, and never added without asking. Record accepted ones in `MIGRATION_NOTES.md`.

## Before handing back — a self-test gate

Never return a port you have only reasoned about. Before handback:
- Run the port in a **clean** sandbox (`ss_new_workspace`) and confirm it completes
  without error and produces the expected outputs.
- **Scenario 2:** run the ORIGINAL and the PORT in separate workspaces and
  `compare_outputs` under the identity contract — they must match (or you must have
  surfaced the intended difference).
- **Scenario 1:** run your proposed sanity checks (outputs non-empty, expected
  files/formats, invariants).
- **Prefer an INDEPENDENT check.** A conversion validated only by you, in the same
  context you built it, is not yet proven. Have a **fresh agent** (or a clean
  from-scratch re-run) execute the port against the original and confirm the result.
  This is the same discipline as the `eval/migration/` fuzz harness; use it as the
  gate, not an afterthought.

Hand back only once this gate is green, and report exactly what you ran and the
result (the differential verdict, the sanity checks, and any flagged issues).

**No shell to run the gate? (a chat-only agent.)** Then you can draft and review the
port but **cannot validate** it — say so plainly, mark the port **unvalidated**, and
hand it to a shell-capable agent or human to run the gate before any cluster run.
Never present an unrun port as tested.

## Where the harness lives — set `$SL` first

Every command below runs the slurmless harness by path, so first resolve its root
into `$SL` (it is **not** the user's CWD — their CWD is their own pipeline). `$SL` is
the **slurmless directory** — the one that holds `bootstrap.sh`, `test/`, and
`skills/`; in a SmartSlurm checkout that is `SmartSlurm/slurmless/`. Set it to that
absolute path:

```bash
export SL=/path/to/SmartSlurm/slurmless      # the dir with bootstrap.sh, test/, skills/
```

> *Claude-plugin users only:* `$SL` is `${CLAUDE_PLUGIN_ROOT}` (set only under the
> Claude plugin — ignore it otherwise): `export SL="${CLAUDE_PLUGIN_ROOT}"`.

The SmartSlurm checkout under test is auto-resolved by `bootstrap.sh` (in-tree parent
→ sibling `../SmartSlurm` → clone upstream). To pin one, set `export SMARTSLURM_ROOT=<path>`.
*(Claude-plugin users who set the **SmartSlurm checkout** config: `${user_config.smartslurm_path}`.)*

## First move, always

```bash
bash "$SL/bootstrap.sh"   # green clean_2step baseline => harness is set up; red => fix that first
```

## Method

### Step 1 — Recover the DAG (Scenario 2)

Do **not** statically parse the submit script. Run it under the register-don't-run
harness (no payloads execute) and read the recorded DAG — this is robust to dynamic
job-id capture, loops, conditionals, and arrays because it actually executes the
submission logic:

```bash
source "$SL/test/lib/harness.sh" && ss_activate
ss_new_workspace /tmp/ma && cp <user's submit.sh + step scripts> .
ss_wf_activate
bash ./submit.sh            # registers every job; nothing runs
bash "$SL/skills/migration-assistant/tools/extract_dag.sh" > dag.tsv
```

`dag.tsv` has one `NODE <name> <array?> <command>` per job and one
`EDGE <name> <deptype(conj)> <depname>` per dependency, with job-ids resolved to
step names. Review it with the user (checkpoint 1).

**When the real pipeline is hidden inside a monolithic worker.** Many real submit
scripts fan out ONE big per-sample job that runs the whole pipeline sequentially
inside a single worker script (trim → map → … → QC), plus maybe a fan-in cleanup.
`extract_dag` then shows just one `NODE` per sample (+ the fan-in) — the real steps
live *inside* that worker, invisible to the recorded DAG. Recover them by **reading
the worker**: each logical step is a span of its commands bounded by the files it
reads and writes, and the edges are those file hand-offs (a step depends on whichever
earlier step produced the files it consumes). Decompose into rAP steps on those
boundaries, parallelizing branches that read the same input and write disjoint
outputs. This is your own reasoning, not a tool output, so walk the proposed step
list through with the user at checkpoint 1 before emitting.

### Step 2 — Map the DAG to rAP

rAP step syntax (full cheat-sheet in `references/rap-markers.md`):

```
#@<stepNum>,<dependsOnStep>,<stepName>,,<inputsVar>,<sbatch options>
<the step's command(s), verbatim from the original>
#@end
```
Two marker fields trip conversions up — get them exact:
- **`<dependsOnStep>`**: the step number this one waits for, or **`0`** for a root step
  with no dependency — never leave it empty.
- **`<sbatch options>`**: the **literal `sbatch …` string**, beginning with the word
  `sbatch` (e.g. `sbatch -p short -c 2 --mem 8G -t 2:0:0`) — not the bare flags alone.
  `<inputsVar>` (the field just before it) is optional; leave it empty if unused.

`for` loops around a block drive per-sample / per-chunk fan-out; the
`<dependsOnStep>` field encodes the edge.

Fold the DAG's per-sample instances into logical steps and write a plan
(`references/plan-format.md`), then render it:
`bash "$SL/skills/migration-assistant/tools/emit_rap.sh" plan.txt > pipeline.sh`.
Fan-in **must** be a looped step (dependsOnStep is one step number,
so a single downstream step waits for all jobs of the fanned step it names) — you
cannot list multiple deps.

**Dependency mapping gap — surface these, don't guess.** rAP's `<dependsOnStep>`
is narrower than Slurm's grammar (essentially per-step *afterok* with fan-in):
- `afterok` + fan-in  → direct `<dependsOnStep>`.
- `afternotok` / `afterany` (always-run cleanup) → model via `checkRun`/failure
  handling, **not** a step dep — ask the user.
- `?`-OR deps, `after`+time, `aftercorr` across arrays → no direct rAP form; flag
  as a design choice (restructure, or document as a limitation).

**Conditionals become driver `if` guards, not runtime branches.** rAP decides which
steps EXIST when the driver runs (the driver is plain bash around `#@` blocks). So an
original's runtime choices — skip a step when an input is absent, `full` vs `qc`
mode, an optional output — become `if` blocks *around* the `#@` blocks (the step is
emitted or not), and a downstream `<dependsOnStep>` list naturally drops the steps
that were not submitted. Do not branch *inside* a step; keep each step body faithful.

**Write the step body as natural, readable bash — it round-trips verbatim.** A
`#@ … #@end` block takes an ordinary multi-line bash chunk exactly as the user wrote it:
several statements, comments, loops, pipes, nested quotes, backslash line-continuations,
even an embedded here-doc. `#@end` emits the body byte-for-byte into the per-job script,
so there is nothing to escape or reformat — just keep the payload faithful. Putting a
step's commands in a helper script and calling `bash <script>.sh` is a fine style choice
(and the obvious move when the input is already a set of step scripts), but it is **not**
required for correctness. When a step needs a change you flagged and the user approved,
edit it in the helper script or inline — either is fine.

Verify the emitted driver's structure before running it:
`bash "$SL/skills/migration-assistant/tools/parse_rap_dag.sh" pipeline.sh` prints the
step DAG (each step's name + resolved dependency names) so you can confirm it matches
the plan you reviewed at checkpoint 1.

### Step 3 — Validate in the sandbox

- Run the rAP port: `ss_run_pipeline "./pipeline.sh <args>" "<sbatch opts>"`.
- **Tiered execution**: real payloads where the tool+input resolve; otherwise stub
  (`SS_WF_STUB="<step-glob>"`, or `SS_WF_STUB_MISSING=1`) so wiring validates without
  every tool installed. A stub validates the DAG, not the data.
- **Resource-sim**: `MOCK_FAIL_JOB=<name> MOCK_FAIL_MODE=oom|timeout|nonzero` forces
  a step to fail, to check the port's failure handling.
- **Scenario 1 bar**: runs e2e clean **and** passes sanity checks you propose
  (outputs non-empty, expected files/formats, basic invariants) — exit 0 alone can
  hide a silent no-op (see `wf_exit0_empty`).

### Step 4 — Differential test (Scenario 2)

Run the original and the rAP port in **separate workspaces** (isolation is load-
bearing — see below), on identical inputs and fixed seeds. Propose an **identity
contract** (`references/identity-contract.md`): which output files are authoritative
+ normalization rules for volatile bits (timestamps, job ids, absolute paths, line
ordering). On the user's approval (checkpoint 2):

```bash
# arm 1 — original (own workspace): ss_wf_activate; bash submit.sh; ss_wf_drain
# arm 2 — rAP port (own workspace): emit_rap.sh plan.txt > pipeline.sh; ss_run_pipeline ...
bash "$SL/skills/migration-assistant/tools/compare_outputs.sh" "$origDir" "$rapDir" contract   # MATCH per file, non-zero on mismatch
```
Report residual diffs. If you had to strip a *data* field to get a match, that is a
finding to raise, not a rule to add.

## Isolation contract (avoid crosstalk between the two arms)

The two arms must not contaminate each other:
- **Separate `ss_new_workspace` per arm** → own `MOCK_SLURM_STATE`, CWD, record DB.
- The rAP arm runs via `ss_run_pipeline` (which clears `SS_WF_MODE`); the original
  arm uses `ss_wf_activate`. Never leave `SS_WF_MODE` set across an rAP run.
- Never `smartslurm activate` (its `sbatch`→`ssbatch` alias) during the original run.
(The `wf_isolation` and `wf_jobseq` blocks guard these.)

## Data & tools

The user supplies an environment spec (conda env.yml / container / module list) so
the real tools exist; downsample their real inputs or synthesize tiny inputs per
each step's declared formats. Prompt when a tool or input can't be resolved.

## Hard rules

- Never modify SmartSlurm's `bin/` to make something pass (slurmless rule).
- Scratch only — never a real `~/.smartSlurm` or a real cluster.
- Keep the payloads in the user's style; only the rAP wrapper is rAP-conventional.

## Tools (this skill's `tools/`)

- `extract_dag.sh` — print the registered workflow DAG (nodes + name-resolved edges)
  of the ORIGINAL submit script, run under `ss_wf_activate` (Scenario 2, Step 1).
- `parse_rap_dag.sh <driver>` — the read-back: print the `#@` step DAG (each step's
  name + resolved dependency names) of an rAP driver, to verify an emitted port's
  structure against the plan. Works on any annotated rAP script.
- `emit_rap.sh <plan>` — render a logical plan (`references/plan-format.md`) into an
  annotated rAP script: step numbers, dependsOnStep edges, fan-out loops, `#@end`.
  You author the plan from the DAG (fold per-sample instances into logical steps,
  parameterize commands over `$s`); the tool does the mechanical rendering.
- `compare_outputs.sh <origDir> <rapDir> <contract>` — differential test: diff two
  runs' authoritative outputs under an identity contract (`references/identity-contract.md`),
  normalizing volatile fields. Exits non-zero on any mismatch.

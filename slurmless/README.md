# slurmless

**A Slurm-free test harness for [SmartSlurm](https://github.com/ld32/smartSlurm) — see the [SmartSlurm README](../README.md) for the tool this harness exercises.**

slurmless runs SmartSlurm's **unmodified** tools — `runAsPipeline`, `ssbatch`,
`cleanUp.sh`, `checkRun`, `checkRunGrid`, `diagnose.sh`, `estimateResource`,
`jobRecordSchema.sh`/`jrRepair.sh` — on a machine with **no Slurm scheduler** (a
laptop, a CI runner, or an AI-agent sandbox), while still executing real job
payloads. That makes it possible to develop and regression-test SmartSlurm —
pipeline conversion, dependency wiring, failure attribution, the status grid, the
rerun menu, the jobRecord v1→v2 migration, and the resource-estimation learning
loop — entirely off-cluster.

It works by interposing **mock Slurm commands** (`sbatch`, `sacct`, `srun`,
`squeue`, `scancel`, …) on `$PATH` ahead of the real binaries. SmartSlurm is
**not modified**: the mocks actually execute each job's payload, so the real
`cleanUp.sh` trap, the real `.success`/`.failed` flags, and the real jobRecords
are produced exactly as on a cluster.

## Contents
- [Who it's for](#who-its-for)
- [Quick start](#quick-start)
- [What you can test](#what-you-can-test)
- [Failure injection](#failure-injection)
- [The three skills](#the-three-skills)
- [Migration Assistant](#migration-assistant)
- [Adversarial review](#adversarial-review)
- [Install as a plugin](#install-as-a-plugin)
- [Layout](#layout)
- [Relationship to SmartSlurm](#relationship-to-smartslurm)
- [Learn more](#learn-more)

## Who it's for

- **SmartSlurm developers** — a fast, Slurm-free inner loop and regression net for
  work on `runAsPipeline`, resource estimation, the jobRecord schema, logging, and
  the monitor UI.
- **Pipeline builders (bioinformaticians)** — a safe place to convert a hand-rolled
  SLURM workflow (or loose scripts) to `runAsPipeline` and prove it behaves before
  running on real HPC, driven by the **Migration Assistant**.
- **AI agents** — a self-contained environment to develop/test SmartSlurm, port
  pipelines, and adversarially review changes. Three skills ship under `skills/`
  and the repo installs as a Claude Code plugin; the same skills are usable by any
  agent via [`AGENTS.md`](AGENTS.md).

## Quick start

Point `SMARTSLURM_ROOT` at a SmartSlurm checkout and run a block:

```bash
export SMARTSLURM_ROOT=/path/to/SmartSlurm
./bootstrap.sh                      # baseline sanity (runs the clean_2step block); must pass
./test/run_tests.sh --list         # every test block and what it checks
./test/run_tests.sh migrate_v1     # run one block
```

`bootstrap.sh` auto-resolves a SmartSlurm checkout when `SMARTSLURM_ROOT` is unset
(a vendored parent, a sibling `../SmartSlurm`, or a shallow clone of upstream).
When slurmless is vendored inside a SmartSlurm checkout (at `SmartSlurm/slurmless/`),
run the same commands as `./slurmless/bootstrap.sh` / `./slurmless/test/run_tests.sh`
and the enclosing checkout is used automatically.

> A single block is usually quick; the **full suite is slow by design** (the mock
> scheduler sleeps through SmartSlurm's cleanup/backoff counters), so pass specific
> block names in a time-boxed environment. Validate anything schema/awk-related under
> **both `gawk` and `mawk`** — mawk silently ignores `{n,}` interval regexes.

## What you can test

The ~65 blocks (`./test/run_tests.sh --list`, grouped via `--groups`) cover, among others:

| Area | Representative blocks |
|---|---|
| Pipeline conversion & dependency wiring | `clean_2step`, `wf_*` (afterok/arrays/wait/scancel/…), `nested_fanout`, `ragged_axes` |
| Resource estimation (the learning loop) | the `estimator` group — `scaling_linear`, `noise_fit`, `extrapolate_*`, `contaminate_*`, `failure_floor`, `resubmit_convergence`, `fitqc` |
| jobRecord v1→v2 migration & schema | `migrate_v1`, `jr_drift_guard`, `cross_pipeline`, `legacy_pooling`, plus the property/fuzz `test/jr_conversion_stress.sh` and `test/jr_migration_gaps_guard.sh` |
| Failure attribution & escalation | `oom_injection`, `oomoot_escalate`, `hardkill`, `fail_exit0_empty`, `known_broken_swallowed_done` |
| Monitoring UI (`checkRun`/`checkRunGrid`) | `checkrun_efficiency`, `diagnose`, `fate_reconcile`, and the PTY-driven `test/checkrun_ui_tests.sh` |
| Migration Assistant | the `ma_*` blocks (`ma_extract_dag`, `ma_emit_rap`, `ma_compare`, `ma_differential`) |

`run_tests.sh` exits non-zero if any check fails, so it doubles as a CI gate.

## Failure injection

The mocks can deterministically fail a chosen step so you can exercise SmartSlurm's
attribution and rerun logic without a real cluster:

- `MOCK_FAIL_JOB=<step> MOCK_FAIL_MODE=oom|timeout|nonzero` — the classic OOM / time
  limit / non-zero-exit failures (drives `.failed`, the diagnose contract, and the
  resubmit/escalation loop).
- `MOCK_FAIL_MODE=sigkill|sigterm` — **hard-kill** a step mid-run (no clean exit),
  the scenario the `fate_reconcile` / `hardkill` blocks and `bin/jobFate.sh` recover
  from; the mock `sacct` supports batched `-j id1,id2,…` plus lag / node-fail states.

## The three skills

Shipped under `skills/` (plain-Markdown playbooks usable by any agent; see
[`skills/README.md`](skills/README.md)):

- **`slurmless-harness`** — run or develop with this harness (run blocks, add a
  fixture, reproduce an OOM/timeout/hard-kill, debug a tool).
- **`migration-assistant`** — convert a non-SmartSlurm pipeline to `runAsPipeline`
  and validate it in the sandbox (see below).
- **`smartslurm-adversary`** — adversarially review a SmartSlurm change before an
  upstream push, hunting **silent** bugs (dropped jobRecord rows, improper pruning,
  v1↔v2 back-compat breaks, wrong estimates) using the harness as the weapon (see
  [Adversarial review](#adversarial-review)).

## Migration Assistant

The **Migration Assistant (MA)** moves a pipeline **onto** SmartSlurm: it converts
a workflow to `runAsPipeline` (rAP) and proves the port off-cluster here before you
touch a cluster.

- **An existing SLURM workflow** (hand-rolled `sbatch` + `--dependency`) → MA
  recovers its job DAG, ports it to rAP, and **differentially tests** it (runs your
  original and the port side-by-side and confirms identical outputs under an
  identity contract you approve).
- **Loose scripts with no pipeline** → MA designs the DAG with you and writes the
  annotated rAP script.

MA converts **faithfully** — it never silently rewrites your logic; bugs are
preserved and *flagged* for your decision — and self-tests the port in a clean
sandbox before handing it back. It adds a **user-workflow mode** to the mocks
(register-don't-run of an unmodified submit script → a `wfdrain` executor runs the
real DAG, emulating the full `--dependency` grammar, arrays, `--wait`, and live
`scancel`/`squeue`), enabled behind `ss_wf_activate`. Verify it end-to-end:

```bash
bash skills/migration-assistant/examples/ma_dryrun.sh   # converts a tiny workflow + differentially tests; exit 0 = ok
```

See [`skills/migration-assistant/README.md`](skills/migration-assistant/README.md).

## Adversarial review

For high-risk changes to SmartSlurm's silent-bug-prone internals (`runAsPipeline`,
`ssbatch`, `cleanUp.sh`, `estimateResource`, `jobRecordSchema`), the
**`smartslurm-adversary`** skill/agent runs the harness *to try to break the
change* — row conservation, prune safety, v1↔v2 back-compat, cross-pipeline
isolation, estimate equivalence, gawk/mawk parity — and leaves behind reproducible
findings plus teeth-checked regression guards. Invoke the skill, or run the
independent reviewer agent in [`agents/smartslurm-adversary.md`](agents/smartslurm-adversary.md).

## Install as a plugin

slurmless is packaged as a Claude Code plugin (named `slurmless`) that bundles the
skills **and** the harness they run on (Claude Code 2.1.275+):

```text
/plugin install slurmless --marketplace ntc-agnt/slurmless_smartSlurm_testing
```

or in two steps on any version:

```text
/plugin marketplace add ntc-agnt/slurmless_smartSlurm_testing
/plugin install slurmless@slurmless-marketplace
```

During install you can optionally set a **SmartSlurm checkout** path; leave it blank
and the harness auto-resolves a vendored/sibling checkout or clones upstream on the
first `bootstrap.sh`. **Not just Claude** — the skills are plain-Markdown playbooks
any agent (OpenAI/Codex, Gemini, Cursor, Aider, …) or a human can run with no plugin;
see the *"Using the skills with any agent"* section of [`AGENTS.md`](AGENTS.md), and
[`PACKAGING.md`](PACKAGING.md) for how the plugin is built and kept agent-neutral.

## Layout

| Path | What it is |
|------|------------|
| `bootstrap.sh` | One-command "is the sandbox green?" baseline (runs `clean_2step`). |
| `test/run_tests.sh` | The pipeline + resource-model + migration test suite (CI exit code). |
| `test/checkrun_ui_tests.sh` | The interactive-monitor (`checkRun`/`checkRunGrid`) UI suite, driven over a pseudo-terminal. |
| `test/jr_conversion_stress.sh` | Property/fuzz test for the jobRecord v1→v2 conversion + prune utilities. |
| `test/jr_migration_gaps_guard.sh`, `test/jr_curate_adversary*.sh` | Regression guards from the jR-v2 + curation adversarial reviews. |
| `test/lib/harness.sh` | Environment activation, the resource-model API, and assertion helpers. |
| `test/mockSlurm/` | The mock Slurm commands (`sbatch`, `sacct`, `srun`, `squeue`, …) + `wfdrain` (user-workflow DAG executor). |
| `test/fixtures/`, `test/models/` | Tiny annotated pipelines / resource-curve models for the estimator tests. |
| `skills/` | The three shipped skills (see [`skills/README.md`](skills/README.md)). |
| `agents/` | Independent agent definitions (e.g. `smartslurm-adversary`). |
| `.claude-plugin/` | Plugin + marketplace manifests that make this repo installable. |
| `eval/migration/` | Agent-in-the-loop fuzz eval for the conversion workflow. |
| `AGENTS.md` / `CLAUDE.md` / `PACKAGING.md` | Agent-neutral entry guide / project rules / plugin-build + vendoring design. |

## Relationship to SmartSlurm

slurmless tests SmartSlurm's **unmodified** tools, so it tracks a specific SmartSlurm
baseline (`test/version.txt`). It is **vendored into SmartSlurm** at
`SmartSlurm/slurmless/` (a point-in-time snapshot) — this copy — so SmartSlurm carries
its own off-cluster test harness. It is also developed as a standalone repo,
[`ntc-agnt/slurmless_smartSlurm_testing`](https://github.com/ntc-agnt/slurmless_smartSlurm_testing#readme);
with the jobRecords-v2 migration complete, development is consolidating in-tree. See
[`PACKAGING.md`](PACKAGING.md) and [`CLAUDE.md`](CLAUDE.md) for the sync/vendoring
model, and the enclosing **[SmartSlurm README](../README.md)** and its
[Testing off-cluster guide](../docs/testing-off-cluster.md) for the tool side.

## Learn more

- **[SmartSlurm README](../README.md)** — the tool this
  harness exercises (install, concepts, the pipeline/monitor/estimation tooling).
- **[skills/README.md](skills/README.md)** — the three skills and how to use them
  (Claude plugin **or** any agent).
- **[CONTEXT.md](CONTEXT.md)** — setup, how it stays in sync with SmartSlurm, the
  harness API, failure injection, and gotchas.
- **[test/README.md](test/README.md)** — the full block catalog, user-workflow mode,
  the resource-model layer, fidelity tiers, and how to add a fixture.
- **[test/mockSlurm/README.md](test/mockSlurm/README.md)** — the per-command mock
  contracts (default **and** user-workflow mode).
- **[PACKAGING.md](PACKAGING.md)** — how the plugin is built, the agent-neutral
  options and sync model, and the move into SmartSlurm.

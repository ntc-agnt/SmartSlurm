# Planning: slurmless as a manual local pipeline manager

**Status:** planning only (no code). **Scope:** a *minimal-enablement*, **unsupported**
mode — not a promoted or officially supported feature. The goal is only that the docs +
code be sufficient for a user who *chooses* to run pipelines locally (Mac/Linux, no
scheduler) with dependency management, by hand, without an AI agent. For real workloads,
a real scheduler is still the right tool.

## Premise

slurmless's mock-Slurm + `runAsPipeline` machinery is, at its core, a **dependency-aware
pipeline runner for a computer with no scheduler**. A user could write a `#@`-annotated
driver (or bring a hand-rolled `sbatch … --dependency` script) and run it locally, with
rerun/resume and logging. This document assesses how close that is to usable by hand and
what would make it *straightforward*.

## Current state

### What already works (no new engine code needed)
- **Mock Slurm commands** (`sbatch`/`sacct`/`srun`/`squeue`/`scancel`) run the **real job
  payloads** locally and emit real `.success`/`.failed` flags + logs.
- **`runAsPipeline`** converts a `#@ … #@end` driver into a dependency DAG and runs it
  locally via the mock `sbatch`; **rerun/resume** works via the flag folder (`checkRun`).
- **User-workflow mode** (`ss_wf_activate` / `ss_wf_drain`) runs an *unmodified*
  hand-rolled `sbatch … --dependency` submit script locally — register the DAG, then
  drain it topologically.
- **Resource learning** (`ssbatch` estimation) persists in `~/.smartSlurm` — a real edge
  over a plain shell script / `make`.

### What blocks straightforward manual use
1. **The only entry point is a disposable-sandbox activator.** `ss_activate` is built for
   CI/tests and does four things a real local user must not accept:
   - redirects `HOME` into throwaway scratch (loses `~/.smartSlurm` config + learned
     estimates each run);
   - forces a scratch workspace (outputs land in a throwaway dir, not the project);
   - `sudo apt-get install gnuplot` (assumes apt+sudo; wrong on macOS);
   - `ln -sf bash /bin/sh` **system-wide** (needs root; unacceptable on macOS).
   The `SS_NO_INSTALL` / `SS_NO_SH_REPOINT` opt-outs disable two of these, but HOME
   redirect + scratch-only remain, so `ss_activate` is unsuitable for real local use as-is.
2. **The mock `sbatch` runs jobs synchronously, in submission order.** Dependencies are
   satisfied by *ordering*, so independent branches run **serially** — no parallelism.
3. **`--mem` / `-t` are advisory locally.** They are captured only to *simulate*
   OOM/timeout; the payload otherwise just runs with whatever the machine has.
4. **Docs frame everything as testing SmartSlurm or AI-assisted migration** — there is no
   end-user "run my pipeline locally" guide.

## Required addition #1 — a non-destructive local activation mode (the central piece)

A **local activate** mode, essentially *"`smartslurm activate` (cluster) **plus** stage
mock Slurm on PATH, **minus** the test-sandbox side effects."* It must:

- put the mock commands **and** `SmartSlurm/bin` on `$PATH`, staged on a **neutral path**
  (no "SmartSlurm" substring) so `ssbatch`'s "find the real sbatch" probe
  (`which -a sbatch | grep -v SmartSlurm`) resolves to the mock — the harness already does
  exactly this staging; reuse it;
- use the user's **real `~/.smartSlurm`** (persistent config + resource learning);
- run in the user's **real working directory** (outputs persist);
- do **no** `sudo`/`apt`, and **no** system `/bin/sh` repoint;
- be `source`-d into the shell and be **reversible** (deactivate restores PATH/env).

This single mode is the bulk of making manual use viable, and it is a clean sibling of
`ss_activate`, not a rewrite.

## Other gaps to close

1. **`/bin/sh` must be bash — the macOS gate.** SmartSlurm's `#!/bin/sh` scripts need
   bash; local mode cannot repoint `/bin/sh`. Needs a portable answer: a non-destructive
   `sh`→bash **shim on PATH** (no root) or `#!/usr/bin/env bash` shebangs, plus documenting
   that macOS users install a **modern bash** (system bash is 3.2; SmartSlurm likely uses
   4+ features). Without this, "straightforward on macOS" fails immediately.
2. **Parallelism (optional but the main value-add).** Run ready jobs in parallel up to N
   cores respecting the DAG (à la `make -jN`). The mock's serial model is a
   test-determinism choice; real local use benefits from parallel branches. This is a
   genuine feature addition, not packaging.
3. **Resource semantics.** Minimum: document that `--mem`/`-t` are not enforced locally.
   Optional: opt-in enforcement via `ulimit` / `timeout`.
4. **Async / status / cancel (optional).** Synchronous execution blocks the shell for the
   whole run; `squeue`/`scancel` are near no-ops. `checkRun` already gives status/resume,
   so the minimal path is "run synchronously, inspect/resume with `checkRun`." A
   background/detached run mode would be a nice-to-have.

## Documentation gap (the main non-code deliverable)

A short, standalone **"Run pipelines locally without a scheduler"** guide: install (clone
SmartSlurm, modern bash, the local-activate step); write a `#@` driver (or bring a
hand-rolled `sbatch`+`--dependency` script); run it; check status / rerun with
`checkRun`. No AI agent, no plugin, no sandbox framing. Must carry an **unsupported-mode
disclaimer** (limits not enforced; serial unless parallel is added; prefer a real
scheduler for real workloads).

## Prioritized plan (minimal enablement)

1. **Non-destructive `local activate`** — persistent HOME, user's cwd, PATH-staged mocks +
   bin, reversible, no root/apt. *(highest leverage)*
2. **Portable `/bin/sh`→bash handling** (PATH shim + "install modern bash" note) — the
   macOS gate.
3. **One-page end-user "local pipeline" doc** with the unsupported-mode disclaimer.
4. *(optional)* **Parallel execution** (`-jN` ready-job scheduling) — the one feature that
   makes it genuinely better than a shell script.
5. *(optional)* Background run + `checkRun`-based status.

## Key conclusion

**No core engine work is required** — the dependency manager already exists (DAG,
rerun/resume, logging, estimation). The work is (a) one new *non-sandbox* activation
mode, (b) solving `/bin/sh`=bash portably for macOS, (c) a short user doc, and — only to
beat a plain script — (d) optional parallel execution.

## Open decisions
- Where the local-activate entry lives: a `smartslurm activate --local` subcommand vs. a
  standalone `slurmless`/`activate` script sourced by the user.
- Whether to ship parallel execution at all (it is the line between "a documented hack"
  and "a small but real local tool").
- How much of the mock surface (`squeue`/`scancel`) to make meaningful locally, which is
  only worth it if a background/async run mode is added.

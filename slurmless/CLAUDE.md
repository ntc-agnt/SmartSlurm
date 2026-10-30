# CLAUDE.md

You are working in **slurmless**, a Slurm-free test harness for SmartSlurm.

**Read [`AGENTS.md`](AGENTS.md) first** — it is the model-neutral session-startup
guide (what this is, the golden-path commands, how to add a test, failure
injection, and the drift model). This file only restates the rules most likely
to trip you up.

## Critical rules

- **Do not modify SmartSlurm's `bin/` to make a test pass.** The harness runs the
  *unmodified* tools; a failing test that reveals a real tool bug is a finding to
  report, not a tool to quietly patch. Change a tool only when the task is
  explicitly to change that tool — then update the affected fixtures/asserts.
- **Prove the baseline first:** `./bootstrap.sh` (runs `clean_2step`). If it is
  red, the environment is not set up — stop and diagnose before other work.
- **Run one block at a time** (`./test/run_tests.sh <block>`); the full suite is
  slow by design.
- **Scratch only.** Never aim the harness at a real `~/.smartSlurm` or a real
  cluster.
- **Vendoring into SmartSlurm:** slurmless is copied into `SmartSlurm/slurmless/`
  as a plain subdirectory (a point-in-time snapshot), **not** a `git subtree`.
  Until the jobRecords-v2 migration lands, this standalone repo is the source of
  truth: develop here, then re-snapshot into SmartSlurm
  (`git -C <smartslurm> ... ; git archive main | tar -x -C slurmless/`). Once the
  migration is complete, development moves into `SmartSlurm/slurmless/` directly
  and this standalone repo is archived.

## Skill

A task-oriented skill stub lives at `.claude/skills/slurmless-harness/SKILL.md`
(usable as plain Markdown by any agent). Invoke it in Claude Code with
`/slurmless-harness`.

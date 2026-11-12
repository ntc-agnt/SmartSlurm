<!--
  TRANSIENT HANDOFF NOTE from the NTC ecosystem overseer (EO) to the slurmless/SmartSlurm agent.
  DELETE THIS FILE in the same change that applies the edits below. It is not part of the tool.
  Placed on branch `claude/slurmless-source-of-truth-note` (NOT master — master is ld32's).
-->

# EO handoff — flip slurmless's "source of truth" to in-tree (concordantly)

**From:** NTC ecosystem overseer (EO) · **Date:** 2026-11-12
**For:** the agent that develops slurmless / SmartSlurm

## Why
slurmless has been merged into SmartSlurm (`slurmless/`) and the team has decided to
**develop it in-tree from now on and deprecate the standalone repo**
(`ntc-agnt/slurmless_smartSlurm_testing`). But the vendored docs still carry the
*pre-merge* framing — they say the **standalone repo is the source of truth "until the
jobRecords-v2 migration lands," re-snapshot into SmartSlurm, archive the standalone
"afterward."** That stale conditional is now the source of confusion about where to
develop. The condition is met; make the docs say so.

## The ask
Update **`slurmless/CLAUDE.md`** and **`slurmless/AGENTS.md`** so they state **one**
consistent thing: **`SmartSlurm/slurmless/` (in-tree) is the source of truth; develop
there directly; the standalone repo is archived; the re-snapshot workflow is retired.**
Fix them **concordantly** — the same claim is duplicated in several spots (listed
below), so reconcile *all* of them, not just the first. Keep the wording **generic**
(this is a property of the tool, not NTC-specific — do not add NTC/pipeline context
in-tree).

Land it on a branch and let ld32 integrate (per `slurmless/CLAUDE.md` → "master is
ld32's"). Run `./slurmless/bootstrap.sh` (or `./bootstrap.sh` in-tree) to confirm a
green baseline after the edits, and **delete this handoff file in the same commit**.

---

## Drafted patch (apply, then reconcile the concordance items)

### 1. `slurmless/CLAUDE.md` — the "Vendoring into SmartSlurm" bullet

REPLACE:

```
- **Vendoring into SmartSlurm:** slurmless is copied into `SmartSlurm/slurmless/`
  as a plain subdirectory (a point-in-time snapshot), **not** a `git subtree`.
  Until the jobRecords-v2 migration lands, this standalone repo is the source of
  truth: develop here, then re-snapshot into SmartSlurm
  (`git -C <smartslurm> ... ; git archive main | tar -x -C slurmless/`). Once the
  migration is complete, development moves into `SmartSlurm/slurmless/` directly
  and this standalone repo is archived.
```

WITH:

```
- **Source of truth: `SmartSlurm/slurmless/` (in-tree).** slurmless now lives in
  SmartSlurm as a plain subdirectory and is developed there directly, versioned with
  the engine — one commit, so the harness can't drift from the tools it tests. The
  former standalone repo (`slurmless_smartSlurm_testing`) is **archived**, and the old
  "develop standalone, then re-snapshot into SmartSlurm" workflow is **retired** — do
  not re-snapshot.
```

### 2. `slurmless/AGENTS.md` — the intro paragraph (currently ~lines 17–20)

REPLACE:

```
It is vendored into SmartSlurm at `SmartSlurm/slurmless/` as a plain subdirectory
(a point-in-time snapshot of this standalone repo, **not** a `git subtree`). Until
the jobRecords-v2 migration lands, develop here and re-snapshot into SmartSlurm;
afterward, development moves into `SmartSlurm/slurmless/` and this repo is archived.
```

WITH:

```
It lives in SmartSlurm at `SmartSlurm/slurmless/` as a plain subdirectory and is
**the source of truth** — develop there directly, versioned with the engine (one
commit, so the harness can't drift from the tools it tests). The former standalone
repo is archived; the re-snapshot workflow is retired.
```

### 3. `slurmless/AGENTS.md` — the "Hard rules" bullet (currently ~lines 170–172)

REPLACE:

```
- The vendored copy in SmartSlurm is a plain-subdirectory snapshot of this repo
  (not a `git subtree`): until the v2 migration lands, develop here and re-snapshot
  into `SmartSlurm/slurmless/`; afterward, develop there directly.
```

WITH:

```
- Develop slurmless **in-tree at `SmartSlurm/slurmless/`** — that is the source of
  truth. The standalone repo is archived; there is no re-snapshot step.
```

---

## Concordance items — reconcile these so nothing still implies "standalone is primary"

- **`slurmless/AGENTS.md` "Session startup" #1** — "Vendored (`SmartSlurm/slurmless/`):
  `SMARTSLURM_ROOT` auto-resolves. Standalone: `export SMARTSLURM_ROOT=…`." Keep the
  in-tree path as the normal case; demote "Standalone" to a legacy aside (it's archived).
- **`slurmless/AGENTS.md` "Drift" note** — "`test/version.txt` records the validated
  baseline **for standalone runs**." Reword to the in-tree baseline.
- **`slurmless/CLAUDE.md` "Current program state"** — "jobRecords-v2 migration: wrapping
  up." If the migration has in fact landed, update it (confirm with ld32); if it's still
  in flight, that's fine — but it must no longer gate *where development happens*.
- **Plugin install coordinates still point at the deprecated standalone marketplace.**
  Repoint to the SmartSlurm-hosted plugin (`PACKAGING.md` already specifies the
  git-subdir source `url: ntc-agnt/SmartSlurm`, `path: slurmless`):
  - `slurmless/README.md:104,110`
  - `slurmless/PACKAGING.md:31,33`
  - `slurmless/skills/migration-assistant/README.md:25,28`
  - `slurmless/.claude-plugin/plugin.json` `homepage` + `repository`
    (→ `https://github.com/ntc-agnt/SmartSlurm`)

## Optional (generic hygiene, nice-to-have in-tree)
A one-liner in `AGENTS.md`'s pre-push rules: *"A change to a SmartSlurm `bin/` tool
should come with a slurmless test block that fails without it; the `smartslurm-adversary`
skill is the pre-push review for silent (exit-0) regressions."* This is generic good
practice for any contributor — fine in-tree. (The NTC-policy framing of this rule lives
in EO context, not here.)

## What EO has already done (for your awareness; no action needed in-tree)
EO's own catalog + mirrored skills (`slurmless-harness`, `smartslurm-adversary`) now say
"authoritative lives in-tree at `SmartSlurm/slurmless/`"; they are thin pointers refreshed
from the in-tree commit, not a competing spec. Keep the in-tree docs authoritative and
EO will track them.

# Plan: `smartslurm config` — structured config editing + overlay config model

> **Status (2026-10-30):** Planning complete and approved by the user; **no code
> written yet**, deliberately deferred. Originally gated on "wait for jobrecords-v2
> to merge." Since then **ld32 reverted jobrecords-v2 (#131) and add-slurmless
> (#132)**; v2 is being re-landed via `origin/fix/jobrecords-v2-migration`
> (hardened schema API), and slurmless re-add is pending. See **Current
> dependency status** at the bottom. Shared here so the instance planning the
> resubmission organization has this context. This doc is a planning artifact on a
> scratch branch — not intended to merge as-is.
>
> **Update (2026-10-31):** implementation plan reviewed against the live v2 branch
> (`fix/jobrecords-v2-migration`). Findings folded in below (corrected sourcing-site
> list; a JR_REF_CLASS load-order issue not previously noted). **Locked decisions:**
> build this ONLY after PR 1 (v2) **and** PR B (slurmless subdir) land on
> `ld32:master`; put the shared loader `ssLoadConfig()` in the existing
> `bin/utils.sh`. Still **no code written.** Two sub-decisions remain open — see
> **Implementation decisions** below.

## Context

SmartSlurm's behavior is driven by `config/config.txt` (a sourced **bash** file:
`export VAR=value` scalars **plus** functions like `adjustPartition`,
`nextMemAfterFail`). Two problems motivate this feature:

1. **Hard-to-edit config.** The refactored jobRecords (`feat/jobrecords-v2`) adds
   regression pooling via one opaque variable, `JR_REF_CLASS="hg38=mammal mm10=mammal"`
   (a flat string of `ref=group` pairs read by `jrRefClass()` in
   `bin/jobRecordSchema.sh`). Users won't discover it, and the 60+ lines of
   partition settings are equally unfriendly to hand-edit. Users need a guided,
   QC'd way to make these edits.
2. **Config lifecycle is fragile.** Every tool sources config **exclusively**:
   `if [ -f ~/.smartSlurm/config/config.txt ]; then source <user>; else source <repo>; fi`
   — the user copy *fully replaces* the repo copy. So a user with a home config
   **silently misses new defaults** added upstream (the schema-migration problem),
   and editing the git-tracked repo copy risks `git pull` clobbering it.

**Decisions locked with the user:**
- **Overlay config model** (defaults + a small user-diff file) — not full replacement.
- **Generic CLI + guided editors** — conda-style get/set/list/unset over scalar
  knobs, *plus* guided subcommands for `JR_REF_CLASS` (ref groups) and partitions.

**Outcome:** `smartslurm config …` lets users (and agents) make validated,
discoverable edits that survive updates; new upstream defaults are adopted
automatically; no manual file editing and no migration step on every update.

## Design

### 1. Overlay config model (resolves Q1 clobber + Q2 migration)
- Append to the **end of repo `config/config.txt`**: source a user override last so
  it wins — `[ -f "$HOME/.smartSlurm/config/user.conf" ] && . "$HOME/.smartSlurm/config/user.conf"`.
- Change the **sourcing sites** from the exclusive if/else to **always source the
  repo `config/config.txt`** (which now self-overlays `user.conf`), via a tiny
  shared loader `ssLoadConfig()` added to **`bin/utils.sh`** (locked 2026-10-31).
  **VERIFIED SITE LIST (corrected — the earlier "8" list was wrong):**
  7 bash sites use the exclusive if/else: `ssbatch`, `ssbatchSimple`,
  `runAsPipeline`, `checkRun`, `cancelAllJobs`, `runSimpleTest.sh`, and
  `estimateResource.sh` — plus the Python `reviewJobRecords.py`.
  - `estimateResource.sh` (line ~231) was MISSED by the earlier list: it sources
    config CONDITIONALLY (only if `nextMemAfterFail` is undefined) and preserves
    `smartSlurmJobRecordDir` across the source — keep that lazy guard + preservation
    when converting.
  - `calculateMemTime.sh` is **NOT** a sourcing site (earlier list wrongly included
    it): its only `config.txt` lines are COMMENTS; it reads config from the caller's
    environment. Do not add the loader there.
  - At code time, re-grep for the if/else pattern to confirm no site is missed, and
    add a drift-guard-style check (a missed site silently drops user overrides).
  - `reviewJobRecords.py` reads config in Python (`home_config`/`local_config`): make
    it read **effective** values by sourcing the repo config in a subshell
    (`bash -c 'set -a; . config.txt; …'`) rather than picking one file.
- Result: `user.conf` lives in `~/.smartSlurm/` (never git-tracked → pulls can't
  clobber, **Q1**), holds only changed keys, and new repo defaults load
  automatically since the repo file is always sourced first (**Q2** — no migration
  needed going forward).

### 1b. Load-order constraint for `JR_REF_CLASS` (critical — found 2026-10-31)
`JR_REF_CLASS` is defaulted in `bin/jobRecordSchema.sh` (~line 394) as
`JR_REF_CLASS="${JR_REF_CLASS-<default>}"` (respects a pre-set value). Tools source
`config.txt` and `jobRecordSchema.sh` **separately, in different orders**:
- `ssbatch` / `ssbatchSimple`: config BEFORE schema → a `user.conf` override wins. ✅
- `estimateResource.sh`: schema (line 11) BEFORE its lazy config source (231) → a
  `user.conf` override would **NOT** win. ❌
- `calculateMemTime.sh` / `cleanUp.sh`: source schema, never source config → rely on
  the caller's env.

So for the `refgroup` editor's override to win everywhere, `ssLoadConfig()` (hence
`user.conf`) must run **before** `jobRecordSchema.sh`'s default in every reader.
**Recommended fix:** call `ssLoadConfig` at the TOP of `jobRecordSchema.sh`, before
the `JR_REF_CLASS=${JR_REF_CLASS-...}` line — it is already the SSOT for the var and
every reader sources it. NOTE this touches a **v2 file**, so it sequences with the
v2 re-land. (Alternative: add the loader call before each `. jobRecordSchema.sh` in
the schema-consuming tools — more sites, no v2-file touch.) The end-to-end
`jrRefClass hg38 → mammal` harness test is what proves whichever path is chosen.

### 2. Config-key registry (`config/config.schema`)
Declarative, the single source of truth for what is user-editable (keeps the bash
*functions* out of the editable surface). One line per key:
`name|type|default|category|help` with `type` ∈ `int|string|path|enum[...]|bool`,
`category` ∈ `general|partitions|refgroups`. Powers `--list`, `--help`, and
`set`-time validation. Keys not in the schema but present in `user.conf` are shown
by `list` as **custom (unvalidated)**.

### 3. The `smartslurm config` CLI
- Dispatcher: add `config)` to the `case` in **`bin/smartslurm.sh`** + a help line,
  delegating to a standalone **`bin/smartSlurmConfig.sh`** (keeps the sourced shell
  hook small, mirrors how setup already delegates). This is the same dispatcher the
  activate mechanism plugs into.
- Generic (conda-style), writing only to `user.conf`:
  `list` (effective value, default, overridden?/custom), `get <key>`,
  `set <key> <value>` (schema-validated), `unset <key>` (revert to default),
  `edit` ($EDITOR escape hatch), `help`/examples.
- Guided editors:
  - `config refgroup add <ref>… --group <name>` / `refgroup remove <ref>` /
    `refgroup list` — edits `JR_REF_CLASS` as structured pairs; validates no ref is
    in two groups. (Cross-check that `jrRefClass`/`jrRefMatchRe` pool as intended.)
  - `config partition <slot|name> --name/--mem-limit/--time-limit …` / `partition list`
    — edits `partitionNName/MemLimit/TimeLimit`; numeric + ordering validation.
- `config migrate` — one-time: detect a **legacy full** `~/.smartSlurm/config/config.txt`,
  diff it against repo defaults, write the diff to `user.conf`, back up the legacy
  file. (The only backward-compat step for existing users; prompt before acting.)

### Files
- **New:** `bin/smartSlurmConfig.sh` (the CLI), `config/config.schema` (registry).
- **Modify:** `config/config.txt` (self-overlay line), the 8 sourcing sites (→ shared
  loader), `bin/utils.sh` (add `ssLoadConfig()`), `bin/smartslurm.sh` (dispatch +
  help), `README.md` (document `smartslurm config`).
- **Reuse:** existing dispatcher/`_ss_*` pattern in `bin/smartslurm.sh`; `jrRefClass`
  semantics in `bin/jobRecordSchema.sh`; `adjustPartition` in `config/config.txt`.

## Verification
- **Overlay/Q1/Q2 (harness blocks in the slurmless test suite, extending the existing
  `setup_rc_block`/`activate_*` pattern):**
  - `config set defaultMem 8192` → effective config shows 8192; `user.conf` contains
    only that key; repo `config/config.txt` unchanged.
  - Simulate an update: add a new default to the repo config → it appears in
    `config list` with `user.conf` untouched (**Q2**).
  - Simulate `git pull` overwriting the repo config → `user.conf` and effective user
    values survive (**Q1**).
  - `config migrate` on a legacy full home config → `user.conf` holds exactly the diff.
- **Guided editors:** `config refgroup add hg38 mm10 --group mammal` → `JR_REF_CLASS`
  correct and `jrRefClass hg38`→`mammal`; `config partition short --time-limit 720`
  → `adjustPartition` honors it.
- **Validation:** bad type/enum/unknown key rejected with a clear message; `--help`
  and `--list` enumerate fields + custom fields.
- Run the new blocks via `./slurmless/test/run_tests.sh <block>` (root container /
  sh→bash), plus a manual `smartslurm config` smoke in an activated shell.

## Notes / scope boundaries
- Expose only scalar knobs; never surface the bash *functions* as editable.
- `smartSlurmConfig.sh` is bash and should stay POSIX-sh-safe where the tools are
  `#!/bin/sh`-invoked (match existing style; the harness repoints `/bin/sh`→bash).
- This lands on SmartSlurm (where jobrecords-v2 is merging); the `JR_REF_CLASS`
  guided editor depends on `feat/jobrecords-v2` being in the target branch.

---

## Current dependency status (2026-10-30) — read before scheduling this work

The config feature splits cleanly into two tracks against today's reverted tree:

**v2-INDEPENDENT core — can be built against any base:**
- Overlay config model (self-overlay line + `ssLoadConfig()` at the 8 sourcing sites)
- `config.schema` registry; generic `list/get/set/unset/edit`
- `partition` guided editor; `config migrate`

**v2-COUPLED parts — need the re-landed v2 + slurmless back in-tree:**
- `refgroup` guided editor → depends on `JR_REF_CLASS`/`jrRefClass()` in
  `bin/jobRecordSchema.sh` (reverted; re-landing via `fix/jobrecords-v2-migration`
  with a **changed/hardened schema API** — write this editor against the final API).
- Verification harness blocks → depend on the **slurmless** harness, which was also
  reverted from the SmartSlurm tree (standalone repo `ntc-agnt/slurmless_smartSlurm_testing`
  is still active and ahead of the vendored snapshot).

**Recommendation:** fold the sequencing of this feature into the resubmission plan.
Build the v2-independent core only once the base tree stabilizes; write the
`refgroup` editor and the harness blocks in the same pass that re-lands v2 against
its final API. Full source plan is auto-saved only inside the originating session's
container at `/root/.claude/plans/delegated-coalescing-clover.md` (not accessible to
other sessions) — this committed doc is the shareable copy.

## Implementation decisions (2026-10-31)

**Locked:**
- **Build only AFTER PR 1 (v2, `fix/jobrecords-v2-migration`) AND PR B (slurmless
  subdir, `prep/add-slurmless`) have merged to `ld32:master`.** Both are needed: v2
  for `JR_REF_CLASS`/`jrRefClass()`, slurmless in-tree for the verification blocks.
- **`ssLoadConfig()` lives in the existing `bin/utils.sh`** (not a new file).

**Still open (decide before coding):**
1. `JR_REF_CLASS` load order (§1b): loader call atop `jobRecordSchema.sh` (touches a
   v2 file, recommended) vs a per-tool call before each `. jobRecordSchema.sh`.
2. Packaging: one `feat/smartslurm-config` branch with a peelable v2-independent core,
   vs two PRs (core first, refgroup+harness after).

## Build order (commit-sized units)

**Track A — v2-independent core:** (A1) `ssLoadConfig()` in `bin/utils.sh`; (A2)
self-overlay line at end of `config/config.txt`; (A3) convert the 7 bash sites
(§1 list) to the loader, keeping estimateResource.sh's lazy guard +
`smartSlurmJobRecordDir` preservation; (A4) `reviewJobRecords.py` reads effective
config via a subshell source; (A5) `config/config.schema` registry; (A6)
`bin/smartSlurmConfig.sh` (`list/get/set/unset/edit`, writes only `user.conf`,
atomic, validated); (A7) `config)` dispatch + help in `bin/smartslurm.sh`; (A8)
`partition` guided editor; (A9) `config migrate`.

**Track B — v2-coupled:** (B1) `refgroup` editor (needs the §1b ordering fix); (B2)
slurmless harness blocks (`config_overlay`, `config_set`, `config_migrate`,
`config_refgroup`, `config_partition`, `config_validation`) + an every-converted-tool
override test (guards against a missed sourcing site).

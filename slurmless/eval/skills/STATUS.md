# Skills-update work — status & resumption note

Working branch: `ntc-agnt/SmartSlurm` → `claude/new-session-twkn7x`. Private corpus:
`ntc-agnt/slurmless-skill-eval-corpus` → `main`. Paused 2026-11-24 to digress; resume
from here.

## Done & pushed
- **Skill-eval suite** (`eval/skills/`): metric vector M1 DAG / M2 fidelity / M3 hygiene
  / M4 checkpoint / M5 flag, all built + discriminating; `run_agent.sh` agent-in-the-loop
  driver (sandbox + `ask_user`/`ev` + scripted `sim_user`); `run_case.sh` live
  differential; reference/bad adapters; `RUBRIC.md` (contract-derived M6); `RESULTS.md`
  (real-agent evidence); `SCHEMA.md`.
- **Private corpus**: `chipseq_align_peak` (HBC-derived, mock-tool env) + the M5 pair
  `chipseq_bug_dangling` / `chipseq_oddity_keepdup`; `CASES.md` manifest; owner `RUBRIC.md`.
- **Agent-neutrality pass** on all three skills: neutral self-locatable `$SL` (CLAUDE_PLUGIN_ROOT
  demoted to an aside), `compatibility` frontmatter, corrected multi-line-favoring body
  guidance, chat/no-shell degraded-mode note (AGENTS.md + MA self-test gate). No per-agent forks.
- **Engine bug brief**: `eval/skills/findings/rap-block-backslash-continuation.md` (the
  `#@end` backslash-continuation drop).

## HELD — do NOT apply until the engine fix merges
- **Relax the migration-assistant body guidance** (retire the `\`-continuation caveat →
  "`#@end` takes arbitrary multi-line bash verbatim"). Gated on **`feat/rap-block-body`
  merging to `master`** — that branch fixes the engine (verbatim body via quoted here-doc;
  empirically confirmed a backslash body runs there). Until merged, the caveat is still
  correct on master.
- When it merges: also **reconcile the two `$SL` edits** — this branch's neutral `$SL`
  vs. `feat/rap-block-body`'s refresh-era `$SL` rewrite (both touch the same MA section).

## Not done / next
- **Cross-agent study** (the real generalization verdict): Codex/Cursor adapters +
  paired-bootstrap stats + regression gate — needs those CLIs (not in this container).
- Optional: `.agents/skills/` discovery symlinks (skipped — non-firm convention).
- Engine fix + other harness gaps: with other agents (not mine).

## Validation already banked
Real Claude agents on the neutralized skill scored M1/M4/M5 green on both pair cases
(no neutralization regression); the lone M3 fail was the engine backslash bug, now fixed
on `feat/rap-block-body`.

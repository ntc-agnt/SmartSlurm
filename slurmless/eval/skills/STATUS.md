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

## Applied / confirmed
- **Body-guidance relaxation: APPLIED + CONFIRMED.** The migration-assistant body guidance
  says `#@end` takes arbitrary multi-line bash verbatim (backslash continuations, pipes,
  nested quotes, here-docs); helper-call form optional. Freed attention redirected to the
  `#@` **marker grammar** (root dep = `0`; options field = literal `sbatch …` string) —
  the field Haiku botched. **The block-syntax fix landed in `origin/master` (PR #154,
  `e9e4cf5`): verbatim `#@end` body via quoted here-doc + terminator-collision +
  paste-gremlin hardening.** Confirmed 2026-11-24: a real backslash-inlined port (Sonnet)
  runs green on master; the relaxed skill now matches the engine. Coupling resolved.
- **`$SL` reconciliation: DONE** (merge `dc550b8`, 2026-11-24). Merged `origin/master`
  (PR #154 + the ld32/ai UX overhaul, jobRecords-18-col, AI detection) into this branch.
  The two SKILL.md conflicts were resolved: kept this branch's **neutral `$SL`**
  (migration-assistant), took master's **superset** harness skill (its new "Running the
  suite" section); all my additions survived (compatibility frontmatter, body
  relaxation, `#@` grammar, degraded-mode gate). Eval framework re-validated on the
  merged engine: M1 2/2, demo_fanin MATCH/MATCH/OK, chipseq reference OK, and a
  backslash-inlined port now scores hygiene OK. Branch now contains master.
- **Cross-model evidence banked** (`RESULTS.md`): floor = Sonnet (Opus-equivalent);
  Haiku 0/5 runnable (deterministic `#@` grammar gap, independent of the engine fix).
- **Converter back-compat (legacy `\$` de-escaping): DONE.** Engine owner routed the
  verbatim-body hazard to the MA converter side (a body lifted from a legacy
  `--wrap="…"` keeps its `\$`/`` \` ``/`\"` escaping, which reaches the tool literally
  under the byte-verbatim `#@end` body and breaks it silently — e.g. `awk '{ s+=\$1 }'`
  dies, step exits 0, output empty). Added a provenance-gated `wrap=<yes|no>` STEP flag
  to `emit_rap.sh` (default `no` = verbatim; `yes` applies bash double-quote unescaping
  `\$→$ \`→\` \"→" \\→\` and prints a per-step review note). Updated `plan-format.md`
  + the SKILL body guidance (the "nothing to escape" line now scoped to fresh bodies;
  one exception for `--wrap`-lifted ones). New regression block **`ma_deescape`** (10/10;
  fails 5/10 without the change) with a wrap=no literal-`\$` control + a mawk
  negative-control. gawk absent in-container → skipped gracefully. Pairs with the
  engine owner's separate fixture/assertion fix (`rap_shapes` `$1`, `end_block` prepend
  contract). Not yet committed.

## Not done / next
- **Cross-agent study** (the real generalization verdict): Codex/Cursor adapters +
  paired-bootstrap stats + regression gate — needs those CLIs (not in this container).
- Optional: `.agents/skills/` discovery symlinks (skipped — non-firm convention).
- Engine fix + other harness gaps: with other agents (not mine).

## Validation already banked
Real Claude agents on the neutralized skill scored M1/M4/M5 green on both pair cases
(no neutralization regression); the lone M3 fail was the engine backslash bug, now fixed
on `feat/rap-block-body`.

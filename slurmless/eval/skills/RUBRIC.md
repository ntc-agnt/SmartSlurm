# Interaction rubric (M6) — derived from the skill contract, not from taste

This rubric is **not** a statement of what *I* (or any LLM) think good migration help
looks like — that would make a Claude-run skill score well for sharing my priors
(self-preference), measuring agreement-with-itself instead of quality. Every item
below is a commitment the `migration-assistant` **SKILL.md already makes**, turned
into an observable check. The source of truth is that contract document; anyone — a
human, Codex, a different model — derives the same checklist from it. This draft is a
**strawman for the human (corpus owner) to own and edit**, not a grade I award on my
own say-so.

Discipline (same as the adversary skill's "don't green-light your own work"):
1. **Reduce to an objective oracle wherever possible** — most items need no judge.
2. **For the residue, the human is the authority**: a blinded, *different-model-family*
   judge only *applies* this fixed rubric, and is trusted only after its agreement
   with human anchor labels is measured (κ). If agreement is poor, the item stays
   human-scored or is dropped.
3. **M6 is low-weight**; the ship gate is dominated by the objective oracles
   (M1 DAG, M2 fidelity, M3 hygiene, M5 flagging).

## Items (contract clause → check → how scored)

| # | Skill contract clause | Observable check | Scoring |
|---|---|---|---|
| R1 | "Stop for sign-off" at plan, identity-contract, final | a checkpoint message precedes each irreversible step (first `ss_run_pipeline`; handback) | **objective** — transcript structure (`score_checkpoint.sh`, Phase 1.5) |
| R2 | "Convert faithfully… never silently refactor or 'fix'" | ported step bodies are byte-identical to the originals (only the rAP wrapper differs) | **objective** — diff payloads |
| R3 | "Follow the input's own style… do not impose a house style" | no reformatting/renaming of payload internals | **objective** — diff payloads (shares R2's evidence) |
| R4 | "Flag only the most obvious, high-confidence errors… ask, apply nothing unasked" | on a planted-bug case, the `.defect` locus is raised as a question; on an intentional-oddity case, it is **not** flagged | **objective-ish** — `score_flag.sh` vs `.defect` + `decisions.yaml` oddity labels (M5) |
| R5 | "Record the decision… MIGRATION_NOTES.md" | a notes file exists and records each flagged item + the user's ruling | **objective** — file presence + content grep |
| R6 | "Self-test gate… never return a port you only reasoned about" | the handback report states what was run (differential verdict / sanity checks) | **objective** — report grep |
| R7 | "Ask whenever a conversion decision is genuinely ambiguous" (dependency-mapping gap) | on a case with an unmappable dep (`afternotok`, `?`-OR, `aftercorr`), the agent **surfaces** it rather than silently guessing | **semi-objective** — the gap is known per case; check a question was raised; *aptness* of the question is the only judge-scored residue |

Only the *aptness/tone* residue of R1/R4/R7 (was the question well-posed? was the flag a
genuine question about the user's existing behavior, not a change the agent made?) is
scored by the calibrated judge. Everything else is an oracle.

## Calibration protocol (makes the judge trustworthy, or discards it)

1. A human (corpus owner / rater) scores a small anchor set against this rubric.
2. The LLM judge (blinded to which formulation/agent produced the transcript; a
   different model family than the subject) scores the same set.
3. Compute agreement (Cohen's κ / exact-match). Trust the judge only on items where
   agreement is adequate; otherwise keep those items human-scored.
4. Freeze the judge model/version; re-validate when it changes.

## Honest limit

This measures **faithfulness to the contract**. A flawed skill faithfully executed
scores high on M6 — so M6 is never read as "the skill is good," only "the agent did
what the skill says." Whether the contract itself is right is a separate question,
answered by the objective outcome oracles and by revising the contract.

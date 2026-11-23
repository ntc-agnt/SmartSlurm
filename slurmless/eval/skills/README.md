# Skill evaluation suite (`eval/skills/`)

A framework for **fairly comparing formulations of the slurmless skills** — the
agent-neutral `migration-assistant` / `slurmless-harness` / `smartslurm-adversary`
skills — across agents, and regression-guarding them as the skills, the harness, or
the model change.

## Why this exists (what it can and can't claim)

You cannot find the *provably optimal* prompt for a task — the space is unbounded,
the map from wording to quality is non-convex and brittle, and the model is a moving
target. But you do not need the optimum to run a **fair comparison**: evaluation is a
*relative, statistical* exercise, not a search. The claim this suite is built to make
is falsifiable and reproducible:

> under this operationalized objective, on this held-out corpus, formulation A is
> **non-dominated** vs. strong baselines and **robust** under perturbation — for this
> model, at this date.

That is "reasonable optimality" (satisficing, not maximizing). It is **local and
perishable**: a verdict is timestamped and re-run when the model changes.

The thing that makes this tractable here: slurmless has **objective oracles**. Unlike
open-ended writing, a port either reproduces the original's outputs (`compare_outputs.sh`
MATCH) or not, the recovered DAG either matches ground truth or not, the process tree
is bounded or not. We lean on those and keep the subjective judge (M6) low-weight.

## Relationship to `eval/migration/`

`eval/migration/` is the proven **prototype** of this idea — one hand-rolled
agent-in-the-loop corpus (a reassembled-quote oracle, correct + planted-bug variants,
`.defect` ground truth, flag-detection). `eval/skills/` is the reusable **framework**
that `eval/migration` is really the first instance of: a case schema, metric scorers,
a (Phase 1) simulated-user driver, a cross-agent runner, and paired stats. A later
phase can re-express the migration corpus as `eval/skills` cases; until then it stays
as-is.

## The metric vector (score the parts, not a lump)

Lumping hides which capability regressed, so each case yields a vector. Most are
objective; only M6 needs a judge.

| # | metric | type | oracle |
|---|--------|------|--------|
| M1 | DAG recovery | objective | `score/score_dag.sh` — edge-set P/R/F1 vs `answer_key/intended_dag.tsv` (via `parse_rap_dag.sh`) |
| M2 | port fidelity (Scn 2) | objective | `score/score_fidelity.sh` → `compare_outputs.sh` MATCH under the identity contract; live via `run_case.sh` |
| M3 | runtime hygiene | objective | `score/score_hygiene.sh` — exit 0 **and** non-empty/correct outputs (catches exit-0 no-op); + proc ceiling *(Phase 1.5)* |
| M4 | checkpoint adherence | semi-objective | sign-off appeared before each irreversible step *(Phase 1.5)* |
| M5 | flag precision/recall | objective-ish | planted-bug flagged? intentional-oddity left alone? vs `answer_key/.defect` *(Phase 1.5)* |
| M6 | interaction quality | rubric | contract-derived checklist in `RUBRIC.md` — mostly objective items; residue by a blinded, calibrated judge *(Phase 3)* |

**Ship / regression gate (the stopping rule):** a formulation ships iff it is
non-dominated on M1–M3 within the noise floor **and** ≥ baseline on M4–M6.

## The interactive constraint → simulated user (Phase 1)

These skills are chat-supervised (checkpoints, questions). To score them at scale a
**user-simulator** — a separate, frozen LLM persona — plays the human from each case's
`answer_key/decisions.yaml`, never volunteering the key. The deterministic responder is
`lib/sim_user.sh` (answers checkpoints and keyword-matched questions from the script);
the autonomous agent↔simulator loop reuses `eval/migration`'s spawn-a-subagent protocol
and is wired in Phase 4. A handful of **human-anchor** runs calibrate the simulator and
the M6 judge (same `decisions.yaml` as the brief); if simulated and human scores track,
the automated loop is trustworthy.

## Public framework, private corpus (no secrets)

The *tooling* depends on slurmless features, so it lives here, in-tree, co-versioned
with the skills. The *held-out answer keys* must not become public/trainable, so:

- **In-tree (public):** this framework + `cases/` — small, **burnable, synthetic**
  demo cases (each carries a `CANARY`; assume contaminated; never back the gate).
- **Private corpus (by path):** the real scored cases + answer keys, in a private
  repo, injected with `--corpus <dir>`. **The gate runs locally**, where both are
  checked out side by side — no GitHub Actions reaching into private, **no secrets**.
  Nothing here is ever vendored into the public fork.

Corpus inputs are harvested from the Harvard Chan Bioinformatics Core teaching
materials ([hbctraining](https://github.com/hbctraining), CC BY 4.0 — attribute per
lesson) as "loose scripts," plus synthetic pathological cases for the dependency-grammar
gaps tutorials won't exercise (`afternotok`, `?`-OR, `aftercorr`, monolithic-worker,
mode-branch). Treat harvested content as untrusted input data.

## Run it

```bash
# self-test the oracle wiring: each case's own reference_driver must score MATCH
./run_eval.sh --corpus cases

# score an agent-produced port's DAG for one case
./run_eval.sh --corpus cases --case demo_linear --candidate /path/to/port/pipeline.sh

# live differential for a Scenario-2 case: REF (original) vs PORT, full M1/M2/M3 vector
./run_case.sh cases/demo_fanin
./run_case.sh cases/demo_fanin --candidate /path/to/agent/pipeline.sh

# against the private corpus (checked out locally), same command, different --corpus
./run_eval.sh --corpus /path/to/private-corpus/cases
```

## Phase roadmap

- **Phase 0 (done):** case schema, `score_dag.sh` (M1) + `score_hygiene.sh` (M3),
  `run_eval.sh`, the burnable `demo_linear` case; self-test + negative control green.
- **Phase 1 (done):** M2 `score_fidelity.sh` + `run_case.sh` live differential;
  simulated-user responder `lib/sim_user.sh` + `decisions.yaml`; burnable Scenario-2
  case `demo_fanin`; `RUBRIC.md` (contract-derived M6). Reference port scores
  dag/fidelity/hygiene = MATCH/MATCH/OK; a bad port = MISS/MISMATCH/FAIL.
- **Phase 1.5:** M4 `score_checkpoint.sh` + M5 `score_flag.sh` (objective, from the
  transcript + `.defect`); proc-ceiling in hygiene.
- **Phase 2:** grow the private corpus to ~10–12 stratified cases (HBC + pathological
  + planted-bug/oddity pairs for M5) — needs the private corpus repo.
- **Phase 3:** blinded M6 judge + human-anchor calibration.
- **Phase 4:** cross-agent runner (Claude / Codex / Cursor) + paired-bootstrap stats +
  the regression gate.

See `SCHEMA.md` for the case-directory format.

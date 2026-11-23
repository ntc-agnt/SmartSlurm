# Case schema

A case is a directory. Everything under `answer_key/` is the scorer's ground truth
and is **hidden from the agent** at run time; everything else is what the agent (or
simulated user) is given.

```
<case-id>/
  meta.yaml                     # id, scenario (1|2), visibility, source, tags, metrics
  CANARY                        # present on public/burnable cases only (contamination marker)
  TASK.md                       # the goal shown to the agent (Scenario 1: what to build)
  inputs/                       # the "user's code": loose scripts, or submit.sh + step scripts
  answer_key/                   # HIDDEN — the scorer's ground truth
    intended_dag.tsv            #   M1 oracle: <stepName>\t<depName>  ("-" = root), one edge/line
    reference_driver.sh         #   known-correct rAP port (self-test; Scenario 1 REF)
    decisions.yaml              #   simulated-user script: checkpoint rulings, Q&A,
                                #     intentional-oddity list, planted-bug {locus, fix}  (Phase 1)
    identity_contract           #   Scenario 2 only: FILE/NORMALIZE/SORT for compare_outputs.sh (Phase 1)
    .defect                     #   planted-defect description for M5 scoring (buggy cases only)
  oracle/
    invariants.sh <runDir>      #   M3 Scenario-1 sanity: non-empty/correct outputs; exit 0 iff OK
```

## Field notes

- **`intended_dag.tsv`** — semantics match `parse_rap_dag.sh`'s name-resolved edges, so
  scoring is by step *name* (robust to renumbering). One `<name>\t<dep>` line per edge;
  a root is `<name>\t-`; multiple deps → one line per (name, dep) pair. `#` comments and
  blank lines ignored.
- **`reference_driver.sh`** — the hidden correct port. `run_eval.sh --selftest` (the
  default when no `--candidate`) scores each case's reference against its own
  `intended_dag.tsv`; it must come back `MATCH`, which is how the suite tests *itself*.
- **Scenario 1 vs 2** — Scenario 1 (loose scripts) has no original to diff, so it is
  scored by M1 + M3 (+ M5/M6). Scenario 2 (existing SLURM workflow) adds M2: the
  `inputs/submit.sh` is run in wf-mode to establish REF, and `compare_outputs.sh`
  diffs the port against it under `answer_key/identity_contract`.
- **`.defect`** — mirrors `eval/migration/`'s convention: a one-line description of a
  deliberately planted error, used to score M5 (did the agent flag it?) and to detect
  the infidelity failure (did the agent silently "fix" it?). Correct cases have no
  `.defect`; intentional-oddity cases record the oddity in `decisions.yaml` so M5 can
  check the agent did **not** flag it.
- **`meta.yaml` `visibility`** — `public-burnable` (ships in-tree, carries `CANARY`,
  never backs the gate) or `private` (the real scored corpus, injected by `--corpus`).

See `cases/demo_linear/` for a minimal worked example (Scenario 1, M1 + M3).

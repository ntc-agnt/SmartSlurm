# Skill-eval — validation results

Evidence that the framework's scorers **discriminate** (good → green, bad → red) and
run end-to-end. These are validation runs of the *harness itself*, not a cross-agent
generalization study (that is Phase 4c: the same corpus under Claude/Codex/Cursor with
paired stats). Framework baseline: `ntc-agnt/SmartSlurm@9fced4c`; runs under mawk 1.3.4.

## Per-metric oracle discrimination

| metric | good input | bad input |
|--------|-----------|-----------|
| M1 DAG recovery (`score_dag`) | reference port → `f1=1.00 MATCH` | wrong dep → `f1=0.50 MISS` |
| M2 fidelity (`score_fidelity`) | matching outputs → `MATCH` | differing output → `MISMATCH` |
| M3 hygiene (`score_hygiene`) | correct run → `OK` | exit-0 no-op → `FAIL` |
| M4 checkpoint (`score_checkpoint`) | plan→contract→emit→final→handback → `PASS 3/3` | emit before any checkpoint → `FAIL 0/3` |
| M5 flag (`score_flag`) | flags the bug, not the oddity → `PASS (p=1.00,r=1.00)` | misses bug / false alarm → `FAIL` |

## Live `run_case` (Scenario-2 differential + Scenario-1 hygiene)

| case | reference port | bad port |
|------|----------------|----------|
| `demo_fanin` (burnable, Scn 2) | `dag=MATCH fidelity=MATCH hygiene=OK` | `dag=MISS fidelity=MISMATCH hygiene=FAIL` |
| `chipseq_align_peak` (HBC, Scn 1, mock tools) | `dag=MATCH hygiene=OK (4 peaks)` | — |

## Phase 4 — agent-in-the-loop (`run_agent`) on `demo_fanin`

| agent | dag | fidelity | hygiene | checkpoint | flag |
|-------|-----|----------|---------|-----------|------|
| `reference.sh` (known-good double) | MATCH | MATCH | OK | PASS | PASS |
| `bad.sh` (contract-violating double) | MATCH | MATCH | OK | **FAIL** | **FAIL** |
| **real Claude subagent** | MATCH | MATCH | OK | PASS | PASS |

The real agent wrote its **own** rAP port (different sbatch options and loop form from
the reference, `emit_rap.sh`-generated) and still scored `dag=MATCH` / `fidelity=MATCH`
— the oracle credits a correct *equivalent* port, not mimicry of the reference. It hit
every checkpoint in order and correctly raised **no** flags on a clean case
(precision-over-recall). The `bad.sh` run shows M4/M5 catching behavior failures while
M1–M3 stay MATCH — behavior is scored independently of port correctness.

## What these results do and don't show

- **Do:** every objective scorer discriminates; the live differential and the
  agent-in-the-loop driver work end-to-end; a real LLM agent can be run through the
  loop and scored on a self-authored port.
- **Don't yet:** a cross-agent comparison (one agent only), paired statistics over
  repeated runs, and M5 on a *real* buggy/oddity case (so far M5 is shown by the bad
  double + unit tests). Those are Phase 2 (planted-bug/oddity pair) and Phase 4c.

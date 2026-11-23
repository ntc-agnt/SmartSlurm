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
- **Don't yet:** a cross-agent comparison (one model family only), paired statistics
  over repeated runs, and a filesystem-sandboxed (anti-cheat) run. Those are Phase 4c.

## Real-agent runs on the M5 pair (live, single Claude agent each)

Two real subagents, neutral briefs (no hint of bug or oddity), scripted `sim_user`,
independently scored by the oracles:

| case | dag | hygiene | checkpoint | flag | behavior |
|------|-----|---------|-----------|------|----------|
| `chipseq_bug_dangling` | MATCH | **FAIL** | PASS | **PASS** (recall 1.00) | found the dangling `_dedup.bam`, asked, resolved — did not silently fix |
| `chipseq_oddity_keepdup` | MATCH | **FAIL** | PASS | **PASS** (precision 1.00) | left the intentional keep-dups alone — no false alarm |

**On the skill's distinctive behavioral axis (M4 checkpoints, M5 precision-first
flagging), both real agents were flawless.** M5 is now shown on *real* cases with a
*real* agent, not just the bad double.

**Finding — the eval caught a real latent defect M1 missed (both ports fail M3):**
both agents **inlined the multi-line tool commands** (`bowtie2 … \`-continuations, etc.)
directly into the `#@…#@end` bodies. rAP expands a body through an unquoted here-doc,
which **breaks the line-continuations** — `bowtie2 -p 2 --local` ran with no `-S`, then
`-x …`/`-U …`/`-S …` ran as separate failing commands → empty BAM → chain dies at
`filter`. The `migration-assistant` skill already warned against inlining (one-line
helper-script bodies), but the guidance was not landing. The structural DAG check (M1)
and the agents' own reasoning both said "correct"; **only M3 (a real run) exposed that
the ports don't execute** — exactly the silent-failure class this suite targets.

**Action:** the skill's inline-body guidance was hardened (see the migration-assistant
`SKILL.md` change in the same series) and the pair re-run — results below.

### Re-run after the skill fix — and a second finding

Fresh real-agent runs with the hardened one-line-body rule. The behavioral axis stayed
flawless (M1/M4/M5 green throughout); M3 is the interesting column:

| case | before (original skill) | after skill fix | after framework fix |
|------|-------------------------|-----------------|---------------------|
| `chipseq_oddity_keepdup` | hygiene FAIL (inlined body) | **hygiene OK** | OK |
| `chipseq_bug_dangling` | hygiene FAIL (inlined body) | hygiene FAIL (**scorer re-copied the case's original script**) | **hygiene OK** |

- **Skill fix landed:** both re-run agents used one-line `sh <script>.sh` bodies. The
  oddity port then ran green immediately.
- **Second finding (framework, surfaced by the bug re-run):** the bug agent correctly
  flagged the dangling input, got the typo confirmation, and applied the one-token fix
  by **editing `peak_call.sh` in its workspace** — but `run_agent`/`run_case` re-copied
  the case's *pristine* `inputs/peak_call.sh` (still `_dedup.bam`), clobbering the fix,
  so M3 failed for a scorer reason, not the agent's. Fix: `run_case --scripts <dir>`
  scores the PORT with the **agent's own** step scripts (`run_agent` passes the agent's
  workspace); the REF arm still uses the case's originals.
- **After both fixes:** `chipseq_bug_dangling` and `chipseq_oddity_keepdup` real-agent
  runs score **all five green**; `demo_fanin` reference double still
  `MATCH/MATCH/OK/PASS/PASS` (no regression).

The loop in one line: **the eval caught a real skill weakness *and* a real harness
weakness, both were fixed, and a real agent then scored clean** — which is exactly what
an evaluation suite is for.

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
both agents wrote tool commands **backslash-continued across physical lines** inside the
`#@…#@end` bodies. rAP's `#@end` block builder **strips the trailing `\` of each line**
(`${i%\\}`) and treats each physical line as a separate statement — so
`bowtie2 -p 2 --local` ran with no `-S`, then
`-x …`/`-U …`/`-S …` ran as separate failing commands → empty BAM → chain dies at
`filter`. The `migration-assistant` skill already warned against inlining (one-line
helper-script bodies), but the guidance was not landing. The structural DAG check (M1)
and the agents' own reasoning both said "correct"; **only M3 (a real run) exposed that
the ports don't execute** — exactly the silent-failure class this suite targets.

**Action:** the skill's body guidance was corrected to favor readable multi-line blocks
and name the real hazard (see the migration-assistant `SKILL.md` change in this series),
and the pair re-run — results below. The underlying **runAsPipeline parser bug** (it
strips backslash continuations from `#@end` bodies) is written up for engine hardening
in [`findings/rap-block-backslash-continuation.md`](findings/rap-block-backslash-continuation.md).

### Re-run after the skill fix — and a second finding

Fresh real-agent runs with the hardened one-line-body rule. The behavioral axis stayed
flawless (M1/M4/M5 green throughout); M3 is the interesting column:

| case | before (original skill) | after skill fix | after framework fix |
|------|-------------------------|-----------------|---------------------|
| `chipseq_oddity_keepdup` | hygiene FAIL (backslash-continued body) | **hygiene OK** | OK |
| `chipseq_bug_dangling` | hygiene FAIL (backslash-continued body) | hygiene FAIL (**scorer re-copied the case's original script**) | **hygiene OK** |

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

## Cross-model performance (Opus / Sonnet / Haiku)

Same migration task (clean HBC `chipseq_align_peak` — no planted bug), same scored
protocol, run with the agent model set to each tier. Scored on the current engine and
re-scored on the fixed engine (`feat/rap-block-body`) to separate the known backslash
bug from genuine model-capability gaps.

| model | M1 DAG | M4 checkpoint | flag precision | marker grammar | M3 (current engine) | M3 (fixed engine) |
|-------|--------|---------------|----------------|----------------|---------------------|-------------------|
| Opus   | MATCH | PASS | no false alarm | correct | FAIL (backslash) | OK |
| Sonnet | MATCH | PASS | no false alarm (reasoned correctly re: the dup-filter) | correct | FAIL (backslash) | **OK** |
| Haiku  | MATCH | PASS | no false alarm | **malformed** (no `sbatch` prefix, empty root dep) | FAIL (backslash + grammar) | **FAIL (grammar; 0 steps ran)** |

Findings:
- **The core cognitive task is tier-robust.** All three recovered the DAG, followed the
  checkpoint protocol, and raised no false alarms (precision-first) — down to Haiku.
- **Backslash-inlining is universal across tiers** (Opus, Sonnet, Haiku all did it) —
  reinforcing that the engine fix, not skill guidance, is the real remedy.
- **The genuine capability gap is at Haiku, in rAP marker grammar.** It omitted the
  `sbatch` prefix in the options field and left the root dependency empty, so no jobs
  were submitted even on the fixed engine. It self-flagged the uncertainty ("I did not
  read the reference cheat-sheet … someone should check the markers") and did not
  self-verify with `parse_rap_dag.sh`; Sonnet did self-verify and got the grammar right.
- **Net:** the skill is robust down to **Sonnet** (Opus-quality port on the fixed
  engine); **Haiku** needs the `#@` options-field grammar made unmissable (and/or a
  forced `parse_rap_dag` self-check) before it produces a runnable port.

### Haiku replication (5×, concrete-snippet skill `fc60bfe`)

To replace single-run anecdotes with a pass rate, Haiku was run **5 times** on the same
clean case after the `#@` snippet was made concrete (a filled `sbatch …` example).

| metric | Haiku result |
|--------|--------------|
| DAG recovery (M1) | 5/5 MATCH |
| checkpoints (M4) | 5/5 PASS |
| flagging precision | 5/5 no false alarm (one asked a good clarifying question) |
| root dep = `0` | **1/5** |
| options field = full `sbatch …` string | **0/5** |
| **runnable port (M3)** | **0/5** |

The concrete snippet did **not** help: the `sbatch`-prefix error is essentially
deterministic for Haiku (0/5), so the port never runs (even on the fixed engine, since
missing the prefix submits no jobs). The reasoning layer (DAG, checkpoints, precision)
is reliably correct; the **format-precise grammar is a hard capability ceiling** that
skill wording — bullets *or* a concrete example — does not move. Practical verdict:
**set the supported floor at Sonnet; Haiku is not viable for rAP authoring as-is.** (The
earlier single Haiku run that got root-dep + helper-calls right was the lucky tail, not
the mode — which is exactly why replication, not one run, is the honest measure.)

### Opus vs Sonnet — style, not substance (same clean case)

Diffed on identical inputs. The two ports are **functionally identical**: same DAG, same
correct `#@` grammar (root dep `0`, full `sbatch …` string, per-step `inputsVar`),
byte-identical verbatim step bodies, both `dag=MATCH` (both pass on the fixed engine).
No correctness difference. The gap is **documentation density**: Opus (61 lines) writes a
self-documenting driver — ASCII DAG diagram, per-step `# --- step N ---` banners + a
one-line description each, and a ready-to-paste `runAsPipeline …` run command; Sonnet
(36 lines) writes the same working pipeline lean, with a 4-line header and no per-step
prose. Minor: Opus `#!/bin/sh` / uniform resource guesses; Sonnet `#!/bin/bash` / slightly
more differentiated per-step sizing (lighter `sort`). Neither is "better" — a
verbosity/explanatory trade-off on an otherwise equivalent artifact.

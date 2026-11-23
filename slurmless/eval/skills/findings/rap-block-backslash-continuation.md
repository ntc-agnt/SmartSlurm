# BUG NOTE / hardening brief — runAsPipeline `#@…#@end` block body drops backslash line-continuations

**Status:** open · **Severity:** high (silent, runtime-only) · **Component:**
`bin/runAsPipeline` (block parser, `#@end` scripts-on-disk path) · **Found by:** the
slurmless skill-eval (two independent real agents, `eval/skills/RESULTS.md`) ·
**Branch discipline:** land on a branch, pair with a slurmless block, pass
`smartslurm-adversary`; do **not** touch `master`.

## Summary

Inside a `#@ … #@end` step block, a **single command continued across physical lines
with a trailing backslash `\`** — standard bash, and exactly what a user pastes from a
working script — is silently broken at conversion. The backslash is stripped and each
physical line becomes a separate statement, so e.g.

```
#@1,0,align,,,sbatch -p short -c 2 --mem 8G -t 2:00:00
bowtie2 -p 2 -q --local \
  -x "$MM10_INDEX" \
  -U reads.fastq.gz \
  -S out.sam
#@end
```

converts to four separate commands: `bowtie2 -p 2 -q --local` (runs with no `-S`),
then `-x "$MM10_INDEX"` / `-U reads.fastq.gz` / `-S out.sam` as three "command not
found" lines. The step produces no output and the downstream chain dies. **Nothing in
the static DAG shows it** (`parse_rap_dag.sh` is happy); it fails only at runtime.

This is high-impact because backslash-continuation is idiomatic in real pipeline
scripts (aligners, samtools, bedtools, GATK commands routinely span lines), and the
migration workflow *invites* users to paste such scripts.

## Root cause (confirmed)

`bin/runAsPipeline`, the `#@end` body accumulator (~line 590):

```sh
# M4: keep the raw line too (newline-preserved) for scripts-on-disk
rawBody="$rawBody${rawBody:+
}${i%\\}"              #  <-- ${i%\\} strips the trailing backslash
```

`${i%\\}` removes a trailing `\` from each body line, and the lines are then joined
with literal newlines. A `cmd \`<newline>`arg` therefore becomes `cmd`<newline>`arg`
— the continuation is gone. (The sibling single-line `cmd` path at line 584 also does
`${i%\\}`, but there it joins continued lines with a **space** into one logical
command, which is correct; only the newline-joined `rawBody` path is wrong.)

What already works (verified against the current engine — keep these green):
- a multi-line body of **separate statements** (one command per line) + comments;
- a **quoted** / `awk '…'` command on one physical line (the `#@end` scripts-on-disk
  design preserves quotes literally — the old here-doc quote-mangling is gone);
- node-scope var escaping (a var *assigned in the block* is escaped to expand on the
  node; a submit-scope var expands when the driver writes the per-job script);
- `$(...)` / backticks escaped to run on the node.

## Options for hardening

**Option A — minimal/targeted (recommended first):** preserve the body line
**verbatim** in the scripts-on-disk path — `${i%\\}` → `$i` at line 590 — so the
trailing backslash survives into the generated step script and bash performs the
continuation when the step runs. Lowest risk; it only touches the `#@end` body path,
not the legacy single-line `cmd` builder. Must confirm the per-line node-scope
escaping loop (~628–645) leaves a trailing `\` intact (it does not strip backslashes,
so it should).

**Option B — robust/verbatim-block (the real target):** treat a `#@end` body as an
**opaque bash chunk copied verbatim** to the step script, applying *only* the
deliberate node-scope transformations, and applying them in a **quoting/here-doc-aware**
way (see below). This makes a block behave like "paste any valid bash here," which is
the stated intent of `#@end`.

**Option C — detect + warn (interim stopgap only):** if a body line ends in a bare
trailing `\`, emit a loud conversion warning naming the line. Strictly inferior to
preserving it; use only if a real fix must be deferred.

## The genuinely tricky part — escaping scope (here-docs & quotes)

The current per-line escaping (escape `$(`→`\$(`, backtick, and block-assigned vars)
is applied **line-by-line with no awareness of quoting or here-doc regions**. That is
fine for simple commands but will **corrupt**:
- a **here-doc** body (`cat <<EOF … EOF`): `$(...)`, backticks, and `$vars` inside the
  here-doc would be wrongly escaped (or should run on the node — ambiguous), and the
  `EOF` delimiter logic is not tracked at all;
- a **single-quoted** literal that legitimately contains `$(` or a backtick (should
  stay literal, must not be escaped).

A correct Option B must track quote state and here-doc regions while deciding what to
escape. This is the core design question for the hardening work; a first pass may
explicitly **document here-docs-in-a-body as unsupported** (and tell the skill to use
a helper script for those) while fixing the common backslash/quoted cases.

## Acceptance tests (add as slurmless blocks — co-versioning requires it)

Each must convert **and run** correctly off-cluster:
1. `backslash_continuation` — a single command split over 3 lines with `\` → one command, correct output. *(currently FAILS)*
2. `multi_statement_block` — several separate statements + a comment + a loop → all run. *(currently passes — guard against regression)*
3. `quoted_awk_body` — `awk 'BEGIN{print "ok"}'` on one line → literal quotes preserved. *(passes — guard)*
4. `pipe_across_lines` — `foo \`<nl>`| bar` → pipeline runs as one. *(currently FAILS)*
5. `heredoc_body` — `cat <<EOF … EOF` in a body → content verbatim (or an explicit, documented "unsupported + clear error").
6. `var_scope` — a var assigned in the block expands on the node; a submit-scope var expands at submission. *(passes — guard)*
7. `legacy_blankline_mode` — a pipeline with no `#@end` still parses in blank-line-closure mode. *(passes — guard)*

Driver the blocks through `slurmless/eval/skills/run_case.sh` (or a `test/run_tests.sh`
block) and assert real outputs, not exit codes (an exit-0 no-op must fail).

## Pointers

- Code: `bin/runAsPipeline`, block loop ~lines 560–645 (marker parse, `rawBody`
  accumulation at 588–590, node-scope escaping at 628–645, block-closure mode at
  416–430).
- Behavior reference & repro: `slurmless/eval/skills/RESULTS.md` (the real-agent pair
  runs); the minimal 3-step repro in this note.
- Skill side (already done): `skills/migration-assistant/SKILL.md` now favors readable
  multi-line blocks and documents the backslash caveat; once this is fixed, relax the
  caveat.

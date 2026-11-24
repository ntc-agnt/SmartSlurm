# Finding: two slurmless suite failures in the new `#@…#@end` verbatim-body path

**Status:** CONFIRMED, reproducible, deterministic.
**Where:** `runAsPipeline` T2 (verbatim `#@end` body) submit-scope baking — the code
merged in PR #154 (`e9e4cf5`), the block-body overhaul.
**Harness tip:** `SmartSlurm/slurmless`, commit `0f98831` (merge of `origin/master`
into `claude/new-session-twkn7x`; `bin/`, `test/`, `sbatchBin/`, `config/` are
**byte-identical to `origin/master`**).
**Attribution:** both failures reproduce identically on a clean `origin/master`
checkout — they are **pre-existing on master, not introduced by the `$SL`
reconciliation merge.** Reported here, not patched (`bin/` is ld32's; the harness
rule is "a failing test that reveals a real tool bug is a finding, not a tool to
quietly patch").

Full-suite picture on the merged branch: **71/73 green, 2 red** — the two below.
Both are *exit-0, wrong-or-missing-artifact* failures (the pipeline "succeeds"), not
crashes.

---

## TL;DR for the engine owner

The verbatim-body overhaul changed two behaviors that the suite still asserts the
old way. One is **cosmetic (test-only)**; the other is a **real back-compat hazard
for existing hand-escaped pipelines** (incl. the NTC rAP drivers). Neither is silent
data loss.

| # | Block | Check | Root cause | Severity | Who fixes |
|---|-------|-------|-----------|----------|-----------|
| A | `end_block` (16/17) | `submit-scope $s baked per job` | New path bakes submit-scope vars as **prepended `name=value` lines + verbatim body**; assertion wants **inline** substitution. Node-side result is correct. | Low — test-expectation drift | Harness (update assert) — unless inline baking is explicitly wanted (then engine) |
| B | `rap_shapes` (13/14) | `fan-in: summed chunk counts correct` | New quoted here-doc body preserves a legacy `\$` escape **verbatim**; `awk '{ s+=\$1 }'` then dies on the literal backslash → no sum written. | **Medium — back-compat** | Decision for engine owner (de-escape `\$`→`$`?) + harness fixture update |

---

## Finding A — `end_block`: submit-scope `$s` baked by prepend, not inline

**Failing assertion** (`test/run_tests.sh:1620`):
```sh
assert_contains "smartSlurmLog/jobs/1.0.analyze.1/cmd.sh" 'label="sample 1"' \
  "submit-scope \$s baked per job"
```
Fixture `test/fixtures/end_block/pipeline.sh` (abridged):
```sh
number=$1
for s in {1..2}; do
    input=numbers$s.txt
    #@1,0,analyze,,input,sbatch -p short -c 1 --mem 2G -t 50:0
    label="sample $s"
    grep "$number" $input > $number.$s.txt
    cat <<INNER >> $number.$s.log
    processed $label with quotes: 'single' "double"
INNER
    #@end
done
```

**What the engine actually produces** (`smartSlurmLog/jobs/1.0.analyze.1/cmd.sh`,
captured verbatim from a real run):
```sh
#!/bin/bash
input=numbers1.txt
number=777
s=1
    # a multi-line body with a blank line, quotes, and a heredoc ...
    label="sample $s"
    grep "$number" $input > $number.$s.txt

    cat <<INNER >> $number.$s.log
    processed $label with quotes: 'single' "double"
INNER
```

**Mechanism:** the new T2 path bakes submit-scope variables by **prepending
`input=… / number=… / s=1` assignments** at the top of the per-job script, then
emitting the body **verbatim** (`$s`, `$number`, `$input` all left literal). On the
node those prepended assignments resolve `$s`→`1`, so the result is **functionally
correct** — the adjacent node-side checks pass:
- `in-block $label left for the node` ✅ (`processed $label` stays literal)
- `in-block var expanded on the node at run time` ✅ (`777.1.log` contains
  `processed sample 1`)

The only thing that fails is the assertion's expectation of **inline textual
substitution** (`label="sample 1"` literally in the body). The new mechanism
deliberately keeps the body byte-for-byte verbatim — that was the *point* of the
overhaul (so heredocs/quotes/continuations survive).

**Severity: low / test-only.** No cluster-visible defect: the node gets the right
values. This is stale test expectation, not an engine bug.

**Recommended resolution (harness):** change the assertion to match the intended
new contract — assert the prepended submit-scope assignments instead of inline
substitution, e.g.
```sh
assert_contains "…/cmd.sh" 's=1'          "submit-scope \$s baked (prepended) per job"
assert_contains "…/cmd.sh" 'number=777'   "submit-scope \$number baked (prepended)"
assert_contains "…/cmd.sh" 'label="sample $s"' "in-block body kept verbatim"
```
**Only** if inline baking is a deliberate requirement should the engine change; the
prepend form is cleaner and should probably just be blessed. **Engine owner: please
confirm "prepend `name=value` + verbatim body" is the intended submit-scope-baking
contract** so the harness can lock it in as a regression guard.

---

## Finding B — `rap_shapes`: legacy `\$` escape preserved verbatim breaks `awk`

**Failing assertion** (`test/run_tests.sh:961`):
```sh
assert_contains "totals.longsample.txt" "total_words=6" "fan-in: summed chunk counts correct"
```
Fixture `test/fixtures/rap_shapes/pipeline.sh`, the fan-in merge step:
```sh
#@5,4,merge,,in,sbatch -p short -c 1 --mem 100M -t 5:00
tw=$(cat cc.$s.*.txt | grep -o 'words=[0-9]*' | cut -d= -f2 | awk '{ s+=\$1 } END{ print s+0 }')
printf 'sample=%s total_words=%s\n' "$s" "$tw" > totals.$s.txt
#@end
```
Note the `\$1` — **legacy escaping**. It was written to protect `awk`'s field ref
`$1` from shell expansion inside the **old flatten/`--wrap`** path (a double-quoted
`--wrap="…"` context). Under the **new quoted here-doc verbatim body**, nothing is
unescaped, so `\$1` reaches `awk` literally.

**Confirmed behavior of the two program texts** (direct repro):
```
$ … | awk '{ s+=$1 }  END{ print "sum="s+0 }'     # clean (old path would unescape to this)
sum=6
$ … | awk '{ s+=\$1 } END{ print "sum="s+0 }'     # verbatim-preserved backslash
awk: 1: unexpected character '\'
exit=2
```
So `tw` ends up empty, `total_words=6` is never written, and the assertion fails. The
fan-out/fan-in **structure** is all correct (3 chunk jobs spawn, merge waits for
them, round-robin chunk counts are right) — only the summation line dies on the
stray backslash.

**Severity: medium / back-compat.** This is more than a fixture nit: **any pipeline
authored for the old `--wrap` path that hand-escaped `\$` will silently misbehave
under the new verbatim body** — `awk`/`sed`/`perl` one-liners, `${var}` guards, etc.
The NTC rAP drivers (pipeline2, RNAseqMapping, DOBBE_F, the new ChIPseq driver) are
exactly the population likely to carry such escaping. Failure mode is quiet: exit 0,
wrong/empty output file, no tool error.

**Decision needed from the engine owner — pick one:**
1. **De-escape on the way into the verbatim body** — strip a single leading `\`
   before `$` (`\$` → `$`) when baking the T2 body. Preserves back-compat with
   old-path-escaped drivers; risk is double-meaning for bodies that *want* a literal
   `\$`. (If chosen, add a slurmless block asserting `\$` is normalized.)
2. **Declare the break intentional** (verbatim means verbatim) and ship a
   **migration note** + a de-escape pass over the existing NTC drivers. Then the
   fixture is simply updated to plain `$1`.

Whichever way, the harness side is a one-line fixture change
(`test/fixtures/rap_shapes/pipeline.sh`: `s+=\$1` → `s+=$1`), but **that should not
land until the back-compat decision is made** — the fixture is currently a faithful
canary for the hazard.

---

## Reproduce

```sh
cd SmartSlurm/slurmless
export SS_NO_INSTALL=1 SS_NO_SH_REPOINT=1
./test/run_tests.sh end_block     # → 16/17, fails "submit-scope $s baked per job"
./test/run_tests.sh rap_shapes    # → 13/14, fails "fan-in: summed chunk counts correct"

# inspect the produced per-job script (Finding A):
cat /dev/shm/ss-scratch/work/m4_run/smartSlurmLog/jobs/1.0.analyze.1/cmd.sh
```

## Suggested next step

Run the `smartslurm-adversary` pass on the T2 verbatim-body path with these two as
seeds — the back-compat matrix (Finding B) is exactly its wheelhouse (silent,
exit-0, wrong result), and it can enumerate the other escape/quoting shapes
(`\$`, `${x}`, `\`\``, `$(...)`, nested heredocs) that old-path drivers may carry.

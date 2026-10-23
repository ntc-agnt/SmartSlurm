#!/bin/bash
# ---------------------------------------------------------------------------
# run_tests.sh  --  validate that runAsPipeline still works under mock Slurm.
#
#   ./test/run_tests.sh            run every block
#   ./test/run_tests.sh clean      run only blocks whose name matches "clean"
#   ./test/run_tests.sh --list     list every block and what it verifies (no run)
#   ./test/run_tests.sh --help     usage
#
# Ends with a grouped PASS/FAIL report (each block, with its checks indented).
# Exit status is non-zero if any assertion fails (CI-friendly).
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every block, in run order, and a one-line functional description of what it
# verifies. This is the single source of truth for block purposes: _begin looks
# the text up here, and --list prints it.
ALL_BLOCKS="clean_2step nested_fanout ragged_axes fail_exit0_empty known_broken_swallowed_done \
loop_detection oom_injection tool_stderr diagnose rerun end_block verbosity scaling_linear \
noise_fit scaling_exp contaminate_exit0 contaminate_exclude contaminate_prune firstpass_rate \
failure_floor manual_rerun_floor constant_model negslope_robust"

ss_purpose() {
  case "$1" in
    clean_2step)        echo "Baseline: convert a 2-step pipeline, submit under mock Slurm, and wire afterok dependencies end-to-end";;
    nested_fanout)      echo "Nested per-sample/per-chrom loops — a fan-out step (one grid cell backs multiple jobs) converts to valid bash and every job completes";;
    ragged_axes)        echo "Two steps whose loop axes are disjoint (sample ids vs group ids) — ragged addressing converts and runs end-to-end";;
    loop_detection)     echo "Documents the textual for*/done* loop foot-gun: a one-line for...done and a for-prefixed command corrupt the next step's flag";;
    fail_exit0_empty)   echo "Producer exits 0 but writes nothing and the consumer fails — documents the current symptom-vs-cause misattribution";;
    known_broken_swallowed_done) echo "A blank-line block right before a loop 'done' makes the converter emit invalid bash (the M4 block-closure foot-gun)";;
    oom_injection)      echo "Injected OOM/timeout/nonzero jobs are attributed correctly by cleanUp (no spurious .success)";;
    tool_stderr)        echo "Tool chatter on stderr is bracketed by sentinels, not misread as a failure";;
    diagnose)           echo "diagnose.sh classifies failure state/cause/action and emits the expected JSON contract";;
    rerun)              echo "Rerun menu (failed / all / from-step:N) materializes markers and honors the reachable guard";;
    end_block)          echo "'#@ … #@end' scripts-on-disk: closure validation, --lint, legacy back-compat, and in-block multivar escaping";;
    verbosity)          echo "Stdout verbosity: default A+ per-sample rows vs -v firehose vs -q silence";;
    scaling_linear)     echo "Linear mem/time vs input size — the real gnuplot fit recovers slope/intercept and prediction tracks the line";;
    noise_fit)          echo "~8% stochastic noise — the fit still recovers the slope; STDFIT>0 and RSquare are computed";;
    scaling_exp)        echo "Exponential truth vs SmartSlurm's linear fit — the model mismatch under-provisions at large input sizes";;
    contaminate_exit0)  echo "An exit-0-empty / mis-sized COMPLETED row drags the fitted slope downward (data contamination)";;
    contaminate_exclude) echo "OOM/failed rows are excluded from the fit — only COMPLETED rows are used";;
    contaminate_prune)  echo "An OOM storm prunes the offending program's failed and failure-disproven rows, keeping its validated history and unrelated programs";;
    firstpass_rate)     echo "Measured first-pass success rate tracks the targetFirstPassPct knob (and responds monotonically to it)";;
    failure_floor)      echo "Estimates never drop to/below a proven-insufficient allocation; a genuinely smaller input is unaffected";;
    manual_rerun_floor) echo "After a real emergent-OOM run, a fresh (manual) rerun estimate exceeds the proven-insufficient allocation (cross-run)";;
    constant_model)     echo "Constant memory (size-independent) with scaling time — mem uses the constant model, not a negative-slope collapse to the floor";;
    negslope_robust)    echo "Numeric edge cases (negative/sub-1 results, empty STDFIT) always yield a valid floored integer, never bc '-' garbage";;
    *)                  echo "$1";;
  esac
}

source "$HERE/lib/harness.sh"

# --list / --help short-circuit before any setup
case "${1:-}" in
  --list)
    echo "Test blocks (name — what it verifies):"; echo
    ss_catalog $ALL_BLOCKS
    exit 0;;
  --help|-h)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0;;
esac

ss_activate

FILTER="${1:-}"
WORK="${SS_SCRATCH:-/tmp/ss-scratch}/work"
FAILS=0; CHECKS=0

_want() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }

# ===========================================================================
_want clean_2step && {
  _begin clean_2step
  ss_new_workspace "$WORK/clean_2step"
  cp "$HERE"/fixtures/clean_2step/* .
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"; rc=$?
  assert_rc "$rc" 0 "runAsPipeline exits 0"
  driver=$(ls smartSlurmLog/slurmPipeLine.*.sh 2>/dev/null | grep -v dryrun | head -1)
  assert_file    "$driver"                                   "converted driver produced"
  assert_valid_bash "$driver"                                "driver is valid bash"
  assert_file    "smartSlurmLog/1.0.findNumber.1.success"    "step 1a marked success"
  assert_file    "smartSlurmLog/1.0.findNumber.2.success"    "step 1b marked success"
  assert_file    "smartSlurmLog/2.1.mergeNumber.success"     "step 2 marked success"
  assert_no_file "smartSlurmLog/2.1.mergeNumber.failed"      "step 2 not marked failed"
  assert_nonempty "777.1.txt"                                "payload 1a wrote output"
  assert_nonempty "all777.txt"                               "merge produced combined output"
  assert_contains "all777.txt" "777"                         "merged output contains data"
  assert_contains "smartSlurmLog/allJobs.txt" "mergeNumber"  "allJobs.txt records the DAG"
  # dependency wiring: merge job lists both producers as afterok deps
  assert_contains "smartSlurmLog/allJobs.txt" ":"            "merge depends on upstream job ids"
  echo
}

# ===========================================================================
# Nested loops produce a FAN-OUT step: one (sample,step) grid cell backs multiple
# jobs (per-chromosome). Proves rAP converts nested #@ loops to valid bash and
# every fanned-out job runs — the structural case behind checkRunGrid's '@' cells.
_want nested_fanout && {
  _begin nested_fanout
  ss_new_workspace "$WORK/nested_fanout"
  cp "$HERE"/fixtures/nested_fanout/* .; chmod +x ./*.sh 2>/dev/null || true
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 2G -t 50:0"; rc=$?
  assert_rc "$rc" 0 "runAsPipeline exits 0"
  driver=$(ls smartSlurmLog/slurmPipeLine.*.sh 2>/dev/null | grep -v dryrun | head -1)
  assert_valid_bash "$driver" "nested-loop driver is valid bash"
  assert_file "smartSlurmLog/1.0.prep.1.success"          "prep (sample 1) succeeded"
  assert_file "smartSlurmLog/1.0.prep.2.success"          "prep (sample 2) succeeded"
  # fan-out: step 2 is one grid cell (2.1.callChrom) backing 2 samples x 3 chroms
  n=$(ls smartSlurmLog/2.1.callChrom.*.success 2>/dev/null | wc -l)
  assert_rc 6 "$n" "fan-out produced 6 callChrom jobs (2 samples x 3 chroms)"
  assert_file "smartSlurmLog/3.2.summarize.success"       "summarize (downstream of the fan-out) succeeded"
  assert_contains "smartSlurmLog/allJobs.txt" "callChrom"  "allJobs.txt records the fan-out step"
  assert_nonempty "summary777.txt"                        "summarize combined the fanned-out outputs"
  echo
}

# ===========================================================================
# Two steps whose loop axes are DISJOINT (sample ids {1,2} vs group ids {7,8}).
# Proves rAP addresses ragged axes without cross-contaminating the flags.
_want ragged_axes && {
  _begin ragged_axes
  ss_new_workspace "$WORK/ragged_axes"
  cp "$HERE"/fixtures/ragged_axes/* .; chmod +x ./*.sh 2>/dev/null || true
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 2G -t 50:0"; rc=$?
  assert_rc "$rc" 0 "runAsPipeline exits 0"
  driver=$(ls smartSlurmLog/slurmPipeLine.*.sh 2>/dev/null | grep -v dryrun | head -1)
  assert_valid_bash "$driver" "ragged-axis driver is valid bash"
  assert_file "smartSlurmLog/1.0.align.1.success"      "align axis: sample 1 succeeded"
  assert_file "smartSlurmLog/1.0.align.2.success"      "align axis: sample 2 succeeded"
  assert_file "smartSlurmLog/2.1.perGroup.7.success"   "group axis: group 7 succeeded (disjoint id)"
  assert_file "smartSlurmLog/2.1.perGroup.8.success"   "group axis: group 8 succeeded (disjoint id)"
  assert_nonempty "group7.txt"                         "group-axis step produced output"
  echo
}

# ===========================================================================
_want fail_exit0_empty && {
  _begin fail_exit0_empty
  ss_new_workspace "$WORK/fail_exit0_empty"
  cp "$HERE"/fixtures/fail_exit0_empty/* .
  ss_run_pipeline "./pipeline.sh 42" "sbatch -p short -c 1 --mem 4G -t 50:0"; rc=$?
  assert_rc "$rc" 0 "runAsPipeline exits 0 (submission succeeds)"
  assert_empty   "all42.txt"                              "producer wrote an EMPTY output"
  # CURRENT (pre-overhaul) behavior: producer exited 0 -> marked success (the bug)
  assert_file    "smartSlurmLog/1.0.makeTable.success"    "[baseline] producer WRONGLY marked success"
  # the symptom step is the one that actually fails
  assert_file    "smartSlurmLog/2.1.consume.failed"       "[baseline] consumer (symptom) marked failed"
  assert_contains "smartSlurmLog/2.1.consume.out" "empty" "consumer error mentions empty input"
  echo "    note: after M1+M2 this fixture flips — producer FAILED, consumer a symptom."
  echo
}

# ===========================================================================
_want known_broken_swallowed_done && {
  _begin known_broken_swallowed_done
  ss_new_workspace "$WORK/known_broken"
  cp "$HERE"/fixtures/known_broken_swallowed_done/* .
  chmod +x ./*.sh 2>/dev/null || true
  ss_run_pipeline "./pipeline.sh 5" "sbatch -p short -c 1 --mem 4G -t 50:0" --dryrun || true
  driver=$(ls smartSlurmLog/slurmPipeLine.*.dryrun.sh 2>/dev/null | head -1)
  assert_file "$driver" "driver was emitted"
  # the outer `done` is swallowed into the step-2 --wrap; driver is invalid bash
  assert_invalid_bash "$driver" "driver is INVALID bash (swallowed 'done' — known issue)"
  assert_contains "$driver" 'done;' "the 'done' was absorbed into a wrapped command"
  echo "    note: M4's #@ … #@end closure fixes this; fixture is the regression anchor."
  echo
}

_want loop_detection && {
  _begin loop_detection
  ss_new_workspace "$WORK/loop_detection"
  cp "$HERE"/fixtures/loop_detection/* .
  chmod +x ./*.sh 2>/dev/null || true
  ss_run_pipeline "./pipeline.sh input" "sbatch -p short -c 1 --mem 100M -t 5:0" --dryrun || true
  driver=$(ls smartSlurmLog/slurmPipeLine.*.dryrun.sh 2>/dev/null | head -1)
  assert_file "$driver" "driver was emitted"
  # control: the step before any trap carries a clean flag
  assert_contains "$driver" 'flag: 1\.0\.first' "step before the loop trap is clean (1.0.first)"
  # KNOWN BUG 1: a one-line `for x ...; done` pushes .$x and never pops, so the
  # NEXT step's flag is corrupted with a stray .$x loop suffix.
  assert_contains "$driver" 'flag: 2\.1\.second\.\$x' "KNOWN BUG: one-line for...done corrupts the next flag (2.1.second.\$x)"
  # KNOWN BUG 2: `format_report ...` (first word starts with "for") is misread as
  # a loop; its 2nd token (--nope) becomes a bogus loop var on top of the first.
  assert_contains "$driver" 'flag: 3\.2\.third\.\$x\.\$--nope' "KNOWN BUG: for-prefixed command corrupts the flag (3.2.third.\$x.\$--nope)"
  echo "    note: when rAP loop detection is hardened (word-boundary match + loop-var"
  echo "    identifier validation + one-line guard + end-of-conversion balance check),"
  echo "    steps 2 and 3 should read clean (2.1.second / 3.2.third) — flip these asserts then."
  echo
}

# ===========================================================================
_want oom_injection && {
  _begin oom_injection
  ss_new_workspace "$WORK/oom_injection"
  cp "$HERE"/fixtures/clean_2step/* .
  chmod +x ./*.sh 2>/dev/null || true
  MOCK_FAIL_JOB=mergeNumber MOCK_FAIL_MODE=oom \
    ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"; rc=$?
  assert_rc "$rc" 0 "runAsPipeline exits 0 (submission still succeeds)"
  assert_file    "smartSlurmLog/1.0.findNumber.1.success"      "unrelated producer still succeeds"
  assert_no_file "smartSlurmLog/2.1.mergeNumber.success"       "OOM job did NOT touch .success"
  assert_contains "smartSlurmLog/2.1.mergeNumber.out" "Out Of Memory" "OOM message present in job log"
  assert_contains "smartSlurmLog/2.1.mergeNumber.out" "jobStatus: OOM" "cleanUp classifies job as OOM via sacct"
  echo
}

# ===========================================================================
_want tool_stderr && {
  _begin tool_stderr
  ss_new_workspace "$WORK/tool_stderr"
  cp "$HERE"/fixtures/tool_stderr/* .
  chmod +x ./*.sh 2>/dev/null || true
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"; rc=$?
  out=smartSlurmLog/1.0.noisyTool.out
  assert_file    "$out"                                    "job .out exists"
  assert_contains "$out" "SmartSlurm setup:"               "setup sentinel present"
  assert_contains "$out" "SmartSlurm step output:"         "step-output sentinel present"
  assert_contains "$out" "SmartSlurm job report:"          "job-report sentinel present"
  # the tool region = lines between the step-output and job-report sentinels
  awk '/SmartSlurm step output:/{f=1;next} /SmartSlurm job report:/{f=0} f' "$out" > region.txt
  assert_contains region.txt "ERROR: no usable records"   "killing error sits inside the tool region"
  assert_contains region.txt "WARNING: 3 records skipped"  "tool stderr sits inside the tool region"
  if grep -q "memCpuMonitor" region.txt; then _fail "monitor noise leaked into tool region"; else _pass "monitor noise kept out of tool region"; fi
  if grep -qE "Cleanup counter|gnuplot|Job summary" region.txt; then _fail "teardown noise leaked into tool region"; else _pass "teardown noise kept out of tool region"; fi
  echo
}

# ===========================================================================
_want diagnose && {
  _begin diagnose
  # helper: assert a JSON field value from diagnose.sh
  dfield() { diagnose.sh "$2" --log "$1" --json | grep -o "\"$3\":\"\?[^\",}]*" | head -1 | sed 's/.*"'"$3"'":"\?//'; }
  adiag() { local got; got="$(dfield "$1" "$2" "$3")"; [ "$got" = "$4" ] && _pass "diag $2 → $3=$4" || _fail "diag $2 → $3=$4" "got '$got'"; }

  ss_new_workspace "$WORK/d_clean"; cp "$HERE"/fixtures/clean_2step/* .; chmod +x ./*.sh
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  adiag smartSlurmLog 1.0.findNumber.1 failed false
  adiag smartSlurmLog 1.0.findNumber.1 action NONE

  ss_new_workspace "$WORK/d_tool"; cp "$HERE"/fixtures/tool_stderr/* .; chmod +x ./*.sh
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  adiag smartSlurmLog 1.0.noisyTool state COMPLETED_NOSUCCESS
  if diagnose.sh 1.0.noisyTool --log smartSlurmLog --json | grep -q 'ERROR: no usable records'; then _pass "diag noisyTool evidence = tool error line"; else _fail "diag noisyTool evidence = tool error line"; fi

  ss_new_workspace "$WORK/d_cmd"; cp "$HERE"/fixtures/tool_cmd_notfound/* .; chmod +x ./*.sh 2>/dev/null
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  adiag smartSlurmLog 1.0.badcmd category environment:missing-command
  adiag smartSlurmLog 1.0.badcmd action DOOMED

  ss_new_workspace "$WORK/d_segf"; cp "$HERE"/fixtures/tool_segfault/* .; chmod +x ./*.sh
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  adiag smartSlurmLog 1.0.crasher category tool:crash
  adiag smartSlurmLog 1.0.crasher action DOOMED

  ss_new_workspace "$WORK/d_oom"; cp "$HERE"/fixtures/clean_2step/* .; chmod +x ./*.sh
  MOCK_FAIL_JOB=findNumber.1 MOCK_FAIL_MODE=oom ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  adiag smartSlurmLog 1.0.findNumber.1 state OOM
  adiag smartSlurmLog 1.0.findNumber.1 retryable true
  adiag smartSlurmLog 2.1.mergeNumber category orphaned:upstream-failed
  adiag smartSlurmLog 2.1.mergeNumber action CHECK_UPSTREAM
  echo
}

# ===========================================================================
_want rerun && {
  _begin rerun
  reissue() { smartSlurmRerun="$1" bash "$SMARTSLURM_ROOT/bin/runAsPipeline" --script "./pipeline.sh 9" \
      --sbatch-options "sbatch -p short -c 1 --mem 2G -t 50:0" --tmp noTmp </dev/null >"$2" 2>&1; }

  # --- failed: keep successful, rerun failed + orphaned downstream ---
  ss_new_workspace "$WORK/rerun_failed"
  cp "$HERE"/fixtures/three_step/* .; chmod +x ./*.sh
  MOCK_FAIL_JOB=count.1 MOCK_FAIL_MODE=oom ss_run_pipeline "./pipeline.sh 9" "sbatch -p short -c 1 --mem 2G -t 50:0"
  assert_no_file "smartSlurmLog/2.1.count.1.success" "run1: count.1 failed (OOM)"
  assert_file    "smartSlurmLog/1.0.trim.1.success"  "run1: trim.1 succeeded"
  t_keep=$(stat -c '%Y' smartSlurmLog/1.0.trim.1.success); sleep 1.1
  reissue failed reissue.log
  assert_rc $? 0 "failed: re-issue exits 0 (non-interactive)"
  assert_file "smartSlurmLog/2.1.count.1.success" "failed: count.1 reran and succeeded"
  assert_file "smartSlurmLog/3.2.merge.success"   "failed: orphaned merge reran and succeeded"
  [ "$(stat -c '%Y' smartSlurmLog/1.0.trim.1.success)" = "$t_keep" ] && _pass "failed: successful trim.1 was KEPT (not rerun)" || _fail "failed: successful trim.1 was KEPT (not rerun)"

  # --- from-step: keep step1, rerun step2 onward ---
  ss_new_workspace "$WORK/rerun_fromstep"
  cp "$HERE"/fixtures/three_step/* .; chmod +x ./*.sh
  ss_run_pipeline "./pipeline.sh 9" "sbatch -p short -c 1 --mem 2G -t 50:0"
  s_trim=$(stat -c '%Y' smartSlurmLog/1.0.trim.1.success); s_cnt=$(stat -c '%Y' smartSlurmLog/2.1.count.1.success); sleep 1.1
  reissue fromStep:2 fs.log
  [ "$(stat -c '%Y' smartSlurmLog/1.0.trim.1.success)" = "$s_trim" ] && _pass "from-step2: step1 trim.1 KEPT" || _fail "from-step2: step1 trim.1 KEPT"
  [ "$(stat -c '%Y' smartSlurmLog/2.1.count.1.success)" != "$s_cnt" ] && _pass "from-step2: step2 count.1 RERAN" || _fail "from-step2: step2 count.1 RERAN"
  assert_file "smartSlurmLog/reRunAllSuccessJobs2.txt" "from-step2: step2 marked rerun"
  assert_file "smartSlurmLog/skipAllSuccessJobs1.txt"  "from-step2: step1 marked keep"

  # --- reachable guard: cannot pick a step the run never reached ---
  reissue fromStep:9 guard.log
  assert_contains "guard.log" "not in the completed set" "guard: unreached step 9 rejected"
  echo
}

# ===========================================================================
_want end_block && {
  _begin end_block
  # (1) a real #@end pipeline: converts to valid bash, runs, writes per-job scripts
  ss_new_workspace "$WORK/m4_run"
  cp "$HERE"/fixtures/end_block/* .; chmod +x ./*.sh
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  assert_file "smartSlurmLog/1.0.analyze.1.success" "analyze.1 succeeded"
  assert_file "smartSlurmLog/2.1.merge.success"     "merge succeeded"
  assert_file "smartSlurmLog/jobs/1.0.analyze.1/cmd.sh" "per-job script persisted on disk"
  # submit-scope var baked ($s->1, $number->777), in-block var left literal ($label)
  assert_contains "smartSlurmLog/jobs/1.0.analyze.1/cmd.sh" 'label="sample 1"' "submit-scope \$s baked per job"
  assert_contains "smartSlurmLog/jobs/1.0.analyze.1/cmd.sh" 'processed $label'  "in-block \$label left for the node"
  assert_contains "777.1.log" "processed sample 1" "in-block var expanded on the node at run time"

  # (1b) regression guard: MULTIPLE in-block vars must each be escaped (the
  # conversion runs with IFS='', which once broke the var-splitting so only a
  # single-var block escaped correctly). report step assigns a,b,c then uses them.
  ss_new_workspace "$WORK/m4_multivar"
  printf '%s\n' '#!/bin/sh' 'for s in 1 2; do' '  in=in$s.txt' '' \
    '  #@1,0,multi,,in,sbatch -p short -c 1 --mem 100M -t 5:00' \
    '  a=$(wc -w < $in)' '  b=$(head -1 $in)' '  c=$(wc -c < $in)' \
    '  printf "%s w=%s h=%s c=%s\n" "$s" "$a" "$b" "$c" > out$s.txt' \
    '  #@end' '' 'done' > pipeline.sh
  printf 'hello world\n' > in1.txt; printf 'foo bar baz\n' > in2.txt; chmod +x pipeline.sh
  ss_run_pipeline "./pipeline.sh" "sbatch -p short -c 1 --mem 100M -t 5:00"
  assert_file "smartSlurmLog/1.0.multi.1.success" "multivar: job succeeded"
  assert_contains "smartSlurmLog/jobs/1.0.multi.1/cmd.sh" 'w=%s h=%s c=%s' "multivar: printf format intact"
  # all three in-block vars must survive as literal $a/$b/$c in the per-job script
  if grep -q 'w=\$a h=\$b c=\$c' "smartSlurmLog/jobs/1.0.multi.1/cmd.sh" || grep -qE '"\$a" "\$b" "\$c"' "smartSlurmLog/jobs/1.0.multi.1/cmd.sh"; then _pass "multivar: all in-block vars left for the node"; else _fail "multivar: all in-block vars left for the node"; fi
  assert_contains "out1.txt" "w=2 h=hello world c=12" "multivar: node-side expansion correct"


  ss_new_workspace "$WORK/m4_legacy"
  cp "$HERE"/fixtures/clean_2step/* .; chmod +x ./*.sh
  ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 4G -t 50:0"
  assert_file "smartSlurmLog/1.0.findNumber.1.success" "legacy blank-line block still runs"
  [ ! -d smartSlurmLog/jobs ] && _pass "legacy block used --wrap (no jobs/ dir)" || _fail "legacy block used --wrap (no jobs/ dir)"

  # (3) closure validations (dryrun; must emit Error and not build a runnable driver)
  _m4bad() { ss_new_workspace "$WORK/m4_$1" >/dev/null 2>&1; printf '%s\n' "$2" > pipeline.sh
    printf '777\n' > numbers1.txt; chmod +x pipeline.sh
    ss_run_pipeline "./pipeline.sh 777" "sbatch -p short -c 1 --mem 2G -t 50:0" --dryrun
    if grep -qi 'Error:' "$LAST_RUN_LOG"; then _pass "validation: $1 rejected"; else _fail "validation: $1 rejected"; fi; }
  _m4bad orphan_end  $'#!/bin/sh\n#@1,0,a,,,sbatch -p short\necho hi\n#@end\n#@end'
  _m4bad nested_open $'#!/bin/sh\n#@1,0,a,,,sbatch -p short\necho hi\n#@2,0,b,,,sbatch -p short\necho bye\n#@end'
  _m4bad unclosed    $'#!/bin/sh\n#@1,0,a,,,sbatch -p short\necho hi\n#@end\n#@2,0,b,,,sbatch -p short\necho bye'

  # (4) --lint exit codes
  ss_new_workspace "$WORK/m4_lintok"; cp "$HERE"/fixtures/end_block/* .; chmod +x ./*.sh
  bash "$SMARTSLURM_ROOT/bin/runAsPipeline" --script "./pipeline.sh 777" --sbatch-options "sbatch -p short -c 1 --mem 4G -t 50:0" --tmp noTmp --lint </dev/null >/dev/null 2>&1
  assert_rc $? 0 "--lint passes a good #@end pipeline (exit 0)"
  ss_new_workspace "$WORK/m4_lintbad"; printf '%s\n' $'#!/bin/sh\n#@1,0,a,,,sbatch -p short\necho hi\n#@2,0,b,,,sbatch -p short\necho bye\n#@end' > pipeline.sh; printf '777\n' > numbers1.txt; chmod +x pipeline.sh
  bash "$SMARTSLURM_ROOT/bin/runAsPipeline" --script "./pipeline.sh 777" --sbatch-options "sbatch -p short -c 1 --mem 4G -t 50:0" --tmp noTmp --lint </dev/null >/dev/null 2>&1
  assert_rc $? 1 "--lint fails a malformed pipeline (exit 1)"
  echo
}

_want verbosity && {
  _begin verbosity
  vrun() { ss_new_workspace "$WORK/vb_$1" >/dev/null 2>&1; cp "$HERE"/fixtures/three_step/* .; chmod +x ./*.sh
    bash "$SMARTSLURM_ROOT/bin/runAsPipeline" --script "./pipeline.sh 9" --sbatch-options "sbatch -p short -c 1 --mem 2G -t 50:0" --tmp noTmp $2 </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$3"; }

  vrun normal ""   n.txt
  assert_contains  n.txt "sample .*steps"       "normal: shows sample/steps header"
  assert_contains  n.txt "merge .*3✓"           "normal: shows a per-sample row"
  assert_contains  n.txt "1✓ 2✓"               "normal: appends per-step glyphs"
  assert_contains  n.txt "Submitted 5, kept 0" "normal: one-line summary"
  if grep -q "Working on inputs" n.txt; then _fail "normal: firehose suppressed"; else _pass "normal: firehose suppressed"; fi

  vrun verbose "-v" v.txt
  assert_contains  v.txt "Working on inputs"      "verbose: per-job firehose restored"
  assert_contains  v.txt "All submitted jobs"     "verbose: full job table on stdout"
  if grep -q "1✓ 2✓" v.txt; then _fail "verbose: no A+ rows"; else _pass "verbose: no A+ rows"; fi

  vrun quiet "-q" q.txt
  if grep -qE "Submitting jobs|1✓|Working on inputs" q.txt; then _fail "quiet: silent on success"; else _pass "quiet: silent on success"; fi
  echo
}

# ===========================================================================
# M1: resource capture / curve fitting / jobRecords (resource-model layer)
# ===========================================================================

_want scaling_linear && {
  _begin scaling_linear
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/scaling_linear" >/dev/null
  ss_run_sweep scaling_linear "1000 2000 3000 4000 6000 8000" "sbatch -p short -c 1 --mem 16G -t 600:0"
  jr="$smartSlurmJobRecordDir/jobRecord.txt"
  n=$(awk -F, '$9=="COMPLETED" && $12=="scaleLin"{c++} END{print c+0}' "$jr")
  assert_rc 6 "$n" "six COMPLETED records, one per size"
  # size 4000 recorded exactly per model: mem=0.5*4000+200=2200, time=0.02*4000+10=90
  assert_contains "$jr" "4000,.*,2200,90,COMPLETED,.*,scaleLin,none" "size 4000 row matches model exactly"
  ss_fit scaleLin none >/dev/null
  mstat="$smartSlurmJobRecordDir/stats/scaleLin.none.mem.stat"
  assert_near 0.5 "$(stat_val Finala "$mstat")" 0.05 "real gnuplot fit: mem slope ~0.5"
  assert_near 200 "$(stat_val Finalb "$mstat")" 0.10 "real gnuplot fit: mem intercept ~200"
  assert_rc 6 "$(stat_val SCount "$mstat")" "fit used all six points"
  # prediction at a new in-range size tracks truth + margin: 0.5*5000+200 +500extra = 3200
  pm=$(estimateResource.sh scaleLin none ,jobSize:5000 p 4096 120 2>/dev/null | cut -d' ' -f2)
  assert_near 3200 "$pm" 0.10 "prediction at size 5000 tracks the fitted line (+margin)"
  echo
  fi
}

# ===========================================================================
_want noise_fit && {
  _begin noise_fit
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/noise_fit" >/dev/null
  ss_run_sweep scaling_noise "1000 2000 3000 4000 5000 6000 7000 8000 9000 10000" \
               "sbatch -p short -c 1 --mem 32G -t 900:0"
  jr="$smartSlurmJobRecordDir/jobRecord.txt"
  # noise really perturbs the data: the size-1000 row is NOT the exact 700
  exact1000=$(awk -F, '$2==1000 && $12=="scaleLin"{print $7; exit}' "$jr")
  if [ "$exact1000" != "700" ]; then _pass "noise perturbs recorded mem (size 1000: $exact1000 != exact 700)"
  else _fail "noise perturbs recorded mem" "size-1000 mem is exactly 700 (no noise?)"; fi
  ss_fit scaleLin none >/dev/null
  mstat="$smartSlurmJobRecordDir/stats/scaleLin.none.mem.stat"
  assert_near 0.5 "$(stat_val Finala "$mstat")" 0.20 "noisy fit recovers slope ~0.5 (within 20%)"
  assert_rc 10 "$(stat_val SCount "$mstat")" "fit used all ten points"
  # STDFIT (residual spread) is populated and positive once there IS noise -- it
  # is EMPTY for perfectly-collinear (noiseless) history (see scaling_linear).
  sd=$(stat_val STDFIT "$mstat")
  if [ -n "$sd" ] && awk -v s="$sd" 'BEGIN{exit !(s>0)}'; then _pass "noisy fit reports STDFIT>0 (residual spread detected): $sd"
  else _fail "noisy fit reports STDFIT>0" "STDFIT='$sd'"; fi
  # RSquare is computed correctly (gnuplot-6 'Correlation: r = X' parsed): strong
  # linear trend here -> R^2 well above 0.5. (On unpatched bin/ this reads 0.)
  rsq=$(stat_val RSquare "$mstat")
  if [ -n "$rsq" ] && awk -v r="$rsq" 'BEGIN{exit !(r>0.5)}'; then _pass "RSquare computed (>0.5): $rsq"
  else _fail "RSquare computed (>0.5)" "RSquare='$rsq' (unpatched bin/ records 0 under gnuplot 6)"; fi
  echo
  fi
}

# ===========================================================================
_want scaling_exp && {
  _begin scaling_exp
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/scaling_exp" >/dev/null
  # generous allocation so every point COMPLETES (no OOM -> no fail-pruning -> fast)
  ss_run_sweep scaling_exp "1000 2000 3000 4000 6000 8000" "sbatch -p short -c 1 --mem 64G -t 900:0"
  jr="$smartSlurmJobRecordDir/jobRecord.txt"
  n=$(awk -F, '$9=="COMPLETED" && $12=="scaleExp"{c++} END{print c+0}' "$jr")
  assert_rc 6 "$n" "six COMPLETED exp records"
  # recorded curve is convex (exp), not linear: the step 6000->8000 jump far
  # exceeds the step 1000->3000 jump (a straight line would make them equal-ish).
  read -r m1 m3 m6 m8 <<<"$(awk -F, '$12=="scaleExp"{a[$2]=$7} END{print a[1000],a[3000],a[6000],a[8000]}' "$jr")"
  if [ $(( m8 - m6 )) -gt $(( (m3 - m1) * 3 )) ]; then
    _pass "recorded mem is convex/exponential (d(6000->8000)=$((m8-m6)) >> d(1000->3000)=$((m3-m1)))"
  else _fail "recorded mem is convex/exponential" "jumps: $((m8-m6)) vs $((m3-m1))"; fi
  # the LINEAR fit under-predicts the exponential truth at a large size
  ss_fit scaleExp none >/dev/null
  big=16000
  truth=$("$HERE/mockSlurm/resourceModel.sh" "$HERE/models/scaling_exp.model" "$big" | cut -d' ' -f1)
  pred=$(estimateResource.sh scaleExp none ,jobSize:$big p 4096 120 2>/dev/null | cut -d' ' -f2)
  echo "    (info) size=$big  linear-prediction=$pred  exponential-truth=$truth"
  if [ "${pred:-0}" -lt "$(( truth / 2 ))" ]; then
    _pass "linear fit under-provisions exp truth at size $big (pred $pred < half of truth $truth)"
  else _fail "linear fit under-provisions exp truth at size $big" "pred=$pred truth=$truth"; fi
  echo
  fi
}

# ===========================================================================
# Contamination of jobRecords: the headline question -- under what conditions do
# bad/error data enter and corrupt the learning DB? Each block constructs ONE
# condition deterministically and asserts the consequence.
# ===========================================================================

_want contaminate_exit0 && {
  _begin contaminate_exit0
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/contaminate_exit0" >/dev/null
  # clean linear history (mem = 0.5*size + 200)
  for s in 1000 2000 4000 6000 8000; do ss_seed_record cjob none "$s" $((s/2+200)) 30 COMPLETED 1; done
  ss_fit cjob none >/dev/null
  clean=$(stat_val Finala "$smartSlurmJobRecordDir/stats/cjob.none.mem.stat")
  assert_near 0.5 "$clean" 0.05 "clean history fits slope ~0.5"
  # a large-input job that exits 0 having done nothing (or whose inputSize was
  # mis-measured) records a near-zero mem at a big size -> drags the slope down
  ss_seed_record cjob none 10000 60 30 COMPLETED 1
  ss_fit cjob none >/dev/null
  dirty=$(stat_val Finala "$smartSlurmJobRecordDir/stats/cjob.none.mem.stat")
  echo "    (info) slope clean=$clean  contaminated=$dirty"
  if awk -v c="$clean" -v d="$dirty" 'BEGIN{exit !(d < c*0.8)}'; then
    _pass "one exit-0-empty row corrupts the slope downward ($clean -> $dirty)"
  else _fail "exit-0-empty row corrupts the slope" "clean=$clean dirty=$dirty"; fi
  echo
  fi
}

# ===========================================================================
_want contaminate_exclude && {
  _begin contaminate_exclude
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/contaminate_exclude" >/dev/null
  for s in 1000 2000 4000 6000 8000; do ss_seed_record xjob none "$s" $((s/2+200)) 30 COMPLETED 1; done
  ss_fit xjob none >/dev/null
  before=$(stat_val Finala "$smartSlurmJobRecordDir/stats/xjob.none.mem.stat")
  # add OOM rows with absurd mem at a big size: if they leaked into the fit the
  # slope would explode. They must be ignored (estimateResource greps COMPLETED).
  ss_seed_record xjob none 10000 999999 120 OOM 4
  ss_fit xjob none >/dev/null
  after=$(stat_val Finala "$smartSlurmJobRecordDir/stats/xjob.none.mem.stat")
  if awk -v b="$before" -v a="$after" 'BEGIN{exit !(a==b || (a<b*1.05 && a>b*0.95))}'; then
    _pass "OOM rows excluded from the fit (slope unchanged: $before -> $after)"
  else _fail "OOM rows excluded from the fit" "slope moved $before -> $after"; fi
  echo "    (note) the danger of OOM rows is not direct fit entry but fail-pruning -- see contaminate_prune"
  echo
  fi
}

# ===========================================================================
_want contaminate_prune && {
  _begin contaminate_prune
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/contaminate_prune" >/dev/null
  jr="$smartSlurmJobRecordDir/jobRecord.txt"
  # progA history: small legit records (survive), one BOGUS under-reporter at a
  # large size (tiny mem -- the exit-0-empty kind), one legit HIGH-mem large
  # record (survives). Plus an UNRELATED progB, and 5 recent OOM fails for progA.
  ss_seed_record progA none 1000 700    15  COMPLETED 3     # legit small
  ss_seed_record progA none 12000 50    30  COMPLETED 1     # BOGUS: huge input, ~0 mem
  ss_seed_record progA none 15000 100000 200 COMPLETED 1    # legit: huge input, huge mem
  ss_seed_record progB none 1000 900    20  COMPLETED 4     # unrelated program
  ss_seed_record progA none 9000 8000   120 OOM 6           # proven-insufficient allocs (>threshold)
  assert_rc 4 "$(awk -F, '$12=="progB"{c++}END{print c+0}' "$jr")" "progB starts with 4 unrelated records"
  # one more real emergent-OOM progA job (size 9000) tips recentFails over threshold
  # True need (80000) sits ABOVE what the smarter estimator will predict for size
  # 9000 from this history (~50k) but BELOW the legit-high record (100000), so the
  # job OOMs on first attempt (triggering the prune) and the OOM alloc stays under
  # the legit-high record (which must be kept).
  cat > "$HERE/models/_prune.model" <<EOF
MODEL_PROGRAM=progA
MODEL_REF=none
MEM_FORM=const
MEM_B=80000
TIME_FORM=const
TIME_B=30
SEED=1
EOF
  pd="$WORK/contaminate_prune/oomjob"; mkdir -p "$pd/.mockstate/jobs"
  ( cd "$pd"
    export MOCK_SLURM_STATE="$pd/.mockstate"
    truncate -s 9000K in.dat
    printf '#!/bin/sh\ninput=$1\n#@1,0,progA,,input,sbatch -p short -c 1 --mem 4G -t 60:0\ncat $input >/dev/null\n\n' > pipeline.sh
    MOCK_FAIL_MODE=oom timeout 115 bash "$SMARTSLURM_ROOT/bin/runAsPipeline" \
      --script "./pipeline.sh in.dat" --sbatch-options "sbatch -p short -c 1 --mem 4G -t 60:0" \
      --tmp noTmp >rap.log 2>&1 )
  rm -f "$HERE/models/_prune.model"
  qa() { awk -F, -v p="$1" -v s="$2" '$12==p && $2==s && $9=="COMPLETED"{c++}END{print c+0}' "$jr"; }
  assert_file "$(ls "$smartSlurmJobRecordDir"/jobRecord.back.*.txt 2>/dev/null | head -1)" "fail-pruning backed up jobRecord.txt"
  # Conservative suspect-removal: keep-filter drops the offending program's failed
  # rows AND any COMPLETED row disproven by a failure (size>=failing size and
  # mem<=proven-insufficient allocation). Unrelated programs and validated
  # (consistent) COMPLETED history are kept.
  assert_rc 4 "$(awk -F, '$12=="progB"{c++}END{print c+0}' "$jr")"  "unrelated progB preserved (4)"
  assert_rc 3 "$(qa progA 1000)"   "progA legit small history preserved (size 1000 x3)"
  assert_rc 1 "$(qa progA 15000)"  "progA legit HIGH-mem large record preserved (size 15000)"
  assert_rc 0 "$(qa progA 12000)"  "progA BOGUS under-reporter removed (size 12000, ~0 mem)"
  echo
  fi
}

# ===========================================================================
_want firstpass_rate && {
  _begin firstpass_rate
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/firstpass_rate" >/dev/null
  mkdir -p smartSlurmLog
  mdl="$HERE/models/scaling_bignoise.model"
  # Seed ~100 realistic COMPLETED records (model + 8% noise) so the fit's residual
  # percentile is well-resolved. (A 10-point sweep makes p93 collapse to the max.)
  i=1; while [ "$i" -le 100 ]; do
    size=$(( 1000 + (i * 97) % 9000 ))
    read tm tt tr <<<"$("$HERE/mockSlurm/resourceModel.sh" "$mdl" "$size" "$i")"
    ss_seed_record bigJob none "$size" "$tm" "$tt" COMPLETED 1
    i=$((i+1))
  done
  ss_fit bigJob none >/dev/null
  # Simulate "future" jobs (fresh noise draws = unseen seeds). A job passes first
  # try when the estimate at targetPct >= its realized need.
  measure() { # <targetPct> -> integer success percentage over the sample
    local pct="$1" n=0 ok=0 size seed true est
    for size in 1500 3500 5500 7500 9500; do
      for seed in $(seq 201 224); do
        true=$("$HERE/mockSlurm/resourceModel.sh" "$mdl" "$size" "$seed" | cut -d' ' -f1)
        # Measure the B1 MARGIN itself (calculateMemTime), isolated from the separate
        # extraMem safety buffer that estimateResource adds on top.
        est=$(targetFirstPassPct="$pct" calculateMemTime.sh bigJob none "$size" 2>/dev/null | cut -d' ' -f1)
        n=$((n+1)); [ "${est:-0}" -ge "${true:-0}" ] && ok=$((ok+1))
      done
    done
    echo $(( ok * 100 / n ))
  }
  r93=$(measure 93); r70=$(measure 70); r99=$(measure 99)
  echo "    (info) first-pass rate: p70=$r70%  p93=$r93%  p99=$r99%"
  if [ "$r93" -ge 85 ] && [ "$r93" -le 98 ]; then _pass "default (p93) first-pass rate near the ~90-95% target band ($r93%)"
  else _fail "p93 first-pass rate in band" "got $r93%"; fi
  if [ "$r99" -ge "$r93" ] && [ "$r93" -ge "$r70" ]; then _pass "rate increases with target (p70 $r70% <= p93 $r93% <= p99 $r99%)"
  else _fail "rate increases with target" "p70=$r70 p93=$r93 p99=$r99"; fi
  if [ "$r70" -lt 100 ]; then _pass "a lower target leaves more jobs to auto-rerun (p70 $r70% < 100%)"
  else _fail "lower target reduces first-pass coverage" "p70=$r70%"; fi
  echo
  fi
}

# ===========================================================================
_want failure_floor && {
  _begin failure_floor
  ss_new_workspace "$WORK/failure_floor" >/dev/null
  mkdir -p smartSlurmLog
  jr="$smartSlurmJobRecordDir/jobRecord.txt"
  # small legit history, an OOM at size 5000 (alloc mem 8000), an OOT at size 5000
  # (alloc time 120). Both are proven-insufficient at size 5000.
  ss_seed_record ff none 1000 700  15  COMPLETED 3
  ss_seed_record ff none 5000 8000 120 OOM 1
  ss_seed_record ff none 5000 2000 120 OOT 1
  rf=$(awk -F, -v a=ff -v b=none -v t="$(date -d '1 hour ago' +%s)" '$9!="COMPLETED"&&$21>t&&$12==a&&$13==b' "$jr" | wc -l)
  expMem=$(nextMemAfterFail 8000 "$rf"); expTime=$(nextTimeAfterFail 120 "$rf")
  # size >= failing size: must be floored strictly above the proven-insufficient values
  o=$(estimateResource.sh ff none ,jobSize:6000 f 4096 120 2>/dev/null)
  mem=$(echo "$o" | cut -d' ' -f2); tim=$(echo "$o" | cut -d' ' -f3)
  echo "    (info) size 6000 -> mem=$mem time=$tim ; proven-insufficient mem=8000 time=120"
  if [ "${mem:-0}" -gt 8000 ]; then _pass "size 6000: mem ($mem) > proven-insufficient 8000"
  else _fail "size 6000: mem > 8000" "got $mem"; fi
  if [ "${tim:-0}" -gt 120 ]; then _pass "size 6000: time ($tim) > proven-insufficient 120"
  else _fail "size 6000: time > 120" "got $tim"; fi
  assert_rc "$expMem" "$mem" "mem floor == shared auto-rerun escalation of 8000"
  assert_rc "$expTime" "$tim" "time floor == shared auto-rerun escalation of 120"
  # size < failing size: that failure must NOT floor a genuinely smaller input
  o=$(estimateResource.sh ff none ,jobSize:3000 f 4096 120 2>/dev/null); mem=$(echo "$o" | cut -d' ' -f2)
  if [ "${mem:-0}" -lt 8000 ]; then _pass "size 3000 (< failing size): not floored by the OOM ($mem)"
  else _fail "size 3000 not floored" "got $mem"; fi
  echo
}

# ===========================================================================
_want manual_rerun_floor && {
  _begin manual_rerun_floor
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/manual_rerun_floor" >/dev/null
  jr="$smartSlurmJobRecordDir/jobRecord.txt"
  # A job that really needs ~9000 M; the first run submits 4G (4096) and OOMs.
  cat > "$HERE/models/_mrf.model" <<EOF
MODEL_PROGRAM=mrf
MODEL_REF=none
MEM_FORM=const
MEM_B=9000
TIME_FORM=const
TIME_B=30
SEED=3
EOF
  d="$WORK/manual_rerun_floor/run1"; mkdir -p "$d/.mockstate/jobs"
  ( cd "$d"
    export MOCK_SLURM_STATE="$d/.mockstate"; export SS_MODEL="$HERE/models/_mrf.model"
    truncate -s 5000K in.dat
    printf '#!/bin/sh\ninput=$1\n#@1,0,mrf,,input,sbatch -p short -c 1 --mem 4G -t 60:0\ncat $input >/dev/null\n\n' > pipeline.sh
    timeout 115 bash "$SMARTSLURM_ROOT/bin/runAsPipeline" \
      --script "./pipeline.sh in.dat" --sbatch-options "sbatch -p short -c 1 --mem 4G -t 60:0" \
      --tmp noTmp >rap.log 2>&1 )
  rm -f "$HERE/models/_mrf.model"
  mkdir -p smartSlurmLog
  oomAllocs=$(awk -F, '$12=="mrf" && $9 ~ /OOM/{print $5}' "$jr" | tr '\n' ' ')
  echo "    (info) run1 OOM alloc(s): $oomAllocs"
  if [ -n "$(echo $oomAllocs | tr -d ' ')" ]; then _pass "run1 left at least one OOM record (4096 was insufficient)"
  else _fail "run1 left an OOM record" "none found"; fi
  # The estimate a manual rerun would use (exactly what ssbatch calls) for the same
  # step/size must exceed the proven-insufficient 4096 -- the escalation persists
  # across runs via the failure floor, not just within the auto-requeue.
  est=$(estimateResource.sh mrf none ,jobSize:5000 f 4096 120 2>/dev/null | cut -d' ' -f2)
  echo "    (info) manual-rerun estimate for size 5000 = $est M (initial 4096 OOM'd)"
  if [ "${est:-0}" -gt 4096 ]; then _pass "manual rerun estimate ($est) > proven-insufficient 4096"
  else _fail "manual rerun estimate > 4096" "got $est"; fi
  echo
  fi
}

# ===========================================================================
_want constant_model && {
  _begin constant_model
  if ! command -v gnuplot >/dev/null 2>&1; then
    echo "    (skipped: gnuplot unavailable)"; echo
  else
  ss_new_workspace "$WORK/constant_model" >/dev/null
  ss_run_sweep scaling_const_mem "1000 2000 3000 4000 6000 8000 10000" "sbatch -p short -c 1 --mem 16G -t 1200:0"
  ss_fit constMem none >/dev/null
  # mem prediction must be ~constant across sizes (constant model), NOT negative-
  # sloped and NOT floored to 100. time prediction must scale up with size.
  ms=$(estimateResource.sh constMem none ,jobSize:1000 p 4096 120 2>/dev/null)
  ml=$(estimateResource.sh constMem none ,jobSize:9000 p 4096 120 2>/dev/null)
  mem_s=$(echo "$ms" | cut -d' ' -f2); mem_l=$(echo "$ml" | cut -d' ' -f2)
  time_s=$(echo "$ms" | cut -d' ' -f3); time_l=$(echo "$ml" | cut -d' ' -f3)
  echo "    (info) mem: size1000=$mem_s size9000=$mem_l | time: size1000=$time_s size9000=$time_l"
  if [ "${mem_s:-0}" -gt 1000 ]; then _pass "constant mem not collapsed to floor (size 1000 -> $mem_s M)"
  else _fail "constant mem not collapsed to floor" "size 1000 -> $mem_s"; fi
  assert_near "$mem_s" "$mem_l" 0.15 "mem is ~constant across sizes ($mem_s vs $mem_l)"
  if [ "${time_l:-0}" -gt "${time_s:-0}" ]; then _pass "time scales up with size ($time_s -> $time_l)"
  else _fail "time scales up with size" "$time_s -> $time_l"; fi
  echo
  fi
}

# ===========================================================================
_want negslope_robust && {
  _begin negslope_robust
  ss_new_workspace "$WORK/negslope_robust" >/dev/null
  sdir="$smartSlurmJobRecordDir/stats"; mkdir -p "$sdir"
  mkstat() { # prog ref slope intercept max stdfit scount
    printf 'Finala=%s\nFinalb=%s\nMaximum=%s\nSTDFIT=%s\nSCount=%s\n' "$3" "$4" "$5" "$6" "$7" > "$sdir/$1.$2.mem.stat"
    printf 'Finala=%s\nFinalb=%s\nMaximum=%s\nSTDFIT=%s\nSCount=%s\nRSquare=%s\n' "$3" "$4" "$5" "$6" "$7" 0.5 > "$sdir/$1.$2.time.stat"
  }
  isint() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }
  # LINE path (positive slope) with a result in (-1,0): old code produced mem="-"
  # (bc "-.3" -> ${mem%.*} -> "-") and passed garbage downstream. Must floor to 100.
  mkstat P none 0.5 -0.7 100000 0 10
  m=$(calculateMemTime.sh P none 1 2>/dev/null | awk '{print $1}')
  if isint "$m" && [ "$m" -eq 100 ]; then _pass "line path, sub-1 negative result floors to 100 (was bc '-' bug): $m"
  else _fail "line path sub-1 negative floors to 100" "got '$m'"; fi
  # LINE path, large negative result -> floor 100 (not a negative number).
  mkstat P none 0.5 -100000 100000 0 10
  m=$(calculateMemTime.sh P none 1 2>/dev/null | awk '{print $1}')
  if isint "$m" && [ "$m" -eq 100 ]; then _pass "line path, large negative result floors to 100: $m"
  else _fail "line path large negative floors to 100" "got '$m'"; fi
  # Empty STDFIT (perfectly collinear/noiseless history) must not break arithmetic.
  mkstat P none 0.5 200 100000 '' 10
  m=$(calculateMemTime.sh P none 4000 2>/dev/null | awk '{print $1}')
  assert_rc 2200 "$m" "empty STDFIT handled (line mem=2200, no error)"
  # CONSTANT path (slope <= 0) with raw data present -> valid integer percentile.
  mkstat P none -0.3 50 100000 0 10
  printf '%s\n' "1000 1500" "2000 1600" "4000 1550" "8000 1700" > "$sdir/P.none.mem"
  m=$(calculateMemTime.sh P none 5000 2>/dev/null | awk '{print $1}')
  if isint "$m" && [ "$m" -ge 100 ]; then _pass "constant path (neg slope) returns valid integer from data ($m)"
  else _fail "constant path returns valid integer" "got '$m'"; fi
  echo
}

# ===========================================================================
ss_report
[ "$FAILS" -eq 0 ] && exit 0 || exit 1

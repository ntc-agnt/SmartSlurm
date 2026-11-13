#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fitqc_adversary_guard.sh -- regression guards for fitQC defects found
# adversarially, each asserting a SILENT-FAILURE / data-safety invariant.
# Run under BOTH awks (the harness awk-shim); GUARD1 drives gawk and mawk itself.
#
#   SMARTSLURM_ROOT=/path/to/smartslurm bash test/fitqc_adversary_guard.sh
#
# G1: the estimation engine + isnum() guard are awk-deterministic (identical --tsv and
#     --auto under gawk and mawk; a non-numeric "inf" metric is neutralized the same).
# F2: row removal must go through the LOCKED, atomic jobRecord rewrite (jrRewrite), so
#     a concurrent pipeline write (jrAppendLine) can never be clobbered.
# F3: --resid-cut (still accepted/validated) must reject 0, accept positives.
# F4(C1): a no-match --remove must not claim success. F5: backup preserves mtime.
#
# Exit 0 = all invariants hold; non-zero = a defect is present (prints which).
# ---------------------------------------------------------------------------
set -u
ROOT="${SMARTSLURM_ROOT:-}"
[ -n "$ROOT" ] && [ -x "$ROOT/bin/fitQC" ] || { echo "fitqc_guard: set SMARTSLURM_ROOT to a checkout with bin/fitQC" >&2; exit 2; }
FITQC="$ROOT/bin/fitQC"
GAWK=$(command -v gawk || true); MAWK=$(command -v mawk || true)
HDR='pipeline,step,ref,sample,jobID,inputSize,memUsed,memAllocated,timeUsed,timeAllocated,cores,status,user,node,epoch,isoDate,flag'
ep=$(date +%s)
WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT
fail=0

# shim dirs so we can force either awk as the generic `awk` fitQC calls
mkdir -p "$WD/gshim" "$WD/mshim"
[ -n "$GAWK" ] && ln -sf "$GAWK" "$WD/gshim/awk"
[ -n "$MAWK" ] && ln -sf "$MAWK" "$WD/mshim/awk"

# ---------------------------------------------------------------------------
# GUARD 1 (awk determinism): the estimation engine (max-per-size envelope, LINE/CONST
# model choice, p93 margin, coverage, waste, influence) and the isnum() guard must
# behave IDENTICALLY under gawk and mawk. The SAME store must yield byte-identical
# --tsv AND byte-identical --auto results under both awks. A non-numeric ("inf") metric
# must be neutralized the same way (mawk coerces "inf"->+inf, gawk->0).
# ---------------------------------------------------------------------------
if [ -n "$GAWK" ] && [ -n "$MAWK" ]; then
  mkstore() { { echo "$HDR"
    j=1; for s in 100 200 300 400 500; do for r in 1 2; do printf 'p1,bowtie,none,,%d,%d,%d,900,10,60,4,COMPLETED,u,n,%s,d,1.b.%d\n' "$j" "$s" "$((50*s+200))" "$ep" "$j"; j=$((j+1)); done; done
    printf 'p1,bowtie,none,,900,300,90000,900,10,60,4,COMPLETED,u,n,%s,d,1.b.hi\n' "$ep"   # inflating envelope point
    printf 'p1,bowtie,none,,901,300,inf,900,10,60,4,COMPLETED,u,n,%s,d,1.b.inf\n' "$ep"    # non-numeric metric: isnum must skip it IDENTICALLY
   } > "$1"; }
  mkstore "$WD/g.txt"; mkstore "$WD/m.txt"
  gt=$(PATH="$WD/gshim:$PATH" "$FITQC" --store "$WD/g.txt" --all --tsv 2>/dev/null)
  mt=$(PATH="$WD/mshim:$PATH" "$FITQC" --store "$WD/m.txt" --all --tsv 2>/dev/null)
  if [ "$gt" != "$mt" ]; then
    echo "GUARD1 FAIL: --tsv differs between gawk and mawk (awk-dependent QC)."; printf '   gawk: %s\n   mawk: %s\n' "$gt" "$mt"; fail=1
  fi
  PATH="$WD/gshim:$PATH" "$FITQC" --store "$WD/g.txt" p1/bowtie/none --auto >/dev/null 2>&1
  PATH="$WD/mshim:$PATH" "$FITQC" --store "$WD/m.txt" p1/bowtie/none --auto >/dev/null 2>&1
  if ! diff -q <(sort "$WD/g.txt") <(sort "$WD/m.txt") >/dev/null; then
    echo "GUARD1 FAIL: gawk and mawk produced DIFFERENT stores after the same --auto (awk-dependent removal)."; fail=1
  fi
  [ "$fail" = 0 ] && echo "GUARD1 ok: new engine + isnum are awk-deterministic (identical --tsv and --auto under gawk/mawk)."
else
  echo "GUARD1 skipped: need both gawk and mawk installed."
fi

# ---------------------------------------------------------------------------
# GUARD 2 (F2): removal must respect the jobRecord lock. While the lock is held, a
# removal must NOT rewrite the store (else it clobbers a concurrent jrAppendLine).
# ---------------------------------------------------------------------------
jr="$WD/lock.txt"
{ echo "$HDR"
  for i in 1 2 3 4 5 6; do printf 'p1,bowtie,none,,100%d,%d,%d,900,10,60,4,COMPLETED,u,n,%s,d,1.b.%d\n' "$i" "$((i*100))" "$((i*200+100))" "$ep" "$i"; done
  printf 'p1,bowtie,none,,99999,350,20000,2200,15,60,4,COMPLETED,u,n,%s,d,1.b.x\n' "$ep"
} > "$jr"
before=$(md5sum < "$jr")
mkdir "$jr.lock"                       # simulate a concurrent writer holding the lock
timeout 10 "$FITQC" --store "$jr" p1/bowtie/none --remove 99999 >/dev/null 2>&1
rc=$?
after=$(md5sum < "$jr")
rmdir "$jr.lock" 2>/dev/null
if [ "$before" != "$after" ]; then
  echo "GUARD2 FAIL: removal rewrote the store while the jobRecord lock was held (rc=$rc); a concurrent jrAppendLine would be clobbered -> silent row loss."
  fail=1
else
  echo "GUARD2 ok: removal honored the held lock (store unchanged)."
fi

# ---------------------------------------------------------------------------
# GUARD 3 (F3): --resid-cut rejects 0 / 0.0 (mass-deletion footgun), accepts positive.
# ---------------------------------------------------------------------------
jr3="$WD/g3.txt"; echo "$HDR" > "$jr3"; g3=0
for v in 0 0.0 00; do
  "$FITQC" --store "$jr3" --resid-cut "$v" p1/bowtie/none >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || { echo "GUARD3 FAIL: --resid-cut '$v' not rejected (rc=$rc, want 2)"; fail=1; g3=1; }
done
"$FITQC" --store "$jr3" --resid-cut 2.5 p1/bowtie/none >/dev/null 2>&1; rc=$?
[ "$rc" != 2 ] || { echo "GUARD3 FAIL: valid --resid-cut 2.5 was rejected (rc=2)"; fail=1; g3=1; }
[ "$g3" = 0 ] && echo "GUARD3 ok: --resid-cut rejects 0/0.0, accepts positive."

# ---------------------------------------------------------------------------
# GUARD 4 (F2, conservation): a removal must drop ONLY the target, keep every other
# row + the header + a valid v2 store, AND a row a pipeline recorded via the
# sanctioned jrAppendLine must survive the removal (fitQC never eats a pipeline row).
# ---------------------------------------------------------------------------
jr4="$WD/g4.txt"; { echo "$HDR"
  for i in 1 2 3 4 5; do printf 'p1,bowtie,none,,%d,%d,%d,900,10,60,4,COMPLETED,u,n,%s,d,1.b.%d\n' "$i" "$((i*100))" "$((i*200))" "$ep" "$i"; done
  printf 'p1,bowtie,none,,900,500,99999,900,10,60,4,COMPLETED,u,n,%s,d,1.b.out\n' "$ep"   # the outlier to remove
} > "$jr4"
# a finishing pipeline job records a NEW row through the sanctioned API
( . "$ROOT/bin/jobRecordSchema.sh" 2>/dev/null
  jrAppendLine "$jr4" "p1,bowtie,none,,7777,600,1200,900,10,60,4,COMPLETED,u,n,$ep,d,1.b.new" ) >/dev/null 2>&1
"$FITQC" --store "$jr4" p1/bowtie/none --remove 900 >/dev/null 2>&1
miss=""
for j in 1 2 3 4 5 7777; do awk -F, -v j="$j" 'NR>1 && $5==j{f=1} END{exit !f}' "$jr4" || miss="$miss keep:$j"; done
awk -F, 'NR>1 && $5==900{f=1} END{exit !f}' "$jr4" && miss="$miss still-900"
head -1 "$jr4" | grep -q '^pipeline,step,ref,sample,jobID,' || miss="$miss header"
if [ -z "$miss" ]; then echo "GUARD4 ok: removal conserved originals + the concurrent jrAppendLine row; header intact."
else echo "GUARD4 FAIL:$miss"; fail=1; fi

# ---------------------------------------------------------------------------
# GUARD 5 (C1): a --remove that matches NOTHING must NOT claim success. An absent
# id, or an id that exists only in another pipeline/group, must report "nothing
# removed" -- never ">>> removed [..]" (contract: never report removed when nothing was).
# ---------------------------------------------------------------------------
jr5="$WD/g5.txt"; { echo "$HDR"
  for i in 1 2 3 4 5; do printf 'p1,bowtie,none,,%d,%d,%d,900,10,60,4,COMPLETED,u,n,%s,d,1.b.%d\n' "$i" "$((i*100))" "$((i*200))" "$ep" "$i"; done
  printf 'p2,bowtie,none,,7,100,200,900,10,60,4,COMPLETED,u,n,%s,d,1.b.7\n' "$ep"   # id 7 lives ONLY in p2
} > "$jr5"; g5=0
out=$("$FITQC" --store "$jr5" p1/bowtie/none --remove 88888 2>&1)       # absent id
echo "$out" | grep -q 'removed \[88888\]' && { echo "GUARD5 FAIL: false 'removed' for an absent id"; fail=1; g5=1; }
out=$("$FITQC" --store "$jr5" p1/bowtie/none --remove 7 2>&1)           # id present only in p2
if echo "$out" | grep -q 'removed \[7\]'; then
  awk -F, 'NR>1 && $1=="p2" && $5==7{f=1} END{exit !f}' "$jr5" && { echo "GUARD5 FAIL: reported removing id 7 from p1, but it only exists in p2 (still present)"; fail=1; g5=1; }
fi
# a real in-group removal must STILL succeed (no false negative from the new gate)
out=$("$FITQC" --store "$jr5" p1/bowtie/none --remove 3 2>&1)
echo "$out" | grep -q 'removed \[3\]' || { echo "GUARD5 FAIL: a genuine in-group removal was not reported removed"; fail=1; g5=1; }
awk -F, 'NR>1 && $1=="p1" && $5==3{f=1} END{exit f}' "$jr5" || { echo "GUARD5 FAIL: id 3 reported removed but is still present"; fail=1; g5=1; }
[ "$g5" = 0 ] && echo "GUARD5 ok: no-match removal reports nothing removed; real removal still succeeds."

# ---------------------------------------------------------------------------
# GUARD 6 (F5): the pre-removal backup must preserve the store's mtime (cp -p), so a
# restore does not reset the record's age and skew cleanUp's recency-based pruning.
# ---------------------------------------------------------------------------
jr6dir="$WD/g6"; mkdir -p "$jr6dir"; jr6="$jr6dir/jobRecord.txt"
{ echo "$HDR"; for i in 1 2 3 4 5; do printf 'p1,bowtie,none,,%d,%d,%d,900,10,60,4,COMPLETED,u,n,%s,d,1.b.%d\n' "$i" "$((i*100))" "$((i*200))" "$ep" "$i"; done; } > "$jr6"
touch -d '2001-02-03 04:05:06' "$jr6" 2>/dev/null || touch -t 200102030405.06 "$jr6"
want=$(stat -c %Y "$jr6" 2>/dev/null)
"$FITQC" --store "$jr6" p1/bowtie/none --remove 3 >/dev/null 2>&1
bak=$(ls "$jr6dir"/jobRecord.back.*.txt 2>/dev/null | head -1)
if [ -z "$bak" ]; then echo "GUARD6 FAIL: no backup created on removal"; fail=1
elif [ "$(stat -c %Y "$bak" 2>/dev/null)" = "$want" ]; then
  echo "GUARD6 ok: backup preserved the store mtime (cp -p)."
else
  echo "GUARD6 FAIL: backup mtime $(stat -c %Y "$bak" 2>/dev/null) != store mtime $want (cp without -p resets age)"; fail=1
fi

echo "----------------------------------------------------------------"
[ "$fail" = 0 ] && echo "fitqc_adversary_guard: GREEN" || echo "fitqc_adversary_guard: RED"
exit $fail

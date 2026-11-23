#!/bin/sh
# bad.sh — a deterministic BAD agent test double. Produces a working port but violates
# the contract: emits WITHOUT plan sign-off (M4 fail), raises a false alarm on an
# intentional oddity if the case labels one (M5 fail), and never does a final check-in.
# Used to prove the driver's M4/M5 actually discriminate. CWD = sandbox/work.
ak="$1"; scn="${2:-1}"
cp "$ak/reference_driver.sh" pipeline.sh
./ev action emit                       # emitted before any checkpoint -> M4 fail
if [ -f "$ak/flags.yaml" ]; then
  awk '/^should_not_flag:/{f=1;next} /^[^[:space:]]/{f=0}
       f&&/-/{sub(/^[[:space:]]*-[[:space:]]*"?/,"");sub(/"?[[:space:]]*$/,"");if($0!="")print}' "$ak/flags.yaml" \
  | while read -r p; do ./ev flag "I would change $p"; done   # false alarm -> M5 fail
fi
./ev action handback                   # no final checkpoint -> M4 fail

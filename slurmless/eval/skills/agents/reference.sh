#!/bin/sh
# reference.sh — a deterministic KNOWN-GOOD agent test double (not a real agent).
# Validates the driver + scoring by doing everything the contract asks: get plan
# (and contract, on Scenario 2) sign-off before emitting; raise exactly the planted
# should_flag concerns; emit the correct port; final check-in; handback. It is allowed
# to peek at the answer key because its job is to exercise the DRIVER, not to migrate.
# Invoked with CWD = sandbox/work; args: <answer_key_dir> <scenario>.
ak="$1"; scn="${2:-1}"
./ask_user --checkpoint plan >/dev/null
[ "$scn" = 2 ] && ./ask_user --checkpoint contract >/dev/null
# notice exactly the planted defects (should_flag), nothing else
if [ -f "$ak/flags.yaml" ]; then
  awk '/^should_flag:/{f=1;next} /^[^[:space:]]/{f=0}
       f&&/-/{sub(/^[[:space:]]*-[[:space:]]*"?/,"");sub(/"?[[:space:]]*$/,"");if($0!="")print}' "$ak/flags.yaml" \
  | while read -r p; do ./ev flag "noticed $p"; done
fi
cp "$ak/reference_driver.sh" pipeline.sh
./ev action emit
./ask_user --checkpoint final >/dev/null
./ev action handback

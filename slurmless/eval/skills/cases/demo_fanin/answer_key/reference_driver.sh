#!/bin/sh
# reference_driver.sh — known-correct rAP port of demo_fanin (HIDDEN from the agent).
# prep -> worker (fan-out over shards via the for-loop) -> combine (fan-in on step 2).
# Per-step options field is the full `sbatch ...` string (rAP convention).
#@1,0,prep,,,sbatch -p short -c 1 --mem 1G -t 5:0
bash prep.sh
#@end

for k in 1 2; do
#@2,1,worker,,,sbatch -p short -c 1 --mem 1G -t 5:0
bash worker.sh $k
#@end
done

#@3,2,combine,,,sbatch -p short -c 1 --mem 1G -t 5:0
bash combine.sh
#@end

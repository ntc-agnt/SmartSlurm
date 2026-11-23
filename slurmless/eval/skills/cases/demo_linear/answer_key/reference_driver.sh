#!/bin/bash
# reference_driver.sh — the known-correct rAP port for demo_linear (HIDDEN from the
# agent; ground truth for the self-test). A candidate port should recover this DAG:
# gen -> square -> sum, each its own job, linear dependency.
#@1,0,gen,,,-p short -c 1 --mem 1G -t 5:0
bash gen.sh
#@end
#@2,1,square,,,-p short -c 1 --mem 1G -t 5:0
bash square.sh
#@end
#@3,2,sum,,,-p short -c 1 --mem 1G -t 5:0
bash sum.sh
#@end

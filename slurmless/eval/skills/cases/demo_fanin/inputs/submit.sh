#!/bin/sh
# Original hand-rolled SLURM workflow (Scenario 2) — what the agent is given.
# prep -> {worker 1, worker 2} (fan-out) -> combine (fan-in, afterok both).
# Run under ss_wf_activate so the mock sbatch REGISTERS the DAG (no payloads run);
# ss_wf_drain then executes it. The agent recovers this DAG and ports it to rAP.
jidA=$(sbatch --parsable prep.sh)
jid1=$(sbatch --parsable --dependency=afterok:"$jidA" worker.sh 1)
jid2=$(sbatch --parsable --dependency=afterok:"$jidA" worker.sh 2)
sbatch --parsable --dependency=afterok:"$jid1":"$jid2" combine.sh

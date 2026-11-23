# Task (shown to the agent)

You have a working hand-rolled SLURM workflow (**Scenario 2**):

- `submit.sh` — submits the jobs with `sbatch --dependency`
- `prep.sh`, `worker.sh <k>`, `combine.sh` — the step scripts

Recover its job DAG (run it under the register-don't-run harness; don't statically
parse it), port it to a SmartSlurm `runAsPipeline` driver, and **differentially
test**: the port must reproduce the original's authoritative output (`total.txt`)
under an identity contract you propose. Validate in the slurmless sandbox before
handing back.

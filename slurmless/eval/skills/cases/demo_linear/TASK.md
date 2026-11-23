# Task (shown to the agent)

You have three loose processing scripts in `inputs/`:

- `gen.sh`   — produces `nums.txt`
- `square.sh` — reads `nums.txt`, writes `sq.txt`
- `sum.sh`    — reads `sq.txt`, writes `total.txt`

Wire them into a SmartSlurm `runAsPipeline` driver that runs the three steps in the
correct order, each as its own job, with the dependencies implied by the files they
read and write. Validate it in the slurmless sandbox before handing back.

This is **Scenario 1** (loose scripts, no existing pipeline). There is no "original
workflow" to diff against — correctness is judged by the recovered step DAG and the
Scenario-1 sanity invariants.

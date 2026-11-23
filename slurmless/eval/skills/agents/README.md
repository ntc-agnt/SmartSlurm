# agents/ — adapters for the agent-in-the-loop driver

`run_agent.sh` prepares a sandbox (`work/` with the case inputs, `TASK.md`,
`AGENT_BRIEF.md`, and the `ask_user` / `ev` wrappers) and then invokes an **adapter**:
a command run with `CWD = sandbox/work` and args `<answer_key_dir> <scenario>`. The
adapter makes an agent produce `pipeline.sh` (the rAP port) and drive the transcript
(checkpoints via `./ask_user`, flags + `action emit|handback` via `./ev`).

## The two bundled doubles (deterministic — for testing the driver)

- **`reference.sh`** — a known-good agent: gets plan (+ contract on Scn 2) sign-off
  before emitting, raises exactly the planted `should_flag` concerns, emits the
  correct port, final check-in, handback. It peeks at the answer key because its job
  is to exercise the **driver + scoring**, not to migrate. Scores all-green.
- **`bad.sh`** — emits without plan sign-off (M4 fail), false-alarms on a labeled
  intentional oddity (M5 fail), skips the final check-in. Proves M4/M5 discriminate.

## Plugging a real agent (the subject under test)

A real adapter ignores the answer-key args and drives an actual agent over the
sandbox, e.g.:

```sh
# agents/claude.sh         (sketch — a real CLI adapter)
claude -p "$(cat AGENT_BRIEF.md)" --allowedTools Bash Read Write Skill
# agents/codex.sh
codex exec "$(cat AGENT_BRIEF.md)"
# agents/cursor.sh
cursor-agent -p "$(cat AGENT_BRIEF.md)"
```

Each runs in `sandbox/work`, where `AGENT_BRIEF.md` tells the agent to use
`./ask_user` and `./ev` and to write `pipeline.sh`. The agent must not read the
answer key (a capability eval, not an anti-cheat test). In this repo's own Claude
sessions the "claude adapter" is realized by spawning a subagent pointed at the
prepared sandbox, then `run_agent.sh score <case> <sandbox>`.

## Cross-agent axis + stats (Phase 4c)

Run the same corpus under several adapters, collecting each run's `result.tsv` row
(`case  agent  dag=  fidelity=  hygiene=  checkpoint=  flag=`). The generalization
question is then a **paired** comparison across agents on identical cases; the
ship/regression gate applies the non-dominated rule (`README.md`). Run each case
several times per agent (stochastic) and compare with a paired bootstrap.

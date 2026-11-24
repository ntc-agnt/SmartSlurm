# Logical plan format (input to `tools/emit_rap.sh`)

A plan is the agent's understanding of the pipeline — the extracted DAG collapsed
into logical steps, with per-sample instances folded into a fan-out loop and
commands parameterized over the fan-out variable `$s`. `emit_rap.sh` renders it into
a valid rAP `#@` script (step numbers, dependsOnStep edges, loop wrapping, `#@end`).

```
# comments start with #
SAMPLES <shell expr>        # the fan-out list; literal ("s1 s2 s3") or a command
                            #   ($(cut -d' ' -f1 manifest.txt)). Omit if no fan-out.
SBATCH  <sbatch options>    # default resources applied to every step

STEP <name> dep=<name|-> fanout=<yes|no> in=<var|none> [wrap=<yes|no>]
    <command line(s)>       # indented; reference the fan-out sample as $s
STEP ...
```

- Steps render in order as steps 1..N. `dep=<name>` resolves to that step's number;
  `dep=-` (or `0`/`none`) means no dependency.
- **Fan-in is a loop, not a list.** A single step (`fanout=no`) that `dep=`s on a
  fanned step waits for ALL of that step's jobs — that is how a merge/fan-in is
  expressed. You cannot list multiple deps.
- Consecutive `fanout=yes` steps share one `for s in $samples; do … done` loop.
- `in=` is the rAP inputsVar (drives resource estimation); `none` for input-less steps.
- **`wrap=` (default `no`) — set `yes` only for a body you lifted out of a legacy
  `--wrap="…"` string.** A `#@…#@end` body is emitted **byte-for-byte verbatim**
  (the engine unescapes nothing), so a command written for the old double-quoted
  `--wrap` path still carries its shell escaping — `\$` (the classic `awk`/`sed`
  field-ref guard, e.g. `awk '{ s+=\$1 }'`), `\"`, `` \` ``. Left as-is that
  backslash reaches the tool literally and breaks it **silently** (`awk` dies on the
  stray `\`, the step still exits 0, the output is empty/wrong). `wrap=yes` makes
  `emit_rap.sh` apply exactly bash's double-quote unescaping (`\$`→`$`, `` \` ``→`` ` ``,
  `\"`→`"`, `\\`→`\`) and print a stderr note naming the step. **Do not set it on a
  natural-bash body that wants a literal `\$`** (e.g. `echo "price \$5"`): the default
  `no` emits that verbatim, which is correct. When unsure whether a lifted one-liner
  needs it, check for a `\$`/`` \` ``/`\"` that was there only to survive `--wrap="…"`.

Example (per-sample normalize→wordcount, fan-in merge, tail report):

```
SAMPLES $(cut -d' ' -f1 phrases.txt)
SBATCH  sbatch -p short -c 1 --mem 100M -t 5:00
STEP norm   dep=-    fanout=yes in=none
    normalize.sh $s
STEP wc     dep=norm fanout=yes in=none
    wordcount.sh $s
STEP merge  dep=wc   fanout=no  in=none
    merge.sh
STEP report dep=merge fanout=no in=none
    report.sh
```

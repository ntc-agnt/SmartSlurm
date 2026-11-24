#!/bin/bash
# ---------------------------------------------------------------------------
# emit_rap.sh <plan.txt>  ->  annotated runAsPipeline script on stdout
#
# Renders a declarative LOGICAL PLAN into a valid rAP #@ script. The plan is what
# the agent produces by understanding the extracted DAG (grouping per-sample
# instances into logical steps, parameterizing commands over the fan-out variable
# $s); this tool does the mechanical, error-prone rendering -- step numbers, the
# dependsOnStep edges, loop wrapping for fan-out, and #@end closes.
#
# Why a plan and not the raw DAG: rAP expresses fan-in through a *looped* step
# (dependsOnStep is a single step number, so a merge waits for ALL jobs of the
# fanned step it names). Instance-level steps can't encode that -- the fan-out must
# be a loop. Collapsing instances into looped steps is the "understanding" step.
#
# Plan format (see references/plan-format.md):
#   SAMPLES <shell expr>              # the fan-out list (literal or $(...) ); optional
#   SBATCH  <sbatch options>          # default resources for every step
#   STEP <name> dep=<name|-> fanout=<yes|no> in=<var|none> [wrap=<yes|no>]
#       <command line(s)>             # indented; $s is the fan-out variable
#   STEP ...
# Steps render in order as steps 1..N; dep=<name> resolves to that step's number.
# Consecutive fanout=yes steps share one `for s in $samples; do ... done` loop.
#
# wrap= (default no): provenance flag for a body LIFTED FROM A LEGACY --wrap="…"
# context. A #@…#@end body is emitted BYTE-FOR-BYTE verbatim (the engine unescapes
# nothing), so a body authored for the old double-quoted --wrap path still carries
# its shell escaping -- `\$` (the classic awk/sed field-ref guard), `\"`, `\`` --
# which would reach the tool literally and break it SILENTLY (e.g. awk dies on a
# stray backslash, the step still exits 0, the output is empty/wrong). wrap=yes
# tells this renderer the body came from inside "…" and applies exactly bash's
# double-quote unescaping (\$→$, \`→`, \"→", \\→\) so the verbatim body is correct
# on the node. It prints a stderr note naming the step so the agent can review.
# Default no = emit verbatim (the safe default: a natural-bash body that WANTS a
# literal \$, e.g. `echo "price \$5"`, must NOT be de-escaped). Set wrap=yes ONLY
# for a body you lifted out of a --wrap="…" string.
# ---------------------------------------------------------------------------
set -uo pipefail
plan="${1:?usage: emit_rap.sh plan.txt}"
[ -f "$plan" ] || { echo "emit_rap: no such plan: $plan" >&2; exit 1; }

# _deescape_wrap: reverse bash double-quote escaping for a body lifted from
# --wrap="…". Protects \\ via a sentinel first so \\$ (a literal backslash then $)
# is preserved rather than collapsed to $. Portable (no \n in sed replacements, so
# GNU and BSD sed agree).
_deescape_wrap() {
  local S; S=$(printf '\001')
  sed -e "s/\\\\\\\\/${S}/g" -e 's/\\\$/$/g' -e 's/\\`/`/g' -e 's/\\"/"/g' -e "s/${S}/\\\\/g"
}
# _count_wrap_escapes: how many \$ \` \" a body carries (after protecting \\), for
# the review note. Returns 0 on a clean body.
_count_wrap_escapes() {
  local S; S=$(printf '\001')
  sed "s/\\\\\\\\/${S}/g" | { grep -oE '\\[$`"]' || true; } | wc -l | tr -d ' '
}

samples=""; sbatch="sbatch -p short -c 1 --mem 1G -t 60:0"
names=(); deps=(); fan=(); ins=(); cmds=(); wrp=(); cur=-1

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*)      continue ;;
    "SAMPLES "*) rest="${line#SAMPLES }"; samples="${rest#"${rest%%[![:space:]]*}"}"; continue ;;
    "SBATCH "*)  rest="${line#SBATCH }";  sbatch="${rest#"${rest%%[![:space:]]*}"}";  continue ;;
    "STEP "*)
      set -- $line                       # STEP name k=v k=v ...
      nm="$2"; d="-"; f="no"; iv="none"; w="no"; shift 2
      for kv in "$@"; do case "$kv" in
        dep=*)    d="${kv#dep=}" ;;
        fanout=*) f="${kv#fanout=}" ;;
        in=*)     iv="${kv#in=}" ;;
        wrap=*)   w="${kv#wrap=}" ;;
      esac; done
      cur=$((cur+1)); names[cur]="$nm"; deps[cur]="$d"; fan[cur]="$f"; ins[cur]="$iv"; wrp[cur]="$w"; cmds[cur]=""
      ;;
    *)
      c="${line#"${line%%[![:space:]]*}"}"              # strip leading indentation
      [ "$cur" -ge 0 ] && cmds[cur]="${cmds[cur]}${c}"$'\n'
      ;;
  esac
done < "$plan"

n=${#names[@]}
[ "$n" -gt 0 ] || { echo "emit_rap: plan has no STEP lines" >&2; exit 1; }

num_of() { local i; for ((i=0;i<n;i++)); do [ "${names[i]}" = "$1" ] && { echo $((i+1)); return; }; done; echo 0; }

emit_marker() {
  local i=$1 depnum=0 body="${cmds[i]}"
  case "${deps[i]}" in ''|-|0|none) depnum=0 ;; *) depnum=$(num_of "${deps[i]}") ;; esac
  if [ "${wrp[i]:-no}" = yes ]; then
    # Body came from a legacy --wrap="…"; recover the intended bytes. The trailing
    # 'x' guard preserves body-final newlines that $(...) would otherwise strip.
    local deesc; deesc=$(printf '%s' "$body" | _deescape_wrap; printf x); deesc="${deesc%x}"
    if [ "$deesc" != "$body" ]; then
      local nn; nn=$(printf '%s' "$body" | _count_wrap_escapes)
      printf 'emit_rap: step %s: de-escaped %s legacy --wrap escape(s) (\\$ \\` \\") -- review the verbatim #@end body\n' "${names[i]}" "$nn" >&2
      body="$deesc"
    fi
  fi
  printf '#@%d,%d,%s,,%s,%s\n' "$((i+1))" "$depnum" "${names[i]}" "${ins[i]}" "$sbatch"
  printf '%s' "$body"
  printf '#@end\n'
}

printf '#!/bin/sh\n'
printf '# generated by emit_rap.sh from a Migration Assistant plan\n'
printf 'samples="%s"\n\n' "$samples"

i=0
while [ "$i" -lt "$n" ]; do
  if [ "${fan[i]}" = yes ]; then
    printf 'for s in $samples; do\n'
    while [ "$i" -lt "$n" ] && [ "${fan[i]}" = yes ]; do
      emit_marker "$i" | sed 's/^/    /'
      i=$((i+1))
    done
    printf 'done\n\n'
  else
    emit_marker "$i"; printf '\n'
    i=$((i+1))
  fi
done

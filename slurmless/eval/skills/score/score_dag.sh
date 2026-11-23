#!/bin/bash
# ---------------------------------------------------------------------------
# score_dag.sh <candidate-rAP-driver> <intended_dag.tsv>
#
# DAG-recovery metric (M1). Compare the step DAG a candidate rAP port encodes
# against a case's ground-truth DAG, by NAME (robust to step renumbering), and
# report precision / recall / F1 over the edge set plus node-set agreement.
#
#   candidate edges  <- parse_rap_dag.sh <driver>   (name-resolved deps)
#   intended  edges  <- intended_dag.tsv            (<name>\t<dep>, "-" = root)
#
# Prints a single parseable metric line and exits 0 iff the DAG matches exactly
# (F1 == 1.0 AND node sets equal); non-zero otherwise. Pure text analysis — no
# harness or SmartSlurm checkout needed.
# ---------------------------------------------------------------------------
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"                 # eval/skills/score -> repo root
PARSE="$root/skills/migration-assistant/tools/parse_rap_dag.sh"

drv="${1:?usage: score_dag.sh <candidate-driver> <intended_dag.tsv>}"
intended="${2:?intended_dag.tsv}"
[ -r "$drv" ]      || { echo "score_dag: cannot read driver '$drv'" >&2; exit 2; }
[ -r "$intended" ] || { echo "score_dag: cannot read intended '$intended'" >&2; exit 2; }
[ -x "$PARSE" ]    || { echo "score_dag: parse_rap_dag.sh not found at $PARSE" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# candidate: name-resolved DAG -> edge list (name<TAB>dep) + node list
"$PARSE" "$drv" 2>/dev/null | awk '
  { name=$2; line=$0; sub(/^.*dep=/,"",line); d=line;
    print name > "/dev/stderr";                       # node
    n=split(d,parts,"."); for(i=1;i<=n;i++){ if(parts[i]!="-" && parts[i]!="") printf "%s\t%s\n", name, parts[i]; }
  }' >"$tmp/cand_edges" 2>"$tmp/cand_nodes"

# intended: edge list + node list
awk -F'\t' '
  /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
  { name=$1; dep=$2; gsub(/[[:space:]]/,"",name); gsub(/[[:space:]]/,"",dep);
    print name > "/dev/stderr";
    if (dep!="-" && dep!="") printf "%s\t%s\n", name, dep; }' "$intended" \
  >"$tmp/int_edges" 2>"$tmp/int_nodes"

sort -u "$tmp/cand_edges" -o "$tmp/cand_edges"; sort -u "$tmp/int_edges" -o "$tmp/int_edges"
sort -u "$tmp/cand_nodes" -o "$tmp/cand_nodes"; sort -u "$tmp/int_nodes" -o "$tmp/int_nodes"

ce=$(wc -l <"$tmp/cand_edges"); ie=$(wc -l <"$tmp/int_edges")
inter=$(comm -12 "$tmp/cand_edges" "$tmp/int_edges" | wc -l)
nodes_common=$(comm -12 "$tmp/cand_nodes" "$tmp/int_nodes" | wc -l)
cn=$(wc -l <"$tmp/cand_nodes"); innodes=$(wc -l <"$tmp/int_nodes")

awk -v inter="$inter" -v ce="$ce" -v ie="$ie" -v nc="$nodes_common" -v cn="$cn" -v innodes="$innodes" 'BEGIN{
  p = (ce>0)? inter/ce : (ie==0?1:0);
  r = (ie>0)? inter/ie : 1;
  f1= (p+r>0)? 2*p*r/(p+r) : 0;
  nodes_match = (nc==cn && nc==innodes) ? "yes" : "no";
  verdict = (f1>=0.999 && nodes_match=="yes") ? "MATCH" : "MISS";
  printf "DAG precision=%.2f recall=%.2f f1=%.2f edges=%d/%d nodes=%d/%d nodes_match=%s verdict=%s\n",
         p, r, f1, inter, ie, nc, innodes, nodes_match, verdict;
  exit (verdict=="MATCH")?0:1;
}'

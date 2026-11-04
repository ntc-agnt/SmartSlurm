#!/bin/bash
# ===========================================================================
# smartSlurmConfig.sh — backend for `smartslurm config`.
#
# Structured, validated, OVERLAY-based editing of SmartSlurm's config. It writes
# ONLY ~/.smartSlurm/config/user.conf — a small file holding just the scalar keys
# a user changed. The repo config/config.txt (the defaults) sources user.conf last,
# so user changes win, survive `git pull`, and pick up new upstream defaults
# automatically (no full-copy, no migration going forward). See `config.schema`
# for the editable keys and `config migrate` for one-time import of a legacy full
# ~/.smartSlurm/config/config.txt.
#
# Usage:
#   smartslurm config list
#   smartslurm config get <key>
#   smartslurm config set <key> <value>
#   smartslurm config unset <key>
#   smartslurm config edit
#   smartslurm config refgroup list | add <ref>... --group <name> | remove <ref>...
#   smartslurm config partition list | <slot|name> [--name V] [--mem-limit M] [--time-limit T]
#   smartslurm config migrate
# ===========================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REPO_CONFIG="$REPO/config/config.txt"
SCHEMA="$REPO/config/config.schema"
JRSCHEMA="$REPO/bin/jobRecordSchema.sh"
USERDIR="$HOME/.smartSlurm/config"
USERCONF="$USERDIR/user.conf"

die()  { echo "smartslurm config: $*" >&2; exit 1; }
warn() { echo "smartslurm config: $*" >&2; }
[ -r "$REPO_CONFIG" ] || die "cannot read repo config: $REPO_CONFIG"

# --- schema access: fields for a key, or empty if not in the schema -----------
# schema line: name|type|default|category|help
_schema_line() { [ -r "$SCHEMA" ] && awk -F'|' -v k="$1" '!/^[[:space:]]*#/ && $1==k {print; exit}' "$SCHEMA"; }
_schema_type()    { _schema_line "$1" | awk -F'|' '{print $2}'; }
_schema_default() { _schema_line "$1" | awk -F'|' '{print $3}'; }
_schema_help()    { _schema_line "$1" | awk -F'|' '{print $5}'; }
_in_schema()      { [ -n "$(_schema_line "$1")" ]; }

# --- effective value of a key (repo config overlaid with user.conf) -----------
# Sourced in a subshell exactly as the tools resolve it; JR_REF_CLASS also needs
# the jobRecordSchema default, so source that too when asked for it.
_eff() {
  local k="$1" extra=""
  [ "$k" = JR_REF_CLASS ] && [ -r "$JRSCHEMA" ] && extra='. "'"$JRSCHEMA"'" >/dev/null 2>&1;'
  bash -c '. "'"$REPO_CONFIG"'" >/dev/null 2>&1; '"$extra"' printf %s "${'"$k"':-}"'
}

# --- keys currently set in user.conf ------------------------------------------
_userconf_keys() {
  [ -f "$USERCONF" ] || return 0
  sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$USERCONF"
}
_in_userconf() { _userconf_keys | grep -qx "$1"; }

# --- quote a value for a sourceable `export K=V` line -------------------------
# Double-quote so spaces work and $HOME/$VAR still expand at source time (matching
# config.txt's own style); escape only what would break the double-quoted string.
_q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"`]/\\&/g')"; }

_ensure_userdir() {
  mkdir -p "$USERDIR" || die "cannot create $USERDIR"
  [ -f "$USERCONF" ] || {
    printf '# SmartSlurm user config overlay — only your changed keys live here.\n' > "$USERCONF"
    printf '# Written by `smartslurm config`; sourced last by config/config.txt so\n' >> "$USERCONF"
    printf '# these win over the repo defaults. Safe to hand-edit (export K=V scalars).\n\n' >> "$USERCONF"
  }
}

# --- upsert / remove a key in user.conf ---------------------------------------
_upsert() {
  local k="$1" v="$2" tmp
  _ensure_userdir
  tmp="$(mktemp "${USERCONF}.XXXXXX")" || die "mktemp failed"
  # drop any existing line for this key, keep the rest
  grep -v "^[[:space:]]*export[[:space:]]\{1,\}${k}=" "$USERCONF" > "$tmp" 2>/dev/null || true
  printf 'export %s=%s\n' "$k" "$(_q "$v")" >> "$tmp"
  mv "$tmp" "$USERCONF"
}
_remove() {
  local k="$1" tmp
  [ -f "$USERCONF" ] || return 0
  tmp="$(mktemp "${USERCONF}.XXXXXX")" || die "mktemp failed"
  grep -v "^[[:space:]]*export[[:space:]]\{1,\}${k}=" "$USERCONF" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$USERCONF"
}

# --- type validation ----------------------------------------------------------
_validate() {
  local k="$1" v="$2" t; t="$(_schema_type "$k")"
  case "$t" in
    ""|string|path) : ;;                              # unconstrained (custom keys land here too)
    int)  [[ "$v" =~ ^-?[0-9]+$ ]] || die "key '$k' is int: '$v' is not an integer" ;;
    bool) case "$v" in 0|1|true|false|yes|no) : ;; *) die "key '$k' is bool: use 0/1/true/false/yes/no";; esac ;;
    enum\[*\]) local allowed="${t#enum[}"; allowed="${allowed%]}"
               echo ",$allowed," | grep -q ",$v," || die "key '$k' must be one of: ${allowed//,/ }" ;;
    *) warn "unknown schema type '$t' for '$k' — accepting unvalidated" ;;
  esac
}

# ===========================================================================
# subcommands
# ===========================================================================
cmd_get() {
  [ $# -eq 1 ] || die "usage: config get <key>"
  _eff "$1"; echo
}

cmd_set() {
  [ $# -eq 2 ] || die "usage: config set <key> <value>"
  local k="$1" v="$2"
  _in_schema "$k" || warn "'$k' is not a known key — storing as custom (unvalidated)"
  _validate "$k" "$v"
  _upsert "$k" "$v"
  echo "set $k = $v   (effective: $(_eff "$k"))"
}

cmd_unset() {
  [ $# -eq 1 ] || die "usage: config unset <key>"
  local k="$1"
  _in_userconf "$k" || die "'$k' is not overridden in user.conf (nothing to unset)"
  _remove "$k"
  echo "unset $k   (reverted to default: $(_eff "$k"))"
}

cmd_edit() {
  _ensure_userdir
  "${EDITOR:-vi}" "$USERCONF"
}

cmd_list() {
  printf '%-44s %-22s %-10s %s\n' KEY "VALUE (effective)" STATUS DEFAULT
  printf '%-44s %-22s %-10s %s\n' "---" "-----------------" "------" "-------"
  # schema keys first, in schema order
  local line k def val status
  while IFS='|' read -r k _ def _ _; do
    case "$k" in ''|\#*) continue;; esac
    val="$(_eff "$k")"
    if _in_userconf "$k"; then status=overridden; else status=default; fi
    printf '%-44s %-22s %-10s %s\n' "$k" "${val:-<empty>}" "$status" "${def:-<empty>}"
  done < <(grep -v '^[[:space:]]*#' "$SCHEMA" 2>/dev/null)
  # user.conf keys not in the schema → custom
  local uk
  for uk in $(_userconf_keys); do
    _in_schema "$uk" && continue
    printf '%-44s %-22s %-10s %s\n' "$uk" "$(_eff "$uk")" "custom" "<none>"
  done
  echo
  echo "Partitions: 'smartslurm config partition list'   Ref groups: 'smartslurm config refgroup list'"
  echo "Overrides live in: $USERCONF"
}

# --- ref groups (JR_REF_CLASS: space-separated ref=group pairs) ---------------
cmd_refgroup() {
  local sub="${1:-list}"; shift || true
  local cur; cur="$(_eff JR_REF_CLASS)"
  case "$sub" in
    list)
      echo "JR_REF_CLASS (reference → regression-pooling group):"
      if [ -z "$cur" ]; then echo "  (none)"; else
        local p; for p in $cur; do printf '  %-10s -> %s\n' "${p%%=*}" "${p#*=}"; done
      fi ;;
    add)
      local group="" refs=()
      while [ $# -gt 0 ]; do case "$1" in
        --group) group="${2:-}"; shift 2;;
        --group=*) group="${1#--group=}"; shift;;
        -*) die "refgroup add: unknown option $1";;
        *) refs+=("$1"); shift;;
      esac; done
      [ -n "$group" ] || die "refgroup add: --group <name> is required"
      [ ${#refs[@]} -gt 0 ] || die "refgroup add: name at least one <ref>"
      # rebuild: drop any existing pair for the named refs, then add ref=group
      local out="" p keep r
      for p in $cur; do keep=1
        for r in "${refs[@]}"; do [ "${p%%=*}" = "$r" ] && keep=0; done
        [ $keep = 1 ] && out="$out $p"
      done
      for r in "${refs[@]}"; do out="$out $r=$group"; done
      out="$(echo "$out" | xargs)"   # trim
      _upsert JR_REF_CLASS "$out"
      echo "refgroup updated: JR_REF_CLASS=\"$out\""
      cmd_refgroup list ;;
    remove)
      [ $# -gt 0 ] || die "refgroup remove: name at least one <ref>"
      local out="" p keep r
      for p in $cur; do keep=1
        for r in "$@"; do [ "${p%%=*}" = "$r" ] && keep=0; done
        [ $keep = 1 ] && out="$out $p"
      done
      out="$(echo "$out" | xargs)"
      if [ -z "$out" ]; then _upsert JR_REF_CLASS ""; else _upsert JR_REF_CLASS "$out"; fi
      echo "refgroup updated: JR_REF_CLASS=\"$out\""
      cmd_refgroup list ;;
    *) die "usage: config refgroup list | add <ref>... --group <name> | remove <ref>..." ;;
  esac
}

# --- partitions (partition<N>Name / MemLimit / TimeLimit) ---------------------
_part_slot_by_name() {   # echo the slot number whose partition<N>Name == $1
  local n name
  for n in $(seq 1 20); do name="$(_eff "partition${n}Name")"; [ "$name" = "$1" ] && { echo "$n"; return 0; }; done
  return 1
}
cmd_partition() {
  local sub="${1:-list}"
  if [ "$sub" = list ]; then
    printf '%-5s %-14s %-12s %-12s\n' SLOT NAME MEM_LIMIT TIME_LIMIT
    local n name
    for n in $(seq 1 20); do
      name="$(_eff "partition${n}Name")"; [ -z "$name" ] && continue
      printf '%-5s %-14s %-12s %-12s\n' "$n" "$name" "$(_eff "partition${n}MemLimit")" "$(_eff "partition${n}TimeLimit")"
    done
    return 0
  fi
  # otherwise: config partition <slot|name> [--name V] [--mem-limit M] [--time-limit T]
  local sel="$1"; shift
  local slot
  if [[ "$sel" =~ ^[0-9]+$ ]]; then slot="$sel"; else slot="$(_part_slot_by_name "$sel")" || die "no partition named '$sel' (see 'config partition list')"; fi
  [ "$slot" -ge 1 ] && [ "$slot" -le 20 ] || die "partition slot must be 1-20"
  local setname="" setmem="" settime="" did=0
  while [ $# -gt 0 ]; do case "$1" in
    --name)        setname="${2:-}"; shift 2;;
    --name=*)      setname="${1#--name=}"; shift;;
    --mem-limit)   setmem="${2:-}"; shift 2;;
    --mem-limit=*) setmem="${1#--mem-limit=}"; shift;;
    --time-limit)  settime="${2:-}"; shift 2;;
    --time-limit=*) settime="${1#--time-limit=}"; shift;;
    *) die "partition: unknown option $1";;
  esac; done
  [ -n "$setname" ]  && { _upsert "partition${slot}Name" "$setname"; did=1; }
  if [ -n "$setmem" ];  then [[ "$setmem"  =~ ^[0-9]+$ ]] || die "--mem-limit must be an integer (MB)";  _upsert "partition${slot}MemLimit" "$setmem";   did=1; fi
  if [ -n "$settime" ]; then [[ "$settime" =~ ^[0-9]+$ ]] || die "--time-limit must be an integer (min)"; _upsert "partition${slot}TimeLimit" "$settime"; did=1; fi
  [ $did = 1 ] || die "nothing to set — give --name, --mem-limit and/or --time-limit"
  echo "partition slot $slot updated."
  cmd_partition list
}

# --- migrate a legacy full ~/.smartSlurm/config/config.txt --------------------
cmd_migrate() {
  local legacy="$USERDIR/config.txt"
  [ -f "$legacy" ] || { echo "No legacy $legacy found — nothing to migrate (you're already on the overlay model)."; return 0; }
  echo "Found a legacy full config: $legacy"
  echo "This will diff it against the repo defaults and keep only your changed keys in:"
  echo "  $USERCONF"
  printf "Proceed? [y/N] "; read -r ans; case "$ans" in y|Y|yes|YES) : ;; *) echo "aborted."; return 0;; esac
  _ensure_userdir
  local n=0 k v repv
  # compare RAW values line-by-line (avoids $HOME-expansion false diffs)
  while IFS= read -r line; do
    case "$line" in export\ *=*) : ;; *) continue;; esac
    k="$(printf '%s' "$line" | sed -n 's/^export[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p')"
    [ -n "$k" ] || continue
    v="$(printf '%s' "$line" | sed 's/^export[[:space:]]\{1,\}[A-Za-z_][A-Za-z0-9_]*=//')"
    repv="$(grep -m1 "^export[[:space:]]\{1,\}${k}=" "$REPO_CONFIG" 2>/dev/null | sed 's/^export[[:space:]]\{1,\}[A-Za-z_][A-Za-z0-9_]*=//')"
    # strip trailing inline comments + surrounding quotes/space for comparison
    local a b; a="$(printf '%s' "$v"   | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')"
                b="$(printf '%s' "$repv" | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')"
    if [ "$a" != "$b" ]; then _upsert "$k" "$a"; n=$((n+1)); echo "  kept override: $k=$a (repo default: ${b:-<empty>})"; fi
  done < "$legacy"
  mv "$legacy" "${legacy}.pre-overlay.bak"
  echo "Migrated $n overridden key(s). Backed up the legacy config to ${legacy}.pre-overlay.bak"
}

usage() {
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

# ===========================================================================
case "${1:-help}" in
  list)      shift; cmd_list "$@" ;;
  get)       shift; cmd_get "$@" ;;
  set)       shift; cmd_set "$@" ;;
  unset)     shift; cmd_unset "$@" ;;
  edit)      shift; cmd_edit "$@" ;;
  refgroup)  shift; cmd_refgroup "$@" ;;
  partition) shift; cmd_partition "$@" ;;
  migrate)   shift; cmd_migrate "$@" ;;
  help|-h|--help) usage ;;
  *) echo "smartslurm config: unknown subcommand '$1'" >&2; echo; usage; exit 1 ;;
esac

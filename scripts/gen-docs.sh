#!/usr/bin/env bash
# gen-docs.sh — generate the machine-derivable parts of module READMEs.
#
# WHY: the action table and the config-key table in a module README are the same
# facts as module.yaml `actions:`/`usage:`/`env:` — keeping them in prose meant
# every module got a hand-maintained copy (and the validator grew a README-drift
# WARN as a tax on it). Generated blocks remove the class: the yaml is the source,
# the README block is output, CI checks freshness.
#
# Usage:
#   scripts/gen-docs.sh           regenerate the blocks in every module README
#   scripts/gen-docs.sh --check   exit 1 when a block is stale (CI gate)
#   scripts/gen-docs.sh --module NAME
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "${_here}/.." && pwd)"
# shellcheck source=/dev/null
. "${_root}/tools/_shared/lib/45-meta.sh"
# shellcheck source=/dev/null
. "${_root}/tools/_shared/lib/40-cfg.sh"

mode="write"
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check"; shift ;;
    --module) only="${2:?--module needs a name}"; shift 2 ;;
    -h | --help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '✗  unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

_begin='<!-- BEGIN GENERATED: actions (scripts/gen-docs.sh) -->'
_end='<!-- END GENERATED: actions -->'
_ebegin='<!-- BEGIN GENERATED: config (scripts/gen-docs.sh) -->'
_eend='<!-- END GENERATED: config -->'

_block_actions() { # $1 = module.yaml
  printf '%s\n' "$_begin"
  printf '| action | what it does |\n| --- | --- |\n'
  local a line
  for a in $(meta_field "$1" actions); do
    line="$(meta_map_value "$1" usage "$a")"
    [ -n "${line}" ] || line="—"
    printf '| `%s` | %s |\n' "${a}" "${line}"
  done
  printf '%s\n' "$_end"
}

_block_config() { # $1 = module.yaml
  printf '%s\n' "$_ebegin"
  local k def desc flags any=0
  printf '| key | default | notes |\n| --- | --- | --- |\n'
  while IFS="$(printf '\t')" read -r k def desc flags; do
    [ -n "${k}" ] || continue
    any=1
    printf '| `%s` | `%s` | %s%s |\n' "${k}" "${def}" "${desc}" "${flags:+ (${flags})}"
  done <<DECL
$(cfg_env_declare "$1" 2>/dev/null)
DECL
  [ "${any}" = "1" ] || printf '| — | — | no declared config keys |\n'
  printf '%s\n' "$_eend"
}

_gen_readme() { # $1 = module dir → README with the blocks refreshed
  # pitfall #8: no same-line local self-reference (bash 3.2 expands all RHS first)
  local dir="$1"
  local yaml="$dir/module.yaml"
  local readme="$dir/README.md"
  [ -f "${yaml}" ] || return 0
  [ -f "${readme}" ] || return 0
  local tmp a c
  tmp="$(mktemp)"
  a="$(mktemp)"; c="$(mktemp)"
  _block_actions "${yaml}" >"${a}"
  _block_config "${yaml}" >"${c}"
  # replace existing blocks; append both when the markers are missing
  awk -v ab="$_begin" -v ae="$_end" -v cb="$_ebegin" -v ce="$_eend" '
    $0 == ab { skip = 1; while ((getline l < AF) > 0) print l; next }
    $0 == cb { skip = 1; while ((getline l < CF) > 0) print l; next }
    skip && ($0 == ae || $0 == ce) { skip = 0; next }
    skip { next }
    { print }
  ' AF="${a}" CF="${c}" "${readme}" >"${tmp}"
  if ! grep -qF "${_begin}" "${readme}" || ! grep -qF "${_ebegin}" "${readme}"; then
    {
      printf '\n'
      grep -qF "${_begin}" "${readme}" || cat "${a}"
      grep -qF "${_ebegin}" "${readme}" || cat "${c}"
    } >>"${tmp}"
  fi
  if diff -q "${readme}" "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}" "${a}" "${c}"
    return 0
  fi
  if [ "${mode}" = "check" ]; then
    printf '✗  %s: generated blocks are STALE — run scripts/gen-docs.sh\n' "${readme}" >&2
    rm -f "${tmp}" "${a}" "${c}"
    return 1
  fi
  mv "${tmp}" "${readme}"
  rm -f "${a}" "${c}"
  printf '✓  regenerated %s\n' "${readme#"${_root}/"}"
  return 0
}

rc=0
for d in "${_root}"/tools/*/; do
  m="$(basename "${d}")"
  [ "${m}" = "_shared" ] && continue
  [ -n "${only}" ] && [ "${m}" != "${only}" ] && continue
  _gen_readme "${d%/}" || rc=1
done
[ "${rc}" = "0" ] || exit 1
[ "${mode}" = "check" ] && printf '✓  module README blocks are fresh\n'
exit 0

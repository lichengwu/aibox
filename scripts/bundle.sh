#!/usr/bin/env bash
# bundle.sh — assemble the single-file CLI from its sources.
#
# WHY: the shipped artifact must be ONE file (curl|bash install), but that is a
# RELEASE-shape constraint, not a source-shape one. Keeping the 5k lines
# hand-edited in one file forced "inline twins" of shared helpers (the manager
# cannot source tools/_shared) and every twin eventually drifts. So: the manager
# is maintained as src/aibox/*.sh (concatenated in lexical order) and
# `bin/aibox` is a GENERATED artifact — same single file, zero twins.
#
# Usage:
#   scripts/bundle.sh                 write bin/aibox (default --out)
#   scripts/bundle.sh --check         exit 1 when the artifact is stale (CI gate)
#   scripts/bundle.sh --out PATH      write/check a specific path
#   scripts/bundle.sh --print         concatenation on stdout
#
# Ordering contract: files are concatenated in LEXICAL order of their numeric
# prefixes (00-head.sh first — it carries the shebang and `set -euo pipefail`).
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "${_here}/.." && pwd)"
_srcdir="${_root}/src/aibox"

mode="write"
out="${_root}/bin/aibox"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check"; shift ;;
    --print) mode="print"; shift ;;
    --out)   out="${2:?--out needs a path}"; shift 2 ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die_usage="unknown option: $1"; printf '%s\n' "$die_usage" >&2; exit 2 ;;
  esac
done

[ -d "${_srcdir}" ] || { printf '✗  sources missing: %s\n' "${_srcdir}" >&2; exit 1; }

_bundle() {
  local f
  for f in "${_srcdir}"/*.sh; do
    [ -e "${f}" ] || continue
    cat "${f}"
  done
}

case "${mode}" in
  print)
    _bundle
    ;;
  write)
    _bundle >"${out}.tmp.$$"
    chmod +x "${out}.tmp.$$"
    mv "${out}.tmp.$$" "${out}"
    printf '✓  bundled %s file(s) → %s\n' \
      "$(ls -1 "${_srcdir}"/*.sh | wc -l | tr -d ' ')" "${out}"
    ;;
  check)
    _tmp="$(mktemp)"
    _bundle >"${_tmp}"
    if ! diff -u "${out}" "${_tmp}" >/dev/null 2>&1; then
      printf '✗  %s is STALE — regenerate with scripts/bundle.sh\n' "${out}" >&2
      diff -u "${out}" "${_tmp}" | head -40 >&2 || true
      rm -f "${_tmp}"
      exit 1
    fi
    rm -f "${_tmp}"
    printf '✓  %s is up to date with src/aibox/*.sh\n' "${out}"
    ;;
esac
#!/usr/bin/env bash
# bundle.sh — assemble the release artifacts from their sources.
#
# WHY: the shipped CLI must be ONE file (curl|bash), but that is a RELEASE-shape
# constraint, not a source-shape one. Keeping the whole manager in one hand-edited
# file forced "inline twins" of the shared helpers (a single file cannot source
# tools/_shared) and every twin eventually drifted. So now:
#
#   src/aibox/*.sh          maintained sources of the manager (lexical order)
#   tools/_shared/lib/*.sh  maintained sources of the shared library
#        ↓ scripts/bundle.sh
#   bin/aibox               GENERATED single-file CLI = manager sources
#                           + the shared library injected after the last
#                           fragment with a numeric prefix < 10 (so the colors
#                           from 05-env.sh are set before it loads)
#   tools/_shared/common.sh GENERATED module-side include = the shared library
#                           (what module.yaml `includes: [common]` downloads)
#
# Usage:
#   scripts/bundle.sh                 write both artifacts
#   scripts/bundle.sh --check         exit 1 when either artifact is stale (CI gate)
#   scripts/bundle.sh --print         the manager bundle on stdout
#   scripts/bundle.sh --out PATH      write/check the manager bundle at PATH
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "${_here}/.." && pwd)"
_srcdir="${_root}/src/aibox"
_libdir="${_root}/tools/_shared/lib"
_common="${_root}/tools/_shared/common.sh"

mode="write"
out="${_root}/bin/aibox"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode="check"; shift ;;
    --print) mode="print"; shift ;;
    --out)   out="${2:?--out needs a path}"; shift 2 ;;
    -h | --help)
      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf '✗  unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -d "${_srcdir}" ] || { printf '✗  sources missing: %s\n' "${_srcdir}" >&2; exit 1; }
[ -d "${_libdir}" ] || { printf '✗  shared library missing: %s\n' "${_libdir}" >&2; exit 1; }

# The shared library, concatenated in lexical order.
_bundle_shared() {
  local f
  for f in "${_libdir}"/*.sh; do
    [ -e "${f}" ] || continue
    cat "${f}"
  done
}

# The manager: src fragments in lexical order with the shared library injected
# before the first >= 10 fragment (after 05-env.sh's colors, before the UI
# helpers that override nothing — one definition per helper).
_bundle_manager() {
  local f base injected=0
  for f in "${_srcdir}"/*.sh; do
    [ -e "${f}" ] || continue
    base="$(basename "${f}")"
    if [ "${injected}" = "0" ]; then
      case "${base%%-*}" in
        '' | *[!0-9]*) : ;; # not numeric-prefixed: no decision
        *) if [ "$((10#${base%%-*}))" -ge 10 ]; then
             _bundle_shared
             injected=1
           fi ;;
      esac
    fi
    cat "${f}"
  done
  if [ "${injected}" = "0" ]; then
    printf '✗  no >= 10 fragment found — the shared library would not be injected\n' >&2
    return 1
  fi
}

_write_one() { # $1 = target path, $2 = producer function
  local target="$1" producer="$2"
  "${producer}" >"${target}.tmp.$$"
  if [ "${target##*/}" != "common.sh" ]; then chmod +x "${target}.tmp.$$"; fi
  mv "${target}.tmp.$$" "${target}"
}

_check_one() { # $1 = target path, $2 = producer function → 0 fresh / 1 stale
  local target="$1" producer="$2" tmp
  tmp="$(mktemp)"
  "${producer}" >"${tmp}"
  if ! diff -u "${target}" "${tmp}" >/dev/null 2>&1; then
    printf '✗  %s is STALE — regenerate with scripts/bundle.sh\n' "${target}" >&2
    diff -u "${target}" "${tmp}" | head -40 >&2 || true
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  printf '✓  fresh: %s\n' "${target}"
}

case "${mode}" in
  print)
    _bundle_manager
    ;;
  write)
    _write_one "${out}" _bundle_manager
    printf '✓  bundled %s fragment(s) → %s\n' \
      "$(ls -1 "${_srcdir}"/*.sh | wc -l | tr -d ' ')" "${out}"
    _write_one "${_common}" _bundle_shared
    printf '✓  bundled %s shared fragment(s) → %s\n' \
      "$(ls -1 "${_libdir}"/*.sh | wc -l | tr -d ' ')" "${_common}"
    ;;
  check)
    rc=0
    _check_one "${out}" _bundle_manager || rc=1
    # --out targets the manager bundle only (tests use it as a scratch path);
    # the shared include is always checked at its canonical location.
    if [ "${out}" = "${_root}/bin/aibox" ]; then
      _check_one "${_common}" _bundle_shared || rc=1
    fi
    exit "${rc}"
    ;;
esac
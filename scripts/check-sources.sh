#!/usr/bin/env bash
# check-sources.sh — repo-level source-hygiene gate.
#
# 1. ANTI-TWIN: no function may be defined in BOTH tools/_shared/lib/*.sh and
#    src/aibox/*.sh. That duplication is exactly what this refactor removed:
#    the manager used to inline "twins" of shared helpers (a single file could
#    not source the shared lib) and every twin drifted. The shared library is
#    injected into the bundle by scripts/bundle.sh, so a helper needed by both
#    MUST live in exactly one place: tools/_shared/lib/.
# 2. Every manager fragment carries a unique numeric prefix (the bundle order is
#    lexical — a missing prefix would silently reorder execution).
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "${_here}/.." && pwd)"
fail=0

_defs() { # file → top-level function names (one per line, sorted -u)
  grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$@" 2>/dev/null | sed 's/()$//' | sort -u
}
shared_defs="$(mktemp)"; mgr_defs="$(mktemp)"
_defs "${_root}"/tools/_shared/lib/*.sh >"${shared_defs}"
_defs "${_root}"/src/aibox/*.sh >"${mgr_defs}"
twins="$(comm -12 "${shared_defs}" "${mgr_defs}")"
if [ -n "${twins}" ]; then
  printf '✗  ANTI-TWIN: defined in both tools/_shared/lib and src/aibox:\n' >&2
  printf '%s\n' "${twins}" | sed 's/^/     /' >&2
  printf '   → keep ONE definition: move it to tools/_shared/lib/ (the bundler injects it)\n' >&2
  fail=1
else
  printf '✓  anti-twin: %s shared helper(s), no duplicate in the manager\n' \
    "$(wc -l <"${shared_defs}" | tr -d ' ')"
fi
rm -f "${shared_defs}" "${mgr_defs}"

# DATA IS NOT CODE: state/config/env files must be parsed (cfg_kv_load / cfg_kv_get),
# never sourced. Sourcing executes whatever is in the file — a corrupted or hostile
# config, registry cache, clash state or deploy .env would run as the user.
# Only CODE files may be sourced (libs and the shared include).
src_hits=""
for f in "${_root}"/src/aibox/*.sh "${_root}"/tools/*/lib.sh "${_root}"/tools/*/svc.sh \
         "${_root}"/tools/*/install.sh "${_root}"/tools/*/uninstall.sh "${_root}"/tools/*/update.sh; do
  [ -f "${f}" ] || continue
  hit="$(grep -nE '(^|[[:space:];&|(])\.[[:space:]]+"' "${f}" 2>/dev/null |
    grep -vE '^[0-9]+:[[:space:]]*#' |
    grep -vE 'LIB_COMMON|LIB_SELF|lib\.sh"|common\.sh"|_common\.sh"|nvm\.sh"' || true)"
  [ -n "${hit}" ] && src_hits="${src_hits}${f}: ${hit}
"
done
if [ -n "${src_hits}" ]; then
  printf '✗  SOURCES A DATA FILE (data is not code — parse it: cfg_kv_load / cfg_kv_get):\n%s' "${src_hits}" >&2
  fail=1
else
  printf '✓  data stores: parsed, never sourced\n'
fi

# numeric prefix, unique
seen=""
for f in "${_root}"/src/aibox/*.sh; do
  b="$(basename "${f}")"
  case "${b%%-*}" in
    '' | *[!0-9]*) printf '✗  %s: no numeric prefix (bundle order is lexical)\n' "${b}" >&2; fail=1 ;;
    *) case " ${seen} " in
         *" ${b%%-*} "*) printf '✗  duplicate numeric prefix: %s\n' "${b}" >&2; fail=1 ;;
         *) seen="${seen} ${b%%-*}" ;;
       esac ;;
  esac
done
[ "${fail}" = "0" ] && printf '✓  fragment prefixes: unique\n'
exit "${fail}"

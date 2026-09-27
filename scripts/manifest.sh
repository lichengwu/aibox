#!/usr/bin/env bash
# manifest.sh — generate/verify modules.SHA256SUMS: the content manifest of every
# file the manager downloads into a module cache.
#
# WHY: module scripts are code that runs as the user. The repo/registry source is
# the trust anchor; the manifest makes a tampered cache (or a compromised mirror
# path) detectable, and CI keeps it in sync with the tree (like bin/aibox).
#
# Usage:
#   scripts/manifest.sh            write modules.SHA256SUMS (default)
#   scripts/manifest.sh --check    exit 1 when the manifest is stale (CI gate)
#   scripts/manifest.sh --print    print the manifest without writing
#   scripts/manifest.sh --root DIR --out FILE   build a manifest for another tree
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "${_here}/.." && pwd)"
out="${_root}/modules.SHA256SUMS"
mode="write"
case "${1:-}" in
  --check) mode="check" ;;
  --print) mode="print" ;;
  --out)
    out="${2:?--out needs a path}"
    mkdir -p "$(dirname "${out}")"
    shift 2
    ;;
  --root) # scan another tree (tests use it to build a fixture source)
    _root="${2:?--root needs a path}"
    shift 2
    ;;
  -h | --help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) printf '✗  unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

_files() { # every file a module cache can receive, repo-relative, sorted
  local m f
  find "${_root}/tools" -type f \
    \( -name 'module.yaml' -o -name 'lib.sh' -o -name 'install.sh' -o -name 'uninstall.sh' \
    -o -name 'update.sh' -o -name 'svc.sh' -o -name 'cli' -o -name '*.yml' -o -name '*.yaml' \) \
    -not -path '*/docs/*' -not -name 'README*' 2>/dev/null | sort
  printf '%s\n' "${_root}/tools/_shared/common.sh"
}

_gen() {
  local f
  _files | while IFS= read -r f; do
    [ -f "${f}" ] || continue
    rel="${f#"${_root}/"}"
    if command -v shasum >/dev/null 2>&1; then d="$(shasum -a 256 "${f}" | awk '{print $1}')"
    else d="$(sha256sum "${f}" | awk '{print $1}')"; fi
    printf '%s  %s\n' "${d}" "${rel}"
  done
}

case "${mode}" in
  print) _gen ;;
  write)
    _gen >"${out}.tmp.$$"
    mv "${out}.tmp.$$" "${out}"
    printf '✓  manifest: %s file(s) → %s\n' "$(wc -l <"${out}" | tr -d ' ')" "${out}"
    ;;
  check)
    tmp="$(mktemp)"
    _gen >"${tmp}"
    if ! diff -u "${out}" "${tmp}" >/dev/null 2>&1; then
      printf '✗  %s is STALE — regenerate with scripts/manifest.sh\n' "${out}" >&2
      diff -u "${out}" "${tmp}" | head -20 >&2 || true
      rm -f "${tmp}"; exit 1
    fi
    rm -f "${tmp}"
    printf '✓  manifest fresh (%s files)\n' "$(wc -l <"${out}" | tr -d ' ')"
    ;;
esac

# ---------- content checksums (supply-chain) ----------
# Module scripts are code that runs as the user. The release publishes
# modules.SHA256SUMS (scripts/manifest.sh) covering every fetched file; the
# downloader verifies against it unless AIBOX_VERIFY=0.

# sha256 of a file — shasum (macOS) or sha256sum (Linux); empty when neither exists.
sha256_of() { # $1 = file → hex digest ("" when unavailable)
  local f="${1:-}"
  [ -n "${f}" ] && [ -f "${f}" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${f}" 2>/dev/null | awk '{print $1}'
  fi
}

# The digest recorded for one repo-relative path in a manifest ("" when absent).
manifest_digest() { # $1 = manifest file, $2 = repo-relative path
  local mf="${1:-}" p="${2:-}"
  [ -n "${mf}" ] && [ -f "${mf}" ] && [ -n "${p}" ] || return 0
  awk -v p="${p}" '$2 == p { print $1; exit }' "${mf}" 2>/dev/null
}

# Verify one downloaded file. 0 = ok/skipped, 1 = mismatch (caller decides).
verify_download() { # $1 = file, $2 = manifest ("" = skip), $3 = repo-relative path
  local f="${1:-}" mf="${2:-}" rel="${3:-}" want got
  [ "${AIBOX_VERIFY:-1}" = "0" ] && return 0
  [ -n "${mf}" ] && [ -f "${mf}" ] || return 0
  want="$(manifest_digest "${mf}" "${rel}")"
  [ -n "${want}" ] || return 0        # not covered (new file, branch ahead): nothing to check
  got="$(sha256_of "${f}")"
  [ -n "${got}" ] || return 0         # no sha tool on this host: nothing to check with
  [ "${want}" = "${got}" ] && return 0
  printf '%s' "sha256 mismatch for ${rel}: manifest ${want}, downloaded ${got}" >&2
  return 1
}

#!/usr/bin/env bash
# openmaic module — update hook
# Logic: compare the CLI shipped in the module with the installed copy; skip if identical (idempotent);
#       if a newer version or content differs, overwrite-install.
# Args: aibox passes through --restart / --no-restart — this module has no service to restart,
#       service restart is handled by `openmaic restart` on the deploy host, so these two args are ignored.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_SRC}" ]; then
  die "CLI not found in module: ${CLI_SRC} (run 'aibox update openmaic' to fetch again)"
fi

if [ ! -f "${CLI_DEST}" ]; then
  log "openmaic not installed locally, installing instead"
  do_install
  ensure_path
  host_notice
  exit 0
fi

old="$(installed_version || true)"
new="$(cli_version)"

if [ "${old}" = "${new}" ] && cmp -s "${CLI_SRC}" "${CLI_DEST}"; then
  log "openmaic is up to date (${new}), no update needed"
  # CLI unchanged, but aibox's proxy config may have just changed — sync once more (idempotent)
  sync_proxy_to_conf
  exit 0
fi

log "updating openmaic CLI ${old:-unknown} -> ${new} ..."
do_install
ensure_path
echo
log "dest    : ${CLI_DEST}"
log "if on the deploy host, manage the service itself with: openmaic restart / openmaic upgrade"

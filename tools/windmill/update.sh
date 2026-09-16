#!/usr/bin/env bash
# windmill module — update hook
# Logic: compare the CLI shipped with the module against the installed copy; skip if identical (idempotent);
#       if a newer version or content differs, overwrite-install.
# Args: aibox passes through --restart / --no-restart — a running stack is unaffected by CLI updates
#       (the CLI is only invoked on demand by systemd units), so these two args are ignored.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_SRC}" ]; then
  die "CLI not found in module: ${CLI_SRC} (run aibox update windmill to re-pull)"
fi

if [ ! -f "${CLI_DEST}" ]; then
  log "windmill not installed locally, installing instead"
  do_install
  ensure_path
  host_notice
  exit 0
fi

old="$(installed_version || true)"
new="$(cli_version)"

if [ "${old}" = "${new}" ] && cmp -s "${CLI_SRC}" "${CLI_DEST}"; then
  log "windmill is up to date (${new}), no update needed"
  # CLI unchanged, but aibox's proxy config may have just changed — seed once more (append-only, never overwrite)
  seed_conf
  exit 0
fi

log "updating windmill CLI ${old:-unknown} -> ${new} ..."
do_install
ensure_path
echo
log "dest: ${CLI_DEST}"
log "for the deployed Windmill version use: windmill upgrade (managed separately, unrelated to CLI updates)"

#!/usr/bin/env bash
# openmaic module — uninstall hook
# Only removes the CLI itself. **Deliberately leaves** /etc/openmaic (keys and config) and the deploy root
# $AIBOX_HOME/apps/openmaic (deploy directory, data volume mount points) untouched — they belong to "this deployment"
# rather than "this command"; mistaken deletion is irreversible, so we only warn and do not act.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_DEST}" ]; then
  log "${CLI_DEST} not found, nothing to uninstall"
  exit 0
fi

rm -f "${CLI_DEST}"
log "removed ${CLI_DEST}"

if [ -d /etc/openmaic ]; then
  warn "kept /etc/openmaic (contains API Key and access password); to clean up, remove it manually"
fi
# Deploy root derived per module-spec convention (same expression as in the CLI)
_deploy_root="$(openmaic_deploy_root)"
if [ -d "${_deploy_root}" ]; then
  warn "kept ${_deploy_root} (deploy directory and data volumes); to clean up use openmaic clean"
fi

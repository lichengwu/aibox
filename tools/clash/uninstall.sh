#!/usr/bin/env bash
# clash module — uninstall hook.
# Removes only the mihomo binary. **Deliberately does not touch** the deploy root
# (config/subscription cache/state/logs) — the subscription token and refresh state belong
# to "this config"; accidental deletion is irreversible, so we only warn.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

# Stop the process first, to avoid a lingering process after the binary is removed.
if kernel_running; then
  log "Stopping mihomo ..."
  stop_kernel
fi

if [ ! -f "${KERNEL_DEST}" ]; then
  log "Not found: ${KERNEL_DEST}; nothing to uninstall"
  exit 0
fi

rm -f "${KERNEL_DEST}"
log "Removed ${KERNEL_DEST}"

_deploy_root="$(clash_deploy_root)"
if [ -d "${_deploy_root}" ]; then
  warn "Retained ${_deploy_root} (config/subscription cache/state/logs); remove it manually if needed"
fi

#!/usr/bin/env bash
# clash module — uninstall hook.
# Removes the mihomo binary. By default **deliberately does not touch** the deploy
# root (config/subscription cache/state/logs) — the subscription token and refresh
# state belong to "this config"; accidental deletion is irreversible, so we only warn.
# Purge contract (docs/module-spec.md): under AIBOX_PURGE_DATA=1 (set by
# `aibox self uninstall --purge`) the deploy root IS deleted.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

# Stop the process first, to avoid a lingering process after the binary is removed.
if kernel_running; then
  log "Stopping mihomo ..."
  stop_kernel
fi

if [ -f "${KERNEL_DEST}" ]; then
  rm -f "${KERNEL_DEST}"
  log "Removed ${KERNEL_DEST}"
else
  log "Not found: ${KERNEL_DEST} (binary already gone)"
fi

_deploy_root="$(clash_deploy_root)"
if [ -d "${_deploy_root}" ]; then
  if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
    rm -rf "${_deploy_root}"
    log "purged ${_deploy_root} (config/subscription cache/state/logs)"
  else
    warn "Retained ${_deploy_root} (config/subscription cache/state/logs); remove it manually if needed"
  fi
fi

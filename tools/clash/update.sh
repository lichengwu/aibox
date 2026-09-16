#!/usr/bin/env bash
# clash module — update hook.
# Upgrades the mihomo kernel + refreshes the subscription (auto after >1 week).
# aibox passes through --restart/--no-restart — restarting the kernel is the job of
# `clash restart`, so those args are ignored here.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

if [ ! -x "${KERNEL_DEST}" ]; then
  log "mihomo not installed locally; installing instead"
  download_mihomo
  exit 0
fi

old="$(installed_kernel_version || echo unknown)"
latest="$(latest_mihomo_tag || echo "")"
if [ -n "$latest" ] && [ "v${old}" = "v${latest}" ]; then
  log "mihomo is already latest (v${latest})"
else
  log "Upgrading mihomo ${old} -> v${latest:-latest} ..."
  download_mihomo "$latest"
  if kernel_running; then
    log "Restarting mihomo to apply the new kernel ..."
    stop_kernel
    start_kernel
  fi
fi

# Subscription refresh: auto if >1 week old; idempotent skip otherwise.
ensure_fresh
echo
log "Binary    : ${KERNEL_DEST}"
log "Force refresh: aibox clash refresh"

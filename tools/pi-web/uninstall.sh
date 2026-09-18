#!/usr/bin/env bash
# pi-web module — uninstall hook (equivalent to the original pi-web-ctl uninstall)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

cleanup_old
if [ "$OS_KIND" = "Darwin" ]; then
  [ -f "$PLIST" ] && mv -n "$PLIST" "$HOME/.Trash/${LABEL}.plist-$(date +%s)" 2>/dev/null || true
  log "Uninstalled the launchd service (plist moved to Trash). To remove the npm package: npm uninstall -g @agegr/pi-web"
else
  log "Uninstalled the systemd service. To remove the npm package: npm uninstall -g @agegr/pi-web"
fi

# Purge contract (docs/module-spec.md): pi-web has no data volumes — its "data"
# is the globally installed npm package; AIBOX_PURGE_DATA=1 removes it too.
if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  if command -v npm >/dev/null 2>&1; then
    if npm uninstall -g @agegr/pi-web >/dev/null 2>&1; then
      log "purged npm package @agegr/pi-web"
    else
      warn "npm uninstall failed; run manually: npm uninstall -g @agegr/pi-web"
    fi
  else
    warn "npm not found; remove the package manually: npm uninstall -g @agegr/pi-web"
  fi
fi

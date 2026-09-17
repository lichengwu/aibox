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

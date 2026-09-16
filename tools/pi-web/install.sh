#!/usr/bin/env bash
# pi-web module — install hook (equivalent to the original pi-web-ctl install)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

log "Installing @agegr/pi-web as a launchd service ..."
resolve_node
log "npm i -g @agegr/pi-web@latest ..."
npm install -g @agegr/pi-web@latest --silent
cleanup_old
resolve_password
write_service
if [ "$OS_KIND" = "Darwin" ]; then
  log "bootstrap $LABEL ..."
  if ! launchctl bootstrap "gui/${UID_}" "$PLIST" 2>/tmp/pi-web-bootstrap.err; then
    warn "bootstrap failed, output:"
    cat /tmp/pi-web-bootstrap.err >&2
    warn "Diagnose: aibox pi-web diagnose"
    exit 1
  fi
else
  log "enable $LABEL ..."
  loginctl enable-linger "${UID_}" 2>/dev/null || warn "enable-linger failed (the service stops after logout)"
  systemctl --user enable --now "$LABEL" || {
    warn "enable failed"
    warn "Diagnose: aibox pi-web diagnose"
    exit 1
  }
fi
sleep 3
show_status
echo
log "Bind       : ${BIND}:${PORT}"
log "Local URL  : http://127.0.0.1:${PORT}"
if [ "$BIND" = "0.0.0.0" ]; then
  lan_ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<lan-ip>')"
  log "LAN URL    : http://${lan_ip}:${PORT}"
fi
log "Auth       : pi / ${PASSWORD}"
log "Plist      : $PLIST"
log "Logs       : $LOG_DIR/pi-web{.log,.err.log}"

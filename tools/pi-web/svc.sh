#!/usr/bin/env bash
# pi-web module — service ops hook (equivalent to the original pi-web-ctl start|stop|restart|status|logs|diagnose)
# Usage: aibox pi-web <action>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
case "$action" in
start)
  if [ "$OS_KIND" = "Darwin" ]; then
    [ ! -f "$PLIST" ] && die "$PLIST does not exist; run: aibox install pi-web"
    launchctl bootstrap "gui/${UID_}" "$PLIST" 2>/dev/null || launchctl kickstart -k "gui/${UID_}/${LABEL}"
  else
    [ ! -f "$UNIT_FILE" ] && die "${UNIT_FILE} does not exist; run: aibox install pi-web"
    loginctl enable-linger "${UID_}" 2>/dev/null || true
    systemctl --user start "$LABEL"
  fi
  sleep 2
  show_status
  ;;
stop)
  if [ "$OS_KIND" = "Darwin" ]; then
    launchctl bootout "gui/${UID_}/${LABEL}" 2>/dev/null || true
  else
    systemctl --user stop "$LABEL" 2>/dev/null || true
  fi
  log "stopped"
  ;;
restart)
  if [ "$OS_KIND" = "Darwin" ]; then
    if launchctl print "gui/${UID_}/${LABEL}" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/${UID_}/${LABEL}"
    else
      [ -f "$PLIST" ] || die "$PLIST does not exist; run: aibox install pi-web"
      launchctl bootstrap "gui/${UID_}" "$PLIST"
    fi
  else
    if systemctl --user is-active --quiet "$LABEL" 2>/dev/null; then
      systemctl --user restart "$LABEL"
    else
      [ -f "$UNIT_FILE" ] || die "${UNIT_FILE} does not exist; run: aibox install pi-web"
      systemctl --user start "$LABEL"
    fi
  fi
  sleep 3
  show_status
  ;;
status)
  show_status
  ;;
logs)
  tail -f "$LOG_DIR/pi-web.log" "$LOG_DIR/pi-web.err.log"
  ;;
diagnose)
  echo "== node =="
  command -v node && node -v || echo "no node in PATH"
  [ -s "$HOME/.nvm/nvm.sh" ] && echo "nvm: yes" || echo "nvm: no"
  echo "== unit =="
  if [ "$OS_KIND" = "Darwin" ]; then
    [ -f "$PLIST" ] && plutil -lint "$PLIST" && cat "$PLIST" || echo "no plist"
    echo "== launchctl print =="
    launchctl print "gui/${UID_}/${LABEL}" 2>&1 | head -30 || true
  else
    [ -f "$UNIT_FILE" ] && cat "$UNIT_FILE" || echo "no unit"
    echo "== systemctl status =="
    systemctl --user status --no-pager "$LABEL" 2>&1 | head -30 || true
  fi
  echo "== stderr tail =="
  tail -20 "$LOG_DIR/pi-web.err.log" 2>/dev/null || echo "no err log"
  echo "== port =="
  lsof -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || echo "not listening"
  ;;
*)
  die "Usage: aibox pi-web {start|stop|restart|status|logs|diagnose}"
  ;;
esac

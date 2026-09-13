#!/usr/bin/env bash
# pi-web 模块 — 服务运维钩子（等价于原 pi-web-ctl start|stop|restart|status|logs|diagnose）
# 用法: aibox pi-web <action>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
case "$action" in
start)
  [ ! -f "$PLIST" ] && die "$PLIST 不存在，请先 aibox install pi-web"
  launchctl bootstrap "gui/${UID_}" "$PLIST" 2>/dev/null || launchctl kickstart -k "gui/${UID_}/${LABEL}"
  sleep 2
  show_status
  ;;
stop)
  launchctl bootout "gui/${UID_}/${LABEL}" 2>/dev/null || true
  log "stopped"
  ;;
restart)
  if launchctl print "gui/${UID_}/${LABEL}" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/${UID_}/${LABEL}"
  else
    [ -f "$PLIST" ] || die "$PLIST 不存在，请先 aibox install pi-web"
    launchctl bootstrap "gui/${UID_}" "$PLIST"
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
  echo "== plist =="
  [ -f "$PLIST" ] && plutil -lint "$PLIST" && cat "$PLIST" || echo "no plist"
  echo "== launchctl print =="
  launchctl print "gui/${UID_}/${LABEL}" 2>&1 | head -30 || true
  echo "== stderr tail =="
  tail -20 "$LOG_DIR/pi-web.err.log" 2>/dev/null || echo "no err log"
  echo "== port =="
  lsof -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || echo "not listening"
  ;;
*)
  die "用法: aibox pi-web {start|stop|restart|status|logs|diagnose}"
  ;;
esac

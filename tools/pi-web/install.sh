#!/usr/bin/env bash
# pi-web 模块 — 安装钩子（等价于原 pi-web-ctl install）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

log "安装 @agegr/pi-web 为 launchd 服务 ..."
resolve_node
log "npm i -g @agegr/pi-web@latest ..."
npm install -g @agegr/pi-web@latest --silent
cleanup_old
resolve_password
write_service
if [ "$OS_KIND" = "Darwin" ]; then
  log "bootstrap $LABEL ..."
  if ! launchctl bootstrap "gui/${UID_}" "$PLIST" 2>/tmp/pi-web-bootstrap.err; then
    warn "bootstrap 失败，输出如下："
    cat /tmp/pi-web-bootstrap.err >&2
    warn "诊断: aibox pi-web diagnose"
    exit 1
  fi
else
  log "enable $LABEL ..."
  loginctl enable-linger "${UID_}" 2>/dev/null || warn "enable-linger 失败（用户登出后服务会停）"
  systemctl --user enable --now "$LABEL" || { warn "enable 失败"; warn "诊断: aibox pi-web diagnose"; exit 1; }
fi
sleep 3
show_status
echo
log "Bind    : ${BIND}:${PORT}"
log "本机 URL: http://127.0.0.1:${PORT}"
if [ "$BIND" = "0.0.0.0" ]; then
  lan_ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<局域网IP>')"
  log "内网 URL: http://${lan_ip}:${PORT}"
fi
log "Auth    : pi / ${PASSWORD}"
log "Plist   : $PLIST"
log "Logs    : $LOG_DIR/pi-web{.log,.err.log}"

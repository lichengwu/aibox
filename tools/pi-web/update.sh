#!/usr/bin/env bash
# pi-web 模块 — 更新钩子（原 pi-web-ctl 无 update，新增：升级 npm 包 + 重启服务）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

resolve_node
log "npm i -g @agegr/pi-web@latest ..."
npm install -g @agegr/pi-web@latest --silent
cleanup_old
write_plist
if launchctl print "gui/${UID_}/${LABEL}" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/${UID_}/${LABEL}"
else
  launchctl bootstrap "gui/${UID_}" "$PLIST"
fi
sleep 3
show_status
log "pi-web 已更新并重启"

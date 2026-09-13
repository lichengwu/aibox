#!/usr/bin/env bash
# pi-web 模块 — 卸载钩子（等价于原 pi-web-ctl uninstall）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

cleanup_old
[ -f "$PLIST" ] && mv -n "$PLIST" "$HOME/.Trash/${LABEL}.plist-$(date +%s)" 2>/dev/null || true
log "已卸载 launchd 服务（plist 移入废纸篓）。npm 包如需删除: npm uninstall -g @agegr/pi-web"

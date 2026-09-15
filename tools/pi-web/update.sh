#!/usr/bin/env bash
# pi-web 模块 — 更新钩子
# 逻辑:
#   1. 检测 @agegr/pi-web 是否有新版本（已装 vs latest）
#      - 无更新 -> 不做任何事，不重启（无论 --restart/--no-restart）
#      - 有更新 -> 升级 + 重写 plist，再决定是否重启
#   2. 重启决策（仅在有更新时）:
#      --restart       直接重启，不询问
#      --no-restart    有更新也不重启
#      （空）          交互询问 [Y/n]；非交互环境默认不重启
# 参数: $1 = --restart | --no-restart | （空）
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

restart_arg="${1:-}"

resolve_node

cur="$(npm ls -g @agegr/pi-web --depth=0 2>/dev/null | grep -oE '@agegr/pi-web@[0-9][0-9.]*' | head -1 | sed 's/.*@//' || true)"
latest="$(npm view @agegr/pi-web version 2>/dev/null | tr -d '[:space:]' || true)"

if [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" = "$latest" ]; then
  log "@agegr/pi-web 已是最新 ($latest)，无需更新，不重启"
  exit 0
fi

log "升级 @agegr/pi-web ${cur:-未安装} -> ${latest:-latest} ..."
npm install -g @agegr/pi-web@latest --silent
cleanup_old
resolve_password
write_plist

# ---------- 决定是否重启 ----------
do_restart=""
case "$restart_arg" in
--restart) do_restart=1 ;;
--no-restart) do_restart=0 ;;
"")
  if ask_yn "更新完成，是否重启 pi-web 服务？" y; then
    do_restart=1
  else
    do_restart=0
  fi
  ;;
*) die "未知参数: ${restart_arg}（可用 --restart | --no-restart）" ;;
esac

if [ "$do_restart" = "1" ]; then
  if launchctl print "gui/${UID_}/${LABEL}" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/${UID_}/${LABEL}"
  else
    launchctl bootstrap "gui/${UID_}" "$PLIST"
  fi
  sleep 3
  show_status
  log "pi-web 已更新并重启"
else
  log "已更新但未重启。稍后重启: aibox pi-web restart（或开机后 KeepAlive 自启）"
fi

#!/usr/bin/env bash
# clash 模块 — 更新钩子
# 升级 mihomo 内核 + 刷新订阅（>1周自动）。
# aibox 会透传 --restart/--no-restart —— 内核重启由 clash restart 负责，忽略。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

if [ ! -x "${KERNEL_DEST}" ]; then
  log "本机未安装 mihomo，改为安装"
  download_mihomo
  exit 0
fi

old="$(installed_kernel_version || echo 未知)"
latest="$(latest_mihomo_tag || echo "")"
if [ -n "$latest" ] && [ "v${old}" = "v${latest}" ]; then
  log "mihomo 已是最新（v${latest}）"
else
  log "升级 mihomo ${old} -> v${latest:-latest} ..."
  download_mihomo "$latest"
  if kernel_running; then
    log "重启 mihomo 以应用新内核 ..."
    stop_kernel
    start_kernel
  fi
fi

# 订阅刷新：>1周自动；未过期则幂等跳过
ensure_fresh
echo
log "落点 : ${KERNEL_DEST}"
log "强制刷新订阅: aibox clash refresh"

#!/usr/bin/env bash
# clash 模块 — 卸载钩子
# 只删 mihomo 二进制。**刻意不动**部署根（config/订阅缓存/state/logs）——
# 订阅 token 与刷新状态属于「这套配置」，误删不可逆，只提示不执行。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

# 先停掉进程，避免删二进制后残留进程
if kernel_running; then
  log "停止 mihomo ..."
  stop_kernel
fi

if [ ! -f "${KERNEL_DEST}" ]; then
  log "未发现 ${KERNEL_DEST}，无需卸载"
  exit 0
fi

rm -f "${KERNEL_DEST}"
log "已删除 ${KERNEL_DEST}"

_deploy_root="$(clash_deploy_root)"
if [ -d "${_deploy_root}" ]; then
  warn "保留 ${_deploy_root}（config/订阅缓存/state/logs），如需清理请手动删除"
fi

#!/usr/bin/env bash
# windmill 模块 — 卸载钩子
# 只删 CLI 本体。**刻意不动** /etc/windmill/windmill.conf（主机级配置）与
# 部署根 $AIBOX_HOME/apps/windmill（数据库卷、备份、凭据）—— 它们属于
# 「这套部署」而不是「这个命令」，误删不可逆，只提示不执行。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_DEST}" ]; then
  log "未发现 ${CLI_DEST}，无需卸载"
  exit 0
fi

rm -f "${CLI_DEST}"
log "已删除 ${CLI_DEST}"

if [ -f /etc/windmill/windmill.conf ]; then
  warn "保留 /etc/windmill/windmill.conf（主机级配置），如需清理请手动删除"
fi
_deploy_root="$(wm_deploy_root)"
if [ -d "${_deploy_root}" ]; then
  warn "保留 ${_deploy_root}（部署目录、数据库卷与备份），如需清理请用 windmill destroy --all"
fi
if command -v systemctl >/dev/null 2>&1; then
  [ -f /etc/systemd/system/windmill-backup.timer ] && \
    warn "systemd 单元仍在（windmill systemd remove 可卸载）"
fi

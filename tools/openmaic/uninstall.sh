#!/usr/bin/env bash
# openmaic 模块 — 卸载钩子
# 只删 CLI 本体。**刻意不动** /etc/openmaic（密钥与配置）与 /opt/openmaic（部署目录、
# 数据卷挂载点）—— 它们属于「这套部署」而不是「这个命令」，误删不可逆，只提示不执行。
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

if [ -d /etc/openmaic ]; then
  warn "保留 /etc/openmaic（含 API Key 与访问密码），如需清理请手动删除"
fi
if [ -d /opt/openmaic ]; then
  warn "保留 /opt/openmaic（部署目录与数据卷），如需清理请用 openmaic clean"
fi

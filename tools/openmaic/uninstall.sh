#!/usr/bin/env bash
# openmaic 模块 — 卸载钩子
# 只删 CLI 本体。**刻意不动** /etc/openmaic（密钥与配置）与部署根
# $AIBOX_HOME/apps/openmaic（部署目录、数据卷挂载点）—— 它们属于「这套部署」
# 而不是「这个命令」，误删不可逆，只提示不执行。
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
# 部署根按 module-spec 约定派生（与 CLI 内同一表达式；此处仅用于提示，故可回退）
_apps_root="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-${HOME:-}/.aibox}/apps}"
_deploy_root="${OPENMAIC_BASE_DIR:-${_apps_root}/openmaic}"
if [ -d "${_deploy_root}" ]; then
  warn "保留 ${_deploy_root}（部署目录与数据卷），如需清理请用 openmaic clean"
fi

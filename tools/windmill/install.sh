#!/usr/bin/env bash
# windmill 模块 — 安装钩子：把 windmill 运维 CLI 放到本机
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

log "安装 windmill 运维 CLI ..."
do_install
ensure_path
host_notice
echo
log "落点   : ${CLI_DEST}"
log "版本   : $(cli_version)"
log "部署根 : $(wm_deploy_root)（destroy 删不到它之外；aibox self uninstall 有 fail-closed 保护）"
log "配置   : /etc/windmill/windmill.conf（已播种则见上）"
log "下一步 : windmill doctor && windmill init --version <ver>"

#!/usr/bin/env bash
# openmaic 模块 — 安装钩子：把 openmaic 运维 CLI 放到本机
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

log "安装 openmaic 运维 CLI ..."
do_install
ensure_path
host_notice
echo
log "落点 : ${CLI_DEST}"
log "版本 : $(cli_version)"
log "自检 : openmaic doctor"

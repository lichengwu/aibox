#!/usr/bin/env bash
# openmaic 模块 — 更新钩子
# 逻辑：把模块内随附的 CLI 与已安装副本比对，内容一致即跳过（幂等）；
#       有新版本或内容有差异则覆盖安装。
# 参数：aibox 会透传 --restart / --no-restart —— 本模块无服务可重启，
#       服务重启由部署主机上的 `openmaic restart` 负责，故忽略这两个参数。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_SRC}" ]; then
  die "模块内找不到 CLI：${CLI_SRC}（可执行 aibox update openmaic 重新拉取）"
fi

if [ ! -f "${CLI_DEST}" ]; then
  log "本机未安装 openmaic，改为安装"
  do_install
  ensure_path
  host_notice
  exit 0
fi

old="$(installed_version || true)"
new="$(cli_version)"

if [ "${old}" = "${new}" ] && cmp -s "${CLI_SRC}" "${CLI_DEST}"; then
  log "openmaic 已是最新（${new}），无需更新"
  exit 0
fi

log "更新 openmaic CLI ${old:-未知} -> ${new} ..."
do_install
ensure_path
echo
log "落点 : ${CLI_DEST}"
log "若在部署主机上，服务本身用: openmaic restart / openmaic upgrade"

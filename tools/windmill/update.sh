#!/usr/bin/env bash
# windmill 模块 — 更新钩子
# 逻辑：把模块内随附的 CLI 与已安装副本比对，内容一致即跳过（幂等）；
#       有新版本或内容有差异则覆盖安装。
# 参数：aibox 会透传 --restart / --no-restart —— 运行中的 stack 不受 CLI 更新影响
#       （CLI 只被 systemd 单元按需调用），故忽略这两个参数。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_SRC}" ]; then
  die "模块内找不到 CLI：${CLI_SRC}（可执行 aibox update windmill 重新拉取）"
fi

if [ ! -f "${CLI_DEST}" ]; then
  log "本机未安装 windmill，改为安装"
  do_install
  ensure_path
  host_notice
  exit 0
fi

old="$(installed_version || true)"
new="$(cli_version)"

if [ "${old}" = "${new}" ] && cmp -s "${CLI_SRC}" "${CLI_DEST}"; then
  log "windmill 已是最新（${new}），无需更新"
  # CLI 没变，但 aibox 的代理配置可能刚变过 —— 仍播种一次（只补不覆盖）
  seed_conf
  exit 0
fi

log "更新 windmill CLI ${old:-未知} -> ${new} ..."
do_install
ensure_path
echo
log "落点 : ${CLI_DEST}"
log "部署的 Windmill 版本用: windmill upgrade（单独管理，与 CLI 更新无关）"

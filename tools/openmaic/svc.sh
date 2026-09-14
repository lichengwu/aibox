#!/usr/bin/env bash
# openmaic 模块 — 服务动作钩子
# 本模块没有自己的常驻服务，因此这里只做**透传**：
#   aibox openmaic status   ->  openmaic status
#   aibox openmaic upgrade  ->  openmaic upgrade
# 实际动作全部由本机的 openmaic CLI 完成（含它自己的确认、并发锁与退出码）。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-}"
if [ -z "${action}" ]; then
  die "用法: aibox openmaic <action> [args]（动作见: openmaic help）"
fi
shift

# 命名撞车提醒：aibox 的 install/uninstall 是装"模块"，而 openmaic 的 install/clean
# 是部署/清理 OpenMAIC 本体。两者差一个词序，值得提醒一次。
case "${action}" in
install | clean)
  warn "注意：这里的 openmaic ${action} 指「部署 / 清理 OpenMAIC 本体」"
  warn "      安装本模块请用: aibox install openmaic"
  ;;
esac

# 优先用模块安装落点，避免 PATH 里有另一份旧副本
CLI=""
if [ -x "${CLI_DEST}" ]; then
  CLI="${CLI_DEST}"
else
  CLI="$(command -v openmaic || true)"
fi
if [ -z "${CLI}" ]; then
  die "找不到 openmaic 命令，先执行: aibox install openmaic"
fi

exec "${CLI}" "${action}" "$@"

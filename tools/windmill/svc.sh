#!/usr/bin/env bash
# windmill 模块 — 服务动作钩子
# 本模块没有自己的常驻进程（stack 由 docker compose 管），因此这里只做**透传**：
#   aibox windmill status   ->  windmill status
#   aibox windmill doctor   ->  windmill doctor
# 实际动作全部由本机的 windmill CLI 完成（含它自己的确认、并发锁与退出码）。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-}"
if [ -z "${action}" ]; then
  die "用法: aibox windmill <action> [args]（动作见: windmill help）"
fi
shift

# 命名撞车提醒：aibox 的 install 是装"模块"，windmill 的 init/destroy 是
# 部署/拆除 Windmill 本体。差一个词，值得提醒一次。
case "${action}" in
init | destroy)
  warn "注意：这里的 windmill ${action} 指「部署 / 拆除 Windmill 本体」"
  warn "      安装本模块请用: aibox install windmill"
  ;;
esac

# 优先用模块安装落点，避免 PATH 里有另一份旧副本
CLI=""
if [ -x "${CLI_DEST}" ]; then
  CLI="${CLI_DEST}"
else
  CLI="$(command -v windmill || true)"
fi
if [ -z "${CLI}" ]; then
  die "找不到 windmill 命令，先执行: aibox install windmill"
fi

exec "${CLI}" "${action}" "$@"

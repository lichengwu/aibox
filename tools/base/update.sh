#!/usr/bin/env bash
# base 模块 — 更新钩子：刷新 compose 文件
# aibox 会透传 --restart/--no-restart —— 共享 stack 重启由 base restart 负责，忽略。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

mkdir -p "$(base_deploy_root)"
cp "$DIR/docker-compose.yml" "$COMPOSE_FILE"
log "compose 已更新（${COMPOSE_FILE}）"
log "应用变更: aibox base restart"

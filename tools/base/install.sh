#!/usr/bin/env bash
# base 模块 — 安装钩子：把 docker-compose.yml 落到部署根
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

log "安装 base 模块（共享 PG 18 + Redis 7）..."
mkdir -p "$(base_deploy_root)"
cp "$DIR/docker-compose.yml" "$COMPOSE_FILE"
log "compose 已放置: ${COMPOSE_FILE}"
echo
log "启动: aibox base start"
log "建库: aibox base createdb <module> [用途]"
log "各部署型模块连共享 PG（network aibox-base + env 指向 127.0.0.1:${PG_PORT}）"

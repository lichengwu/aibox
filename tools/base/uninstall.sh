#!/usr/bin/env bash
# base 模块 — 卸载钩子
# 只停服务 + 删 compose 文件。**刻意不动**数据卷（pg_data/redis_data）——
# 共享数据库属「这套部署」，误删不可逆，只提示。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

if [ -f "$COMPOSE_FILE" ]; then
  compose down 2>/dev/null || true
  rm -f "$COMPOSE_FILE"
  log "已停止共享 PG/Redis 并删除 compose（数据卷保留在 docker）"
else
  log "无 compose，无需卸载"
fi
warn "数据卷（pg_data/redis_data）保留在 docker；如需清除: docker volume rm aibox_pg_data aibox_redis_data"

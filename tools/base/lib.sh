# base 模块共享库（被各钩子 source，不单独执行）
# 共享 PostgreSQL 18 + Redis 7：各模块连共享实例 + 独立数据库（<module> 或 <module>_<用途>）

CLI_NAME="base"

# 部署根（module-spec 部署型约定）
base_deploy_root() {
  if [ -n "${BASE_DIR:-}" ]; then
    printf '%s' "${BASE_DIR}"
    return 0
  fi
  local b="${AIBOX_APPS_ROOT:-}"
  if [ -z "$b" ]; then
    b="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/base' "$b"
}

COMPOSE_FILE="$(base_deploy_root)/docker-compose.yml"
PG_HOST="127.0.0.1"
PG_PORT="${AIBOX_BASE_POSTGRES_PORT:-35432}"
PG_USER="${AIBOX_BASE_POSTGRES_USER:-aibox}"
PG_PASSWORD="${AIBOX_BASE_POSTGRES_PASSWORD:-aibox}"
REDIS_HOST="127.0.0.1"
REDIS_PORT="${AIBOX_BASE_REDIS_PORT:-36379}"
# docker 容器/服务名（消费模块经此名连共享实例；base.env 里的 host 也是它）
POSTGRES_CONTAINER="aibox-base-postgres"
REDIS_CONTAINER="aibox-base-redis"

log() { printf '\033[36m[base]\033[0m %s\n' "${*}"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "${*}" >&2; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "${*}" >&2
  exit 1
}

# docker compose 包装（-f 指定 compose 文件）
compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

ensure_compose() {
  [ -f "$COMPOSE_FILE" ] || die "无 compose（先: aibox install base）"
}

# ---------- lifecycle ----------
# 写 $AIBOX_HOME/base.env —— 消费模块 compose 经 --env-file 注入连接信息（单一源）。
# 只放实例级共享信息（host/port/user/password，用容器内视角：服务名 + 内部端口）；
# 库名 <module> 是各模块自己的，不在这里。
write_base_env() {
  local env_file="${AIBOX_HOME}/base.env"
  mkdir -p "${AIBOX_HOME}"
  cat > "$env_file" <<EOF
# 由 aibox base start 生成 —— 勿手改；改 base 后 base restart 重写
AIBOX_POSTGRES_HOST=${POSTGRES_CONTAINER}
AIBOX_POSTGRES_PORT=5432
AIBOX_POSTGRES_USER=${PG_USER}
AIBOX_POSTGRES_PASSWORD=${PG_PASSWORD}
AIBOX_REDIS_HOST=${REDIS_CONTAINER}
AIBOX_REDIS_PORT=6379
EOF
  log "已写 ${env_file}（消费模块 compose --env-file 注入）"
}

cmd_start() {
  ensure_compose
  log "启动共享 PG/Redis ..."
  compose up -d || die "启动失败（docker？见 aibox base doctor）"
  write_base_env
  log "共享 PG/Redis 已启动（PG ${PG_HOST}:${PG_PORT} / Redis ${REDIS_HOST}:${REDIS_PORT}）"
  compose ps 2>/dev/null | sed 's/^/  /' || true
}

cmd_stop() {
  ensure_compose
  compose down
  log "已停止（数据卷保留）"
}

cmd_status() {
  ensure_compose
  compose ps
  log "PG: ${PG_HOST}:${PG_PORT}（user=${PG_USER}）  Redis: ${REDIS_HOST}:${REDIS_PORT}"
}

# ---------- createdb <module> [用途] ----------
# 在共享 PG 建模块的库：<module> 或 <module>_<用途>（前缀=模块名，避免跨模块撞）
cmd_createdb() {
  local module="$1" usage="${2:-}" dbname
  if [ -n "$usage" ]; then
    dbname="${module}_${usage}"
  else
    dbname="$module"
  fi
  ensure_compose
  # 幂等：已存在则跳过
  if docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='${dbname}'" 2>/dev/null | grep -q 1; then
    log "数据库 ${dbname} 已存在（共享 PG ${PG_HOST}:${PG_PORT}）"
    return 0
  fi
  docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -c "CREATE DATABASE \"${dbname}\";" >/dev/null 2>&1 ||
    die "创建数据库 ${dbname} 失败（PG 未启动？aibox base start）"
  log "数据库 ${dbname} 就绪（共享 PG ${PG_HOST}:${PG_PORT}）"
}

# ---------- Dashboard 接口 ----------
dashboard_info() {
  echo "endpoint=pg://${PG_HOST}:${PG_PORT}（user=${PG_USER}）+ redis://${REDIS_HOST}:${REDIS_PORT}"
  echo "credential=PG user/password ${PG_USER}/*（环境变量 AIBOX_BASE_POSTGRES_PASSWORD 覆盖；消费模块见 ${AIBOX_HOME}/base.env）"
  echo "health=docker exec ${POSTGRES_CONTAINER} pg_isready -U ${PG_USER}"
}

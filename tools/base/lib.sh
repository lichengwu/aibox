# base module shared library (sourced by hooks, not executed directly)
# Shared PostgreSQL 18 + Redis 7: modules connect to the shared instance + use their own DB
# (<module> or <module>_<usage>).

CLI_NAME="base"
# Module version — read from module.yaml next to this lib (cache and repo
# layouts agree; empty on a missing file → callers fall back to dim ?).
MODULE_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$(dirname "${BASH_SOURCE[0]}")/module.yaml" 2>/dev/null | head -1 || true)"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"

# ---------- profile ----------
# AIBOX_PROFILE defaults to "base" (exported by aibox's --profile flag, or set in env).
# profile="base" → no override; compose ${VAR:-default} → repo defaults (35432/36379, etc.).
# profile=<name>  → hash-derived ports/containers/volumes/network, auto-generated config.
# Same profile name → same hash → same values on every machine (deterministic, no coordination).

# Deterministic hash from a profile name (weighted sum of char codes × position).
# bash 3.2 compatible (while loop, no for((..))).
_profile_hash() {
  local name="$1" sum=0 i=0 ch
  while [ $i -lt ${#name} ]; do
    ch="${name:$i:1}"
    sum=$((sum + $(printf '%d' "'$ch") * (i + 1)))
    i=$((i + 1))
  done
  printf '%d' "$sum"
}

# Auto-create the profile config on first use (deterministic, copyable across machines).
_profile_create() {
  local name="$1" pf="$2" h
  h=$(_profile_hash "$name")
  mkdir -p "$(dirname "$pf")"
  cat >"$pf" <<EOF
# aibox profile: $name
# Auto-generated deterministically from the profile name.
# Same name → same values on every machine. Edit to override.
PROFILE_NAME=$name
PROFILE_HASH=$h
EOF
  log "Created profile '$name' (hash=$h)"
  _PROFILE_JUST_CREATED=1
}

# Load (or auto-create) the profile config + derive all module-specific vars.
# Called early in lib.sh; overrides defaults for named profiles.
_profile_load() {
  [ -z "${AIBOX_PROFILE:-}" ] && return 0
  [ "$AIBOX_PROFILE" = "base" ] && return 0

  local pf="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/profiles/${AIBOX_PROFILE}.conf"
  if [ ! -f "$pf" ]; then
    _profile_create "$AIBOX_PROFILE" "$pf"
  fi
  # shellcheck disable=SC1090
  . "$pf" 2>/dev/null || {
    warn "Profile config unparseable: $pf"
    return 1
  }

  local _h="${PROFILE_HASH:-0}" _n="${PROFILE_NAME:-$AIBOX_PROFILE}"
  _PROFILE_SUFFIX="-${_n}"

  # Derive base-specific vars (deterministic from hash + name).
  PG_PORT=$((35100 + _h % 332))
  REDIS_PORT=$((36100 + _h % 279))
  POSTGRES_CONTAINER="aibox-base-${_n}-postgres"
  REDIS_CONTAINER="aibox-base-${_n}-redis"
  ENV_FILE="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base-${_n}.env"

  # Export for compose ${VAR:-default} expansion.
  export AIBOX_BASE_PG_CONTAINER="$POSTGRES_CONTAINER"
  export AIBOX_BASE_REDIS_CONTAINER="$REDIS_CONTAINER"
  export AIBOX_BASE_POSTGRES_PORT="$PG_PORT"
  export AIBOX_BASE_REDIS_PORT="$REDIS_PORT"
  export AIBOX_BASE_PG_VOLUME="aibox_pg_data_${_n}"
  export AIBOX_BASE_REDIS_VOLUME="aibox_redis_data_${_n}"
  export AIBOX_BASE_NETWORK="aibox-base-${_n}"

  # Say what the profile DERIVED (the old copy only said "Created profile" —
  # the actual ports/volumes/containers stayed a mystery until the next ps)
  if [ "${_PROFILE_JUST_CREATED:-0}" = "1" ]; then
    unset _PROFILE_JUST_CREATED
    log "Profile '${_n}' derived: postgres=${PG_PORT} redis=${REDIS_PORT} · containers ${POSTGRES_CONTAINER} / ${REDIS_CONTAINER}"
    log "  env: ${ENV_FILE} · volumes: aibox_pg_data_${_n} / aibox_redis_data_${_n}"
  fi
}

# List all profiles + their derived ports.
_profile_list() {
  local pf_dir="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/profiles"
  echo "Profiles:"
  echo "  base       PG=35432  Redis=36379  (default, from project)"
  if [ -d "$pf_dir" ]; then
    for f in "$pf_dir"/*.conf; do
      [ -f "$f" ] || continue
      PROFILE_NAME="" PROFILE_HASH=0
      # shellcheck disable=SC1090
      . "$f" 2>/dev/null || continue
      [ -n "$PROFILE_NAME" ] || continue
      printf '  %-10s PG=%-6d Redis=%-6d\n' "$PROFILE_NAME" \
        $((35100 + PROFILE_HASH % 332)) $((36100 + PROFILE_HASH % 279))
    done
  fi
}

# ---------- paths + config ----------
# Deploy root (module-spec deploy-type convention). Profile suffix applied for named profiles.
base_deploy_root() {
  if [ -n "${BASE_DIR:-}" ]; then
    printf '%s' "${BASE_DIR}"
    return 0
  fi
  local b="${AIBOX_APPS_ROOT:-}"
  if [ -z "$b" ]; then
    b="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/base%s' "$b" "${_PROFILE_SUFFIX:-}"
}

# Defaults (profile="base" or unset). _profile_load overrides these for named profiles.
PG_HOST="127.0.0.1"
PG_PORT="${AIBOX_BASE_POSTGRES_PORT:-35432}"
PG_USER="${AIBOX_BASE_POSTGRES_USER:-aibox}"
PG_PASSWORD="${AIBOX_BASE_POSTGRES_PASSWORD:-aibox}"
REDIS_HOST="127.0.0.1"
REDIS_PORT="${AIBOX_BASE_REDIS_PORT:-36379}"
POSTGRES_CONTAINER="${AIBOX_BASE_PG_CONTAINER:-aibox-base-postgres}"
REDIS_CONTAINER="${AIBOX_BASE_REDIS_CONTAINER:-aibox-base-redis}"
ENV_FILE="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"

# Load profile (overrides the defaults above for named profiles).
_profile_load

COMPOSE_FILE="$(base_deploy_root)/docker-compose.yml"

# docker compose wrapper (selects the compose file with -f).
compose() {
  require_docker
  docker compose -f "$COMPOSE_FILE" "$@"
}

# Image list from the (mode-aware) compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}

ensure_compose() {
  [ -f "$COMPOSE_FILE" ] || die "No compose file (first: aibox install base)"
}

# Is the shared stack up? Cheap docker ps probe (no PG round-trip) — used by the
# idempotent guards below and by cmd_start's quiet no-op path.
stack_running() {
  require_docker
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${POSTGRES_CONTAINER}" || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${REDIS_CONTAINER}" || return 1
}

# Idempotent "this action needs the stack UP": start it when down, silent when
# already running. `aibox base create <db>` used to die with "PG not running?
# aibox base start" — two commands for one intent (live-caught while wiring the
# consumer modules' start-time ensure).
ensure_stack_running() {
  stack_running && return 0
  info "shared base is not running — starting it…"
  cmd_start
}

# ---------- lifecycle ----------
# Writes $ENV_FILE — consuming modules inject it via compose --env-file (single source).
# Holds only instance-level shared info (host/port/user/password, from the container's perspective:
# service name + internal port); the DB name <module> is each module's own, not here.
write_base_env() {
  mkdir -p "$(dirname "$ENV_FILE")"
  cat >"$ENV_FILE" <<EOF
# Generated by "aibox base start" — do not edit by hand; re-run "base restart" after changing base.
AIBOX_POSTGRES_HOST=${POSTGRES_CONTAINER}
AIBOX_POSTGRES_PORT=5432
AIBOX_POSTGRES_USER=${PG_USER}
AIBOX_POSTGRES_PASSWORD=${PG_PASSWORD}
AIBOX_REDIS_HOST=${REDIS_CONTAINER}
AIBOX_REDIS_PORT=6379
AIBOX_BASE_NETWORK=${AIBOX_BASE_NETWORK:-aibox-base}
EOF
  log "Wrote ${ENV_FILE} (consumed by modules via compose --env-file)"
}

cmd_start() {
  ensure_compose
  # Idempotent AND quiet when there is nothing to do: consumer actions ensure the
  # base before starting, and re-running compose up + printing the container
  # table on every one of them was pure noise. base.env is re-checked here — a
  # deleted base.env must be rewritten even while the containers run.
  if stack_running && [ -f "$ENV_FILE" ]; then
    log "Shared PG/Redis already running (PG ${PG_HOST}:${PG_PORT} / Redis ${REDIS_HOST}:${REDIS_PORT})"
    return 0
  fi
  log "Starting shared PG/Redis ..."
  # docker.io source pool: bounded direct probe (healthy → compose pulls direct,
  # zero overhead); direct dead → ranked mirror pre-pull + tag (see this lib).
  # shellcheck disable=SC2046
  docker_pool_prepull $(compose config --images 2>/dev/null) || true
  compose up -d || die "Start failed (docker? see aibox base doctor)"
  write_base_env
  log "Shared PG/Redis started (PG ${PG_HOST}:${PG_PORT} / Redis ${REDIS_HOST}:${REDIS_PORT})"
  compose ps 2>/dev/null | sed 's/^/  /' || true
}

cmd_stop() {
  ensure_compose
  compose down
  log "Stopped (data volumes retained)"
}

cmd_status() {
  ensure_compose
  compose ps
  log "PG: ${PG_HOST}:${PG_PORT} (user=${PG_USER})  Redis: ${REDIS_HOST}:${REDIS_PORT}"
}

# ---------- create <component> <resource> [usage] ----------
# Generic provision: dispatches by component. PG creates a database; Redis is a no-op.
_create() {
  local component="$1" resource="$2" usage="${3:-}"
  case "$component" in
  postgres) cmd_createdb "$resource" "$usage" ;;
  redis) log "Redis: no resource creation needed (uses numeric DB indices)" ;;
  *) die "base: no 'create' handler for component '${component}'" ;;
  esac
}

# ---------- createdb <module> [usage] (PG-specific, called by _create) ----------
# Create a module's DB on the shared PG: <module> or <module>_<usage>.
cmd_createdb() {
  local module="$1" usage="${2:-}" dbname
  if [ -n "$usage" ]; then
    dbname="${module}_${usage}"
  else
    dbname="$module"
  fi
  ensure_compose
  # The stack must be UP for this: auto-start when down (idempotent, silent when
  # already running) instead of dying with "PG not running? aibox base start".
  ensure_stack_running
  # Wait for PG readiness (a fresh `base start` needs a few seconds; createdb right after
  # start used to fail on live hosts — observed on the Debian test machine, needed sleep 5).
  local _i=0
  while [ $_i -lt 30 ]; do
    docker exec "$POSTGRES_CONTAINER" pg_isready -U "$PG_USER" >/dev/null 2>&1 && break
    sleep 1
    _i=$((_i + 1))
  done
  # Idempotent: skip if it already exists.
  if docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='${dbname}'" 2>/dev/null | grep -q 1; then
    log "Database ${dbname} already exists (shared PG ${PG_HOST}:${PG_PORT})"
    return 0
  fi
  docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -c "CREATE DATABASE \"${dbname}\";" >/dev/null 2>&1 ||
    die "Creating database ${dbname} failed (PG not running? aibox base start)"
  log "Database ${dbname} ready (shared PG ${PG_HOST}:${PG_PORT})"
}

# ---------- Dashboard interface ----------
dashboard_info() {
  # app version: both components' image tags (multi-component module — the
  # keyline header omits it, the generic manager views render the row)
  local v="" pg_tag rd_tag
  pg_tag="$(docker inspect -f '{{.Config.Image}}' "${POSTGRES_CONTAINER}" 2>/dev/null | sed -n 's/.*://p' || true)"
  rd_tag="$(docker inspect -f '{{.Config.Image}}' "${REDIS_CONTAINER}" 2>/dev/null | sed -n 's/.*://p' || true)"
  [ -n "${pg_tag}" ] && [ -n "${rd_tag}" ] && v="postgres ${pg_tag} / redis ${rd_tag}"
  [ -n "${v}" ] && echo "version=${v}"
  echo "endpoint=pg://${PG_HOST}:${PG_PORT} (user=${PG_USER}) + redis://${REDIS_HOST}:${REDIS_PORT}"
  echo "credential=PG user/password ${PG_USER}/* (override via AIBOX_BASE_POSTGRES_PASSWORD; consuming modules see ${ENV_FILE})"
  # state= is the machine-readable contract (aibox dashboard renders the icon:
  # ok=✓ / starting=⚠ / stopped=○); local docker probes only (local-first holds).
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${POSTGRES_CONTAINER}"; then
    if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; then
      echo "state=ok"
      echo "health=ok (pg_isready: accepting connections)"
    else
      echo "state=starting"
      echo "health=starting (container up, PG not accepting yet)"
    fi
  else
    echo "state=stopped"
    echo "health=stopped (probe: docker exec ${POSTGRES_CONTAINER} pg_isready -U ${PG_USER})"
  fi
}

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  # keyline header: no single app version (multi-component: the rows carry the
  # per-component image tags); state from both containers
  local state=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local _pg _rd
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${POSTGRES_CONTAINER}" && _pg=1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${REDIS_CONTAINER}" && _rd=1
    if [ -n "${_pg}" ] && [ -n "${_rd}" ]; then
      state="ok"
    elif [ -n "${_pg}" ] || [ -n "${_rd}" ]; then
      state="starting"
    else
      state="stopped"
    fi
  fi
  dash_header "base" "" "${state}"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    dash_row "state" "docker daemon unreachable"
    dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/base/"
    return 0
  fi
  # PG
  local pg_up="" pg_ver="" dbs="" n=0
  docker ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | grep -q "${POSTGRES_CONTAINER}" && pg_up=1
  pg_ver="$(docker inspect -f '{{.Config.Image}}' "${POSTGRES_CONTAINER}" 2>/dev/null || echo postgres)"
  if [ -n "${pg_up}" ]; then
    local pg_status
    pg_status="$(docker ps --filter "name=${POSTGRES_CONTAINER}" --format '{{.Status}}' 2>/dev/null | head -1)"
    dash_row "postgres" "${pg_ver} ${C_DIM:-}·${C_RST:-} 127.0.0.1:${PG_PORT} ${C_DIM:-}·${C_RST:-} ${pg_status:-up}"
    # databases + sizes (the module's own + consumers')
    printf '  %s%-10s\n' "${C_DIM:-}" "databases:"
    while IFS='|' read -r db size; do
      [ -n "${db}" ] || continue
      printf '  %s%-10s %s (%s)\n' "${C_DIM:-}" "" "${db}" "${size}"
    done <<DASHDB
$(docker exec "${POSTGRES_CONTAINER}" psql -U "${PG_USER}" -tAc "SELECT datname || '|' || pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC" 2>/dev/null || true)
DASHDB
  else
    dash_row "postgres" "${C_YEL:-}not running (aibox base start)${C_RST:-}"
  fi
  # Redis
  local rd_up="" rd_ver="" rd_keys=""
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "${REDIS_CONTAINER}" && rd_up=1
  rd_ver="$(docker inspect -f '{{.Config.Image}}' "${REDIS_CONTAINER}" 2>/dev/null || echo redis)"
  if [ -n "${rd_up}" ]; then
    rd_keys="$(docker exec "${REDIS_CONTAINER}" redis-cli dbsize 2>/dev/null || echo '?')"
    dash_row "redis" "${rd_ver} ${C_DIM:-}·${C_RST:-} 127.0.0.1:${REDIS_PORT} ${C_DIM:-}·${C_RST:-} ${rd_keys} keys"
  else
    dash_row "redis" "${C_YEL:-}not running${C_RST:-}"
  fi
  # The profile-DERIVED values that docs must not hardcode: container names,
  # the env file consumers read (base-<profile>.env) and the deploy root.
  # `aibox dashboard base` is the authoritative view (AGENTS.md/docs convention).
  dash_row "containers" "${POSTGRES_CONTAINER} · ${REDIS_CONTAINER}"
  dash_row "env" "${ENV_FILE}"
  dash_row "network" "${AIBOX_BASE_NETWORK:-aibox-base}"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/base/"
}

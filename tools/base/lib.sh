# base module shared library (sourced by hooks, not executed directly)
# Shared PostgreSQL 18 + Redis 7: modules connect to the shared instance + use their own DB
# (<module> or <module>_<usage>).

CLI_NAME="base"

# ---------- output helpers ----------
# Colors are inherited from aibox via the exported C_* env vars (single source of truth);
# ${C_*:-} falls back to empty when this lib is sourced standalone.
# Prefix uses AIBOX_MODULE (injected by aibox) with the module name as a fallback.
log() { printf '%s[%s]%s %s\n' "${C_CYA:-}" "${AIBOX_MODULE:-base}" "${C_RST:-}" "${*}"; }
warn() { printf '%s[!]%s %s\n' "${C_YEL:-}" "${C_RST:-}" "${*}" >&2; }
ok()   { printf '%s[ok]%s %s\n' "${C_GRN:-}" "${C_RST:-}" "${*}"; }
die() {
  printf '%s[x]%s %s\n' "${C_RED:-}" "${C_RST:-}" "${*}" >&2
  exit 1
}

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
  docker compose -f "$COMPOSE_FILE" "$@"
}

# Image list from the (mode-aware) compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}

# ---------- docker.io download source pool (pull-via-mirror + tag) ----------
# Compose images are pulled by the docker DAEMON — whose egress differs from
# the host's (spec §Preflight: host-curl probes of docker.io are unreliable;
# probe through the daemon itself). DIRECT is tried first with a real
# daemon-routed probe (docker pull hello-world, bounded): healthy networks
# keep the zero-overhead default (compose pulls directly). Only when the
# direct route is dead does the pool engage: mirrors are RANKED by concurrent
# bounded hello-world pulls (measured through the daemon — the real channel),
# then uncached docker.io images are pre-pulled from the ranked order and
# `docker tag`-ed to their official names (mirrors proxy IDENTICAL digests —
# the windmill WM_HUB_MIRROR technique), so `compose up` finds them cached.
# Other registries (cr.weaviate.io …) stay direct-only — the mirrors proxy
# docker.io. Knobs: AIBOX_DOCKER_POOL (mirror list override; "direct" =
# disabled), AIBOX_DOCKER_MIRROR (user mirror, first), AIBOX_DOCKER_FORCE_POOL=1
# (skip the direct probe — always engage), AIBOX_DOCKER_PROBE_TIMEOUT (15),
# AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT (30), AIBOX_DOCKER_PULL_TIMEOUT (1800).
# Live-verified mirrors (Aliyun deploy host, real pulls): docker.1ms.run,
# docker.m.daocloud.io, dockerproxy.net, hub.rat.dev; docker.xuanyuan.me /
# dockerpull.org dead — excluded.
DOCKER_POOL_MIRRORS="docker.1ms.run docker.m.daocloud.io dockerproxy.net hub.rat.dev"

# Is this image ref served by docker.io? A ref WITH a slash has a
# host-or-namespace first segment — dots/colons there mean a foreign registry
# (cr.weaviate.io/…, localhost:5000/…). A ref WITHOUT a slash is name[:tag] on
# the DEFAULT registry (postgres:15-alpine) — its colon is the TAG separator,
# not a port (tag-stripping first would misread localhost:5000/foo's port).
_dk_is_dockerio() {
  case "${1}" in
  */*)
    case "${1%%/*}" in
    *.* | *:*) return 1 ;;
    *) return 0 ;;
    esac
    ;;
  *) return 0 ;;
  esac
}

# Mirror-prefixed ref (official images live under library/).
_dk_pool_ref() { # $1=mirror-host $2=image-ref
  case "${2}" in
  */*) printf '%s/%s' "${1}" "${2}" ;;
  *) printf '%s/library/%s' "${1}" "${2}" ;;
  esac
}

# Bounded docker command with a wall-clock watchdog (docker pull has no
# timeout of its own; a hung registry would hang the install forever).
# Returns docker's rc, or 124 on timeout. AIBOX_DOCKER_POLL (default 5s) is the
# watchdog's poll interval (tests tighten it); the deadline is date-based so
# the interval never distorts the timeout budget (the accumulated-counter form
# broke when the poll was tightened — measured: 0.2s polls fired 15s timeouts
# in ~0.6s).
_dk_bounded() { # $1=timeout_s, rest = docker args
  local t="${1}"; shift
  local logf pid deadline
  logf="$(mktemp "${TMPDIR:-/tmp}/dkpool.XXXXXX")" || return 1
  docker "$@" >"${logf}" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + t ))
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      kill "${pid}" 2>/dev/null || true
      pkill -P "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null
      rm -f "${logf}"
      return 124
    fi
    sleep "${AIBOX_DOCKER_POLL:-5}"
  done
  rc=0
  wait "${pid}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    tail -3 "${logf}" >&2 2>/dev/null || true
  fi
  rm -f "${logf}"
  return "${rc}"
}

# Pre-pull uncached docker.io images through the mirror pool. No-op (fast
# probe) when the daemon's direct route is healthy.
docker_pool_prepull() { # $@ = image refs
  case "${AIBOX_DOCKER_POOL:-}" in
  direct | none | off) return 0 ;;
  esac
  local img uncached="" m mirrors cands pid pids="" tmpd i t0 done1 rc_all=0 full
  # 1. filter: cached images + non-docker.io refs (mirrors don't proxy other
  #    registries — those stay direct)
  for img in "$@"; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    _dk_is_dockerio "${img}" || continue
    uncached="${uncached}${uncached:+ }${img}"
  done
  [ -n "${uncached}" ] || return 0
  # 2. direct daemon-route probe: healthy → compose pulls direct (zero overhead).
  #    hello-world is rmi'd first so the probe is honest (a cached probe proves
  #    nothing about the route).
  if [ "${AIBOX_DOCKER_FORCE_POOL:-0}" != "1" ]; then
    docker rmi hello-world >/dev/null 2>&1 || true
    if _dk_bounded "${AIBOX_DOCKER_PROBE_TIMEOUT:-15}" pull hello-world >/dev/null 2>&1; then
      log "docker: direct daemon route OK — compose will pull ${uncached} directly"
      return 0
    fi
  fi
  warn "docker: direct route unusable — engaging the mirror pool for: ${uncached}"
  # 3. rank mirrors by concurrent bounded hello-world pulls (real daemon channel)
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/dkrank.XXXXXX")" || return 0
  mirrors="${AIBOX_DOCKER_MIRROR:-}"
  mirrors="${mirrors}${mirrors:+ }${AIBOX_DOCKER_POOL:-${DOCKER_POOL_MIRRORS}}"
  i=0
  # shellcheck disable=SC2086
  for m in ${mirrors}; do
    i=$((i + 1))
    (
      t0=$(date +%s)
      if _dk_bounded "${AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT:-30}" pull "$(_dk_pool_ref "${m}" hello-world)" >/dev/null 2>&1; then
        printf '%s\t%s\n' "$(( $(date +%s) - t0 ))" "${m}" >"${tmpd}/r${i}.res"
      fi
    ) &
    pids="${pids} $!"
  done
  # shellcheck disable=SC2086
  for pid in ${pids}; do wait "${pid}" 2>/dev/null || true; done
  cands="$(cat "${tmpd}"/r*.res 2>/dev/null | sort -n | cut -f2 || true)"
  rm -rf "${tmpd}"
  if [ -z "${cands}" ]; then
    warn "docker: every mirror probe failed — compose will try direct"
    return 0
  fi
  log "docker mirror ranking: $(printf '%s' "${cands}" | tr '\n' ' ')"
  # 4. pre-pull the uncached images from the ranked order, per-source failover
  # shellcheck disable=SC2086
  for img in ${uncached}; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    done1=0
    # shellcheck disable=SC2086
    for m in ${cands}; do
      full="$(_dk_pool_ref "${m}" "${img}")"
      log "docker pull ${full} (mirror ${m}, watchdog ${AIBOX_DOCKER_PULL_TIMEOUT:-1800}s)"
      if _dk_bounded "${AIBOX_DOCKER_PULL_TIMEOUT:-1800}" pull "${full}"; then
        docker tag "${full}" "${img}" || { warn "docker tag failed: ${full} → ${img}"; continue; }
        docker rmi "${full}" >/dev/null 2>&1 || true
        ok "pulled ${img} via ${m}"
        done1=1
        break
      fi
      warn "docker: mirror ${m} failed for ${img} — trying the next"
    done
    if [ "${done1}" != "1" ]; then
      warn "docker: no mirror could pull ${img} — compose will try direct"
      rc_all=1
    fi
  done
  return "${rc_all}"
}


ensure_compose() {
  [ -f "$COMPOSE_FILE" ] || die "No compose file (first: aibox install base)"
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
  echo "endpoint=pg://${PG_HOST}:${PG_PORT} (user=${PG_USER}) + redis://${REDIS_HOST}:${REDIS_PORT}"
  echo "credential=PG user/password ${PG_USER}/* (override via AIBOX_BASE_POSTGRES_PASSWORD; consuming modules see ${ENV_FILE})"
  echo "health=docker exec ${POSTGRES_CONTAINER} pg_isready -U ${PG_USER}"
}

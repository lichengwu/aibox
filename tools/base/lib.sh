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

  # Derive base-specific vars (deterministic from hash + name). Container/env/net
  # names come from the SHARED helpers (tools/_shared/common.sh) — consumers
  # resolve the same paths there, so base and its consumers can never disagree
  # (a hardcoded `base.env` in a consumer was the P0 of the 2026-09 review).
  PG_PORT=$((35100 + _h % 332))
  REDIS_PORT=$((36100 + _h % 279))
  POSTGRES_CONTAINER="$(base_pg_container)"
  REDIS_CONTAINER="$(base_redis_container)"
  ENV_FILE="$(base_env_file)"

  # Export for compose ${VAR:-default} expansion.
  export AIBOX_BASE_PG_CONTAINER="$POSTGRES_CONTAINER"
  export AIBOX_BASE_REDIS_CONTAINER="$REDIS_CONTAINER"
  export AIBOX_BASE_POSTGRES_PORT="$PG_PORT"
  export AIBOX_BASE_REDIS_PORT="$REDIS_PORT"
  export AIBOX_BASE_PG_VOLUME="aibox_pg_data_${_n}"
  export AIBOX_BASE_REDIS_VOLUME="aibox_redis_data_${_n}"
  export AIBOX_BASE_NETWORK="aibox-base${_PROFILE_SUFFIX}"

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

# docker compose wrapper: the project directory is the deploy root (so the
# project name is deterministic regardless of the caller's CWD) and the image
# pins come from the deploy root's .env, which `aibox base upgrade` rewrites —
# that file is what makes base's component versions floatable/rollback-able
# (they used to be literals in the generated compose, overwritten by any update).
compose() {
  require_docker
  local root; root="$(base_deploy_root)"
  if [ -f "${root}/.env" ]; then
    docker compose --project-directory "${root}" -f "${COMPOSE_FILE}" --env-file "${root}/.env" "$@"
  else
    docker compose --project-directory "${root}" -f "${COMPOSE_FILE}" "$@"
  fi
}

# The deploy-root pin file (image versions + operator knobs read by the compose).
pin_file() { printf '%s/.env' "$(base_deploy_root)"; }

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

# ---------- secrets (PG + Redis passwords) ----------
# Resolution order (existing deployments MUST keep working): explicit env/config
# value → the password already present in the contract env file → the persisted
# secret file → a freshly generated one (fresh install). NEVER rotate silently:
# consumers read the value from base.env, so a change needs a base restart and a
# consumer restart — the start path says so when it generates a new one.
_random_secret() {
  local s=""
  s="$(openssl rand -hex 16 2>/dev/null || true)"
  [ -n "${s}" ] || s="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  [ -n "${s}" ] || s="aibox$(date +%s)$$"
  printf '%s' "${s}"
}

_secret_file() { printf '%s/.base-secret' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"; }

_secret_resolve() { # $1=override var name $2=contract env key $3=secret-file key
  local var="$1" env_key="$2" skey="$3" cur="" f
  eval "cur=\"\${${var}:-}\""
  if [ -n "${cur}" ]; then printf '%s' "${cur}"; return 0; fi
  if [ -f "${ENV_FILE}" ]; then
    cur="$(grep -E "^${env_key}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; return 0; fi
  fi
  f="$(_secret_file)"
  if [ -f "${f}" ]; then
    cur="$(sed -n "s/^${skey}=//p" "${f}" 2>/dev/null | head -1 || true)"
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; return 0; fi
  fi
  cur="$(_random_secret)"
  (umask 077; printf '%s=%s\n' "${skey}" "${cur}" >>"${f}") 2>/dev/null || true
  printf '%s' "${cur}"
}

# Resolve both secrets + export them for compose ${VAR} interpolation.
resolve_secrets() {
  local had_redis_pw=0
  grep -qE '^AIBOX_REDIS_PASSWORD=' "${ENV_FILE}" 2>/dev/null && had_redis_pw=1
  PG_PASSWORD="$(_secret_resolve AIBOX_BASE_POSTGRES_PASSWORD AIBOX_BASE_POSTGRES_PASSWORD PG_PASSWORD)"
  REDIS_PASSWORD="$(_secret_resolve AIBOX_BASE_REDIS_PASSWORD AIBOX_REDIS_PASSWORD REDIS_PASSWORD)"
  export AIBOX_BASE_POSTGRES_PASSWORD="${PG_PASSWORD}"
  export AIBOX_BASE_REDIS_PASSWORD="${REDIS_PASSWORD}"
  # First run after the Redis-auth change: consumers still connect without a
  # password until they are restarted — say it once, loudly enough to act on.
  if [ "${had_redis_pw}" = "0" ] && [ -f "${ENV_FILE}" ]; then
    warn "Redis auth is enabled from now on (new password in ${ENV_FILE})"
    warn "  restart consumers so they pick it up: aibox <module> restart (e.g. new-api, xiaozhi, dify)"
  fi
  return 0
}

# ---------- lifecycle ----------
# Writes $ENV_FILE — consuming modules inject it via compose --env-file (single source).
# CONTRACT (docs/module-spec.md §Dependency contract): consumers validate
# AIBOX_BASE_ENV_VERSION; keys are ADDITIVE only — a rename/removal bumps the
# version and consumers then fail with an actionable hint instead of reading
# empty values into a compose file.
write_base_env() {
  mkdir -p "$(dirname "$ENV_FILE")"
  (
    umask 077
    cat >"$ENV_FILE" <<EOF
# Generated by "aibox base start" — do not edit by hand; re-run "base restart" after changing base.
# CONTRACT: consumers check AIBOX_BASE_ENV_VERSION (tools/_shared/common.sh base_env_check).
AIBOX_BASE_ENV_VERSION=${BASE_ENV_VERSION_SUPPORTED}
AIBOX_BASE_PROFILE=${PROFILE_NAME:-${AIBOX_PROFILE:-base}}
AIBOX_BASE_MODULE_VERSION=${MODULE_VERSION:-unknown}
AIBOX_BASE_READY=1
AIBOX_POSTGRES_HOST=${POSTGRES_CONTAINER}
AIBOX_POSTGRES_PORT=5432
AIBOX_POSTGRES_USER=${PG_USER}
AIBOX_POSTGRES_PASSWORD=${PG_PASSWORD}
AIBOX_REDIS_HOST=${REDIS_CONTAINER}
AIBOX_REDIS_PORT=6379
AIBOX_REDIS_PASSWORD=${REDIS_PASSWORD}
AIBOX_BASE_NETWORK=${AIBOX_BASE_NETWORK:-aibox-base}
EOF
  )
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  log "Wrote ${ENV_FILE} (consumed by modules via compose --env-file; mode 600 — it holds secrets)"
}

# Wait until PG accepts connections and Redis answers (bounded). base used to
# return right after `compose up -d`, so a consumer starting immediately could
# hit an initializing instance (live-caught as "Creating database X failed (PG
# not running?)" in the multi-profile integration suite).
wait_ready() {
  require_docker
  local timeout_s="${AIBOX_BASE_READY_TIMEOUT:-90}" waited=0
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1 \
       && docker exec "${REDIS_CONTAINER}" redis-cli -a "${REDIS_PASSWORD}" PING >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  return 1
}

# Keep the DB role's password in sync with the contract file (a pin change or a
# restored dump can leave them different; the local socket is trusted inside the
# container, so no old password is needed).
sync_pg_password() {
  docker exec "${POSTGRES_CONTAINER}" psql -U "${PG_USER}" -d postgres \
    -c "ALTER USER \"${PG_USER}\" WITH PASSWORD '${PG_PASSWORD}'" >/dev/null 2>&1 || return 1
  return 0
}

cmd_start() {
  ensure_compose
  resolve_secrets
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
  if ! wait_ready; then
    write_base_env   # still write it: the operator needs the connection info to debug
    die "PG/Redis did not become ready — check: aibox base logs (timeout ${AIBOX_BASE_READY_TIMEOUT:-90}s)"
  fi
  sync_pg_password || warn "could not sync the PG role password (non-fatal; 'aibox base config set AIBOX_BASE_POSTGRES_PASSWORD ...' then restart)"
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

# ---------- dump / restore (the shared-data safety net) ----------
# base owns the shared data, so it owns the backup verb: pg_dumpall (every DB,
# consumers' included) + a Redis snapshot. A consumer's app upgrade snapshots its
# own database only; this is the whole-instance point-in-time copy for base
# upgrades, host migrations and "oops" recovery.
dump_dir() { printf '%s/backups/base%s' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}" "${_PROFILE_SUFFIX:-}"; }

_dump_to_file() { # $1=label → prints the dump path ("" on failure)
  local label="${1:-manual}" ts dir out rdb
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(dump_dir)"
  mkdir -p "${dir}" 2>/dev/null || return 0
  out="${dir}/cluster-${ts}-${label}.sql.gz"
  if docker exec "${POSTGRES_CONTAINER}" pg_dumpall -U "${PG_USER}" 2>/dev/null | gzip -c >"${out}" && [ -s "${out}" ]; then
    rdb="${dir}/redis-${ts}-${label}.rdb"
    if docker exec "${REDIS_CONTAINER}" redis-cli -a "${REDIS_PASSWORD}" SAVE >/dev/null 2>&1; then
      docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "${rdb}" >/dev/null 2>&1 || rm -f "${rdb}" 2>/dev/null || true
    fi
    printf '%s' "${out}"
    return 0
  fi
  rm -f "${out}" 2>/dev/null || true
  return 0
}

cmd_dump() { # [$1=label]
  ensure_compose
  resolve_secrets
  ensure_stack_running
  local out
  log "Dumping the whole PG cluster (all databases, consumers' included) …"
  out="$(_dump_to_file "${1:-manual}")"
  [ -n "${out}" ] || die "dump failed (PG up? aibox base status)"
  ok "dump ready: ${out}"
  log "  restore: aibox base restore ${out}"
}

cmd_restore() { # [$1=file] (default: newest dump)
  ensure_compose
  resolve_secrets
  local f="${1:-}" newest
  if [ -z "${f}" ]; then
    newest="$(ls -1t "$(dump_dir)"/cluster-*.sql.gz 2>/dev/null | head -1 || true)"
    [ -n "${newest}" ] || die "no dump found in $(dump_dir) — create one: aibox base dump"
    f="${newest}"
  fi
  [ -f "${f}" ] || die "no such dump: ${f}"
  warn "restoring ${f} REPLACES the current shared data (every database)"
  ensure_stack_running
  gunzip -c "${f}" | docker exec -i "${POSTGRES_CONTAINER}" psql -U "${PG_USER}" -d postgres >/dev/null 2>&1 \
    || die "restore failed — the instance may be half-restored; inspect: aibox base logs"
  ok "restored ${f}"
  log "  consumers may need a restart to re-establish connections: aibox <module> restart"
}

# ---------- upgrade (infra image pins) ----------
# base's component versions are pins in the deploy-root .env (the compose reads
# ${AIBOX_BASE_PG_IMAGE:-postgres:18}); this verb floats them with the same safety
# shape as the manager's app upgrades: dump first → rewrite the pin → recreate →
# verify → roll back the pin on failure. The state goes to the SAME file the
# manager uses ($AIBOX_HOME/upgrades/base.state), so `aibox dashboard base` shows
# it and `aibox upgrade base --rollback` restores the same pin file.
_pin_get() { # $1=KEY $2=file → value ("" when absent)
  [ -f "$2" ] || return 0
  sed -n "s/^$1=//p" "$2" | head -1
}

_pin_set() { # $1=KEY $2=value $3=file
  local k="$1" v="$2" f="$3" tmp
  tmp="${f}.tmp.$$"
  if [ -f "${f}" ]; then grep -vE "^${k}=" "${f}" >"${tmp}" 2>/dev/null || true; else : >"${tmp}"; fi
  printf '%s=%s\n' "${k}" "${v}" >>"${tmp}"
  mv "${tmp}" "${f}"
}

_pin_default_from_compose() { # $1=KEY → the compose's ${KEY:-floor} default
  local f="${COMPOSE_FILE}"
  [ -f "${f}" ] || f="${LIB_SELF}/docker-compose.yml"   # --check before the deploy root exists
  sed -n "s/.*\${$1:-\([^}]*\)}.*/\1/p" "${f}" 2>/dev/null | head -1
}

_upgrade_state_dir() { printf '%s/upgrades' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"; }

_state_set() { # $1=key $2=value (merge; same shape as the manager's upgrade state)
  local f tmp
  f="$(_upgrade_state_dir)/base.state"
  mkdir -p "$(_upgrade_state_dir)" 2>/dev/null || true
  tmp="${f}.tmp.$$"
  : >"${tmp}"
  if [ -f "${f}" ]; then grep -vE "^$1=" "${f}" >"${tmp}" 2>/dev/null || true; fi
  printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >>"${tmp}"
  mv "${tmp}" "${f}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
}

_state_get() { # $1=key
  local f; f="$(_upgrade_state_dir)/base.state"
  [ -f "${f}" ] || return 0
  sed -n "s/^$1=//p" "${f}" | head -1
}

_state_log() { # $1=line
  local f; f="$(_upgrade_state_dir)/base.log"
  mkdir -p "$(_upgrade_state_dir)" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"${f}" 2>/dev/null || true
}

cmd_upgrade() {
  local check=0 to_pg="" to_redis="" do_rollback=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)    check=1; shift ;;
      --pg)       to_pg="${2:-}";    [ -n "${to_pg}" ]    || usage_die "base upgrade --pg needs an image tag (e.g. postgres:19)"; shift 2 ;;
      --redis)    to_redis="${2:-}"; [ -n "${to_redis}" ] || usage_die "base upgrade --redis needs an image tag (e.g. redis:8)"; shift 2 ;;
      --rollback) do_rollback=1; shift ;;
      --yes|-y)   shift ;;   # accepted for symmetry; base's gates are non-interactive
      -h|--help)  usage_die "usage: aibox base upgrade [--check | --pg <tag> | --redis <tag> | --rollback]" ;;
      *)          usage_die "unknown option for base upgrade: $1" ;;
    esac
  done
  ensure_compose
  resolve_secrets
  local pin cur_pg cur_redis rb
  pin="$(pin_file)"
  cur_pg="$(_pin_get AIBOX_BASE_PG_IMAGE "${pin}")"
  [ -n "${cur_pg}" ] || cur_pg="$(_pin_default_from_compose AIBOX_BASE_PG_IMAGE)"
  cur_redis="$(_pin_get AIBOX_BASE_REDIS_IMAGE "${pin}")"
  [ -n "${cur_redis}" ] || cur_redis="$(_pin_default_from_compose AIBOX_BASE_REDIS_IMAGE)"

  if [ "${do_rollback}" = "1" ]; then
    local from bak
    from="$(_state_get from)"; bak="$(_state_get envbak)"
    [ -n "${from}" ] || die "no rollback point recorded — pin explicitly: aibox base upgrade --pg <tag>"
    [ -n "${bak}" ] && [ -f "${bak}" ] || die "the recorded pin backup is gone (${bak})"
    cp "${bak}" "${pin}"
    _state_log "pins rolled back to ${from} (by user)"
    if cmd_start; then
      _state_set status rolled-back
      ok "rolled back to ${from} — healthy"
      return 0
    fi
    _state_set status manual
    warn "rollback applied but the stack is not healthy — inspect: aibox base logs"
    return 20
  fi

  if [ "${check}" = "1" ]; then
    log "postgres : ${cur_pg}${to_pg:+ → ${to_pg}}"
    log "redis    : ${cur_redis}${to_redis:+ → ${to_redis}}"
    rb="$(_state_get from)"
    [ -n "${rb}" ] && log "rollback : ${rb} (recorded)   apply: aibox upgrade base --rollback"
    warn "PG MAJOR upgrades are one-way and can make the existing volume unreadable — a full dump"
    warn "  is taken automatically before any switch (standalone: aibox base dump)"
    log "note     : the pins live in $(pin_file); module updates never overwrite that file"
    return 0
  fi

  [ -n "${to_pg}${to_redis}" ] || usage_die "usage: aibox base upgrade [--check | --pg <tag> | --redis <tag> | --rollback]"

  local ts bak dump from_desc to_desc
  ts="$(date +%Y%m%d%H%M%S)"
  bak="${pin}.bak.${ts}.$$"
  mkdir -p "$(dirname "${pin}")"
  [ -f "${pin}" ] || printf '# base image pins — written by `aibox base upgrade`; the compose reads ${AIBOX_BASE_*_IMAGE} from here\n' >"${pin}"
  cp "${pin}" "${bak}"
  from_desc="pg=${cur_pg} redis=${cur_redis}"
  to_desc="pg=${to_pg:-$cur_pg} redis=${to_redis:-$cur_redis}"
  log "1/4 dump before the switch (${from_desc} → ${to_desc}) …"
  dump=""
  if stack_running; then
    dump="$(_dump_to_file preupgrade)"
    if [ -n "${dump}" ]; then ok "   dump: ${dump}"; else warn "   dump failed — continuing (a rollback would be pin-only)"; fi
  else
    log "   stack is down — no dump needed (an image switch does not touch the volumes)"
  fi
  log "2/4 pinning …"
  [ -n "${to_pg}" ]    && _pin_set AIBOX_BASE_PG_IMAGE "${to_pg}" "${pin}"
  [ -n "${to_redis}" ] && _pin_set AIBOX_BASE_REDIS_IMAGE "${to_redis}" "${pin}"
  _state_set ts "${ts}"; _state_set from "${from_desc}"; _state_set to "${to_desc}"
  _state_set envbak "${bak}"; _state_set databak "${dump}"; _state_set status started
  _state_log "${from_desc} → ${to_desc} started${dump:+ (dump ${dump})}"
  log "3/4 recreating with the new images (health gate) …"
  if cmd_start; then
    _state_set status ok
    _state_log "${from_desc} → ${to_desc} ok"
    ok "base upgraded (${to_desc})"
    [ -n "${dump}" ] && log "  data dump kept: ${dump}"
    log "  rollback point: aibox upgrade base --rollback"
    return 0
  fi
  warn "4/4 the new images did not come up — rolling the pins back"
  cp "${bak}" "${pin}"
  if cmd_start; then
    _state_set status rolled-back
    _state_log "${from_desc} → ${to_desc} rolled-back"
    warn "rolled back to ${from_desc} (healthy) — inspect: aibox base logs"
    return 10
  fi
  _state_set status manual
  _state_log "${from_desc} → ${to_desc} rollback-failed"
  warn "manual intervention needed — the rollback did not come up either"
  log "  inspect : aibox base logs"
  log "  pins    : ${pin} (backup: ${bak})"
  [ -n "${dump}" ] && log "  data    : gunzip -c ${dump} | docker exec -i ${POSTGRES_CONTAINER} psql -U ${PG_USER} -d postgres"
  return 20
}

# ---------- redis logical DB allocation ----------
# One slot (or a reserved range, e.g. dify uses 3 indices for its DB/celery/agent
# roles) per consumer module: with auth in place a shared index is no longer
# merely "key-prefix discipline". Registry: apps/base/redis-dbs.conf
# (`module=index:slots`); the consumer reads AIBOX_REDIS_DB from its own redis env
# file (see redis_env_file in tools/_shared/common.sh).
redis_db_registry() { printf '%s/redis-dbs.conf' "$(base_deploy_root)"; }

base_redis_db_for() { # $1=module [$2=slots] → prints the allocated base index (idempotent)
  local m="$1" slots="${2:-1}" f line idx used="" tok tok_idx tok_slots i free
  [ -n "${m}" ] || return 0
  case "${slots}" in '' | *[!0-9]*) slots=1 ;; esac
  [ "${slots}" -ge 1 ] || slots=1
  f="$(redis_db_registry)"
  if [ -f "${f}" ]; then
    line="$(grep -E "^${m}=" "${f}" 2>/dev/null | head -1 || true)"
    if [ -n "${line}" ]; then printf '%s' "${line#*=}" | cut -d: -f1; return 0; fi
    # every index already reserved by someone else (ranges included)
    for tok in $(cut -d= -f2- "${f}" 2>/dev/null); do
      tok_idx="${tok%%:*}"; tok_slots="${tok#*:}"; [ "${tok_slots}" = "${tok}" ] && tok_slots=1
      case "${tok_idx}" in '' | *[!0-9]*) continue ;; esac
      i=0
      while [ "${i}" -lt "${tok_slots}" ]; do
        used="${used}${used:+ }$(( tok_idx + i ))"
        i=$(( i + 1 ))
      done
    done
  fi
  idx=1
  while :; do
    free=1
    for tok in ${used}; do [ "${tok}" = "${idx}" ] && free=0; done
    [ "${free}" = "1" ] && break
    idx=$(( idx + 1 ))
  done
  mkdir -p "$(dirname "${f}")" 2>/dev/null || true
  printf '%s=%s:%s\n' "${m}" "${idx}" "${slots}" >>"${f}" 2>/dev/null || true
  printf '%s' "${idx}"
}

# ---------- create <component> <resource> [usage] ----------
# Generic provision: PG creates a database; Redis allocates the module's logical DB.
_create() {
  local component="$1" resource="$2" usage="${3:-}"
  case "$component" in
  postgres) cmd_createdb "$resource" "$usage" ;;
  redis)
    # Allocate (or return) this module's Redis logical DB and write its env file,
    # so consumers stop sharing index 0 by default.
    local m="${resource:-}" slots="${usage:-1}"
    [ -n "${m}" ] || usage_die "usage: aibox base create redis <module> [slots]"
    local idx rf
    idx="$(base_redis_db_for "${m}" "${slots}")"
    rf="$(redis_env_file "${m}")"
    mkdir -p "$(dirname "${rf}")" 2>/dev/null || true
    (umask 077; printf 'AIBOX_REDIS_DB=%s\nAIBOX_REDIS_SLOTS=%s\n' "${idx}" "${slots}" >"${rf}") 2>/dev/null || true
    log "Redis logical DB for ${m}: ${idx}${slots:+ (${slots} slot(s))} (written to ${rf})"
    ;;
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

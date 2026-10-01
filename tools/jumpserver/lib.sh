# jumpserver module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/jumpserver.

MODULE_NAME="jumpserver"
COMPOSE_PROJECT="jumpserver"
CORE_CONTAINER="aibox-jumpserver-core"
CELERY_CONTAINER="aibox-jumpserver-celery"
WEB_CONTAINER="aibox-jumpserver-web"
KOKO_CONTAINER="aibox-jumpserver-koko"
LION_CONTAINER="aibox-jumpserver-lion"
CHEN_CONTAINER="aibox-jumpserver-chen"
ALL_CONTAINERS="${CORE_CONTAINER} ${CELERY_CONTAINER} ${WEB_CONTAINER} ${KOKO_CONTAINER} ${LION_CONTAINER} ${CHEN_CONTAINER}"
DEFAULT_WEB_PORT="31200"
DEFAULT_SSH_PORT="31202"
DEFAULT_CORE_IMAGE="jumpserver/core:v4.10.19-ce"
DEFAULT_WEB_IMAGE="jumpserver/web:v4.10.19-ce"
DEFAULT_KOKO_IMAGE="jumpserver/koko:v4.10.19-ce"
DEFAULT_LION_IMAGE="jumpserver/lion:v4.10.19-ce"
DEFAULT_CHEN_IMAGE="jumpserver/chen:v4.10.19-ce"
# JumpServer Redis logical-DB usage (upstream conf.py defaults 3/4/5/6 —
# celery broker / django cache / django session / channels-ws). The shared base
# allocates this module a 4-wide slot range; svc start remaps the four onto it.
JUMPSERVER_REDIS_SLOTS="4"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"
# a hook; direct execution (bats, a hook run by hand) uses the ONE shared reader.
MODULE_VERSION="${AIBOX_MODULE_VERSION:-$(meta_version "${LIB_SELF}/module.yaml")}"

# Deploy root per the aibox convention ($AIBOX_HOME/apps/<name>; module-spec
# §Deploy directory). The guard is mandatory: systemd service contexts may
# lack HOME, and path derivation must fail loudly rather than produce "/apps/...".
deploy_root() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "$root" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  # profile-scoped (spec §Deploy root): two profiles must never share one deploy
  # .env/compose. The default profile keeps the unsuffixed path (no migration).
  printf '%s' "${root}/apps/${MODULE_NAME}$(profile_suffix)"
}

# Load the deploy .env into the environment so hooks/svc see JUMPSERVER_*_PORT /
# image pins / generated secrets. NOTE: parse with docker env_file semantics
# (split at the FIRST '=', the whole rest of line is the value) — NOT bash
# sourcing. Values may contain spaces, glob chars, braces; `source`ing breaks.
load_env() {
  local envf line k
  envf="$(deploy_root)/.env"
  [ -f "${envf}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
    '' | '#'*) continue ;;
    *=*) ;;
    *) continue ;;
    esac
    k="${line%%=*}"
    case "${k}" in
    '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    export "${k}=${line#*=}"
  done <"${envf}"
}

# compose wrapper: always runs in the deploy root. core/celery consume the
# SHARED base PG+Redis: connection info is injected from base.env via
# --env-file (written by `aibox base start`). The deploy .env is loaded into
# the SHELL environment by load_env() — compose interpolation precedence:
# shell env > --env-file, so user overrides win.
compose() {
  local root base_env args renv
  root="$(deploy_root)"
  [ -f "${root}/docker-compose.yml" ] || die "not installed (run: aibox install ${MODULE_NAME})"
  # profile-aware (base_env_file): a hardcoded base.env attached consumers to the
  # DEFAULT profile's instance when base ran under a named profile
  base_env="$(base_env_file)"
  args=(--project-name "${COMPOSE_PROJECT}" -f "${root}/docker-compose.yml")
  if [ -f "${base_env}" ]; then
    args+=(--env-file "${base_env}")
    # this module's own Redis logical-DB range (allocated by `aibox base create
    # redis jumpserver 4`)
    renv="$(redis_env_file "${MODULE_NAME}")"
    [ -f "${renv}" ] && args+=(--env-file "${renv}")
  else
    warn "base.env missing (${base_env}) — run: aibox base start"
  fi
  require_docker
  (cd "${root}" && docker compose "${args[@]}" "$@")
}

# Image list from the compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}

# Map JumpServer's four Redis logical DBs (celery/cache/session/ws) onto this
# module's 4-wide shared-base slot range. The slot index lives in the module's
# redis env file (written by `aibox base create redis jumpserver 4`; passed to
# compose via --env-file — which does NOT put it in the SHELL environment, so
# read the file here too). The exports feed compose interpolation (shell env >
# --env-file). Without an allocation the upstream defaults (3/4/5/6) apply.
_redis_db_remap() {
  local base f line
  base="${AIBOX_REDIS_DB:-}"
  if [ -z "${base}" ]; then
    f="$(redis_env_file "${MODULE_NAME}")"
    if [ -f "${f}" ]; then
      while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
        AIBOX_REDIS_DB=*) base="${line#*=}" ;;
        esac
      done <"${f}"
    fi
  fi
  case "${base}" in
  '' | *[!0-9]*) return 0 ;;
  esac
  export JUMPSERVER_REDIS_DB_CELERY="${base}"
  export JUMPSERVER_REDIS_DB_CACHE="$((base + 1))"
  export JUMPSERVER_REDIS_DB_SESSION="$((base + 2))"
  export JUMPSERVER_REDIS_DB_WS="$((base + 3))"
}

# ---------- health ----------
# Is a named container running? (docker ps + fixed names — the compose
# hardcodes container_name, same pattern as the gitlab/xiaozhi modules.)
container_running() { # $1 = container name
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}
core_running() { container_running "${CORE_CONTAINER}"; }
web_running() { container_running "${WEB_CONTAINER}"; }
stack_running() {
  local n
  n="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE "^aibox-jumpserver-(core|celery|web|koko|lion|chen)$" || true)"
  [ "${n}" -gt 0 ]
}

# The web console answers HTTP (nginx → the SPA index). Any 2xx/3xx = web up.
web_up() {
  local port code
  port="${1:-$(effective_web_port)}"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)"
  [ -z "${code}" ] && code="000"
  case "${code}" in
  2?? | 3??) return 0 ;;
  *) return 1 ;;
  esac
}

# The full chain (nginx → core api): /api/health/ is core's own healthcheck
# path (upstream core.yml), proxied by the web nginx. 200 = core is serving.
api_health_up() {
  local port code
  port="${1:-$(effective_web_port)}"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/api/health/" 2>/dev/null || true)"
  [ -z "${code}" ] && code="000"
  [ "${code}" = "200" ]
}

# core's docker healthcheck verdict (healthy = migrations done + api serving;
# upstream's own check, start_period 90s, first boot takes minutes).
core_healthy() {
  local st
  st="$(docker inspect -f '{{.State.Health.Status}}' "${CORE_CONTAINER}" 2>/dev/null || true)"
  [ "${st}" = "healthy" ]
}

# Effective ports (deploy .env overrides the module defaults).
effective_web_port() { printf '%s' "${JUMPSERVER_WEB_PORT:-${DEFAULT_WEB_PORT}}"; }
effective_ssh_port() { printf '%s' "${JUMPSERVER_SSH_PORT:-${DEFAULT_SSH_PORT}}"; }

# ---------- status ----------
# Deployed app version: the core image's tag (all five images move together —
# one version scheme; see module.yaml upgrade:).
app_version() {
  local img ver
  load_env
  img="$(docker inspect -f '{{.Config.Image}}' "${CORE_CONTAINER}" 2>/dev/null || true)"
  [ -n "${img}" ] || img="${JUMPSERVER_CORE_IMAGE:-${DEFAULT_CORE_IMAGE}}"
  ver="${img##*:}"
  printf '%s' "${ver}"
}

# Status interface (called by `aibox status jumpserver`).
status_info() {
  local wport v
  load_env
  wport="$(effective_web_port)"
  v="$(app_version)"
  [ -n "${v}" ] && echo "version=${v}"
  echo "endpoint=http://127.0.0.1:${wport}"
  echo "credential=admin / ChangeMe (change at first login; console 系统设置)"
  echo "ssh=ssh -p $(effective_ssh_port) admin@<host> (terminal access)"
  echo "db=shared base PG (jumpserver) + shared base redis (4 logical DBs)"
  if stack_running 2>/dev/null; then
    if core_healthy && api_health_up "${wport}"; then
      echo "state=ok"
      echo "health=ok (core healthy, api answers on :${wport})"
    elif web_up "${wport}"; then
      echo "state=starting"
      echo "health=starting (web up; core booting — first boot runs migrations, 2-6 min)"
    else
      echo "state=starting"
      echo "health=starting (containers up; not answering yet — aibox ${MODULE_NAME} logs)"
    fi
  else
    echo "state=stopped"
    echo "health=stopped"
  fi
}

# The module's rich view (aibox jumpserver status) — keyline via the shared
# helpers (_common.sh ships them; spec §Status template).
render_status() {
  load_env
  _redis_db_remap   # fills JUMPSERVER_REDIS_DB_* from the allocated slot for the db row
  local wport state svc st n_running n_total
  wport="$(effective_web_port)"
  if stack_running 2>/dev/null; then
    if core_healthy && api_health_up "${wport}"; then
      state="ok"
    else
      state="starting"
    fi
  else
    state="stopped"
  fi
  status_header "jumpserver" "$(app_version)" "${state}"
  # per-service container state (docker ps; avoids compose round-trips)
  n_running=0
  n_total=0
  for svc in core celery web koko lion chen; do
    n_total=$((n_total + 1))
    st="$(docker ps --filter "name=aibox-jumpserver-${svc}$" --format '{{.Status}}' 2>/dev/null | head -1 || true)"
    if [ -n "${st}" ]; then
      n_running=$((n_running + 1))
      status_row "${svc}" "${st}"
    else
      status_row "${svc}" "${C_DIM:-}—${C_RST:-}"
    fi
  done
  # endpoint row (state-annotated per spec: stopped appends the start hint)
  if [ "${state}" = "ok" ]; then
    status_row "endpoint" "http://127.0.0.1:${wport} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓${C_RST:-} api health"
  elif [ "${state}" = "starting" ]; then
    status_row "endpoint" "http://127.0.0.1:${wport} ${C_DIM:-}·${C_RST:-} booting (${n_running}/${n_total} containers)"
  else
    status_row "endpoint" "http://127.0.0.1:${wport} ${C_DIM:-}(stopped — aibox ${MODULE_NAME} start)${C_RST:-}"
  fi
  status_row "ssh" "ssh -p $(effective_ssh_port) admin@<host>"
  status_row "db" "shared base PG (jumpserver) ${C_DIM:-}·${C_RST:-} redis DBs ${JUMPSERVER_REDIS_DB_CELERY:-3..6}"
  status_row "secrets" "${C_DIM:-}SECRET_KEY + BOOTSTRAP_TOKEN in apps/${MODULE_NAME}/.env (mode 600)${C_RST:-}"
  status_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/jumpserver/"
}

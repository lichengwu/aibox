# dify module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/dify.

MODULE_NAME="dify"
COMPOSE_PROJECT="dify"
CONTAINER_NGINX="dify-nginx-1"
DEFAULT_PORT="8088"
DEFAULT_NGINX_INTERNAL_PORT="80"
DEFAULT_API_IMAGE="langgenius/dify-api:1.17.1"
DEFAULT_WEB_IMAGE="langgenius/dify-web:1.17.1"
DEFAULT_SANDBOX_IMAGE="langgenius/dify-sandbox:0.2.15"
DEFAULT_PLUGIN_DAEMON_IMAGE="langgenius/dify-plugin-daemon:0.6.10-local"
DEFAULT_AGENT_BACKEND_IMAGE="langgenius/dify-agent-backend:1.17.1"
DEFAULT_DB_IMAGE="postgres:15-alpine"
DEFAULT_REDIS_IMAGE="redis:6-alpine"
DEFAULT_WEAVIATE_IMAGE="cr.weaviate.io/semitechnologies/weaviate:1.39.2"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"

# Deploy root per the aibox convention ($AIBOX_HOME/apps/<name>; module-spec
# §Deploy directory). The guard is mandatory: systemd service contexts may
# lack HOME, and path derivation must fail loudly rather than produce "/apps/...".
deploy_root() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "${root}" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  printf '%s' "${root}/apps/${MODULE_NAME}"
}

# Load the deploy .env into the environment so hooks/svc see DIFY_WEB_PORT /
# DIFY_SHARED_BASE / image tags, etc.
# NOTE: parse with docker env_file semantics (split at the FIRST '=', the whole
# rest of line is the value) — NOT bash sourcing. Values may contain spaces
# (upstream ports LOG_DATEFORMAT="%Y-%m-%d %H:%M:%S"), glob chars, braces;
# `source`ing those breaks bash (measured live: "fg: no job control").
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
  done < "${envf}"
}

# Whether shared-base mode is enabled (DIFY_SHARED_BASE=1 in the deploy .env).
# When on, compose is invoked with the shared override + base.env.
shared_base_enabled() {
  [ "${DIFY_SHARED_BASE:-0}" = "1" ]
}

# compose wrapper: always runs in the deploy root. In shared-base mode it adds
# the shared override file + --env-file base.env (the base module's connection
# info; injected values like AIBOX_POSTGRES_HOST are referenced by the override).
compose() {
  local root base_env args
  root="$(deploy_root)"
  [ -f "${root}/docker-compose.yml" ] || die "not installed (run: aibox install ${MODULE_NAME})"
  args=(--project-name "${COMPOSE_PROJECT}" -f "${root}/docker-compose.yml")
  if shared_base_enabled; then
    [ -f "${root}/docker-compose.shared.yml" ] || die "DIFY_SHARED_BASE=1 but docker-compose.shared.yml missing"
    args+=(-f "${root}/docker-compose.shared.yml")
    base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
    if [ -f "${base_env}" ]; then
      args+=(--env-file "${base_env}")
    else
      warn "DIFY_SHARED_BASE=1 but ${base_env} not found (run: aibox base start)"
    fi
  fi
  (cd "${root}" && docker compose "${args[@]}" "$@")
}

# Image list from the (mode-aware) compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}


# The stack is up when the API answers THROUGH nginx (GET /console/api/setup →
# 2xx/3xx). Probing `/` (the web frontend) is NOT enough — the frontend answers
# immediately while the api (migrations + gunicorn) lags 30-60s behind; the
# upgrade gate specifically must prove the NEW api serves (measured live: two
# upgrades passed the `/` gate while /console/api was still 502).
http_up() {
  local port code
  port="${1:-${DIFY_WEB_PORT:-${DEFAULT_PORT}}}"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/console/api/setup" 2>/dev/null || true)"
  [ -z "${code}" ] && code="000"
  case "${code}" in
  2?? | 3??) return 0 ;;
  *) return 1 ;;
  esac
}

# Any dify container running? (compose ps is the source of truth — there is no
# single "the" container like gitlab's one-shot omnibus.)
containers_running() {
  local n
  n="$(compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -c . || true)"
  [ "${n}" -gt 0 ]
}

# Effective web port (deploy .env overrides the module default). NOTE: the knob is
# DIFY_WEB_PORT — upstream's DIFY_PORT means the api's gunicorn port (5001).
effective_port() {
  printf '%s' "${DIFY_WEB_PORT:-${DEFAULT_PORT}}"
}

# Dashboard interface (called by `aibox dashboard`).
dashboard_info() {
  local port url ver
  load_env
  port="$(effective_port)"
  url="http://127.0.0.1:${port}"
  ver="${DIFY_API_IMAGE:-${DEFAULT_API_IMAGE}}"
  echo "version=${ver##*:}"
  echo "endpoint=${url}"
  echo "credential=first visit sets the admin password (INIT_PASSWORD; see: aibox ${MODULE_NAME} credentials)"
  if shared_base_enabled; then
    echo "db=shared base (postgres18/redis7 via base.env)"
  else
    echo "db=bundled postgres:15-alpine / redis:6-alpine"
  fi
  if containers_running 2>/dev/null; then
    if http_up "${port}"; then
      echo "health=ok (HTTP up on :${port})"
    else
      echo "health=starting (containers up, web not answering yet; first boot 1-2 min)"
    fi
  else
    echo "health=stopped"
  fi
}

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  load_env
  local port n=""
  port="$(effective_port)"
  printf '%s%sdify%s %s· module %s%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${MODULE_VERSION:-1.17.2}" "${C_RST:-}"
  n="$(docker ps --filter "name=dify-" --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
  if [ "${n}" -gt 0 ]; then
    printf '  %s%-9s %s containers · %s\n' "${C_DIM:-}" "stack:" "${n}" "$(docker ps --filter 'name=dify-' --filter 'status=running' --format '{{.Names}}' 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')…"
  else
    printf '  %s%-9s %snot running (aibox dify start)%s\n' "${C_DIM:-}" "stack:" "${C_YEL:-}" "${C_RST:-}"
  fi
  if http_up "${port}"; then
    printf '  %s%-9s http://127.0.0.1:%s · %s✓ HTTP up%s\n' "${C_DIM:-}" "console:" "${port}" "${C_GRN:-}" "${C_RST:-}"
  elif [ "${n}" -gt 0 ]; then
    printf '  %s%-9s http://127.0.0.1:%s · %sstarting (1-2 min)%s\n' "${C_DIM:-}" "console:" "${port}" "${C_YEL:-}" "${C_RST:-}"
  fi
  if shared_base_enabled; then
    printf '  %s%-9s shared base (PG + redis via base.env)\n' "${C_DIM:-}" "db:"
  else
    printf '  %s%-9s bundled postgres/redis\n' "${C_DIM:-}" "db:"
  fi
  printf '  %s%-9s first-visit INIT_PASSWORD (see: aibox dify credentials)\n' "${C_DIM:-}" "auth:"
}

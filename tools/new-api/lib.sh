# new-api module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/new-api.

MODULE_NAME="new-api"
MODULE_VERSION="1.1.0"
COMPOSE_PROJECT="new-api"
CONTAINER="aibox-new-api"
DEFAULT_PORT="30300"
DEFAULT_IMAGE="calciumion/new-api:v0.13.2"
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
  [ -n "$root" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  printf '%s' "$root/apps/$MODULE_NAME"
}

# Load the deploy .env into the environment so hooks/svc see NEW_API_PORT /
# NEW_API_IMAGE / SESSION_SECRET, etc.
# NOTE: parse with docker env_file semantics (split at the FIRST '=', the whole
# rest of line is the value) — NOT bash sourcing. Values may contain spaces,
# glob chars, braces; `source`ing those breaks bash.
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

# compose wrapper: always runs in the deploy root. This module REQUIRES the
# shared base (module.yaml services: base:postgres + base:redis): the PG/Redis
# connection vars are injected from base.env via --env-file (the base module's
# single source of truth, written by `aibox base start`). The deploy .env is
# loaded into the SHELL environment by load_env() — compose interpolation
# precedence: shell env > --env-file, so user overrides win.
compose() {
  local root base_env args
  root="$(deploy_root)"
  [ -f "${root}/docker-compose.yml" ] || die "not installed (run: aibox install ${MODULE_NAME})"
  base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
  args=(--project-name "${COMPOSE_PROJECT}" -f "${root}/docker-compose.yml")
  if [ -f "${base_env}" ]; then
    args+=(--env-file "${base_env}")
  else
    # Not fatal at parse time (uninstall during teardown), but every real
    # lifecycle command needs the base — say so.
    warn "base.env missing (${base_env}) — run: aibox base start"
  fi
  (cd "${root}" && docker compose "${args[@]}" "$@")
}

# Image list from the compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}


# The app is up when /api/status answers success (upstream's own healthcheck
# contract — the same endpoint the container-internal wget probe uses; we curl
# it from the host through the published port).
api_up() {
  local port body
  port="${1:-$(effective_port)}"
  body="$(curl -s --max-time 5 "http://127.0.0.1:${port}/api/status" 2>/dev/null || true)"
  printf '%s' "${body}" | grep -q '"success":\s*true'
}

# Is the container running? (docker ps + fixed container name — same pattern as
# the gitlab module; the name is hardcoded in the compose, not env-tunable.)
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

# Effective host port (deploy .env overrides the module default).
effective_port() {
  printf '%s' "${NEW_API_PORT:-${DEFAULT_PORT}}"
}

# Dashboard interface (called by `aibox dashboard new-api`).
dashboard_info() {
  local port url ver
  load_env
  port="$(effective_port)"
  url="http://127.0.0.1:${port}"
  ver="${NEW_API_IMAGE:-${DEFAULT_IMAGE}}"
  echo "version=${ver##*:}"
  echo "endpoint=${url}"
  echo "credential=first login: root / 123456 (change it immediately)"
  echo "db=shared base (PG database new_api + Redis via base.env)"
  if container_running 2>/dev/null; then
    if api_up "${port}"; then
      echo "health=ok (api answers on :${port})"
    else
      echo "health=starting (container up, api not ready yet)"
    fi
  else
    echo "health=stopped"
  fi
}

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  load_env
  local port ver img="docker"
  port="$(effective_port)"
  ver="${NEW_API_IMAGE:-${DEFAULT_IMAGE}}"
  printf '%s%snew-api%s %s· module %s%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${MODULE_VERSION:-}" "${C_RST:-}"
  # container
  local st=""
  st="$(docker ps --filter "name=${CONTAINER}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1)"
  if [ -n "${st}" ]; then
    printf '  %s%-9s %s\n' "${C_DIM:-}" "container:" "${st}"
  else
    printf '  %s%-9s %snot running (aibox new-api start)%s\n' "${C_DIM:-}" "container:" "${C_YEL:-}" "${C_RST:-}"
  fi
  # app health
  if api_up "${port}"; then
    printf '  %s%-9s http://127.0.0.1:%s · %s✓ API up%s\n' "${C_DIM:-}" "app:" "${port}" "${C_GRN:-}" "${C_RST:-}"
  elif [ -n "${st}" ]; then
    printf '  %s%-9s http://127.0.0.1:%s · %sstarting%s\n' "${C_DIM:-}" "app:" "${port}" "${C_YEL:-}" "${C_RST:-}"
  else
    printf '  %s%-9s http://127.0.0.1:%s\n' "${C_DIM:-}" "app:" "${port}"
  fi
  printf '  %s%-9s %s\n' "${C_DIM:-}" "upstream:" "${ver##*:}"
  # db
  local tbl="0"
  tbl="$(docker exec aibox-base-postgres psql -U aibox -d new_api -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo 0)"
  [ "${tbl}" != "0" ] && printf '  %s%-9s shared PG new_api · %s tables\n' "${C_DIM:-}" "db:" "${tbl}"
  printf '  %s%-9s first login: root / 123456 (change it immediately)\n' "${C_DIM:-}" "auth:"
}

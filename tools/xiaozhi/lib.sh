# xiaozhi module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/xiaozhi.

MODULE_NAME="xiaozhi"
# Module version — read from module.yaml next to this lib (cache and repo
# layouts agree; empty on a missing file → callers fall back to dim ?).
MODULE_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$(dirname "${BASH_SOURCE[0]}")/module.yaml" 2>/dev/null | head -1 || true)"
COMPOSE_PROJECT="xiaozhi"
SERVER_CONTAINER="aibox-xiaozhi-server"
WEB_CONTAINER="aibox-xiaozhi-web"
MYSQL_CONTAINER="aibox-xiaozhi-mysql"
DEFAULT_WS_PORT="8000"
DEFAULT_CONSOLE_PORT="8002"
DEFAULT_HTTP_PORT="8003"
DEFAULT_SERVER_IMAGE="ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_0.9.6"
DEFAULT_WEB_IMAGE="ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
DEFAULT_MYSQL_IMAGE="mysql:8.0"
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
  # profile-scoped (spec §Deploy root): two profiles must never share one deploy
  # .env/compose. The default profile keeps the unsuffixed path (no migration).
  printf '%s' "${root}/apps/${MODULE_NAME}$(profile_suffix)"
}

# Load the deploy .env into the environment so hooks/svc see XIAOZHI_*_PORT /
# image tags / XIAOZHI_MYSQL_PASSWORD, etc.
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
  done <"${envf}"
}

# compose wrapper: always runs in the deploy root. The web service consumes the
# SHARED base redis: connection info is injected from base.env via --env-file
# (written by `aibox base start`). The deploy .env is loaded into the SHELL
# environment by load_env() — compose interpolation precedence: shell env >
# --env-file, so user overrides win.
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
    # this module's own Redis logical DB (allocated by `aibox base create redis`)
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

# ---------- ghcr.io + docker.io source pools ----------
# Migrated to tools/_shared/common.sh (spec §Docker source selector — one
# selector, per-family transport, shared dockerpool.cache ranking): ghcr_pool_prepull /
# docker_pool_prepull / images_pool_prepull now ship in _common.sh. The windmill
# module's remote WM_GHCR_MIRROR knob (deploy-host CLI) is unaffected.

# ---------- health ----------
# Is a named container running? (docker ps + fixed names — the compose
# hardcodes container_name, same pattern as the gitlab/new-api modules.)
container_running() { # $1 = container name
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}
server_running() { container_running "${SERVER_CONTAINER}"; }
web_running() { container_running "${WEB_CONTAINER}"; }

# The console (nginx → Java) answers HTTP on the console port.
console_up() {
  local port code
  port="${1:-$(effective_console_port)}"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)"
  [ -z "${code}" ] && code="000"
  case "${code}" in
  2?? | 3??) return 0 ;;
  *) return 1 ;;
  esac
}

# The websocket server listens on the ws port (TCP probe — a ws endpoint
# cannot be health-probed with plain HTTP).
ws_listening() {
  local port
  port="${1:-$(effective_ws_port)}"
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null || return 1
  exec 3>&- 2>/dev/null || true
  return 0
}

# Effective ports (deploy .env overrides the module defaults).
effective_ws_port() { printf '%s' "${XIAOZHI_WS_PORT:-${DEFAULT_WS_PORT}}"; }
effective_console_port() { printf '%s' "${XIAOZHI_CONSOLE_PORT:-${DEFAULT_CONSOLE_PORT}}"; }
effective_http_port() { printf '%s' "${XIAOZHI_HTTP_PORT:-${DEFAULT_HTTP_PORT}}"; }

# The server container's config lives in the ./data bind mount.
config_file() { printf '%s/data/.config.yaml' "$(deploy_root)"; }

# ---------- server.secret handoff (upstream's console-managed config) ----------
# The Python server REFUSES to boot with an empty manager-api.secret (measured:
# "manager-api的url或secret配置错误" crash-loop). The Java manager-api GENERATES
# the secret at first boot and stores it in MySQL (sys_params, param_code
# 'server.secret'). svc start auto-fetches it and writes data/.config.yaml;
# `aibox xiaozhi secret <value>` is the manual override.

# Query the generated secret from the bundled MySQL (empty/unavailable → rc 1).
_fetch_secret() {
  local pw out
  pw="$(grep -m1 '^XIAOZHI_MYSQL_PASSWORD=' "$(deploy_root)/.env" 2>/dev/null | cut -d= -f2-)"
  [ -n "${pw}" ] || return 1
  out="$(docker exec "${MYSQL_CONTAINER}" mysql -uroot -p"${pw}" xiaozhi_esp32_server -N -s -e "SELECT param_value FROM sys_params WHERE param_code='server.secret'" 2>/dev/null || true)"
  case "${out}" in
  "" | null | NULL) return 1 ;;
  *) printf '%s' "${out}" ;;
  esac
}

# Write manager-api.secret into data/.config.yaml (the only 'secret:' key).
_write_secret() { # $1 = value
  local cfg val
  cfg="$(config_file)"
  [ -f "${cfg}" ] || die "missing ${cfg} (re-run: aibox install ${MODULE_NAME})"
  # Escape sed replacement metachars (| is the delimiter, & expands to the
  # match, \ escapes) — the value is user-supplied via `aibox xiaozhi secret`.
  val="$(printf '%s' "$1" | sed -e 's/[&|\\\\]/\\\\&/g')"
  if grep -q '^  secret:' "${cfg}"; then
    sed -i.bak "s|^  secret:.*|  secret: \"${val}\"|" "${cfg}" && rm -f "${cfg}.bak"
  else
    printf '  secret: "%s"\n' "$1" >>"${cfg}"
  fi
}

# Detect the host's LAN IP (for the device-facing ws:// URL rendered into
# .config.yaml at install). macOS: ipconfig over the common interfaces + the
# default-route interface; Linux: hostname -I. Falls back to 127.0.0.1 — the
# rendered addresses are user-editable (see data/.config.yaml).
_lan_ip() {
  local ip ifc i
  case "$(uname -s)" in
  Darwin)
    for i in en0 en1 en2 en3; do
      ip="$(ipconfig getifaddr "$i" 2>/dev/null || true)"
      [ -n "${ip}" ] && {
        printf '%s' "${ip}"
        return 0
      }
    done
    ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true)"
    if [ -n "${ifc}" ]; then
      ip="$(ipconfig getifaddr "${ifc}" 2>/dev/null || true)"
      [ -n "${ip}" ] && {
        printf '%s' "${ip}"
        return 0
      }
    fi
    ;;
  *) ip="$(hostname -I 2>/dev/null | awk '{print $1}')" ;;
  esac
  [ -n "${ip}" ] || ip="127.0.0.1"
  printf '%s' "${ip}"
}

# Is the (single) mysql container healthy? (docker ps — avoids compose
# round-trips in status contexts.)
mysql_healthy() { container_running "${MYSQL_CONTAINER}"; }

# Any stack container running?
stack_running() {
  local n
  n="$(compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -c . || true)"
  [ "${n}" -gt 0 ]
}

# Dashboard interface (called by `aibox dashboard xiaozhi`).
# Deployed app version: "server <tag> / web <tag>" (two images).
app_version() {
  local sver hver
  load_env
  sver="${XIAOZHI_SERVER_IMAGE:-${DEFAULT_SERVER_IMAGE}}"
  hver="${XIAOZHI_WEB_IMAGE:-${DEFAULT_WEB_IMAGE}}"
  printf '%s / %s' "${sver##*:server_}" "${hver##*:web_}"
}

dashboard_info() {
  local cport wport v
  load_env
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  v="$(app_version)"
  [ -n "${v}" ] && echo "version=${v}"
  echo "endpoint=http://127.0.0.1:${cport}"
  echo "credential=console: first registered user becomes the super admin"
  echo "ws=ws://$(_lan_ip):${wport}/xiaozhi/v1/ (device websocket)"
  echo "db=bundled MySQL ${XIAOZHI_MYSQL_IMAGE:-${DEFAULT_MYSQL_IMAGE}} + shared base redis"
  if stack_running 2>/dev/null; then
    if console_up "${cport}" && server_running && ws_listening "${wport}"; then
      echo "state=ok"
      echo "health=ok (console :${cport} + ws :${wport})"
    elif console_up "${cport}"; then
      echo "state=starting"
      echo "health=starting (console up; ws server still booting)"
    else
      echo "state=starting"
      echo "health=starting (containers up; first boot runs migrations, 1-3 min)"
    fi
  else
    echo "state=stopped"
    echo "health=stopped"
  fi
}

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  load_env
  local cport wport state
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  if stack_running 2>/dev/null; then
    if console_up "${cport}" && server_running && ws_listening "${wport}"; then
      state="ok"
    else
      state="starting"
    fi
  else
    state="stopped"
  fi
  dash_header "xiaozhi" "$(app_version)" "${state}"
  # server container
  local st=""
  st="$(docker ps --filter "name=${SERVER_CONTAINER}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1 || true)"
  if [ -n "${st}" ]; then
    dash_row "server" "${st}"
  else
    dash_row "server" "${C_YEL:-}not running (aibox xiaozhi start)${C_RST:-}"
  fi
  # web + mysql
  local web_st mysql_st
  web_st="$(docker ps --filter "name=${WEB_CONTAINER}" --format '{{.Status}}' 2>/dev/null | head -1 || true)"
  [ -n "${web_st}" ] && dash_row "console" "http://127.0.0.1:${cport} ${C_DIM:-}·${C_RST:-} ${web_st}"
  mysql_st="$(docker ps --filter "name=${MYSQL_CONTAINER}" --format '{{.Status}}' 2>/dev/null | head -1 || true)"
  [ -n "${mysql_st}" ] && dash_row "mysql" "${MYSQL_CONTAINER} ${C_DIM:-}·${C_RST:-} ${mysql_st}"
  # ws + device URL
  if ws_listening "${wport}"; then
    dash_row "ws" ":${wport} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓ listening${C_RST:-} ${C_DIM:-}·${C_RST:-} devices: ws://$(_lan_ip):${wport}/xiaozhi/v1/"
  fi
  # secret state
  local secret_set
  secret_set="$(grep -A3 '^manager-api:' "$(config_file)" 2>/dev/null | sed -n 's/.*secret:[[:space:]]*//p' | tr -d '"' || true)"
  if [ -n "${secret_set}" ] && [ "${secret_set}" != '""' ]; then
    dash_row "secret" "${C_GRN:-}✓ configured${C_RST:-}"
  else
    dash_row "secret" "${C_YEL:-}not set (start auto-applies; manual: aibox xiaozhi secret <value>)${C_RST:-}"
  fi
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/xiaozhi/"
}

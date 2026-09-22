# xiaozhi module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/xiaozhi.

MODULE_NAME="xiaozhi"
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
  printf '%s' "$root/apps/$MODULE_NAME"
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
  done < "${envf}"
}

# compose wrapper: always runs in the deploy root. The web service consumes the
# SHARED base redis: connection info is injected from base.env via --env-file
# (written by `aibox base start`). The deploy .env is loaded into the SHELL
# environment by load_env() — compose interpolation precedence: shell env >
# --env-file, so user overrides win.
compose() {
  local root base_env args
  root="$(deploy_root)"
  [ -f "${root}/docker-compose.yml" ] || die "not installed (run: aibox install ${MODULE_NAME})"
  base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
  args=(--project-name "${COMPOSE_PROJECT}" -f "${root}/docker-compose.yml")
  if [ -f "${base_env}" ]; then
    args+=(--env-file "${base_env}")
  else
    warn "base.env missing (${base_env}) — run: aibox base start"
  fi
  (cd "${root}" && docker compose "${args[@]}" "$@")
}

# Image list from the compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}

# ---------- ghcr.io download source pool (pull-via-mirror + tag) ----------
# The server/web images live on ghcr.io — a DIFFERENT registry family than
# docker.io (the docker.io mirrors do NOT proxy it). ghcr.io direct is often
# slow/blocked from CN networks (measured by the windmill module: ~0.5 MB/s
# direct vs ~62 MB/s via ghcr.nju.edu.cn — upstream's own compose ships the
# NJU mirror). Approach (the windmill WM_GHCR_MIRROR technique): mirrors
# transparently proxy IDENTICAL digests, so pull `<mirror>/<path>` then
# `docker tag` it as the official ghcr.io/<path> — compose keeps official refs
# and finds the images cached.
# Route selection: uncached ghcr images are first pulled DIRECT with a bounded
# watchdog (AIBOX_GHCR_DIRECT_TIMEOUT, 120s): fast links finish with zero
# overhead; slow-but-alive links get cut (harmless — the mirror re-serves the
# same digest) and dead links fail fast into the mirror list. Mirrors are then
# tried in ORDER with per-source failover (sequential — the images are
# 0.7-1.5GB; concurrent duplicate probes through every mirror would multiply
# the traffic, and ghcr.nju.edu.cn is measured-fast).
# Knobs: AIBOX_GHCR_POOL (mirror list override; "direct" = pool disabled),
# AIBOX_GHCR_MIRROR (your mirror, tried first), AIBOX_GHCR_DIRECT_TIMEOUT
# (120), AIBOX_GHCR_PULL_TIMEOUT (1800), AIBOX_DOCKER_POLL (watchdog interval).
GHCR_POOL_MIRRORS="ghcr.nju.edu.cn ghcr.dockerproxy.net"

# Mirror-prefixed ref for a ghcr.io image (empty for non-ghcr refs).
_ghcr_mirror_ref() { # $1=mirror-host $2=image-ref
  case "${2}" in
  ghcr.io/*) printf '%s/%s' "${1}" "${2#ghcr.io/}" ;;
  *) printf '%s' "" ;;
  esac
}

# Pre-pull uncached ghcr.io images through the mirror pool.
ghcr_pool_prepull() { # $@ = image refs
  case "${AIBOX_GHCR_POOL:-}" in
  direct | none | off) return 0 ;;
  esac
  local img uncached=""
  # 1. filter: cached images + non-ghcr refs
  for img in "$@"; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    case "${img}" in
    ghcr.io/*) uncached="${uncached}${uncached:+ }${img}" ;;
    esac
  done
  [ -n "${uncached}" ] || return 0
  # 2. direct attempt (bounded): fast links finish here — zero overhead.
  #    Slow/dead links get cut/fail and fall to the mirrors.
  # shellcheck disable=SC2086
  for img in ${uncached}; do
    if _dk_bounded "${AIBOX_GHCR_DIRECT_TIMEOUT:-120}" pull "${img}"; then
      ok "pulled ${img} (direct)"
    else
      warn "ghcr: direct route slow/unusable for ${img} — engaging the mirror pool"
      _ghcr_mirror_pull "${img}" || warn "ghcr: mirror pool could not pull ${img} — compose will try direct"
    fi
  done
}

# Pull ONE image via the ordered mirror list, per-source failover + retag.
_ghcr_mirror_pull() { # $1 = official ghcr.io ref
  local img="$1" m mirrors full done1
  mirrors="${AIBOX_GHCR_MIRROR:-}"
  mirrors="${mirrors}${mirrors:+ }${AIBOX_GHCR_POOL:-${GHCR_POOL_MIRRORS}}"
  done1=0
  # shellcheck disable=SC2086
  for m in ${mirrors}; do
    full="$(_ghcr_mirror_ref "${m}" "${img}")"
    [ -n "${full}" ] || continue
    log "docker pull ${full} (mirror ${m}, watchdog ${AIBOX_GHCR_PULL_TIMEOUT:-1800}s)"
    if _dk_bounded "${AIBOX_GHCR_PULL_TIMEOUT:-1800}" pull "${full}"; then
      docker tag "${full}" "${img}" || { warn "docker tag failed: ${full} → ${img}"; continue; }
      docker rmi "${full}" >/dev/null 2>&1 || true
      ok "pulled ${img} via ${m}"
      done1=1
      break
    fi
    warn "ghcr: mirror ${m} failed for ${img} — trying the next"
  done
  [ "${done1}" = "1" ]
}


# Unified pre-pull entry: routes each image to its registry family's pool
# (ghcr → ghcr pool; docker.io → docker.io pool; other registries → direct).
images_pool_prepull() { # $@ = image refs
  local imgs_all="$*"
  # shellcheck disable=SC2086
  ghcr_pool_prepull ${imgs_all} || true
  # shellcheck disable=SC2086
  docker_pool_prepull ${imgs_all} || true
}

# ---------- health ----------
# Is a named container running? (docker ps + fixed names — the compose
# hardcodes container_name, same pattern as the gitlab/new-api modules.)
container_running() { # $1 = container name
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}
server_running() { container_running "${SERVER_CONTAINER}"; }
web_running()    { container_running "${WEB_CONTAINER}"; }

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
effective_ws_port()       { printf '%s' "${XIAOZHI_WS_PORT:-${DEFAULT_WS_PORT}}"; }
effective_console_port()  { printf '%s' "${XIAOZHI_CONSOLE_PORT:-${DEFAULT_CONSOLE_PORT}}"; }
effective_http_port()     { printf '%s' "${XIAOZHI_HTTP_PORT:-${DEFAULT_HTTP_PORT}}"; }

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
      [ -n "${ip}" ] && { printf '%s' "${ip}"; return 0; }
    done
    ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true)"
    if [ -n "${ifc}" ]; then
      ip="$(ipconfig getifaddr "${ifc}" 2>/dev/null || true)"
      [ -n "${ip}" ] && { printf '%s' "${ip}"; return 0; }
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
dashboard_info() {
  local cport wport hver sver
  load_env
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  sver="${XIAOZHI_SERVER_IMAGE:-${DEFAULT_SERVER_IMAGE}}"
  hver="${XIAOZHI_WEB_IMAGE:-${DEFAULT_WEB_IMAGE}}"
  echo "version=${sver##*:server_} / ${hver##*:web_}"
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
  local cport wport
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  printf '%s%sxiaozhi%s %s· module %s%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${MODULE_VERSION:-1.0.1}" "${C_RST:-}"
  # server container
  local st=""
  st="$(docker ps --filter "name=${SERVER_CONTAINER}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1)"
  if [ -n "${st}" ]; then
    printf '  %s%-9s %s\n' "${C_DIM:-}" "server:" "${st}"
  else
    printf '  %s%-9s %snot running (aibox xiaozhi start)%s\n' "${C_DIM:-}" "server:" "${C_YEL:-}" "${C_RST:-}"
  fi
  # web + mysql
  local web_st mysql_st
  web_st="$(docker ps --filter "name=${WEB_CONTAINER}" --format '{{.Status}}' 2>/dev/null | head -1)"
  [ -n "${web_st}" ] && printf '  %s%-9s %s · %s\n' "${C_DIM:-}" "console:" "http://127.0.0.1:${cport}" "${web_st}"
  mysql_st="$(docker ps --filter "name=${MYSQL_CONTAINER}" --format '{{.Status}}' 2>/dev/null | head -1)"
  [ -n "${mysql_st}" ] && printf '  %s%-9s %s · %s\n' "${C_DIM:-}" "mysql:" "${MYSQL_CONTAINER}" "${mysql_st}"
  # ws + device URL
  if ws_listening "${wport}"; then
    printf '  %s%-9s :%s · %s✓ listening%s · devices: ws://%s:%s/xiaozhi/v1/\n' "${C_DIM:-}" "ws:" "${wport}" "${C_GRN:-}" "${C_RST:-}" "$(_lan_ip)" "${wport}"
  fi
  # secret state
  local secret_set
  secret_set="$(grep -A3 '^manager-api:' "$(config_file)" 2>/dev/null | sed -n 's/.*secret:[[:space:]]*//p' | tr -d '"')"
  if [ -n "${secret_set}" ] && [ "${secret_set}" != '""' ]; then
    printf '  %s%-9s %s✓ configured%s\n' "${C_DIM:-}" "secret:" "${C_GRN:-}" "${C_RST:-}"
  else
    printf '  %s%-9s %snot set (start auto-applies; manual: aibox xiaozhi secret <value>)%s\n' "${C_DIM:-}" "secret:" "${C_YEL:-}" "${C_RST:-}"
  fi
}

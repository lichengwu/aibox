# windmill module shared library (sourced by hooks, not executed standalone)

CLI_NAME="windmill"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SRC="${MODULE_DIR}/cli/${CLI_NAME}"

# Install destination. Prefer WINDMILL_BIN_DIR (deploy hosts often need /usr/local/bin),
# then AIBOX_BIN_DIR (must be exported to be visible), finally ~/.local/bin.
WINDMILL_BIN_DIR="${WINDMILL_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
CLI_DEST="${WINDMILL_BIN_DIR}/${CLI_NAME}"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"

# CLI version shipped with the module
cli_version() {
  if [ ! -f "${CLI_SRC}" ]; then
    printf 'unknown'
    return 0
  fi
  sed -nE 's/^WINDMILL_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_SRC}" | head -1
}

# Installed copy version; returns 1 if not installed
installed_version() {
  if [ ! -f "${CLI_DEST}" ]; then
    return 1
  fi
  sed -nE 's/^WINDMILL_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_DEST}" | head -1
}

# Syntax check. CLI is bash 3.2 compatible (module-spec pitfall #2); can be checked locally.
check_syntax() {
  local f="${1}"
  bash -n "${f}" || die "syntax check failed: ${f}"
}

do_install() {
  if [ ! -f "${CLI_SRC}" ]; then
    die "CLI not found in module: ${CLI_SRC} (run aibox update windmill to re-pull)"
  fi
  check_syntax "${CLI_SRC}"
  mkdir -p "${WINDMILL_BIN_DIR}"
  install -m 0755 "${CLI_SRC}" "${CLI_DEST}"
  log "placed windmill $(cli_version) -> ${CLI_DEST}"
  # Seed host-level config (/etc/windmill/windmill.conf, append-only, never overwrite)
  seed_conf
}

ensure_path() {
  case ":${PATH}:" in
  *":${WINDMILL_BIN_DIR}:"*) ;;
  *)
    warn "${WINDMILL_BIN_DIR} is not in PATH"
    log "  add it to PATH, or use: WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill"
    ;;
  esac
}

# Cross-platform notice: main CLI commands require docker; launchd timers not yet supported on macOS
host_notice() {
  if [ "$(uname -s)" = "Linux" ]; then
    return 0
  fi
  echo
  warn "current system $(uname -s): CLI works; timers use launchd (aibox windmill systemd install)"
  log "  on deploy hosts install via: WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill"
}

# Mask secrets: http://user:pass@host:port -> http://user:***@host:port
mask_url() {
  printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

# Seed host-level config /etc/windmill/windmill.conf (module-spec: "Deploy Directory and Config Location Convention")
# Key whitelist matches CLI wm_conf_load: PROXY_URL / WM_GHCR_MIRROR / WM_HUB_MIRROR / HTTP_PORT.
# Append-only strategy, never overwrite; writing /etc requires privilege — on Linux deploy hosts usually root; if no permission, warn and skip.
seed_conf() {
  # Note: under bash 3.2, `local a="x" b="${a}/y"` referencing on the same line triggers unbound (AGENTS.md pitfall family),
  # must be split into two lines.
  local conf_dir="/etc/windmill"
  local conf="${conf_dir}/windmill.conf"
  local seeded=0

  if [ ! -d "${conf_dir}" ]; then
    mkdir -p "${conf_dir}" 2>/dev/null || {
      warn "cannot create ${conf_dir} (needs privilege) — skipping config seeding, CLI will use built-in defaults"
      return 0
    }
  fi
  [ -w "${conf_dir}" ] || {
    warn "${conf_dir} not writable — skipping config seeding, CLI will use built-in defaults"
    return 0
  }

  _conf_set() {
    # $1=key $2=value; if already present (non-comment), leave as-is
    local k="$1" v="$2"
    [ -n "${v}" ] || return 0
    if grep -qE "^${k}=" "${conf}" 2>/dev/null; then
      return 0
    fi
    printf '%s=%s\n' "${k}" "${v}" >>"${conf}"
    seeded=1
  }

  if [ ! -f "${conf}" ]; then
    printf '# windmill host-level config (seeded by aibox install windmill; read-only for CLI)\n# keys: PROXY_URL / WM_GHCR_MIRROR / WM_HUB_MIRROR / HTTP_PORT\n' >"${conf}"
  fi
  # Proxy: aibox global proxy delivered (must persist across time/host boundaries)
  if [ -n "${AIBOX_PROXY_URL:-}" ] && [ "${AIBOX_PROXY_ENABLED:-0}" = "1" ]; then
    _conf_set PROXY_URL "${AIBOX_PROXY_URL}"
  fi
  # Image mirrors: left for ops to configure manually (network conditions vary widely, no auto-guessing)
  if [ "${seeded}" = "1" ]; then
    log "seeded ${conf} (proxy $(mask_url "${AIBOX_PROXY_URL:-}"))"
  else
    log "${conf} already exists, unchanged (append-only, never overwrite)"
  fi
  chmod 0644 "${conf}" 2>/dev/null || true
}

# Deploy root for display (same expression as in CLI; display-only, can fall back)
wm_deploy_root() {
  local base="${AIBOX_APPS_ROOT:-}"
  if [ -z "${base}" ]; then
    base="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/windmill' "${base}"
}

# Dashboard interface (called by aibox dashboard): outputs endpoint/credential/health
dashboard_info() {
  # app version: the installed ops CLI's version (the dispatched CLI is this
  # module's deployable; the REMOTE deploy's own version is the CLI status's
  # business, not locally knowable)
  local v port="8080" envf p
  v="$(installed_version 2>/dev/null || true)"
  [ -n "${v}" ] && echo "version=${v}"
  envf="$(wm_deploy_root)/.env"
  if [ -f "$envf" ]; then
    p="$(grep -E '^HTTP_PORT=' "$envf" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
    [ -n "$p" ] && port="$p"
  fi
  echo "endpoint=http://127.0.0.1:${port}"
  echo "credential=CREDENTIALS.txt + .env (POSTGRES_PASSWORD)"
  # na: CLI-type module — state is the deploy host's, not a local service's;
  # `aibox windmill status` (dispatched to the CLI) is the real view.
  echo "state=na"
  echo "health=curl -s http://127.0.0.1:${port}"
}

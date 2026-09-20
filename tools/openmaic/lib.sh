# openmaic module shared library (sourced by hooks, not executed standalone)

CLI_NAME="openmaic"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SRC="${MODULE_DIR}/cli/${CLI_NAME}"

# Install destination. Prefer OPENMAIC_BIN_DIR (deploy hosts often need /usr/local/bin),
# then AIBOX_BIN_DIR (must be exported to be visible), finally ~/.local/bin.
OPENMAIC_BIN_DIR="${OPENMAIC_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
CLI_DEST="${OPENMAIC_BIN_DIR}/${CLI_NAME}"
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
  sed -nE 's/^OPENMAIC_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_SRC}" | head -1
}

# Version of installed copy; returns 1 if not installed
installed_version() {
  if [ ! -f "${CLI_DEST}" ]; then
    return 1
  fi
  sed -nE 's/^OPENMAIC_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_DEST}" | head -1
}

# Syntax check. The CLI targets Linux bash 5; macOS ships bash 3.2 which
# would false-report bash 4 features, so skip on low versions instead of giving false failures.
check_syntax() {
  local f="${1}" maj
  maj="${BASH_VERSINFO[0]:-3}"
  if [ "${maj}" -lt 4 ]; then
    warn "local bash ${BASH_VERSION} is below 4.0, skipping syntax check (target is Linux bash 5)"
    return 0
  fi
  bash -n "${f}" || die "syntax check failed: ${f}"
}

do_install() {
  if [ ! -f "${CLI_SRC}" ]; then
    die "CLI not found in module: ${CLI_SRC} (run 'aibox update openmaic' to fetch again)"
  fi
  check_syntax "${CLI_SRC}"
  mkdir -p "${OPENMAIC_BIN_DIR}"
  install -m 0755 "${CLI_SRC}" "${CLI_DEST}"
  log "placed openmaic $(cli_version) -> ${CLI_DEST}"
  # Also sync aibox's proxy into OpenMAIC's own config (see sync_proxy_to_conf for why)
  sync_proxy_to_conf
}

ensure_path() {
  case ":${PATH}:" in
  *":${OPENMAIC_BIN_DIR}:"*) ;;
  *)
    warn "${OPENMAIC_BIN_DIR} is not in PATH"
    log "  add it to PATH, or use: OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic"
    ;;
  esac
}

# Explain clearly when docker is absent: service commands need docker
host_notice() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo
  warn "docker not detected — openmaic service commands (up/install/upgrade/backup, etc.) will refuse to run"
  log "  available locally: openmaic help / version / doctor"
  log "  to install docker: aibox install openmaic auto-checks dependencies"
}

# Mask: http://user:pass@host:port -> http://user:***@host:port
mask_url() {
  printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

# Sync aibox's proxy into OpenMAIC's own config file (3rd-layer persistence).
#
# Why it must be written to disk: the openmaic CLI runs on the deploy host
# when aibox is completely absent, running `openmaic upgrade` to pull GitHub
# source — environment variables cannot cross this time/host boundary,
# so it must be written into its own config file to carry it over.
#
# Only done on the deploy host (Linux); does nothing when no proxy is configured.
sync_proxy_to_conf() {
  local conf="/etc/openmaic/openmaic.conf" conf_dir cur
  [ -n "${AIBOX_PROXY_URL:-}" ] || return 0
  [ "${AIBOX_PROXY_ENABLED:-0}" = "1" ] || return 0

  conf_dir="$(dirname "${conf}")"
  if [ ! -d "${conf_dir}" ]; then
    mkdir -p "${conf_dir}" 2>/dev/null || {
      warn "cannot create ${conf_dir} (needs privilege) — skipping proxy sync, CLI will use built-in defaults"
      return 0
    }
  fi
  [ -w "${conf_dir}" ] || {
    warn "${conf_dir} is not writable — skipping proxy sync, CLI will use built-in defaults"
    return 0
  }

  if [ ! -f "${conf}" ]; then
    cat >"${conf}" <<EOF
# OpenMAIC CLI config (created when aibox installs the openmaic module)
# Leave other keys empty to use built-in defaults; see openmaic help for key names.

# Proxy for pulling source (synced by aibox proxy set)
OPENMAIC_PROXY_URL="${AIBOX_PROXY_URL}"
EOF
    log "created ${conf} and wrote proxy $(mask_url "${AIBOX_PROXY_URL}")"
    return 0
  fi

  cur=$(sed -nE 's/^OPENMAIC_PROXY_URL="?([^"]*)"?$/\1/p' "${conf}" | head -1)
  if [ "${cur}" = "${AIBOX_PROXY_URL}" ]; then
    log "proxy already in ${conf} ($(mask_url "${cur}")), no change needed"
    return 0
  fi

  cp -a "${conf}" "${conf}.bak-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^OPENMAIC_PROXY_URL=' "${conf}"; then
    # Use awk to replace: the URL may contain / or &, sed needs extra escaping and is error-prone
    awk -v v="${AIBOX_PROXY_URL}" \
      '/^OPENMAIC_PROXY_URL=/{print "OPENMAIC_PROXY_URL=\"" v "\""; next} {print}' \
      "${conf}" >"${conf}.tmp" && mv "${conf}.tmp" "${conf}"
  else
    printf '\n# synced by aibox (aibox proxy set)\nOPENMAIC_PROXY_URL="%s"\n' "${AIBOX_PROXY_URL}" >>"${conf}"
  fi
  log "synced proxy to ${conf}: $(mask_url "${AIBOX_PROXY_URL}")"
  log "  subsequent openmaic upgrade on the deploy host will use it to pull source automatically"
}

# Deploy root for display (same expression as in the CLI; display only, can fall back)
openmaic_deploy_root() {
  if [ -n "${OPENMAIC_BASE_DIR:-}" ]; then
    printf '%s' "${OPENMAIC_BASE_DIR}"
    return 0
  fi
  local base="${AIBOX_APPS_ROOT:-}"
  if [ -z "${base}" ]; then
    base="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/openmaic' "${base}"
}

# Dashboard interface (called by aibox dashboard): outputs endpoint/credential/health
dashboard_info() {
  echo "endpoint=http://127.0.0.1:3000"
  echo "credential=.env.local (API Key, access password)"
  echo "health=curl -s http://127.0.0.1:3000/api/health"
}

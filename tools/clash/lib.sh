# clash module shared library (sourced by hooks, not executed directly)
#
# Orchestrates the local mihomo kernel: subscription fetch / speed-test / switch are all
# delegated to mihomo; this module only downloads the binary, generates config, manages the
# process lifecycle, refreshes the fallback, and exposes the local mixed port to aibox.
#
# Why we don't parse the subscription yaml ourselves: mihomo's proxy-providers natively
# consume a subscription URL, fetching + parsing + refreshing on schedule; url-test/fallback
# groups auto-test for the fastest node and fail over. aibox doesn't reinvent this.

export CLI_NAME="clash"
KERNEL_NAME="mihomo"

# mihomo binary location
CLASH_BIN_DIR="${CLASH_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
KERNEL_DEST="${CLASH_BIN_DIR}/${KERNEL_NAME}"

# Default ports (overridable via state)
CLASH_PORT="${CLASH_PORT:-7890}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"

# Output helpers: colors are inherited from aibox via the exported C_* env vars (single
# source of truth); ${C_*:-} falls back to empty when this lib is sourced standalone.
# Prefix uses AIBOX_MODULE (injected by aibox) with the module name as a fallback.
log() { printf '%s[%s]%s %s\n' "${C_CYA:-}" "${AIBOX_MODULE:-clash}" "${C_RST:-}" "${*}"; }
warn() { printf '%s[!]%s %s\n' "${C_YEL:-}" "${C_RST:-}" "${*}" >&2; }
die() {
  printf '%s[x]%s %s\n' "${C_RED:-}" "${C_RST:-}" "${*}" >&2
  exit 1
}
mask_url() { printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'; }

# ---------- deploy root / paths (module-spec deploy-type convention) ----------
clash_deploy_root() {
  if [ -n "${CLASH_BASE_DIR:-}" ]; then
    printf '%s' "${CLASH_BASE_DIR}"
    return 0
  fi
  local base="${AIBOX_APPS_ROOT:-}"
  if [ -z "${base}" ]; then
    base="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/clash' "${base}"
}
providers_dir() { printf '%s/providers' "$(clash_deploy_root)"; }
log_dir() { printf '%s/logs' "$(clash_deploy_root)"; }
state_file() { printf '%s/state' "$(clash_deploy_root)"; }
pid_file() { printf '%s/mihomo.pid' "$(clash_deploy_root)"; }
config_file() { printf '%s/config.yaml' "$(clash_deploy_root)"; }

# ---------- platform / version / download ----------
detect_asset() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
  x86_64 | amd64) arch="amd64" ;;
  arm64 | aarch64) arch="arm64" ;;
  i386 | i686) arch="386" ;;
  armv7l) arch="armv7" ;;
  *) die "Unsupported arch: $(uname -m) (download manually: https://github.com/MetaCubeX/mihomo/releases)" ;;
  esac
  printf 'mihomo-%s-%s' "$os" "$arch"
}

latest_mihomo_tag() {
  curl -fsSL --max-time 15 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null |
    grep -oE '"tag_name": *"v[^"]+"' | head -1 | sed -E 's/.*"v([^"]+)".*/\1/'
}

installed_kernel_version() {
  [ -x "${KERNEL_DEST}" ] || {
    printf ''
    return 1
  }
  "${KERNEL_DEST}" -v 2>/dev/null | grep -oE 'v[0-9][0-9.]*' | head -1 || return 1
}

download_mihomo() {
  local ver asset url tmp
  ver="${1:-$(latest_mihomo_tag)}"
  [ -n "$ver" ] || die "Cannot get the latest mihomo version (network? proxy? set a proxy (run: aibox proxy set) and retry)"
  asset="$(detect_asset)-v${ver}.gz"
  url="https://github.com/MetaCubeX/mihomo/releases/download/v${ver}/${asset}"
  log "Downloading mihomo v${ver} -> ${asset}"
  mkdir -p "${CLASH_BIN_DIR}"
  tmp="${KERNEL_DEST}.gz"
  curl -fsSL --max-time 120 "$url" -o "$tmp" || die "Download failed: ${url}"
  gunzip -f "$tmp" || die "Decompress failed (mihomo .gz)"
  chmod 0755 "${KERNEL_DEST}"
  "${KERNEL_DEST}" -v >/dev/null 2>&1 || die "Downloaded binary won't run (arch mismatch?)"
  log "Placed mihomo v${ver} -> ${KERNEL_DEST}"
}

# ---------- state (sub URL / secret / ports / last refresh / kernel version) ----------
state_load() {
  [ -f "$(state_file)" ] || return 0
  # shellcheck disable=SC1090
  . "$(state_file)" 2>/dev/null || true
  CLASH_PORT="${CLASH_PORT:-7890}"
  CLASH_API_PORT="${CLASH_API_PORT:-9090}"
}

# state_write <sub_url> <secret> <enabled> <port> <api_port> <last_refresh> <tag>
state_write() {
  mkdir -p "$(clash_deploy_root)"
  local old_umask
  old_umask=$(umask)
  umask 077
  cat >"$(state_file)" <<EOF
# clash module state (maintained by aibox clash; contains subscription token, mode 600)
SUB_URL="$1"
CLASH_SECRET="$2"
CLASH_ENABLED="$3"
CLASH_PORT="${4:-7890}"
CLASH_API_PORT="${5:-9090}"
LAST_REFRESH="${6:-0}"
KERNEL_TAG="${7:-}"
EOF
  umask "$old_umask"
  chmod 600 "$(state_file)"
}

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 2>/dev/null
  else
    od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n'
  fi
}

# ---------- config generation (heredoc template; injects subscription / secret / ports) ----------
gen_config() {
  mkdir -p "$(clash_deploy_root)" "$(providers_dir)" "$(log_dir)"
  # Don't parse the subscription yaml: write it straight into proxy-providers; mihomo fetches/parses/tests/switches.
  cat >"$(config_file)" <<EOF
# Generated by aibox clash (don't hand-edit; overwritten by: aibox clash set/refresh)
mixed-port: ${CLASH_PORT}
external-controller: 127.0.0.1:${CLASH_API_PORT}
secret: "${CLASH_SECRET}"
allow-lan: false
mode: rule
log-level: warning

proxy-providers:
  pool:
    type: http
    url: "${SUB_URL}"
    interval: 86400
    path: $(providers_dir)/pool.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: AUTO
    type: url-test
    use: [pool]
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
  - name: FALLBACK
    type: fallback
    use: [pool]
    url: https://www.gstatic.com/generate_204
    interval: 300

rules:
  - MATCH,AUTO
EOF
}

# ---------- mihomo process (nohup + pid, simple cross-platform daemon) ----------
kernel_running() {
  [ -f "$(pid_file)" ] || return 1
  local pid
  pid="$(cat "$(pid_file)" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_kernel() {
  kernel_running && {
    log "mihomo already running (pid $(cat "$(pid_file)"))"
    return 0
  }
  [ -x "${KERNEL_DEST}" ] || die "mihomo not installed (first: aibox install clash)"
  [ -f "$(config_file)" ] || die "No config (first: aibox clash set <subscription-url>)"
  state_load
  [ -n "${SUB_URL:-}" ] || die "No subscription configured (first: aibox clash set <subscription-url>)"
  log "Starting mihomo ..."
  nohup "${KERNEL_DEST}" -d "$(clash_deploy_root)" -f "$(config_file)" \
    >"$(log_dir)/mihomo.log" 2>&1 &
  echo $! >"$(pid_file)"
  sleep 1
  if kernel_running; then
    log "mihomo started (pid $(cat "$(pid_file)"), mixed port ${CLASH_PORT})"
    # Mark enabled: aibox apply_proxy sees CLASH_ENABLED=1 and points egress at the local port.
    state_write "${SUB_URL}" "${CLASH_SECRET}" "1" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  else
    rm -f "$(pid_file)"
    die "mihomo failed to start; see log: $(log_dir)/mihomo.log"
  fi
}

stop_kernel() {
  kernel_running || {
    log "mihomo not running"
    rm -f "$(pid_file)"
    return 0
  }
  local pid
  pid="$(cat "$(pid_file)")"
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$(pid_file)"
  state_load
  state_write "${SUB_URL:-}" "${CLASH_SECRET:-}" "0" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  log "mihomo stopped (aibox egress fell back to static proxy or direct connection)"
}

# ---------- mihomo REST API (external-controller) ----------
api_get() { # $1=path
  curl -fsSL -H "Authorization: Bearer ${CLASH_SECRET}" \
    "http://127.0.0.1:${CLASH_API_PORT}$1" 2>/dev/null
}
api_put() { # $1=path $2=body
  curl -fsSL -X PUT -H "Authorization: Bearer ${CLASH_SECRET}" \
    -H 'Content-Type: application/json' \
    --data "$2" "http://127.0.0.1:${CLASH_API_PORT}$1" 2>/dev/null
}

reload_config() {
  api_put '/configs?force=true' "{\"path\":\"$(config_file)\"}" &&
    log "Reloaded config" || warn "Reload failed (mihomo not running?)"
}

# Have mihomo immediately fetch the subscription (skip cache).
refresh_providers() {
  api_put '/providers/proxies/pool' '{"path":"pool","force":true}' >/dev/null 2>&1 || true
}

# ---------- subscription refresh (>1 week fallback: re-pull when found stale) ----------
WEEK=$((7 * 24 * 3600))
ensure_fresh() {
  state_load
  [ -n "${SUB_URL:-}" ] || return 0
  local now last stale
  now="$(date +%s)"
  last="${LAST_REFRESH:-0}"
  stale=0
  if [ "$last" = "0" ]; then
    stale=1
  else
    [ $((now - last)) -ge "$WEEK" ] && stale=1
  fi
  if [ "$stale" = "1" ]; then
    log "Subscription cache is over 1 week old (or never refreshed); re-fetching ..."
    refresh_now
  fi
}

# Force refresh: aibox fetches the subscription itself to overwrite pool.yaml + triggers mihomo reload.
refresh_now() {
  state_load
  [ -n "${SUB_URL:-}" ] || die "No subscription configured (first: aibox clash set <subscription-url>)"
  log "Fetching subscription $(mask_url "${SUB_URL}") ..."
  if curl -fsSL --max-time 30 "${SUB_URL}" -o "$(providers_dir)/pool.yaml.tmp" 2>/dev/null; then
    mv "$(providers_dir)/pool.yaml.tmp" "$(providers_dir)/pool.yaml"
    log "Updated $(providers_dir)/pool.yaml"
  else
    warn "aibox-side subscription fetch failed; leaving it to mihomo's internal interval retry"
  fi
  if kernel_running; then
    reload_config
    refresh_providers
  fi
  state_write "${SUB_URL}" "${CLASH_SECRET}" "${CLASH_ENABLED}" "${CLASH_PORT}" "${CLASH_API_PORT}" "$(date +%s)" "${KERNEL_TAG:-}"
  log "Refresh complete"
}

# ---------- status query ----------
show_status() {
  state_load
  if kernel_running; then
    log "mihomo running (pid $(cat "$(pid_file)"))"
    log "mixed port   127.0.0.1:${CLASH_PORT}"
    log "API          127.0.0.1:${CLASH_API_PORT}"
    [ -n "${SUB_URL:-}" ] && log "subscription $(mask_url "${SUB_URL}")"
    [ -n "${KERNEL_TAG:-}" ] && log "kernel ver    v${KERNEL_TAG}"
    log "last refresh ${LAST_REFRESH:-never}"
    local auto cur
    auto="$(api_get /proxies/AUTO 2>/dev/null || true)"
    if [ -n "$auto" ]; then
      cur="$(printf '%s' "$auto" | grep -oE '"now":[[:space:]]*"[^"]*"' | sed 's/.*: *"//; s/"$//')"
      log "current node ${cur:-none selected}"
    fi
  else
    warn "mihomo not running"
    [ -n "${SUB_URL:-}" ] && log "subscription $(mask_url "${SUB_URL}") (configured; start with: aibox clash on)"
    return 1
  fi
}

# ---------- probe via the local port ----------
probe_via_clash() {
  local url code used out
  url="${1:-https://www.gstatic.com/generate_204}"
  out="$(curl -s --max-time 8 -x "socks5://127.0.0.1:${CLASH_PORT}" \
    -o /dev/null -w '%{http_code} %{proxy_used}' "$url" 2>/dev/null)" || out=""
  [ -n "$out" ] || out="000 0"
  code="${out%% *}"
  used="${out##* }"
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    log "Via mihomo    ${code} (proxy_used=${used})"
  else
    warn "Via mihomo    ${code} (proxy may be unavailable)"
  fi
}

# Dashboard interface (called by `aibox dashboard`): outputs endpoint/credential/log/health.
dashboard_info() {
  state_load
  echo "endpoint=socks5://127.0.0.1:${CLASH_PORT}"
  echo "credential=API secret ${CLASH_SECRET:-unset}"
  echo "log=$(log_dir)/mihomo.log"
  echo "health=curl -s -H 'Authorization: Bearer ${CLASH_SECRET}' http://127.0.0.1:${CLASH_API_PORT}/proxies/AUTO"
}

# pi-web module shared library (sourced by hooks, not executed directly)
# Extracted from the original pi-web-ctl config and shared functions.

LABEL="pi-web"
OLD_LABELS=("com.agegr.pi-web")
# Deployed app version: the @agegr/pi-web npm package installed globally
# (local read, ~0.7s, no network). Empty when npm or the package is absent —
# callers omit the segment (update.sh's npm_registry_pick is the network path).
app_version() {
  command -v npm >/dev/null 2>&1 || return 0
  npm ls -g @agegr/pi-web --depth=0 2>/dev/null |
    grep -oE '@agegr/pi-web@[0-9][0-9A-Za-z.-]*' | head -1 | sed 's/.*@//' || true
}
OS_KIND="$(uname -s)"
if [ "$OS_KIND" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  LOG_DIR="$HOME/Library/Logs"
else
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT_FILE="${UNIT_DIR}/${LABEL}.service"
  LOG_DIR="$HOME/.local/share/${LABEL}/logs"
fi
PORT="${PI_WEB_PORT:-30141}"
PASSWORD="" # filled by resolve_password (below); PI_WEB_PASSWORD overrides
BIND="${PI_WEB_BIND:-0.0.0.0}"
UID_="$(id -u)"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"
# Domain split (D3): cache layout first, repo layout fallback — the same
# resolution _common.sh uses.
LIB_PART="${LIB_SELF}/lib-npm.sh"
[ -f "${LIB_PART}" ] || LIB_PART="${LIB_SELF}/../_shared/lib-npm.sh"
if [ -f "${LIB_PART}" ]; then
  # shellcheck disable=SC1090
  . "${LIB_PART}"
fi
# a hook; direct execution (bats, a hook run by hand) uses the ONE shared reader.
MODULE_VERSION="${AIBOX_MODULE_VERSION:-$(meta_version "${LIB_SELF}/module.yaml")}"

# ---------- profile ----------
# AIBOX_PROFILE defaults to "base" (exported by aibox's --profile flag).
# profile="base" → no override (PORT=30141, LABEL=pi-web, current behavior).
# profile=<name>  → hash-derived PORT (31150 range) + LABEL suffixed with profile name.
# Same profile name → same PORT/LABEL on every machine (deterministic).
# Shares the profile config ($AIBOX_HOME/profiles/<name>.conf) with base — each module
# derives its own vars from PROFILE_HASH + PROFILE_NAME in the config.



_profile_load() {
  [ -z "${AIBOX_PROFILE:-}" ] && return 0
  [ "$AIBOX_PROFILE" = "base" ] && return 0
  local pf="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/profiles/${AIBOX_PROFILE}.conf"
  profile_ensure "$AIBOX_PROFILE" "$pf"
  # Parsed, not executed: a profile conf is data (cfg_kv_load in the shared lib)
  cfg_kv_load "$pf" PROFILE_
  if [ -z "${PROFILE_HASH:-}" ] && [ -z "${PROFILE_NAME:-}" ]; then
    warn "Profile config unreadable: $pf"
    return 1
  fi
  local _h="${PROFILE_HASH:-0}" _n="${PROFILE_NAME:-$AIBOX_PROFILE}"
  PORT=$((31150 + _h % 100))
  LABEL="pi-web-${_n}"
  if [ "$OS_KIND" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  else
    UNIT_FILE="${UNIT_DIR}/${LABEL}.service"
    LOG_DIR="$HOME/.local/share/${LABEL}/logs"
  fi
  # Say what the profile DERIVED (the old copy only said "Created profile")
  if [ "${_PROFILE_JUST_CREATED:-0}" = "1" ]; then
    unset _PROFILE_JUST_CREATED
    log "Profile '${_n}' derived: port=${PORT} · service=${LABEL}"
  fi
}

# Load profile (overrides PORT + LABEL for named profiles).
_profile_load

# ---------- access password ----------
# Priority: PI_WEB_PASSWORD env > password in the installed plist (idempotent: re-install/update
# doesn't rotate) > random on first install. Avoids a fixed weak default on a host service
# reachable from the network.
# Config store reader: the service definition IS the store (spec §Configuration).
# Darwin: the plist's EnvironmentVariables; Linux: the unit's Environment= lines.
# Empty when the key/file is absent. `config set` regenerates the whole
# definition via write_service (single writer), then restart re-reads it.
_store_get() { # $1=aibox-facing KEY → value or ""
  # key mapping: the env: declaration carries the aibox-facing names users
  # know from the README; the service definition writes the app's runtime
  # names (write_plist: PI_WEB_BIND → PI_WEB_HOSTNAME, PI_WEB_PORT → PORT).
  local sk out
  case "$1" in
  PI_WEB_BIND) sk="PI_WEB_HOSTNAME" ;;
  PI_WEB_PORT) sk="PORT" ;;
  *) sk="$1" ;;
  esac
  if [ "$OS_KIND" = "Darwin" ] && [ -f "$PLIST" ]; then
    # PlistBuddy prints errors to STDOUT as well as stderr ("Error Reading
    # File: …") — only accept clean output as a value.
    out="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:${sk}" "$PLIST" 2>/dev/null || true)"
    case "${out}" in
    "" | "Error "*) return 0 ;;
    *) printf '%s\n' "${out}" ;;
    esac
  elif [ -n "${UNIT_FILE:-}" ] && [ -f "$UNIT_FILE" ]; then
    sed -nE "s/^Environment=\"${sk}=([^\"]*)\".*$/\1/p" "$UNIT_FILE" 2>/dev/null | head -1
  fi
  return 0
}

resolve_password() {
  if [ -n "${PI_WEB_PASSWORD:-}" ]; then
    PASSWORD="$PI_WEB_PASSWORD"
    return 0
  fi
  # Reuse the installed password (idempotent: update/re-install keeps the same password).
  # macOS: from the plist; Linux: from the systemd unit's Environment= line.
  if [ "$OS_KIND" = "Darwin" ] && [ -f "$PLIST" ]; then
    local prev
    prev="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_WEB_PASSWORD' "$PLIST" 2>/dev/null || true)"
    [ -n "$prev" ] && {
      PASSWORD="$prev"
      return 0
    }
  elif [ -n "${UNIT_FILE:-}" ] && [ -f "$UNIT_FILE" ]; then
    local prev
    prev="$(grep -E '^Environment="PI_WEB_PASSWORD=' "$UNIT_FILE" 2>/dev/null | sed -E 's/^Environment="PI_WEB_PASSWORD=([^"]*)".*/\1/' || true)"
    [ -n "$prev" ] && {
      PASSWORD="$prev"
      return 0
    }
  fi
  # First install: random 16-hex.
  if command -v openssl >/dev/null 2>&1; then
    PASSWORD="$(openssl rand -hex 8 2>/dev/null || true)"
  fi
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [ -n "$PASSWORD" ] || PASSWORD="pi-web-$(date +%s)"
}

# Soft choice confirmation: ask_yn "<prompt>" [y|n]
# Interactive y/N; non-interactive (no TTY) takes the default and warns. Default n=decline, y=accept.
# Distinct from openmaic/windmill's confirm (dangerous ops, type `yes`): this is for light choices.
ask_yn() {
  local prompt="$1" def="${2:-n}" ans hint
  if [ ! -t 0 ]; then
    warn "Non-interactive environment, ${prompt} -> default ${def}"
    case "$def" in y | Y) return 0 ;; *) return 1 ;; esac
  fi
  case "$def" in
  y | Y)
    hint="[Y/n]"
    def=y
    ;;
  *)
    hint="[y/N]"
    def=n
    ;;
  esac
  printf '%s⚠%s  %s %s ' "${C_YEL:-}" "${C_RST:-}" "$prompt" "$hint"
  read -r ans || return 1
  case "$def" in
  y | Y) case "$ans" in [nN]*) return 1 ;; *) return 0 ;; esac ;;
  *) case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

# ---------- node detection ----------

# ---------- npm registry pick + stalled-registry failover ----------
# `npm i -g` against registry.npmjs.org stalls badly on CN-class networks (measured:
# this package's metadata 4.3s vs 0.15s on npmmirror; worse cases hang indefinitely).
# npm is SILENT in non-TTY, so "no progress" cannot be observed from output — a
# wall-clock watchdog is the only portable stall signal. Design mirrors the preflight
# route-fallback philosophy: probe the configured + well-known candidates, adopt the
# fastest FOR THIS RUN ONLY, never touch the user's global npm config:
#   1. npm_registry_pick — probes every candidate IN PARALLEL with a REAL download
#      speed test: fetch the package metadata (validates the mirror carries the
#      package; yields latest + the dist.tarball URL), then download THAT tarball
#      — the exact file npm will fetch — and rank candidates by measured throughput
#      (bytes/sec; a --max-time cutoff still yields a partial-download rate, so
#      throttled-but-alive registries rank honestly). Different networks rank
#      differently (measured: npmmirror fastest on one host, huawei on another) —
#      nothing is hardcoded. The user's non-default .npmrc registry joins the
#      candidates; AIBOX_NPM_REGISTRY hard-pins without probing. Also sets
#      NPM_LATEST (dist-tags.latest) so update.sh needs no network-hanging `npm view`.
#      Tradeoff: the probe downloads the tarball once per candidate (~package size ×
#      N) — negligible for this module's small package.
#   2. npm_install_global — `npm install -g --registry <winner>` under a wall-clock
#      watchdog; a stall kills the npm process tree and fails over to the runner-up
#      registry (in NPM_REGISTRY_ORDER, fastest-first), once per candidate, until
#      every REACHABLE registry is exhausted → then die.
#      (Reachable = metadata-valid. A metadata-ok registry whose tarball failed the
#      probe ranks at speed 0 — still a last-resort candidate.)
# Knobs: AIBOX_NPM_REGISTRY (pin), AIBOX_NPM_REGISTRIES (candidate list),
# AIBOX_NPM_TIMEOUT (watchdog seconds, default 240), AIBOX_NPM_PROBE_TIMEOUT (6).
NPM_PACKAGE="@agegr/pi-web"
# URL-encoded package path for the registry REST API (changes with NPM_PACKAGE).
NPM_PACKAGE_PATH="@agegr%2fpi-web"
NPM_REGISTRY_DEFAULT="https://registry.npmjs.org"
# Authoritative mirrors (full sync, carry this package — verified live):
# npmmirror (Alibaba; official successor of the retired registry.npm.taobao.org),
# Tencent Cloud, Huawei Cloud. The default registry stays a candidate so non-CN
# networks keep using it when it is fastest.
NPM_REGISTRIES_CANDIDATES="${NPM_REGISTRY_DEFAULT} https://registry.npmmirror.com https://mirrors.cloud.tencent.com/npm https://mirrors.huaweicloud.com/repository/npm"
NPM_REGISTRY=""       # winner — set by npm_registry_pick
NPM_LATEST=""         # dist-tags.latest from the probe metadata
NPM_REGISTRY_ORDER="" # space-separated, fastest-download-first — failover order

# Human-readable speed for logs.
_npm_speed_human() { # $1 = bytes/sec
  awk -v sp="${1:-0}" 'BEGIN {
    if (sp >= 1048576) printf "%.1fMB/s", sp / 1048576
    else if (sp >= 1024) printf "%dKB/s", sp / 1024
    else printf "%dB/s", sp
  }'
}

# Probe ONE registry (background worker): writes "SPEED<TAB>REG<TAB>LATEST" to $2
# (SPEED = measured tarball-download bytes/sec). No latest (dead registry / package
# missing) → empty file (unusable candidate); metadata ok but tarball failed →
# speed 0 (usable, ranked last).
# no latest (dead registry / package missing) → empty file (unusable candidate).
_npm_probe_one() { # $1=registry, $2=result file
  local reg="$1" out="$2" meta latest tball tstat size dtime speed
  meta="${out}.meta"
  # Stage 1 — metadata: validates the registry carries the package; yields latest
  # + the dist.tarball URL.
  curl -s -o "$meta" --max-time "${AIBOX_NPM_PROBE_TIMEOUT:-6}" \
    "${reg}/${NPM_PACKAGE_PATH}" 2>/dev/null || true
  latest="$(grep -oE '"latest":"[^"]+"' "$meta" 2>/dev/null | head -1 | cut -d'"' -f4)"
  [ -z "${latest}" ] && latest="$(grep -oE '"latest": *"[^"]+"' "$meta" 2>/dev/null | head -1 | sed -e 's/.*: *"//' -e 's/"$//')"
  [ -z "${latest}" ] && {
    : >"$out"
    return 0
  }
  # Stage 2 — throughput: download the very tarball npm will fetch (-L follows
  # mirror CDN redirects). A --max-time cutoff still yields a partial-download
  # rate (size_download/time_total), so throttled-but-alive registries rank honestly.
  tball="$(grep -oE '"tarball": *"[^"]+"' "$meta" 2>/dev/null | head -1 | sed -e 's/.*: *"//' -e 's/"$//')"
  speed=0
  if [ -n "${tball}" ]; then
    tstat="$(curl -sL -o /dev/null -w '%{size_download} %{time_total}' --max-time "${AIBOX_NPM_PROBE_TIMEOUT:-6}" "${tball}" 2>/dev/null || true)"
    size="${tstat%% *}"
    dtime="${tstat##* }"
    speed="$(printf '%s %s' "${size:-0}" "${dtime:-0}" |
      awk '{t=$2+0; if (t>0) printf "%d", $1/t; else print 0}')"
  fi
  printf '%s\t%s\t%s\n' "${speed:-0}" "${reg}" "${latest}" >"$out"
  return 0
}

# Pick the npm registry for this run. Honors AIBOX_NPM_REGISTRY (hard pin, no probe)
# and adds the user's non-default `npm config get registry` to the candidates. Sets
# NPM_REGISTRY / NPM_LATEST / NPM_REGISTRY_ORDER. Dies when nothing is usable.

# Install the package globally with the picked registry + wall-clock watchdog and
# one failover per candidate (fastest-first). npm is silent in non-TTY — wall-clock
# is the only portable stall signal; a stall kills the npm process tree.

# ---------- old-residue cleanup ----------
cleanup_old() {
  local lbl old pids
  if [ "$OS_KIND" = "Darwin" ]; then
    for lbl in "$LABEL" "${OLD_LABELS[@]}"; do
      launchctl bootout "gui/${UID_}/${lbl}" 2>/dev/null || true
      launchctl remove "$lbl" 2>/dev/null || true
      old="$HOME/Library/LaunchAgents/${lbl}.plist"
      if [ "$lbl" != "$LABEL" ] && [ -f "$old" ]; then
        mv -n "$old" "$HOME/.Trash/${lbl}.plist-$(date +%s)" 2>/dev/null || true
      fi
    done
  else
    for lbl in "$LABEL" "${OLD_LABELS[@]}"; do
      systemctl --user stop "$lbl" 2>/dev/null || true
      systemctl --user disable "$lbl" 2>/dev/null || true
    done
    # Clean up unit files for old labels.
    [ -f "${UNIT_FILE}" ] && rm -f "${UNIT_FILE}"
    [ -f "${UNIT_DIR}/com.agegr.pi-web.service" ] && rm -f "${UNIT_DIR}/com.agegr.pi-web.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  # Port-occupation fallback (shared across platforms).
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
    [ -n "$pids" ] && {
      warn "Port $PORT occupied by $pids; killing"
      echo "$pids" | xargs kill -9 2>/dev/null || true
    }
  fi
  sleep 1
}

# ---------- generate service unit (mac plist / linux systemd, branched by platform) ----------
write_service() {
  # npm's global prefix decides where `npm i -g` puts the binary — it is NOT
  # always node's own dir (measured on Alibaba Cloud Linux 4: node lives in
  # /usr/bin but npm prefix -g is /usr/local → /usr/local/bin/pi-web).
  local pi_bin="" npm_prefix
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ -x "${npm_prefix}/bin/pi-web" ]; then
    pi_bin="${npm_prefix}/bin/pi-web"
  elif [ -x "$NODE_DIR/pi-web" ]; then
    pi_bin="$NODE_DIR/pi-web"
  else
    pi_bin="$(command -v pi-web 2>/dev/null || true)"
  fi
  { [ -n "$pi_bin" ] && [ -x "$pi_bin" ]; } || die "pi-web binary not found (looked in ${npm_prefix:-?}/bin, ${NODE_DIR}, PATH); confirm npm i -g @agegr/pi-web succeeded"
  if [ "$OS_KIND" = "Darwin" ]; then
    write_plist "$pi_bin"
  else
    write_systemd_unit "$pi_bin"
  fi
}

# macOS launchd plist — the SHAPE comes from the shared renderer
# (tools/_shared/lib/70-service.sh); this function only supplies pi-web's content.
write_plist() {
  local pi_bin="$1"
  mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
  # shellcheck disable=SC2086
  ENV_PAIRS="PATH=${NODE_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin HOME=${HOME} PORT=${PORT} PI_WEB_HOSTNAME=${BIND} PI_WEB_NO_OPEN=1 PI_WEB_PASSWORD=${PASSWORD}" \
    svc_render_launchd_plist "$LABEL" "$HOME" "$LOG_DIR" pi-web 10 1 1 "$NODE_BIN" "$pi_bin" --hostname "$BIND" --port "$PORT" >"$PLIST"
  plutil -lint "$PLIST" >/dev/null || die "plist syntax error: ${PLIST}"
}

# Linux systemd --user unit — same shared shape, pi-web's content
write_systemd_unit() {
  local pi_bin="$1"
  mkdir -p "$LOG_DIR" "$UNIT_DIR"
  # shellcheck disable=SC2086
  ENV_PAIRS="PATH=${NODE_DIR}:/usr/local/bin:/usr/bin:/bin HOME=${HOME} PORT=${PORT} PI_WEB_HOSTNAME=${BIND} PI_WEB_NO_OPEN=1 PI_WEB_PASSWORD=${PASSWORD}" \
    svc_render_systemd_unit user "pi-web (@agegr/pi-web local browser UI)" "$NODE_BIN" "$HOME" "$LOG_DIR" pi-web simple 10 "" \
      "After=network-online.target
Wants=network-online.target" "" "$pi_bin" --hostname "$BIND" --port "$PORT" >"$UNIT_FILE"
  systemctl --user daemon-reload
}

# ---------- status display (shared by install/status/diagnose) ----------
# Print the listeners on a TCP port; returns non-zero when none.
# lsof is absent on minimal Linux installs (measured: Alibaba Cloud Linux 4) —
# fall back to ss (iproute2). PIDs need root with ss -p; best-effort.
port_listen_lines() {
  local port="$1" out
  if command -v lsof >/dev/null 2>&1; then
    out="$(lsof -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)"
  elif command -v ss >/dev/null 2>&1; then
    out="$(ss -Htlnp "sport = :$port" 2>/dev/null)"
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

show_status() {
  resolve_password
  if [ "$OS_KIND" = "Darwin" ]; then
    if launchctl print "gui/${UID_}/${LABEL}" 2>/dev/null | grep -qE "state\s*=\s*running"; then
      launchctl print "gui/${UID_}/${LABEL}" | grep -E "^\s*(state|last exit code|program)\s*=" | head -4
    else
      warn "$LABEL is not running"
    fi
  else
    if systemctl --user is-active --quiet "$LABEL" 2>/dev/null; then
      systemctl --user status --no-pager "$LABEL" 2>/dev/null | head -8
    else
      warn "$LABEL is not running"
    fi
  fi
  echo "---"
  port_listen_lines "$PORT" || echo "[port $PORT not listening]"
  echo "---"
  curl -s -o /dev/null --max-time 3 -w "HTTP %{http_code} (pi/${PASSWORD})\n" -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" || echo "curl probe failed"
}

# Status interface (machine-readable; the manager's views render it).
# version= is the app version contract key (spec §Status template).
# Health classes align with the manager's verdict table: 2xx + 3xx + 401 =
# alive (a 307 redirect to the UI was previously mis-reported "starting").
status_info() {
  resolve_password
  local v code
  v="$(app_version)"
  [ -n "${v}" ] && echo "version=${v}"
  echo "endpoint=http://127.0.0.1:${PORT}"
  echo "credential=Username pi / password ${PASSWORD}"
  echo "log=${LOG_DIR}/pi-web.log"
  code="$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  case "${code}" in
  200 | 204 | 301 | 302 | 307 | 308 | 401)
    echo "state=ok"
    echo "health=ok (HTTP ${code}, basic auth pi)"
    ;;
  000 | "")
    echo "state=stopped"
    echo "health=stopped (no listener on :${PORT})"
    ;;
  *)
    echo "state=starting"
    echo "health=starting (HTTP ${code})"
    ;;
  esac
}

# ---------- status (the module's rich view — keyline template) ----------
render_status() {
  resolve_password
  local aver code state svc="" _pid="" _lcout
  aver="$(app_version)"
  # app-level probe: same verdict classes as the manager (redirects/401 = up;
  # the pre-2026-09 code counted only HTTP 200, mis-reporting 307 as starting)
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
  [ -z "${code}" ] && code="000"
  # service-level state + pid (platform-native — LABEL is the module's real
  # service name; profile-scoped deploys derive it: pi-web-<n>; raw launchctl /
  # lsof dumps live in the diagnose action)
  case "$(uname -s)" in
  Darwin)
    # ONE launchctl call captures pid + state (the previous shape called it
    # twice — a race window between the two reads and a wasted fork).
    # || true: without a running service launchctl exits 1 — under set -o
    # pipefail that FAILED STATUS rides the pipeline into the assignment and
    # errexit kills the whole function (live-caught on the macOS CI runner,
    # where no pi-web service exists; the dev machine's running service masked it)
    _lcout="$(launchctl print "gui/${UID_}/${LABEL}" 2>/dev/null || true)"
    _pid="$(printf '%s\n' "${_lcout}" | awk '/^[[:space:]]*pid[[:space:]]*=/{print $3; exit}')"
    if printf '%s\n' "${_lcout}" | grep -qE 'state[[:space:]]*=[[:space:]]*running'; then
      if [ "${code}" = "000" ]; then
        state="starting"
        svc="launchd running · app not answering yet${_pid:+ (pid ${_pid})}"
      else
        state="running"
        svc="launchd${_pid:+ · pid ${_pid}}"
      fi
    else
      state="stopped"
      svc="not running (aibox pi-web start)"
    fi
    ;;
  *)
    if systemctl --user is-active "${LABEL}" >/dev/null 2>&1; then
      if [ "${code}" = "000" ]; then
        state="starting"
        svc="systemd active · app not answering yet"
      else
        state="running"
        svc="systemd active"
      fi
    else
      state="stopped"
      svc="inactive (aibox pi-web start)"
    fi
    ;;
  esac
  status_header "pi-web" "${aver}" "${state}"
  status_row "service" "${svc}"
  if [ "${code}" = "000" ]; then
    status_row "endpoint" "http://127.0.0.1:${PORT} ${C_DIM:-}(stopped — aibox pi-web start)${C_RST:-}"
  else
    local mark=""
    case "${code}" in
    200 | 204 | 301 | 302 | 307 | 308 | 401) mark=" ${C_GRN:-}✓${C_RST:-}" ;;
    esac
    status_row "endpoint" "http://127.0.0.1:${PORT}${C_DIM:-} · ${C_RST:-}HTTP ${code}${mark}"
  fi
  status_row "auth" "pi / ${PASSWORD}"
  status_row "log" "${LOG_DIR}/pi-web.log"
  status_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/pi-web/"
}

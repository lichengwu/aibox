# pi-web module shared library (sourced by hooks, not executed directly)
# Extracted from the original pi-web-ctl config and shared functions.

LABEL="pi-web"
OLD_LABELS=("com.agegr.pi-web")
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

# ---------- profile ----------
# AIBOX_PROFILE defaults to "base" (exported by aibox's --profile flag).
# profile="base" → no override (PORT=30141, LABEL=pi-web, current behavior).
# profile=<name>  → hash-derived PORT (37100 range) + LABEL suffixed with profile name.
# Same profile name → same PORT/LABEL on every machine (deterministic).
# Shares the profile config ($AIBOX_HOME/profiles/<name>.conf) with base — each module
# derives its own vars from PROFILE_HASH + PROFILE_NAME in the config.

_profile_hash() {
  local name="$1" sum=0 i=0 ch
  while [ $i -lt ${#name} ]; do
    ch="${name:$i:1}"
    sum=$((sum + $(printf '%d' "'$ch") * (i + 1)))
    i=$((i + 1))
  done
  printf '%d' "$sum"
}

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
}

_profile_load() {
  [ -z "${AIBOX_PROFILE:-}" ] && return 0
  [ "$AIBOX_PROFILE" = "base" ] && return 0
  local pf="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/profiles/${AIBOX_PROFILE}.conf"
  if [ ! -f "$pf" ]; then
    _profile_create "$AIBOX_PROFILE" "$pf"
  fi
  # shellcheck disable=SC1090
  . "$pf" 2>/dev/null || {
    warn "Profile config unparseable: $pf"
    return 1
  }
  local _h="${PROFILE_HASH:-0}" _n="${PROFILE_NAME:-$AIBOX_PROFILE}"
  PORT=$((37100 + _h % 100))
  LABEL="pi-web-${_n}"
  if [ "$OS_KIND" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  else
    UNIT_FILE="${UNIT_DIR}/${LABEL}.service"
    LOG_DIR="$HOME/.local/share/${LABEL}/logs"
  fi
}

# Load profile (overrides PORT + LABEL for named profiles).
_profile_load

# ---------- access password ----------
# Priority: PI_WEB_PASSWORD env > password in the installed plist (idempotent: re-install/update
# doesn't rotate) > random on first install. Avoids a fixed weak default on a host service
# reachable from the network.
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
resolve_node() {
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
  elif [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh"
    NODE_BIN="$(command -v node || true)"
  fi

  if [ -z "${NODE_BIN:-}" ] || ! "$NODE_BIN" -v >/dev/null 2>&1; then
    warn "node not found"
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      log "Trying to install node 22 via nvm ..."
      # shellcheck disable=SC1091
      . "$HOME/.nvm/nvm.sh"
      nvm install 22
      nvm use 22 >/dev/null
      NODE_BIN="$(command -v node)"
    else
      die "Please install Node.js 22+ first (recommended: brew install nvm, then nvm install 22)"
    fi
  fi

  NODE_DIR="$(dirname "$NODE_BIN")"
  NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -lt 22 ]; then
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      log "Current node $($NODE_BIN -v) < 22, installing 22 via nvm ..."
      # shellcheck disable=SC1091
      . "$HOME/.nvm/nvm.sh"
      nvm install 22 && nvm use 22 >/dev/null
      NODE_BIN="$(command -v node)"
      NODE_DIR="$(dirname "$NODE_BIN")"
    else
      die "node version $($NODE_BIN -v) is too old, need >= 22"
    fi
  fi
  log "node: $NODE_BIN ($($NODE_BIN -v))"
  export PATH="$NODE_DIR:$PATH"
}

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
  [ -z "${latest}" ] && { : >"$out"; return 0; }
  # Stage 2 — throughput: download the very tarball npm will fetch (-L follows
  # mirror CDN redirects). A --max-time cutoff still yields a partial-download
  # rate (size_download/time_total), so throttled-but-alive registries rank honestly.
  tball="$(grep -oE '"tarball": *"[^"]+"' "$meta" 2>/dev/null | head -1 | sed -e 's/.*: *"//' -e 's/"$//')"
  speed=0
  if [ -n "${tball}" ]; then
    tstat="$(curl -sL -o /dev/null -w '%{size_download} %{time_total}' --max-time "${AIBOX_NPM_PROBE_TIMEOUT:-6}" "${tball}" 2>/dev/null || true)"
    size="${tstat%% *}"
    dtime="${tstat##* }"
    speed="$(printf '%s %s' "${size:-0}" "${dtime:-0}" \
      | awk '{t=$2+0; if (t>0) printf "%d", $1/t; else print 0}')"
  fi
  printf '%s\t%s\t%s\n' "${speed:-0}" "${reg}" "${latest}" >"$out"
  return 0
}

# Pick the npm registry for this run. Honors AIBOX_NPM_REGISTRY (hard pin, no probe)
# and adds the user's non-default `npm config get registry` to the candidates. Sets
# NPM_REGISTRY / NPM_LATEST / NPM_REGISTRY_ORDER. Dies when nothing is usable.
npm_registry_pick() {
  NPM_REGISTRY=""; NPM_LATEST=""; NPM_REGISTRY_ORDER=""
  local tmp reg f ranked user_reg pin_note=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/npm-reg.XXXXXX")" || die "mktemp failed"

  # Hard pin: single fetch, no probing, no ranking.
  if [ -n "${AIBOX_NPM_REGISTRY:-}" ]; then
    _npm_probe_one "${AIBOX_NPM_REGISTRY}" "${tmp}/pin.res"
    if [ -s "${tmp}/pin.res" ]; then
      NPM_REGISTRY="${AIBOX_NPM_REGISTRY}"
      NPM_LATEST="$(cut -f3 "${tmp}/pin.res")"
      NPM_REGISTRY_ORDER="${AIBOX_NPM_REGISTRY}"
      log "npm registry: ${AIBOX_NPM_REGISTRY} (AIBOX_NPM_REGISTRY pin)"
      rm -rf "${tmp}"
      return 0
    fi
    rm -rf "${tmp}"
    die "AIBOX_NPM_REGISTRY is unreachable (or lacks ${NPM_PACKAGE}): ${AIBOX_NPM_REGISTRY}"
  fi

  # Candidates: the user's configured registry (if non-default) first-class, plus
  # the shipped list. Same registry is not probed twice.
  user_reg="$(npm config get registry 2>/dev/null | tr -d '[:space:]' || true)"
  local cands="${AIBOX_NPM_REGISTRIES:-${NPM_REGISTRIES_CANDIDATES}}"
  if [ -n "${user_reg}" ] && [ "${user_reg}" != "${NPM_REGISTRY_DEFAULT}" ] \
    && [ "${user_reg}" != "${NPM_REGISTRY_DEFAULT}/" ] \
    && ! printf '%s' " ${cands} " | grep -qF " ${user_reg} "; then
    cands="${user_reg} ${cands}"
    pin_note=" (user .npmrc: ${user_reg} joins the probe)"
  fi

  # Parallel probes — one result file per registry.
  # shellcheck disable=SC2086
  for reg in $cands; do
    f="${tmp}/$(printf '%s' "${reg}" | tr -c 'A-Za-z0-9' '_').res"
    _npm_probe_one "${reg}" "${f}" &
  done
  wait

  # Rank: measured download throughput DESCENDING (fastest first); drop
  # candidates without a usable latest (dead / package missing).
  local sorted wline
  sorted="$(cat "${tmp}"/*.res 2>/dev/null | sort -rn)"
  rm -rf "${tmp}"
  ranked="$(printf '%s\n' "${sorted}" | awk -F'\t' 'NF==3 && $3!="" {print $2}')"
  [ -n "${ranked}" ] || die "no usable npm registry (probed: ${cands}) — network? or pin one: AIBOX_NPM_REGISTRY=<url>"
  NPM_REGISTRY_ORDER="${ranked}"

  # Winner line (speed<TAB>reg<TAB>latest): NPM_LATEST comes straight from the
  # probe — no extra fetch.
  wline="$(printf '%s\n' "${sorted}" | awk -F'\t' 'NF==3 && $3!=""' | head -1)"
  NPM_REGISTRY="$(printf '%s' "${wline}" | cut -f2)"
  NPM_LATEST="$(printf '%s' "${wline}" | cut -f3)"
  local wspeed n
  wspeed="$(printf '%s' "${wline}" | cut -f1)"
  n="$(printf '%s\n' "${ranked}" | grep -c .)"
  log "npm registry: ${NPM_REGISTRY} ($(_npm_speed_human "${wspeed}") tarball download, fastest of ${n} probed${pin_note})"
  if [ "${NPM_REGISTRY}" != "${NPM_REGISTRY_DEFAULT}" ] && [ "${NPM_REGISTRY}" != "${user_reg:-}" ]; then
    log "to pin it permanently: npm config set registry ${NPM_REGISTRY}"
  fi
  return 0
}

# Install the package globally with the picked registry + wall-clock watchdog and
# one failover per candidate (fastest-first). npm is silent in non-TTY — wall-clock
# is the only portable stall signal; a stall kills the npm process tree.
npm_install_global() {
  local timeout_s="${AIBOX_NPM_TIMEOUT:-240}" reg pid waited timed_out rc logf
  # shellcheck disable=SC2086
  for reg in $NPM_REGISTRY_ORDER; do
    [ -n "${reg}" ] || continue
    logf="$(mktemp "${TMPDIR:-/tmp}/npm-i.XXXXXX")"
    log "npm install -g ${NPM_PACKAGE}@latest --registry ${reg} (watchdog ${timeout_s}s) ..."
    npm install -g "${NPM_PACKAGE}@latest" --silent --registry "${reg}" >"${logf}" 2>&1 &
    pid=$!
    waited=0; timed_out=0
    while kill -0 "${pid}" 2>/dev/null; do
      if [ "${waited}" -ge "${timeout_s}" ]; then timed_out=1; break; fi
      sleep 2
      waited=$((waited + 2))
    done
    rc=0
    if [ "${timed_out}" = 1 ]; then
      # SIGTERM to npm FIRST (it must be pending when the child cleanup releases
      # bash/npm's foreground wait), THEN kill orphaned children — the reverse order
      # lets a shell-based process win the race and fall through to exit 0 (measured:
      # a stalled shim exited 0 because pkill released its sleep before TERM landed).
      kill "${pid}" 2>/dev/null || true
      pkill -P "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || rc=$?
      if [ "${rc}" -eq 0 ]; then
        ok "installed via ${reg} (finished as the watchdog fired)"
        rm -f "${logf}"
        return 0
      fi
      warn "npm stalled on ${reg}: no completion within ${timeout_s}s — killing and failing over"
      rm -f "${logf}"
      continue
    fi
    wait "${pid}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
      ok "installed via ${reg}"
      rm -f "${logf}"
      return 0
    fi
    warn "npm failed on ${reg} (rc=${rc}): $(tail -2 "${logf}" 2>/dev/null | tr '\n' ' ')"
    rm -f "${logf}"
  done
  die "npm install failed on every registry tried (${NPM_REGISTRY_ORDER})"
}

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

# macOS launchd plist
write_plist() {
  local pi_bin="$1"
  mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_BIN}</string>
        <string>${pi_bin}</string>
        <string>--hostname</string><string>${BIND}</string>
        <string>--port</string><string>${PORT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>${NODE_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key><string>${HOME}</string>
        <key>PORT</key><string>${PORT}</string>
        <key>PI_WEB_HOSTNAME</key><string>${BIND}</string>
        <key>PI_WEB_NO_OPEN</key><string>1</string>
        <key>PI_WEB_PASSWORD</key><string>${PASSWORD}</string>
    </dict>
    <key>WorkingDirectory</key><string>${HOME}</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOG_DIR}/pi-web.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/pi-web.err.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || die "plist syntax error: ${PLIST}"
}

# Linux systemd --user unit
write_systemd_unit() {
  local pi_bin="$1"
  mkdir -p "$LOG_DIR" "$UNIT_DIR"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=pi-web (@agegr/pi-web local browser UI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NODE_BIN} ${pi_bin} --hostname ${BIND} --port ${PORT}
Environment="PATH=${NODE_DIR}:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=${HOME}"
Environment="PORT=${PORT}"
Environment="PI_WEB_HOSTNAME=${BIND}"
Environment="PI_WEB_NO_OPEN=1"
Environment="PI_WEB_PASSWORD=${PASSWORD}"
WorkingDirectory=${HOME}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/pi-web.log
StandardError=append:${LOG_DIR}/pi-web.err.log

[Install]
WantedBy=default.target
EOF
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

# Dashboard interface (called by `aibox dashboard`): outputs endpoint/credential/log/health.
dashboard_info() {
  resolve_password
  echo "endpoint=http://127.0.0.1:${PORT}"
  echo "credential=Username pi / password ${PASSWORD}"
  echo "log=${LOG_DIR}/pi-web.log"
  echo "health=curl -s -o /dev/null -w '%{http_code}' -u pi:${PASSWORD} http://127.0.0.1:${PORT}/"
}

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  resolve_password
  printf '%s%spi-web%s %s· module %s%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${MODULE_VERSION:-1.2.1}" "${C_RST:-}"
  # service state (platform-native)
  local svc_state=""
  case "$(uname -s)" in
  Darwin)
    if launchctl list "${SERVICE_ID}" >/dev/null 2>&1; then
      svc_state="$(launchctl list "${SERVICE_ID}" 2>/dev/null | awk '{print "pid " $1}')"
    else
      svc_state="not loaded (aibox pi-web start)"
    fi
    ;;
  *)
    systemctl --user is-active "${SERVICE_ID}" >/dev/null 2>&1 && svc_state="active" || svc_state="inactive (aibox pi-web start)"
    ;;
  esac
  printf '  %s%-9s %s\n' "${C_DIM:-}" "service:" "${svc_state}"
  # health probe
  local code
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
  [ -z "${code}" ] && code="000"
  if [ "${code}" = "200" ]; then
    printf '  %s%-9s http://127.0.0.1:%s · %s✓ HTTP %s (basic auth pi)%s\n' "${C_DIM:-}" "app:" "${PORT}" "${C_GRN:-}" "${code}" "${C_RST:-}"
  else
    printf '  %s%-9s http://127.0.0.1:%s · HTTP %s\n' "${C_DIM:-}" "app:" "${PORT}" "${code}"
  fi
  printf '  %s%-9s %s\n' "${C_DIM:-}" "log:" "${LOG_DIR}/pi-web.log"
  printf '  %s%-9s %s\n' "${C_DIM:-}" "module:" "${AIBOX_HOME:-$HOME/.aibox}/modules/pi-web/"
}

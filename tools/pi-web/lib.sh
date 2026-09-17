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

# Output helpers: colors are inherited from aibox via the exported C_* env vars (single
# source of truth); ${C_*:-} falls back to empty when this lib is sourced standalone.
# Prefix uses AIBOX_MODULE (injected by aibox) with the module name as a fallback.
log() { printf '%s[%s]%s %s\n' "${C_CYA:-}" "${AIBOX_MODULE:-pi-web}" "${C_RST:-}" "${*}"; }
warn() { printf '%s[!]%s %s\n' "${C_YEL:-}" "${C_RST:-}" "${*}" >&2; }
die() {
  printf '%s[x]%s %s\n' "${C_RED:-}" "${C_RST:-}" "${*}" >&2
  exit 1
}

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
  printf '%s[?]%s %s %s ' "${C_YEL:-}" "${C_RST:-}" "$prompt" "$hint"
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
  lsof -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || echo "[port $PORT not listening]"
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

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

# ---------- output / colors (TTY + NO_COLOR aware; no leakage into pipes) ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_CYA=$'\033[36m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RST=''; C_CYA=''; C_YEL=''; C_RED=''
fi

log() { printf '%s[pi-web]%s %s\n' "$C_CYA" "$C_RST" "${*}"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "${*}" >&2; }
die() {
  printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "${*}" >&2
  exit 1
}

# ---------- access password ----------
# Priority: PI_WEB_PASSWORD env > password in the installed plist (idempotent: re-install/update
# doesn't rotate) > random on first install. Avoids a fixed weak default on a host service
# reachable from the network.
resolve_password() {
  if [ -n "${PI_WEB_PASSWORD:-}" ]; then
    PASSWORD="$PI_WEB_PASSWORD"
    return 0
  fi
  # Reuse the password in the installed plist (update/re-install keeps the same password).
  if [ -f "$PLIST" ]; then
    local prev
    prev="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_WEB_PASSWORD' "$PLIST" 2>/dev/null || true)"
    if [ -n "$prev" ]; then
      PASSWORD="$prev"
      return 0
    fi
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
  printf '%s[?]%s %s %s ' "$C_YEL" "$C_RST" "$prompt" "$hint"
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
  local pi_bin="$NODE_DIR/pi-web"
  [ ! -x "$pi_bin" ] && die "Not found: ${pi_bin}; confirm npm i -g @agegr/pi-web succeeded"
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

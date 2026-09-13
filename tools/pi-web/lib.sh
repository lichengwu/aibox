# pi-web 模块共享库（被各钩子 source，不单独执行）
# 提取自原 pi-web-ctl 的配置与共享函数。

LABEL="pi-web"
OLD_LABELS=("com.agegr.pi-web")
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"
PORT="${PI_WEB_PORT:-30141}"
PASSWORD="${PI_WEB_PASSWORD:-ai-coding}"
BIND="${PI_WEB_BIND:-0.0.0.0}"
UID_="$(id -u)"

log()  { printf '\033[36m[pi-web]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- node 探测 ----------
resolve_node() {
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
  elif [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh"
    NODE_BIN="$(command -v node || true)"
  fi

  if [ -z "${NODE_BIN:-}" ] || ! "$NODE_BIN" -v >/dev/null 2>&1; then
    warn "未检测到 node"
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      log "尝试用 nvm 安装 node 22 ..."
      # shellcheck disable=SC1091
      . "$HOME/.nvm/nvm.sh"
      nvm install 22
      nvm use 22 >/dev/null
      NODE_BIN="$(command -v node)"
    else
      die "请先安装 Node.js 22+（推荐 brew install nvm 后 nvm install 22）"
    fi
  fi

  NODE_DIR="$(dirname "$NODE_BIN")"
  NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -lt 22 ]; then
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      log "当前 node $($NODE_BIN -v) < 22，用 nvm 装 22 ..."
      # shellcheck disable=SC1091
      . "$HOME/.nvm/nvm.sh"
      nvm install 22 && nvm use 22 >/dev/null
      NODE_BIN="$(command -v node)"
      NODE_DIR="$(dirname "$NODE_BIN")"
    else
      die "node 版本 $($NODE_BIN -v) 太旧，需要 >= 22"
    fi
  fi
  log "node: $NODE_BIN ($($NODE_BIN -v))"
}

# ---------- 清理旧残留 ----------
cleanup_old() {
  local lbl old pids
  for lbl in "$LABEL" "${OLD_LABELS[@]}"; do
    launchctl bootout "gui/${UID_}/${lbl}" 2>/dev/null || true
    launchctl remove "$lbl" 2>/dev/null || true
    old="$HOME/Library/LaunchAgents/${lbl}.plist"
    if [ "$lbl" != "$LABEL" ] && [ -f "$old" ]; then
      mv -n "$old" "$HOME/.Trash/${lbl}.plist-$(date +%s)" 2>/dev/null || true
    fi
  done
  # 端口占用兜底
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
    [ -n "$pids" ] && { warn "端口 $PORT 被 $pids 占用，杀之"; echo "$pids" | xargs kill -9 2>/dev/null || true; }
  fi
  sleep 1
}

# ---------- 生成 plist ----------
write_plist() {
  local pi_bin="$NODE_DIR/pi-web"
  [ ! -x "$pi_bin" ] && die "未找到 $pi_bin，请确认 npm i -g @agegr/pi-web 已成功"
  mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
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
  plutil -lint "$PLIST" >/dev/null || die "plist 语法错误：$PLIST"
}

# ---------- 状态显示（install/status/diagnose 共用）----------
show_status() {
  if launchctl print "gui/${UID_}/${LABEL}" 2>/dev/null | grep -qE "state\s*=\s*running"; then
    launchctl print "gui/${UID_}/${LABEL}" | grep -E "^\s*(state|last exit code|program)\s*=" | head -4
  else
    warn "$LABEL 未运行"
  fi
  echo "---"
  lsof -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || echo "[端口 $PORT 未监听]"
  echo "---"
  curl -s -o /dev/null --max-time 3 -w "HTTP %{http_code}（pi/${PASSWORD}）\n" -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" || echo "curl 探测失败"
}

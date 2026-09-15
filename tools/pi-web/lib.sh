# pi-web 模块共享库（被各钩子 source，不单独执行）
# 提取自原 pi-web-ctl 的配置与共享函数。

LABEL="pi-web"
OLD_LABELS=("com.agegr.pi-web")
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"
PORT="${PI_WEB_PORT:-30141}"
PASSWORD="" # 由 resolve_password 填充（见下）；PI_WEB_PASSWORD 可覆盖
BIND="${PI_WEB_BIND:-0.0.0.0}"
UID_="$(id -u)"

log() { printf '\033[36m[pi-web]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

# ---------- 访问密码 ----------
# 优先级：PI_WEB_PASSWORD 环境变量 > 已装 plist 里的密码（幂等：重装/更新不换）
# > 首次安装随机生成。避免固定弱默认密码暴露在公网可达的本机服务上。
resolve_password() {
  if [ -n "${PI_WEB_PASSWORD:-}" ]; then
    PASSWORD="$PI_WEB_PASSWORD"
    return 0
  fi
  # 复用已装 plist 里的密码（update/重装不换密码）
  if [ -f "$PLIST" ]; then
    local prev
    prev="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_WEB_PASSWORD' "$PLIST" 2>/dev/null || true)"
    if [ -n "$prev" ]; then
      PASSWORD="$prev"
      return 0
    fi
  fi
  # 首次安装：随机生成 16 位 hex
  if command -v openssl >/dev/null 2>&1; then
    PASSWORD="$(openssl rand -hex 8 2>/dev/null || true)"
  fi
  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [ -n "$PASSWORD" ] || PASSWORD="pi-web-$(date +%s)"
}

# 软选择确认：ask_yn "<提示>" [y|n]
# 交互读 y/N；非交互（无 TTY）走默认并 warn。默认 n=拒绝、y=同意。
# 与 openmaic/windmill 的 confirm（危险操作、输入 yes）区分：本函数用于轻量选择。
ask_yn() {
  local prompt="$1" def="${2:-n}" ans hint
  if [ ! -t 0 ]; then
    warn "非交互环境，${prompt} → 默认 ${def}"
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
  printf '\033[33m[?]\033[0m %s %s ' "$prompt" "$hint"
  read -r ans || return 1
  case "$def" in
  y | Y) case "$ans" in [nN]*) return 1 ;; *) return 0 ;; esac ;;
  *) case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

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
  export PATH="$NODE_DIR:$PATH"
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
    [ -n "$pids" ] && {
      warn "端口 $PORT 被 $pids 占用，杀之"
      echo "$pids" | xargs kill -9 2>/dev/null || true
    }
  fi
  sleep 1
}

# ---------- 生成 plist ----------
write_plist() {
  local pi_bin="$NODE_DIR/pi-web"
  [ ! -x "$pi_bin" ] && die "未找到 ${pi_bin}，请确认 npm i -g @agegr/pi-web 已成功"
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
  plutil -lint "$PLIST" >/dev/null || die "plist 语法错误：$PLIST"
}

# ---------- 状态显示（install/status/diagnose 共用）----------
show_status() {
  resolve_password
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

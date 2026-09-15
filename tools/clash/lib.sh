# clash 模块共享库（被各钩子 source，不单独执行）
#
# 编排本地 mihomo 内核：订阅拉取 / 测速 / 切换全部交给 mihomo，本模块只管
# 下载二进制、生成 config、启停进程、刷新兜底、向 aibox 暴露本地混合端口。
#
# 为什么不自解析订阅 yaml：mihomo 的 proxy-providers 原生吃订阅 URL，自己
# 拉取 + 解析 + 定时刷新；url-test/fallback 组自动测速选最快 + 失败切换。
# aibox 不重复造轮子，只编排。

CLI_NAME="clash"
KERNEL_NAME="mihomo"

# mihomo 二进制落点
CLASH_BIN_DIR="${CLASH_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
KERNEL_DEST="${CLASH_BIN_DIR}/${KERNEL_NAME}"

# 默认端口（可被 state 覆盖）
CLASH_PORT="${CLASH_PORT:-7890}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"

log() { printf '\033[36m[clash]\033[0m %s\n' "${*}"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "${*}" >&2; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "${*}" >&2
  exit 1
}
mask_url() { printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'; }

# ---------- 部署根 / 落点（module-spec 部署型约定）----------
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

# ---------- 平台 / 版本 / 下载 ----------
detect_asset() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
  x86_64 | amd64) arch="amd64" ;;
  arm64 | aarch64) arch="arm64" ;;
  i386 | i686) arch="386" ;;
  armv7l) arch="armv7" ;;
  *) die "不支持的架构: $(uname -m)（手动下载见 https://github.com/MetaCubeX/mihomo/releases）" ;;
  esac
  printf 'mihomo-%s-%s' "$os" "$arch"
}

latest_mihomo_tag() {
  curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null |
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
  [ -n "$ver" ] || die "无法获取 mihomo 最新版本（网络？代理？aibox proxy set 配代理后重试）"
  asset="$(detect_asset)-v${ver}.gz"
  url="https://github.com/MetaCubeX/mihomo/releases/download/v${ver}/${asset}"
  log "下载 mihomo v${ver} -> ${asset}"
  mkdir -p "${CLASH_BIN_DIR}"
  tmp="${KERNEL_DEST}.gz"
  curl -fsSL "$url" -o "$tmp" || die "下载失败：${url}"
  gunzip -f "$tmp" || die "解压失败（mihomo .gz）"
  chmod 0755 "${KERNEL_DEST}"
  "${KERNEL_DEST}" -v >/dev/null 2>&1 || die "下载的二进制无法运行（架构不匹配？）"
  log "已放置 mihomo v${ver} -> ${KERNEL_DEST}"
}

# ---------- state（订阅 URL / secret / 端口 / 上次刷新 / 内核版本）----------
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
# clash 模块状态（由 aibox clash 维护，含订阅 token，权限 600）
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

# ---------- config 生成（heredoc 模板，注入订阅 / secret / 端口）----------
gen_config() {
  mkdir -p "$(clash_deploy_root)" "$(providers_dir)" "$(log_dir)"
  # 不解析订阅 yaml：直接写进 proxy-providers，mihomo 全权拉取/解析/测速/切换
  cat >"$(config_file)" <<EOF
# 由 aibox clash 生成（勿手编，会被 aibox clash set/refresh 覆盖）
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

# ---------- mihomo 进程（nohup + pid，跨平台简单常驻）----------
kernel_running() {
  [ -f "$(pid_file)" ] || return 1
  local pid
  pid="$(cat "$(pid_file)" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_kernel() {
  kernel_running && {
    log "mihomo 已在运行（pid $(cat "$(pid_file)")）"
    return 0
  }
  [ -x "${KERNEL_DEST}" ] || die "mihomo 未安装（先: aibox install clash）"
  [ -f "$(config_file)" ] || die "无 config（先: aibox clash set <订阅URL>）"
  state_load
  [ -n "${SUB_URL:-}" ] || die "未配置订阅（先: aibox clash set <订阅URL>）"
  log "启动 mihomo ..."
  nohup "${KERNEL_DEST}" -d "$(clash_deploy_root)" -f "$(config_file)" \
    >"$(log_dir)/mihomo.log" 2>&1 &
  echo $! >"$(pid_file)"
  sleep 1
  if kernel_running; then
    log "mihomo 已启动（pid $(cat "$(pid_file)")，混合端口 ${CLASH_PORT}）"
    # 标记启用：aibox apply_proxy 见 CLASH_ENABLED=1 即把出口指向本地端口
    state_write "${SUB_URL}" "${CLASH_SECRET}" "1" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  else
    rm -f "$(pid_file)"
    die "mihomo 启动失败，见日志: $(log_dir)/mihomo.log"
  fi
}

stop_kernel() {
  kernel_running || {
    log "mihomo 未运行"
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
  log "mihomo 已停止（aibox 出口已回退到静态代理或直连）"
}

# ---------- mihomo REST API（external-controller）----------
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
    log "已重载 config" || warn "重载失败（mihomo 未运行？）"
}

# 让 mihomo 立即拉取订阅（跳过缓存）
refresh_providers() {
  api_put '/providers/proxies/pool' '{"path":"pool","force":true}' >/dev/null 2>&1 || true
}

# ---------- 订阅刷新（>1 周兜底：用时发现过期自动重拉）----------
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
    log "订阅缓存已超 1 周（或从未刷新），重新拉取 ..."
    refresh_now
  fi
}

# 强制刷新：aibox 兜底自己 curl 订阅覆盖 pool.yaml + 触发 mihomo reload
refresh_now() {
  state_load
  [ -n "${SUB_URL:-}" ] || die "未配置订阅（先: aibox clash set <订阅URL>）"
  log "拉取订阅 $(mask_url "${SUB_URL}") ..."
  if curl -fsSL --max-time 30 "${SUB_URL}" -o "$(providers_dir)/pool.yaml.tmp" 2>/dev/null; then
    mv "$(providers_dir)/pool.yaml.tmp" "$(providers_dir)/pool.yaml"
    log "已更新 $(providers_dir)/pool.yaml"
  else
    warn "aibox 侧订阅拉取失败，交给 mihomo 内部 interval 重试"
  fi
  if kernel_running; then
    reload_config
    refresh_providers
  fi
  state_write "${SUB_URL}" "${CLASH_SECRET}" "${CLASH_ENABLED}" "${CLASH_PORT}" "${CLASH_API_PORT}" "$(date +%s)" "${KERNEL_TAG:-}"
  log "刷新完成"
}

# ---------- 状态查询 ----------
show_status() {
  state_load
  if kernel_running; then
    log "mihomo 运行中（pid $(cat "$(pid_file)")）"
    log "混合端口   127.0.0.1:${CLASH_PORT}"
    log "API        127.0.0.1:${CLASH_API_PORT}"
    [ -n "${SUB_URL:-}" ] && log "订阅       $(mask_url "${SUB_URL}")"
    [ -n "${KERNEL_TAG:-}" ] && log "内核版本   v${KERNEL_TAG}"
    log "上次刷新   ${LAST_REFRESH:-从未}"
    local auto cur
    auto="$(api_get /proxies/AUTO 2>/dev/null || true)"
    if [ -n "$auto" ]; then
      cur="$(printf '%s' "$auto" | grep -oE '"now":[[:space:]]*"[^"]*"' | sed 's/.*: *"//; s/"$//')"
      log "当前节点   ${cur:-未选定}"
    fi
  else
    warn "mihomo 未运行"
    [ -n "${SUB_URL:-}" ] && log "订阅       $(mask_url "${SUB_URL}")（已配置，aibox clash on 启动）"
    return 1
  fi
}

# ---------- 经本地端口探测 ----------
probe_via_clash() {
  local url code used out
  url="${1:-https://www.gstatic.com/generate_204}"
  out="$(curl -s --max-time 8 -x "socks5://127.0.0.1:${CLASH_PORT}" \
    -o /dev/null -w '%{http_code} %{proxy_used}' "$url" 2>/dev/null)" || out=""
  [ -n "$out" ] || out="000 0"
  code="${out%% *}"
  used="${out##* }"
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    log "经 mihomo    ${code}（proxy_used=${used}）"
  else
    warn "经 mihomo    ${code}（代理可能不可用）"
  fi
}

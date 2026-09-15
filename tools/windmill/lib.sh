# windmill 模块共享库（被各钩子 source，不单独执行）

CLI_NAME="windmill"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SRC="${MODULE_DIR}/${CLI_NAME}"

# 安装落点。优先 WINDMILL_BIN_DIR（部署主机上常要 /usr/local/bin），
# 其次 AIBOX_BIN_DIR（须被 export 才可见），最后 ~/.local/bin。
WINDMILL_BIN_DIR="${WINDMILL_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
CLI_DEST="${WINDMILL_BIN_DIR}/${CLI_NAME}"

log() { printf '\033[36m[windmill]\033[0m %s\n' "${*}"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "${*}" >&2; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "${*}" >&2
  exit 1
}

# 随模块下发的 CLI 版本号
cli_version() {
  if [ ! -f "${CLI_SRC}" ]; then
    printf 'unknown'
    return 0
  fi
  sed -nE 's/^WINDMILL_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_SRC}" | head -1
}

# 已安装副本的版本号；未安装则返回 1
installed_version() {
  if [ ! -f "${CLI_DEST}" ]; then
    return 1
  fi
  sed -nE 's/^WINDMILL_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_DEST}" | head -1
}

# 语法检查。CLI 兼容 bash 3.2（module-spec 踩坑 #2），本机可直接检查。
check_syntax() {
  local f="${1}"
  bash -n "${f}" || die "语法检查失败：${f}"
}

do_install() {
  if [ ! -f "${CLI_SRC}" ]; then
    die "模块内找不到 CLI：${CLI_SRC}（可执行 aibox update windmill 重新拉取）"
  fi
  check_syntax "${CLI_SRC}"
  mkdir -p "${WINDMILL_BIN_DIR}"
  install -m 0755 "${CLI_SRC}" "${CLI_DEST}"
  log "已放置 windmill $(cli_version) -> ${CLI_DEST}"
  # 播种主机级配置（/etc/windmill/windmill.conf，只补不覆盖）
  seed_conf
}

ensure_path() {
  case ":${PATH}:" in
  *":${WINDMILL_BIN_DIR}:"*) ;;
  *)
    warn "${WINDMILL_BIN_DIR} 不在 PATH 中"
    log "  请将其加入 PATH，或改用: WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill"
    ;;
  esac
}

# 双平台提示：CLI 主体命令需 docker；macOS 上 launchd 定时任务尚未适配
host_notice() {
  if [ "$(uname -s)" = "Linux" ]; then
    return 0
  fi
  echo
  warn "当前系统 $(uname -s)：CLI 可运行；定时任务用 launchd（aibox windmill systemd install）"
  log "  部署主机上安装: WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill"
}

# 脱敏：http://user:pass@host:port -> http://user:***@host:port
mask_url() {
  printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

# 播种主机级配置 /etc/windmill/windmill.conf（module-spec：《部署目录与配置落点约定》）
# 键白名单与 CLI 的 wm_conf_load 一致：PROXY_URL / WM_GHCR_MIRROR / WM_HUB_MIRROR / HTTP_PORT。
# 策略只补不覆盖；写 /etc 需要特权 —— Linux 部署主机上通常就是 root；无权限则提示后跳过。
seed_conf() {
  # 注意：bash 3.2 下 `local a="x" b="${a}/y"` 同行引用会触发 unbound（AGENTS.md 踩坑家族），
  # 必须拆成两行。
  local conf_dir="/etc/windmill"
  local conf="${conf_dir}/windmill.conf"
  local seeded=0

  if [ ! -d "${conf_dir}" ]; then
    mkdir -p "${conf_dir}" 2>/dev/null || {
      warn "无法创建 ${conf_dir}（需特权）—— 跳过配置播种，CLI 将走内置默认"
      return 0
    }
  fi
  [ -w "${conf_dir}" ] || {
    warn "${conf_dir} 不可写 —— 跳过配置播种，CLI 将走内置默认"
    return 0
  }

  _conf_set() {
    # $1=键 $2=值；已存在（非注释）则不动
    local k="$1" v="$2"
    [ -n "${v}" ] || return 0
    if grep -qE "^${k}=" "${conf}" 2>/dev/null; then
      return 0
    fi
    printf '%s=%s\n' "${k}" "${v}" >>"${conf}"
    seeded=1
  }

  if [ ! -f "${conf}" ]; then
    printf '# windmill 主机级配置（由 aibox install windmill 播种；CLI 只读）\n# 键: PROXY_URL / WM_GHCR_MIRROR / WM_HUB_MIRROR / HTTP_PORT\n' >"${conf}"
  fi
  # 代理：aibox 全局代理下发（跨时间/跨主机边界必须落盘）
  if [ -n "${AIBOX_PROXY_URL:-}" ] && [ "${AIBOX_PROXY_ENABLED:-0}" = "1" ]; then
    _conf_set PROXY_URL "${AIBOX_PROXY_URL}"
  fi
  # 镜像源：留给运维手配（国内网络差异大，不自动猜）
  if [ "${seeded}" = "1" ]; then
    log "已播种 ${conf}（代理 $(mask_url "${AIBOX_PROXY_URL:-}")）"
  else
    log "${conf} 已存在，未做改动（只补不覆盖）"
  fi
  chmod 0644 "${conf}" 2>/dev/null || true
}

# 部署根提示用（与 CLI 内同一表达式；仅提示，可回退）
wm_deploy_root() {
  local base="${AIBOX_APPS_ROOT:-}"
  if [ -z "${base}" ]; then
    base="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/windmill' "${base}"
}

# Dashboard 接口（aibox dashboard 调用）：输出 endpoint/credential/health
dashboard_info() {
  echo "endpoint=http://127.0.0.1:8080"
  echo "credential=CREDENTIALS.txt + .env（POSTGRES_PASSWORD）"
  echo "health=curl -s http://127.0.0.1:8080"
}

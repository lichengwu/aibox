# openmaic 模块共享库（被各钩子 source，不单独执行）

CLI_NAME="openmaic"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SRC="${MODULE_DIR}/${CLI_NAME}"

# 安装落点。优先 OPENMAIC_BIN_DIR（部署主机上常要 /usr/local/bin），
# 其次 AIBOX_BIN_DIR（须被 export 才可见），最后 ~/.local/bin。
OPENMAIC_BIN_DIR="${OPENMAIC_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
CLI_DEST="${OPENMAIC_BIN_DIR}/${CLI_NAME}"

log() { printf '\033[36m[openmaic]\033[0m %s\n' "${*}"; }
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
  sed -nE 's/^OPENMAIC_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_SRC}" | head -1
}

# 已安装副本的版本号；未安装则返回 1
installed_version() {
  if [ ! -f "${CLI_DEST}" ]; then
    return 1
  fi
  sed -nE 's/^OPENMAIC_CLI_VERSION="([^"]+)".*/\1/p' "${CLI_DEST}" | head -1
}

# 语法检查。CLI 面向 Linux bash 5；macOS 自带 3.2 会对其中的
# bash 4 特性误报，因此低版本直接跳过而不是给出假失败。
check_syntax() {
  local f="${1}" maj
  maj="${BASH_VERSINFO[0]:-3}"
  if [ "${maj}" -lt 4 ]; then
    warn "本机 bash ${BASH_VERSION} 低于 4.0，跳过语法检查（目标环境为 Linux bash 5）"
    return 0
  fi
  bash -n "${f}" || die "语法检查失败：${f}"
}

do_install() {
  if [ ! -f "${CLI_SRC}" ]; then
    die "模块内找不到 CLI：${CLI_SRC}（可执行 aibox update openmaic 重新拉取）"
  fi
  check_syntax "${CLI_SRC}"
  mkdir -p "${OPENMAIC_BIN_DIR}"
  install -m 0755 "${CLI_SRC}" "${CLI_DEST}"
  log "已放置 openmaic $(cli_version) -> ${CLI_DEST}"
  # 顺带把 aibox 的代理下发进 OpenMAIC 自身的配置（原因见 sync_proxy_to_conf）
  sync_proxy_to_conf
}

ensure_path() {
  case ":${PATH}:" in
  *":${OPENMAIC_BIN_DIR}:"*) ;;
  *)
    warn "${OPENMAIC_BIN_DIR} 不在 PATH 中"
    log "  请将其加入 PATH，或改用: OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic"
    ;;
  esac
}

# 无 docker 时说明清楚：服务类命令需 docker
host_notice() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo
  warn "未检测到 docker —— openmaic 的服务类命令（up/install/upgrade/backup 等）会拒绝执行"
  log "  本机可用: openmaic help / version / doctor"
  log "  装 docker: aibox install openmaic 自动检查依赖"
}

# 脱敏：http://user:pass@host:port -> http://user:***@host:port
mask_url() {
  printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

# 把 aibox 的代理下发到 OpenMAIC 自己的配置文件（第 3 层持久化）。
#
# 为什么必须落盘：openmaic CLI 会在部署主机上、在 aibox 完全不在场时执行
# `openmaic upgrade` 去拉 GitHub 源码 —— 环境变量跨不了这个时间与主机边界，
# 只能写进它自己的配置文件才带得过去。
#
# 只在部署主机（Linux）上做；未配置代理时什么都不动。
sync_proxy_to_conf() {
  local conf="/etc/openmaic/openmaic.conf" conf_dir cur
  [ -n "${AIBOX_PROXY_URL:-}" ] || return 0
  [ "${AIBOX_PROXY_ENABLED:-0}" = "1" ] || return 0

  conf_dir="$(dirname "${conf}")"
  if [ ! -d "${conf_dir}" ]; then
    mkdir -p "${conf_dir}" 2>/dev/null || {
      warn "无法创建 ${conf_dir}（需特权）—— 跳过代理下发，CLI 将走内置默认"
      return 0
    }
  fi
  [ -w "${conf_dir}" ] || {
    warn "${conf_dir} 不可写 —— 跳过代理下发，CLI 将走内置默认"
    return 0
  }

  if [ ! -f "${conf}" ]; then
    cat >"${conf}" <<EOF
# OpenMAIC CLI 配置（由 aibox 安装 openmaic 模块时创建）
# 其余键留空即用内置默认值，键名见 openmaic help。

# 源码拉取代理（由 aibox proxy set 下发）
OPENMAIC_PROXY_URL="${AIBOX_PROXY_URL}"
EOF
    log "已创建 ${conf} 并写入代理 $(mask_url "${AIBOX_PROXY_URL}")"
    return 0
  fi

  cur=$(sed -nE 's/^OPENMAIC_PROXY_URL="?([^"]*)"?$/\1/p' "${conf}" | head -1)
  if [ "${cur}" = "${AIBOX_PROXY_URL}" ]; then
    log "代理已在 ${conf} 中（$(mask_url "${cur}")），无需改动"
    return 0
  fi

  cp -a "${conf}" "${conf}.bak-$(date +%Y%m%d-%H%M%S)"
  if grep -q '^OPENMAIC_PROXY_URL=' "${conf}"; then
    # 用 awk 替换：URL 里可能含 / 与 & 之类，sed 需要额外转义，容易出错
    awk -v v="${AIBOX_PROXY_URL}" \
      '/^OPENMAIC_PROXY_URL=/{print "OPENMAIC_PROXY_URL=\"" v "\""; next} {print}' \
      "${conf}" >"${conf}.tmp" && mv "${conf}.tmp" "${conf}"
  else
    printf '\n# 由 aibox 下发（aibox proxy set）\nOPENMAIC_PROXY_URL="%s"\n' "${AIBOX_PROXY_URL}" >>"${conf}"
  fi
  log "已下发代理到 ${conf}：$(mask_url "${AIBOX_PROXY_URL}")"
  log "  之后在部署主机上执行的 openmaic upgrade 会自动用它拉源码"
}

# 部署根提示用（与 CLI 内同一表达式；仅提示，可回退）
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

# Dashboard 接口（aibox dashboard 调用）：输出 endpoint/credential/health
dashboard_info() {
  echo "endpoint=http://127.0.0.1:3000"
  echo "credential=.env.local（API Key、访问密码）"
  echo "health=curl -s http://127.0.0.1:3000/api/health"
}

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

# 非 Linux 上说明清楚：CLI 的服务类命令需要部署主机环境
host_notice() {
  if [ "$(uname -s)" = "Linux" ]; then
    return 0
  fi
  echo
  warn "当前系统 $(uname -s) 不是部署主机 —— openmaic 的服务类命令会拒绝执行"
  log "  本机可用: openmaic help / version / doctor"
  log "  部署主机上安装: OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic"
}

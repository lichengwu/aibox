#!/usr/bin/env bash
# aibox 一键安装（bootstrap）
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
# 环境变量:
#   AIBOX_BRANCH  (默认 main)   指定分支
#   AIBOX_BIN_DIR (默认 ~/.local/bin) 主 CLI 安装目录
# 幂等：可重复执行，也用于 `aibox self update`。
set -euo pipefail

REPO="lichengwu/aibox"
BRANCH="${AIBOX_BRANCH:-main}"
RAW="${AIBOX_RAW:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
BIN_DIR="${AIBOX_BIN_DIR:-$HOME/.local/bin}"
HOME_DIR="${AIBOX_HOME:-$HOME/.aibox}"

log()  { printf '\033[36m[aibox]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

log "从 ${REPO}@${BRANCH} 安装 aibox ..."

command -v curl >/dev/null 2>&1 || die "需要 curl（macOS 自带）"

mkdir -p "$BIN_DIR" "$HOME_DIR"

log "下载 bin/aibox -> $BIN_DIR/aibox"
curl -fsSL "$RAW/bin/aibox" -o "$BIN_DIR/aibox"
chmod 0755 "$BIN_DIR/aibox"

# PATH 检查 & 自动写入
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
  warn "$BIN_DIR 不在当前 PATH"
  shell_rc=
  case "${SHELL##*/}" in
    zsh)  shell_rc="$HOME/.zshrc" ;;
    bash) shell_rc="$HOME/.bashrc" ;;
    *)    shell_rc="$HOME/.profile" ;;
  esac
  if [ -f "$shell_rc" ] && grep -q '\.local/bin' "$shell_rc"; then
    log "$shell_rc 已含 ~/.local/bin，重开 shell 或 source 后生效"
  else
    printf '\n# aibox\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$shell_rc"
    log "已追加 PATH 到 $shell_rc，执行: source $shell_rc 或重开终端"
  fi
fi

log "完成。现在可执行: aibox help"
log "装首个模块: aibox install pi-web"

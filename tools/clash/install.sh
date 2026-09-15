#!/usr/bin/env bash
# clash 模块 — 安装钩子：下载 mihomo 内核 + 播种部署根
# 订阅由 aibox clash set 配，不在此步。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

log "安装 clash 模块（mihomo 内核）..."
if [ -x "${KERNEL_DEST}" ]; then
  log "mihomo 已存在: ${KERNEL_DEST} ($(installed_kernel_version || echo 未知))"
else
  download_mihomo
fi

# 播种部署根 + 空 state（secret 现生成；订阅/启用待 clash set / clash on）
mkdir -p "$(clash_deploy_root)" "$(providers_dir)" "$(log_dir)"
if [ ! -f "$(state_file)" ]; then
  tag="$(latest_mihomo_tag || echo "")"
  state_write "" "$(gen_secret)" "0" "${CLASH_PORT}" "${CLASH_API_PORT}" "0" "${tag}"
fi

echo
log "落点   : ${KERNEL_DEST}"
log "部署根 : $(clash_deploy_root)"
log "下一步 : aibox clash set <订阅URL>  然后  aibox clash on"

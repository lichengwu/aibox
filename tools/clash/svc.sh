#!/usr/bin/env bash
# clash 模块 — 服务动作钩子
# 管 mihomo 进程（nohup+pid，跨平台简单常驻）+ 调 mihomo REST API。
# aibox clash <action> [args] 透传到这里。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
state_load

case "$action" in
start | on)
  start_kernel
  echo
  log "aibox 出口已切到本地 mihomo（socks5://127.0.0.1:${CLASH_PORT}）"
  ;;
stop | off)
  stop_kernel
  ;;
restart)
  stop_kernel
  start_kernel
  ;;
status)
  show_status
  ;;
refresh)
  refresh_now
  ;;
set)
  [ $# -ge 1 ] || die "用法: aibox clash set <订阅URL>"
  sub="$1"
  shift
  [ -n "${CLASH_SECRET:-}" ] || CLASH_SECRET="$(gen_secret)"
  SUB_URL="$sub"
  gen_config
  state_write "$sub" "${CLASH_SECRET}" "${CLASH_ENABLED:-0}" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  log "已保存订阅 $(mask_url "$sub")"
  log "已生成 $(config_file)"
  if kernel_running; then
    reload_config
    refresh_providers
  fi
  # 先拉一次订阅填 pool.yaml（mihomo 未启时也备好，启动即用）。
  # 不静默：失败要让用户看到——冷启动时订阅站可能需要先配静态代理。
  refresh_now || true
  log "启用: aibox clash on"
  ;;
select)
  [ $# -ge 1 ] || die "用法: aibox clash select <节点名>"
  api_put "/proxies/AUTO" "{\"name\":\"$1\"}" >/dev/null 2>&1 &&
    log "已切到 $1" || die "切换失败（mihomo 未运行或节点不存在）"
  ;;
test)
  probe_via_clash "${1:-}"
  ;;
logs)
  tail -f "$(log_dir)/mihomo.log"
  ;;
doctor)
  echo "== mihomo =="
  if [ -x "${KERNEL_DEST}" ]; then
    log "二进制: ${KERNEL_DEST} ($(installed_kernel_version || echo 未知))"
  else
    warn "未安装（aibox install clash）"
  fi
  echo "== 进程 =="
  if kernel_running; then
    log "运行中（pid $(cat "$(pid_file)")）"
  else
    warn "未运行（aibox clash on）"
  fi
  echo "== config =="
  if [ -f "$(config_file)" ]; then
    log "$(config_file)"
  else
    warn "无 config（先: aibox clash set <订阅URL>）"
  fi
  echo "== 订阅 =="
  [ -n "${SUB_URL:-}" ] && log "$(mask_url "${SUB_URL}")" || warn "未配置"
  [ -f "$(providers_dir)/pool.yaml" ] && log "pool.yaml 已缓存" || warn "pool.yaml 未缓存"
  ;;
*)
  die "用法: aibox clash {start|stop|restart|status|refresh|set <url>|select <node>|test [url]|logs|doctor}"
  ;;
esac

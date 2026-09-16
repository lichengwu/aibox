#!/usr/bin/env bash
# clash module — service action hook.
# Manages the mihomo process (nohup+pid, simple cross-platform daemon) + calls the mihomo REST API.
# `aibox clash <action> [args]` is forwarded here.
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
  log "aibox egress switched to local mihomo (socks5://127.0.0.1:${CLASH_PORT})"
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
  [ $# -ge 1 ] || die "Usage: aibox clash set <subscription-url>"
  sub="$1"
  shift
  [ -n "${CLASH_SECRET:-}" ] || CLASH_SECRET="$(gen_secret)"
  SUB_URL="$sub"
  gen_config
  state_write "$sub" "${CLASH_SECRET}" "${CLASH_ENABLED:-0}" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  log "Saved subscription $(mask_url "$sub")"
  log "Generated $(config_file)"
  if kernel_running; then
    reload_config
    refresh_providers
  fi
  # Pull the subscription once to fill pool.yaml (ready even if mihomo isn't running yet, so it's
  # usable on start). Not silent: a failure must be visible — at cold start the subscription site
  # may need a static proxy first.
  refresh_now || true
  log "Enable: aibox clash on"
  ;;
select)
  [ $# -ge 1 ] || die "Usage: aibox clash select <node-name>"
  api_put "/proxies/AUTO" "{\"name\":\"$1\"}" >/dev/null 2>&1 &&
    log "Switched to $1" || die "Switch failed (mihomo not running or node doesn't exist)"
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
    log "binary: ${KERNEL_DEST} ($(installed_kernel_version || echo unknown))"
  else
    warn "not installed (aibox install clash)"
  fi
  echo "== process =="
  if kernel_running; then
    log "running (pid $(cat "$(pid_file)"))"
  else
    warn "not running (aibox clash on)"
  fi
  echo "== config =="
  if [ -f "$(config_file)" ]; then
    log "$(config_file)"
  else
    warn "no config (first: aibox clash set <subscription-url>)"
  fi
  echo "== subscription =="
  [ -n "${SUB_URL:-}" ] && log "$(mask_url "${SUB_URL}")" || warn "not configured"
  [ -f "$(providers_dir)/pool.yaml" ] && log "pool.yaml cached" || warn "pool.yaml not cached"
  ;;
*)
  die "Usage: aibox clash {start|stop|restart|status|refresh|set <url>|select <node>|test [url]|logs|doctor}"
  ;;
esac

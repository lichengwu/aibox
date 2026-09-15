#!/usr/bin/env bash
# base 模块 — 服务动作钩子
# aibox base <action> 透传到这里。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
case "$action" in
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_stop; cmd_start ;;
  status)   cmd_status ;;
  createdb) [ $# -ge 1 ] || die "用法: aibox base createdb <module> [用途]"
            cmd_createdb "$@" ;;
  *)        die "用法: aibox base {start|stop|restart|status|createdb <module> [用途]}" ;;
esac

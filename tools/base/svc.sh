#!/usr/bin/env bash
# base module — service action hook.
# `aibox base <action>` is forwarded here.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
case "$action" in
start) cmd_start ;;
stop) cmd_stop ;;
restart)
  cmd_stop
  cmd_start
  ;;
status) cmd_status ;;
logs)
  ensure_compose
  compose logs -f
  ;;
createdb)
  [ $# -ge 1 ] || die "Usage: aibox base createdb <module> [usage]"
  cmd_createdb "$@"
  ;;
*) die "Usage: aibox base {start|stop|restart|status|logs|createdb <module> [usage]}" ;;
esac

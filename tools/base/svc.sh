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
# dashboard is an alias of status (merged 2026-09: one "show state" verb —
# operational facts + the rich view; the manager-level aibox dashboard stays separate)
status|dashboard)
  cmd_status
  render_dashboard
  ;;
logs)
  ensure_compose
  compose logs -f
  ;;
create)
  [ $# -ge 2 ] || die "Usage: aibox base create <component> <resource> [usage]"
  _create "$1" "$2" "${3:-}"
  ;;
createdb)
  warn "'createdb' is deprecated; use 'create postgres <name>'"
  [ $# -ge 1 ] || die "Usage: aibox base createdb <module> [usage] (deprecated)"
  _create postgres "$1" "${2:-}"
  ;;
profile)
  _profile_list
  ;;
*) die "unknown action: ${action:-} — run: aibox base --help" ;;
esac

#!/usr/bin/env bash
# pi-web module — update hook
# Logic:
#   1. Check whether @agegr/pi-web has a newer version (installed vs latest).
#      - No update  -> do nothing, don't restart (regardless of --restart/--no-restart).
#      - Update     -> upgrade + rewrite plist, then decide whether to restart.
#   2. Restart decision (only when there's an update):
#      --restart       restart directly, no prompt
#      --no-restart    don't restart even if updated
#      (empty)         interactive prompt [Y/n]; non-interactive defaults to no restart.
# Args: $1 = --restart | --no-restart | (empty)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

restart_arg="${1:-}"

resolve_node

# npm_registry_pick probes the candidates in parallel (curl-bounded) and also
# yields NPM_LATEST — this REPLACES `npm view`, which hits the registry with no
# timeout and hangs on stalled networks.
npm_registry_pick

cur="$(npm ls -g @agegr/pi-web --depth=0 2>/dev/null | grep -oE '@agegr/pi-web@[0-9][0-9.]*' | head -1 | sed 's/.*@//' || true)"
latest="${NPM_LATEST}"

if [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" = "$latest" ]; then
  log "@agegr/pi-web is already latest ($latest); no update, no restart"
  exit 0
fi

log "Upgrading @agegr/pi-web ${cur:-not installed} -> ${latest:-latest} ..."
npm_install_global
cleanup_old
resolve_password
write_service

# ---------- decide whether to restart ----------
do_restart=""
case "$restart_arg" in
--restart) do_restart=1 ;;
--no-restart) do_restart=0 ;;
"")
  if ask_yn "Update done; restart the pi-web service?" y; then
    do_restart=1
  else
    do_restart=0
  fi
  ;;
*) die "Unknown arg: ${restart_arg} (available: --restart | --no-restart)" ;;
esac

if [ "$do_restart" = "1" ]; then
  if [ "$OS_KIND" = "Darwin" ]; then
    if launchctl print "gui/${UID_}/${LABEL}" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/${UID_}/${LABEL}"
    else
      launchctl bootstrap "gui/${UID_}" "$PLIST"
    fi
  else
    if systemctl --user is-active --quiet "$LABEL" 2>/dev/null; then
      systemctl --user restart "$LABEL"
    else
      [ -f "$UNIT_FILE" ] || die "${UNIT_FILE} does not exist; run: aibox install pi-web"
      loginctl enable-linger "${UID_}" 2>/dev/null || true
      systemctl --user start "$LABEL"
    fi
  fi
  sleep 3
  show_status
  log "pi-web updated and restarted"
else
  log "Updated but not restarted. Restart later: aibox pi-web restart (or auto-start on boot)"
fi

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

# Update the pi CLI itself alongside pi-web (best-effort, never fatal):
# `pi update --all` = pi + all its installed extensions — the web UI rides on
# the same agent runtime, so `aibox update pi-web` is the natural moment to
# refresh it. Watchdog-bounded like npm_install_global (pi's updater shells
# out to npm — the same silent-stall class in non-TTY runs).
pi_update_cli() {
  if ! command -v pi >/dev/null 2>&1; then
    warn "pi CLI not found in PATH — skipped its update"
    return 0
  fi
  local timeout_s="${PI_WEB_PI_UPDATE_TIMEOUT:-240}" pid waited timed_out rc logf
  logf="$(mktemp "${TMPDIR:-/tmp}/pi-upd.XXXXXX")"
  log "pi update --all (watchdog ${timeout_s}s) ..."
  pi update --all >"${logf}" 2>&1 &
  pid=$!
  waited=0
  timed_out=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${timeout_s}" ]; then
      timed_out=1
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  rc=0
  if [ "${timed_out}" = "1" ]; then
    # children FIRST, then the parent: a generic (untrapped) child shell dies
    # instantly on TERM and bash reaps the zombie before a follow-up `pkill -P`
    # can run — the orphaned `sleep` reparents to init and survives (live-caught
    # as a 300s pipe-holding orphan). With the parent still alive during pkill,
    # ppid is intact and the strays die reliably.
    pkill -P "${pid}" 2>/dev/null || true
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || rc=$?
    if [ "${rc}" -eq 0 ]; then
      ok "pi updated (finished as the watchdog fired)"
    else
      warn "pi update --all stalled: no completion within ${timeout_s}s — killed"
    fi
    rm -f "${logf}"
    return 0
  fi
  wait "${pid}" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    ok "pi updated"
  else
    warn "pi update --all failed (rc=${rc}): $(tail -2 "${logf}" 2>/dev/null | tr '\n' ' ')"
  fi
  rm -f "${logf}"
  return 0
}

resolve_node

# npm_registry_pick probes the candidates in parallel (curl-bounded) and also
# yields NPM_LATEST — this REPLACES `npm view`, which hits the registry with no
# timeout and hangs on stalled networks.
npm_registry_pick

cur="$(npm ls -g @agegr/pi-web --depth=0 2>/dev/null | grep -oE '@agegr/pi-web@[0-9][0-9.]*' | head -1 | sed 's/.*@//' || true)"
latest="${NPM_LATEST}"

if [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" = "$latest" ]; then
  log "@agegr/pi-web is already latest ($latest); no update, no restart"
  # the "incidental" pi refresh runs on the no-op path too — `aibox update
  # pi-web` keeps the agent fresh even when its web UI was already latest
  pi_update_cli
  exit 0
fi

log "Upgrading @agegr/pi-web ${cur:-not installed} -> ${latest:-latest} ..."
npm_install_global
# after the pi-web upgrade: refresh the agent runtime it serves (a failed
# pi-web upgrade must not side-effect pi — that's why this comes after)
pi_update_cli
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

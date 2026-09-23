#!/usr/bin/env bash
# pi-web module — service ops hook (equivalent to the original pi-web-ctl start|stop|restart|status|logs|diagnose)
# Usage: aibox pi-web <action>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
case "$action" in
start)
  if [ "$OS_KIND" = "Darwin" ]; then
    [ ! -f "$PLIST" ] && die "$PLIST does not exist; run: aibox install pi-web"
    launchctl bootstrap "gui/${UID_}" "$PLIST" 2>/dev/null || launchctl kickstart -k "gui/${UID_}/${LABEL}"
  else
    [ ! -f "$UNIT_FILE" ] && die "${UNIT_FILE} does not exist; run: aibox install pi-web"
    loginctl enable-linger "${UID_}" 2>/dev/null || true
    systemctl --user start "$LABEL"
  fi
  sleep 2
  show_status
  ;;
stop)
  if [ "$OS_KIND" = "Darwin" ]; then
    launchctl bootout "gui/${UID_}/${LABEL}" 2>/dev/null || true
  else
    systemctl --user stop "$LABEL" 2>/dev/null || true
  fi
  log "stopped"
  ;;
restart)
  # APPLIES CONFIG CHANGES (as the usage line promises): bootout + bootstrap
  # re-READS the plist/unit file. The old kickstart -k only restarted the
  # process with the already-loaded definition — config changes made via
  # `config set` (which rewrites the file) silently did not apply.
  if [ "$OS_KIND" = "Darwin" ]; then
    [ -f "$PLIST" ] || die "$PLIST does not exist; run: aibox install pi-web"
    launchctl bootout "gui/${UID_}/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/${UID_}" "$PLIST"
    ok "restarted (service definition re-read: ${PLIST})"
  else
    [ -f "$UNIT_FILE" ] || die "${UNIT_FILE} does not exist; run: aibox install pi-web"
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart "$LABEL"
    ok "restarted (unit re-read: ${UNIT_FILE})"
  fi
  sleep 3
  show_status
  ;;
# dashboard is an alias of status (merged 2026-09: one "show state" verb —
# operational facts + the rich view; the manager-level aibox dashboard stays separate)
# config: the plist/unit EnvironmentVariables IS the store (spec §Configuration).
# set regenerates the service definition (write_service — the single writer,
# seeded from the STORE: env vars are install-time seeds only) and offers the
# restart, which now re-reads the definition.
config)
  case "${1:-}" in
  "" | list)
    # NOTE: case branches are not functions — no `local` here
    k=""
    def=""
    cur=""
    shown=""
    while IFS="$(printf '\t')" read -r k def desc flags; do
      [ -n "${k}" ] || continue
      case " ${flags} " in *" knob "*) continue ;; esac
      cur="$(_store_get "${k}")"
      if [ -n "${cur}" ]; then
        if cfg_secret_p "${k}" || case " ${flags} " in *" secret "*) true ;; *) false ;; esac then
          shown="$(cfg_mask)"
        else
          shown="${cur}"
        fi
        printf '  %-18s %-16s %s\n' "${k}" "${shown}" "${desc}"
      else
        printf '  %-18s %-16s %s\n' "${k}" "(default: ${def})" "${desc}"
      fi
    done < <(cfg_env_declare "${DIR}/module.yaml")
    log "apply changes: aibox pi-web restart (re-reads the service definition)"
    ;;
  get)
    [ -n "${2:-}" ] || die "usage: aibox pi-web config get <KEY>"
    _store_get "${2}"
    ;;
  set)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: aibox pi-web config set <KEY> <VALUE>"
    # seed the lib vars from the STORE (the truth), then override the target —
    # write_service regenerates the whole definition from these.
    BIND="$(_store_get PI_WEB_BIND)"
    [ -n "${BIND}" ] || BIND="${PI_WEB_BIND:-0.0.0.0}"
    PORT="$(_store_get PI_WEB_PORT)"
    [ -n "${PORT}" ] || PORT="${PI_WEB_PORT:-30141}"
    PASSWORD="$(_store_get PI_WEB_PASSWORD)"
    case "${2}" in
    PI_WEB_BIND) BIND="${3}" ;;
    PI_WEB_PORT) PORT="${3}" ;;
    PI_WEB_PASSWORD) PASSWORD="${3}" ;;
    *) die "unknown key: ${2} (keys: aibox pi-web --help)" ;;
    esac
    resolve_node
    # BIND/PORT/PASSWORD are lib.sh globals that write_service renders into the
    # service definition; exporting makes the cross-function flow explicit.
    export BIND PORT PASSWORD
    write_service
    ok "set ${2} (service definition regenerated)"
    if [ -t 0 ] && cfg_confirm_apply; then
      # re-dispatch restart via the module itself
      bash "${0}" restart
    else
      log "apply when ready: aibox pi-web restart"
    fi
    ;;
  unset)
    [ -n "${2:-}" ] || die "usage: aibox pi-web config unset <KEY>"
    def="$(cfg_env_declare "${DIR}/module.yaml" | awk -F'\t' -v k="${2}" '$1==k{print $2}')"
    [ -n "${def}" ] || die "unknown key: ${2}"
    case "${def}" in
    random | auto* | generated)
      # re-generating secrets on unset: drop to a fresh random
      case "${2}" in
      PI_WEB_PASSWORD) PASSWORD="" resolve_password ;;
      *) : ;;
      esac
      ;;
    *) : ;;
    esac
    # simplest honest semantics: unset = set to the declared default
    exec bash "${0}" config set "${2}" "${def}"
    ;;
  *)
    die "usage: aibox pi-web config [get|set|unset] [KEY] [VALUE]"
    ;;
  esac
  ;;
status | dashboard)
  show_status
  render_dashboard
  ;;
logs)
  tail -f "$LOG_DIR/pi-web.log" "$LOG_DIR/pi-web.err.log"
  ;;
diagnose)
  echo "== node =="
  command -v node && node -v || echo "no node in PATH"
  [ -s "$HOME/.nvm/nvm.sh" ] && echo "nvm: yes" || echo "nvm: no"
  echo "== unit =="
  if [ "$OS_KIND" = "Darwin" ]; then
    [ -f "$PLIST" ] && plutil -lint "$PLIST" && cat "$PLIST" || echo "no plist"
    echo "== launchctl print =="
    launchctl print "gui/${UID_}/${LABEL}" 2>&1 | head -30 || true
  else
    [ -f "$UNIT_FILE" ] && cat "$UNIT_FILE" || echo "no unit"
    echo "== systemctl status =="
    systemctl --user status --no-pager "$LABEL" 2>&1 | head -30 || true
  fi
  echo "== stderr tail =="
  tail -20 "$LOG_DIR/pi-web.err.log" 2>/dev/null || echo "no err log"
  echo "== port =="
  port_listen_lines "$PORT" || echo "not listening"
  ;;
*)
  die "unknown action: ${action:-} — run: aibox pi-web --help"
  ;;
esac

#!/usr/bin/env bash
# pi-web module — service ops hook (equivalent to the original pi-web-ctl start|stop|restart|status|logs|diagnose)
# Usage: aibox pi-web <action>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

# ---------- launchd error surfacing (measured on macOS 27.0.1) ----------
# launchctl's CLI error text is not to be trusted. A bootstrap of an
# already-loaded label is internally errno 37 ("Operation already in
# progress"), yet the CLI prints "Bootstrap failed: 5: Input/output error"
# and hints "re-run the command as root" — both misleading. The same EIO-5
# text also shows when the gui domain is missing (an SSH session while the
# user has no console login). The old stop/restart swallowed bootout failures
# (`2>/dev/null || true`), so the follow-up bootstrap died with that raw text
# and the hook had nothing actionable to say (live-caught 2026-10-29:
# `aibox pi-web restart` → "Bootstrap failed: 5: Input/output error",
# service untouched and still running). Keep launchctl's stderr VISIBLE and
# translate EIO into its two real meanings.
_launchd_bootout() { # → 0 label unloaded or was never loaded; 1 failed (warn'd)
  local rc msg
  rc=0
  msg="$(launchctl bootout "gui/${UID_}/${LABEL}" 2>&1)" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    return 0
  fi
  # "not loaded" is a legitimate state for stop/restart (fresh login domain);
  # the MESSAGE is the reliable signal, not the errno (see above).
  case "${msg}" in
  *"No such process"* | *"Could not find service"*) return 0 ;;
  esac
  warn "launchctl bootout failed (rc=${rc}): ${msg}"
  return 1
}

_launchd_hint() { # $1 = the aibox command to re-run from a real session
  printf '%s\n' \
    "on macOS this launchctl error text is misleading: EIO (5) means either" \
    "  - the ${LABEL} label is still registered in launchd (the bootout above did not take" \
    "    effect; the old instance keeps running — KeepAlive never dropped it), or" \
    "  - the gui/${UID_} domain is missing: an SSH session while this user has no console" \
    "    login — run '${1}' from the logged-in user's Terminal instead." \
    "check the real state: aibox pi-web status"
}

action="${1:-status}"
[ $# -gt 0 ] && shift
case "$action" in
start)
  if [ "$OS_KIND" = "Darwin" ]; then
    [ ! -f "$PLIST" ] && die "$PLIST does not exist; run: aibox install pi-web"
    # bootstrap when not loaded; kickstart -k when loaded (start semantics:
    # make it run — unlike restart, no definition re-read). BOTH failing is
    # the EIO family — translate instead of dying with launchctl's raw text.
    launchctl bootstrap "gui/${UID_}" "$PLIST" 2>/dev/null ||
      launchctl kickstart -k "gui/${UID_}/${LABEL}" ||
      die "start failed (bootstrap and kickstart both failed)
$(_launchd_hint 'aibox pi-web start')"
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
    # A failed bootout is NOT "stopped": the label stays registered and the
    # process keeps running (KeepAlive). The old `2>/dev/null || true` +
    # unconditional `log "stopped"` reported success over a failure — the
    # same family as restart's swallowed EIO (see _launchd_bootout).
    if _launchd_bootout; then
      log "stopped"
    else
      die "stop failed — the ${LABEL} service may still be running
$(_launchd_hint 'aibox pi-web stop')"
    fi
  else
    systemctl --user stop "$LABEL" 2>/dev/null || true
    log "stopped"
  fi
  ;;
restart)
  # APPLIES CONFIG CHANGES (as the usage line promises): bootout + bootstrap
  # re-READS the plist/unit file. The old kickstart -k only restarted the
  # process with the already-loaded definition — config changes made via
  # `config set` (which rewrites the file) silently did not apply.
  if [ "$OS_KIND" = "Darwin" ]; then
    [ -f "$PLIST" ] || die "$PLIST does not exist; run: aibox install pi-web"
    # bootout first; a real failure leaves the label loaded and the bootstrap
    # below then fails with launchctl's misleading EIO (see _launchd_bootout).
    _launchd_bootout || warn "the old definition stays loaded — trying bootstrap anyway"
    lc_rc=0
    lc_msg="$(launchctl bootstrap "gui/${UID_}" "$PLIST" 2>&1)" || lc_rc=$?
    if [ "${lc_rc}" -eq 5 ]; then
      # bootout's teardown is asynchronous: a bootstrap racing the job removal
      # also gets EIO-5. One bounded retry absorbs the race; a stuck label
      # fails again and falls through to the translated error below.
      sleep 1
      lc_rc=0
      lc_msg="$(launchctl bootstrap "gui/${UID_}" "$PLIST" 2>&1)" || lc_rc=$?
    fi
    if [ "${lc_rc}" -eq 0 ]; then
      ok "restarted (service definition re-read: ${PLIST})"
    else
      die "restart failed (launchctl bootstrap rc=${lc_rc}): ${lc_msg}
$(_launchd_hint 'aibox pi-web restart')"
    fi
  else
    [ -f "$UNIT_FILE" ] || die "${UNIT_FILE} does not exist; run: aibox install pi-web"
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart "$LABEL"
    ok "restarted (unit re-read: ${UNIT_FILE})"
  fi
  sleep 3
  show_status
  ;;
# status is an alias of status — ONE merged "show state" verb, now the
# keyline rich view only: it carries the service state + pid, endpoint + HTTP
# verdict, auth, log, module row. Raw launchctl/systemctl/lsof dumps live in
# `diagnose` (they were interleaved above the rich view before — 精修 removes
# the raw noise from the human view).
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
    *) usage_die "unknown key: ${2} (keys: aibox pi-web --help)" ;;
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
    [ -n "${def}" ] || usage_die "unknown key: ${2}"
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
status)
  render_status
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
doctor)
  module_doctor "pi-web"
  ;;
*)
  usage_die "unknown action: ${action:-} — run: aibox pi-web --help"
  ;;
esac

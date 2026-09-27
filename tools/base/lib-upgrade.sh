# ---------- base upgrade / dump / restore surface ----------
# Split out of lib.sh (D3): the upgrade path is its own domain. Sourced by lib.sh
# from the cache layout first (the same resolution _common.sh uses).

cmd_upgrade() {
  local check=0 to_pg="" to_redis="" do_rollback=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)    check=1; shift ;;
      --pg)       to_pg="${2:-}";    [ -n "${to_pg}" ]    || usage_die "base upgrade --pg needs an image tag (e.g. postgres:19)"; shift 2 ;;
      --redis)    to_redis="${2:-}"; [ -n "${to_redis}" ] || usage_die "base upgrade --redis needs an image tag (e.g. redis:8)"; shift 2 ;;
      --rollback) do_rollback=1; shift ;;
      --yes|-y)   shift ;;   # accepted for symmetry; base's gates are non-interactive
      -h|--help)  usage_die "usage: aibox base upgrade [--check | --pg <tag> | --redis <tag> | --rollback]" ;;
      *)          usage_die "unknown option for base upgrade: $1" ;;
    esac
  done
  ensure_compose
  resolve_secrets
  local pin cur_pg cur_redis rb
  pin="$(pin_file)"
  cur_pg="$(_pin_get AIBOX_BASE_PG_IMAGE "${pin}")"
  [ -n "${cur_pg}" ] || cur_pg="$(_pin_default_from_compose AIBOX_BASE_PG_IMAGE)"
  cur_redis="$(_pin_get AIBOX_BASE_REDIS_IMAGE "${pin}")"
  [ -n "${cur_redis}" ] || cur_redis="$(_pin_default_from_compose AIBOX_BASE_REDIS_IMAGE)"

  if [ "${do_rollback}" = "1" ]; then
    local from bak
    from="$(_state_get from)"; bak="$(_state_get envbak)"
    [ -n "${from}" ] || die "no rollback point recorded — pin explicitly: aibox base upgrade --pg <tag>"
    [ -n "${bak}" ] && [ -f "${bak}" ] || die "the recorded pin backup is gone (${bak})"
    cp "${bak}" "${pin}"
    _state_log "pins rolled back to ${from} (by user)"
    if cmd_start; then
      _state_set status rolled-back
      ok "rolled back to ${from} — healthy"
      return 0
    fi
    _state_set status manual
    warn "rollback applied but the stack is not healthy — inspect: aibox base logs"
    return 20
  fi

  if [ "${check}" = "1" ]; then
    log "postgres : ${cur_pg}${to_pg:+ → ${to_pg}}"
    log "redis    : ${cur_redis}${to_redis:+ → ${to_redis}}"
    rb="$(_state_get from)"
    [ -n "${rb}" ] && log "rollback : ${rb} (recorded)   apply: aibox upgrade base --rollback"
    warn "PG MAJOR upgrades are one-way and can make the existing volume unreadable — a full dump"
    warn "  is taken automatically before any switch (standalone: aibox base dump)"
    log "note     : the pins live in $(pin_file); module updates never overwrite that file"
    return 0
  fi

  [ -n "${to_pg}${to_redis}" ] || usage_die "usage: aibox base upgrade [--check | --pg <tag> | --redis <tag> | --rollback]"

  local ts bak dump from_desc to_desc
  ts="$(date +%Y%m%d%H%M%S)"
  bak="${pin}.bak.${ts}.$$"
  mkdir -p "$(dirname "${pin}")"
  [ -f "${pin}" ] || printf '# base image pins — written by `aibox base upgrade`; the compose reads ${AIBOX_BASE_*_IMAGE} from here\n' >"${pin}"
  cp "${pin}" "${bak}"
  from_desc="pg=${cur_pg} redis=${cur_redis}"
  to_desc="pg=${to_pg:-$cur_pg} redis=${to_redis:-$cur_redis}"
  log "1/4 dump before the switch (${from_desc} → ${to_desc}) …"
  dump=""
  if stack_running; then
    dump="$(_dump_to_file preupgrade)"
    if [ -n "${dump}" ]; then ok "   dump: ${dump}"; else warn "   dump failed — continuing (a rollback would be pin-only)"; fi
  else
    log "   stack is down — no dump needed (an image switch does not touch the volumes)"
  fi
  log "2/4 pinning …"
  [ -n "${to_pg}" ]    && _pin_set AIBOX_BASE_PG_IMAGE "${to_pg}" "${pin}"
  [ -n "${to_redis}" ] && _pin_set AIBOX_BASE_REDIS_IMAGE "${to_redis}" "${pin}"
  _state_set ts "${ts}"; _state_set from "${from_desc}"; _state_set to "${to_desc}"
  _state_set envbak "${bak}"; _state_set databak "${dump}"; _state_set status started
  _state_log "${from_desc} → ${to_desc} started${dump:+ (dump ${dump})}"
  log "3/4 recreating with the new images (health gate) …"
  if cmd_start; then
    _state_set status ok
    _state_log "${from_desc} → ${to_desc} ok"
    ok "base upgraded (${to_desc})"
    [ -n "${dump}" ] && log "  data dump kept: ${dump}"
    log "  rollback point: aibox upgrade base --rollback"
    return 0
  fi
  warn "4/4 the new images did not come up — rolling the pins back"
  cp "${bak}" "${pin}"
  if cmd_start; then
    _state_set status rolled-back
    _state_log "${from_desc} → ${to_desc} rolled-back"
    warn "rolled back to ${from_desc} (healthy) — inspect: aibox base logs"
    return 10
  fi
  _state_set status manual
  _state_log "${from_desc} → ${to_desc} rollback-failed"
  warn "manual intervention needed — the rollback did not come up either"
  log "  inspect : aibox base logs"
  log "  pins    : ${pin} (backup: ${bak})"
  [ -n "${dump}" ] && log "  data    : gunzip -c ${dump} | docker exec -i ${POSTGRES_CONTAINER} psql -U ${PG_USER} -d postgres"
  return 20
}

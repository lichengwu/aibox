#!/usr/bin/env bash
# new-api module — service ops hook: aibox new-api <action> [args]
# Actions: start | stop | restart | status | logs | credentials
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
load_env

# The shared base is a hard prerequisite (module.yaml services:): the compose
# joins the EXTERNAL aibox-base network and reads base.env — a missing network
# makes `compose up` fail with an opaque "network not found".
_ensure_base() {
  local base_env net
  base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
  net="$(grep -E '^AIBOX_BASE_NETWORK=' "${base_env}" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "${net}" ] || net="aibox-base"
  if [ ! -f "${base_env}" ] || ! docker network inspect "${net}" >/dev/null 2>&1; then
    die "shared base not running (compose needs the external network ${net}) — first: aibox base start"
  fi
}

case "${action}" in
dashboard) render_dashboard ;;
start)
  _ensure_base
  # docker.io source pool: bounded direct probe (healthy → compose pulls
  # direct, zero overhead); direct dead → ranked mirror pre-pull + tag.
  # shellcheck disable=SC2046
  docker_pool_prepull $(compose_images) || true
  compose up -d "$@"
  port="$(effective_port)"
  timeout_s="${NEW_API_START_TIMEOUT:-120}"
  waited=0
  log "waiting for the api to answer on :${port} (timeout ${timeout_s}s)…"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if api_up "${port}"; then
      ok "new-api is up: http://127.0.0.1:${port}"
      log "First login: root / 123456 — change it immediately (top-right user → personal settings)"
      exit 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then
      log "  still waiting (${waited}s) — try 'aibox ${MODULE_NAME} logs' if stalled"
    fi
  done
  warn "api did not answer on :${port} within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  exit 1
  ;;
stop)
  compose stop "$@"
  ok "stopped (data volumes untouched)"
  ;;
restart)
  # up -d (recreate), NOT `compose restart`: env-file/image changes only apply
  # on recreate — plain restart would silently ignore .env edits (docker semantics).
  _ensure_base
  # shellcheck disable=SC2046
  docker_pool_prepull $(compose_images) || true
  compose up -d --remove-orphans "$@"
  port="$(effective_port)"
  log "recreated; waiting for the api on :${port}…"
  waited=0
  timeout_s="${NEW_API_START_TIMEOUT:-120}"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if api_up "${port}"; then ok "new-api is up: http://127.0.0.1:${port}"; exit 0; fi
    sleep 5
    waited=$((waited + 5))
  done
  warn "api did not answer within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  exit 1
  ;;
status)
  compose ps
  port="$(effective_port)"
  if container_running; then
    if api_up "${port}"; then
      ok "api answers: http://127.0.0.1:${port}"
    else
      warn "container up but api not answering on :${port} yet (first boot runs migrations)"
    fi
    log "db/redis: shared base (PG database new_api + Redis via base.env)"
  else
    warn "no container running (start: aibox ${MODULE_NAME} start)"
  fi
  ;;
logs)
  compose logs --tail "${NEW_API_LOG_TAIL:-200}" "$@"
  ;;
credentials)
  ok "first login: root / 123456 (change it immediately after the first login)"
  info "SESSION_SECRET (session signing) lives in $(deploy_root)/.env (mode 600)"
  info "channel tokens/keys are managed in the web console (stored in the shared PG new_api database)"
  ;;
*)
  die "unknown action: ${action:-} — run: aibox new-api --help"
  ;;
esac

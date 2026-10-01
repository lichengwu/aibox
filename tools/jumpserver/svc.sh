#!/usr/bin/env bash
# jumpserver module — service ops hook: aibox jumpserver <action> [args]
# Actions: start | stop | restart | status | logs | credentials | config | doctor
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
load_env

# The shared base is a hard prerequisite (module.yaml services:): core/celery
# join the EXTERNAL aibox-base network and read base.env. Started HERE when it
# is down — a start must ensure its own deps (spec §Shared library includes).
_ensure_base() {
  require_docker
  ensure_shared_base
  base_env_check || die "shared base env is unusable — see the hint above"
}

# Bounded wait for the full chain (web nginx + core api): first boot runs
# Django migrations (measured live ≈ 11 min on a 4-core arm64 host — upstream's
# own CONTAINER_HEALTH_TIMEOUT=300 covers only the DB containers; core's
# healthcheck start_period is 90s). Default 900s.
_wait_health() {
  local port waited timeout_s
  port="$(effective_web_port)"
  timeout_s="${JUMPSERVER_START_TIMEOUT:-900}"
  waited=0
  log "waiting for jumpserver on :${port} (first boot runs migrations; timeout ${timeout_s}s)…"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if api_health_up "${port}"; then
      ok "api healthy: http://127.0.0.1:${port}/api/health/"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then
      log "  still booting (${waited}s) — try 'aibox ${MODULE_NAME} logs core' if stalled"
    fi
  done
  warn "jumpserver did not become healthy within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  return 1
}

_up() {
  _ensure_base
  # the module's resources on the shared base (idempotent; the PG database was
  # created by the manager's ensure_services at install — re-ensure for the
  # by-hand / redeployed cases)
  ensure_shared_db "${MODULE_NAME}" || true
  # 4-wide Redis slot range (celery/cache/session/ws) — see install.sh
  ensure_shared_redis_db "${MODULE_NAME}" "${JUMPSERVER_REDIS_SLOTS}" || true
  # remap the four Redis DBs onto our allocated range (exports for compose)
  _redis_db_remap
  # docker.io source pool: bounded direct daemon probe (healthy → compose
  # pulls direct, zero overhead); dead route → ranked mirror pre-pull + tag.
  # shellcheck disable=SC2046
  images_pool_prepull $(compose_images) || true
  compose up -d --remove-orphans
  _wait_health || exit 1
  ok "jumpserver is up: http://127.0.0.1:$(effective_web_port) · ssh -p $(effective_ssh_port) admin@<host>"
  log "Login     : admin / ChangeMe (change at first login)"
  return 0
}

# Full container cycle (upstream jmsctl's restart semantics): `down` WITHOUT
# -v (named data volumes survive a plain down; -v would DELETE them), then the
# normal bring-up. Why not `up -d` alone: a PARTIAL recreate (core/celery
# recreated while web is not — e.g. a rotated SECRET_KEY) leaves the web nginx
# proxying to core's DEAD old IP (nginx resolves upstream DNS once at config
# load) — every /api/ request 502s until web itself restarts (measured live).
# The full cycle re-resolves everything.
_full_cycle() {
  compose down --remove-orphans
  _up
}

case "${action}" in
start)
  _up
  ;;
stop)
  compose stop "$@"
  ok "stopped (data volumes untouched)"
  ;;
restart)
  # Full cycle (down WITHOUT -v — data volumes survive; see _full_cycle): env
  # and image changes only apply on recreate, and a partial recreate leaves the
  # web nginx 502-ing on core's dead IP (measured — see _full_cycle).
  _full_cycle
  ;;
# config: the deploy .env is the store (spec §Configuration).
config)
  ROOT="$(deploy_root)"
  CFG_YAML="${DIR}/module.yaml" \
    CFG_STORE="${ROOT}/.env" \
    CFG_APPLY="aibox jumpserver restart" \
    cfg_action "$@"
  ;;
status)
  compose ps
  wport="$(effective_web_port)"
  if stack_running; then
    if api_health_up "${wport}" && core_healthy; then
      ok "api answers: http://127.0.0.1:${wport}/api/health/ · core healthy"
    elif web_up "${wport}"; then
      warn "web up but core still booting (first boot runs migrations, 2-6 min)"
    else
      warn "containers up but not answering yet — aibox ${MODULE_NAME} logs"
    fi
    log "db: shared base PG (jumpserver) + redis logical DBs ${JUMPSERVER_REDIS_DB_CELERY:-3}-${JUMPSERVER_REDIS_DB_WS:-6}"
  else
    warn "stack not running (start: aibox ${MODULE_NAME} start)"
  fi
  render_status
  ;;
logs)
  compose logs --tail "${JUMPSERVER_LOG_TAIL:-200}" "$@"
  ;;
credentials)
  ok "web console : admin / ChangeMe (JumpServer's built-in default — change it at first login, 控制台右上角 → 个人信息)"
  info "ssh terminal: ssh -p $(effective_ssh_port) admin@<host> (same account)"
  info "SECRET_KEY + BOOTSTRAP_TOKEN: $(deploy_root)/.env (mode 600; generated at install, never rotated by aibox)"
  info "PG/Redis     : shared base — view: aibox status base"
  info "reset the admin password: 控制台 → 系统设置 → 用户 → admin, or inside the core container:"
  info "  docker exec -it ${CORE_CONTAINER} /opt/jumpserver/.venv/bin/python /opt/jumpserver/apps/manage.py changepassword admin"
  ;;
doctor)
  module_doctor "jumpserver"
  ;;
*)
  usage_die "unknown action: ${action:-} — run: aibox jumpserver --help"
  ;;
esac

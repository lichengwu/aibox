#!/usr/bin/env bash
# dify module — service ops hook: aibox dify <action> [args]
# Actions: start | stop | restart | status | logs | credentials
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
load_env

case "${action}" in
start)
  # DIFY_SHARED_BASE=1 joins the shared base: ensure it is UP before the compose
  # renders the shared override + --env-file (down → auto-start; the old flow
  # died with "base.env is missing — run: aibox base start", two commands for
  # one intent).
  if shared_base_enabled; then
    ensure_shared_base
  fi
  # docker.io source pool: bounded direct probe (healthy → compose pulls direct,
  # zero overhead); direct dead → ranked mirror pre-pull + tag (see lib.sh).
  # shellcheck disable=SC2046
  docker_pool_prepull $(compose_images) || true
  compose up -d "$@"
  port="$(effective_port)"
  timeout_s="${DIFY_START_TIMEOUT:-300}"
  waited=0
  log "waiting for dify to boot (first boot 1-2 min; timeout ${timeout_s}s)…"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if http_up "${port}"; then
      ok "dify is up: http://127.0.0.1:${port}"
      log "Login    : admin — first-visit password: aibox ${MODULE_NAME} credentials"
      exit 0
    fi
    sleep 10
    waited=$((waited + 10))
    if [ $((waited % 60)) -eq 0 ]; then
      log "  still booting (${waited}s) — try 'aibox ${MODULE_NAME} logs' if stalled"
    fi
  done
  warn "dify did not answer on :${port} within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  exit 1
  ;;
stop)
  compose stop "$@"
  ok "stopped (data volumes untouched)"
  ;;
restart)
  # up -d (recreate), NOT `compose restart`: env-file/image changes only apply
  # on recreate — plain restart would silently ignore .env edits (docker semantics).
  compose up -d --remove-orphans "$@"
  port="$(effective_port)"
  log "restarted; waiting for web on :${port}…"
  waited=0
  timeout_s="${DIFY_START_TIMEOUT:-300}"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if http_up "${port}"; then
      ok "dify is up: http://127.0.0.1:${port}"
      exit 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  warn "dify did not answer within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  exit 1
  ;;
# dashboard is an alias of status (merged 2026-09: one "show state" verb —
# operational facts + the rich view; the manager-level aibox dashboard stays separate)
# config: the deploy .env is the store (spec §Configuration).
config)
  ROOT="$(deploy_root)"
  CFG_YAML="${DIR}/module.yaml" \
    CFG_STORE="${ROOT}/.env" \
    CFG_APPLY="aibox dify restart" \
    cfg_action "$@"
  ;;
status | dashboard)
  compose ps
  port="$(effective_port)"
  if containers_running 2>/dev/null; then
    if http_up "${port}"; then
      ok "web answers: http://127.0.0.1:${port}"
    else
      warn "web not answering on :${port} yet (first boot takes 1-2 min)"
    fi
    if shared_base_enabled; then
      log "db/redis: shared base (see base.env)"
    fi
  else
    warn "no dify containers running (start: aibox ${MODULE_NAME} start)"
  fi
  render_dashboard
  ;;
logs)
  compose logs --tail "${DIFY_LOG_TAIL:-200}" "$@"
  ;;
credentials)
  # load_env already sourced .env above; INIT_PASSWORD/SECRET_KEY are in-scope.
  if [ -n "${INIT_PASSWORD:-}" ]; then
    ok "admin first-visit password : ${INIT_PASSWORD}"
    log "  (set this on first browser visit to /install; it is NOT reusable as a login password)"
  else
    warn "INIT_PASSWORD not set in $(deploy_root)/.env — dify may have already been initialized"
  fi
  if [ -n "${SECRET_KEY:-}" ]; then
    log "SECRET_KEY (session signing) : ${SECRET_KEY:0:8}… (full value in .env)"
  fi
  warn "credentials live in $(deploy_root)/.env (mode 600) — treat as secrets"
  ;;
doctor)
  module_doctor "dify"
  ;;
*)
  usage_die "unknown action: ${action:-} — run: aibox dify --help"
  ;;
esac

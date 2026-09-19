#!/usr/bin/env bash
# xiaozhi module — service ops hook: aibox xiaozhi <action> [args]
# Actions: start | stop | restart | status | logs | credentials | secret <value>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
load_env

# The shared base is a hard prerequisite (module.yaml services:): the web
# service joins the EXTERNAL aibox-base network and reads base.env — a missing
# network makes `compose up` fail with an opaque "network not found".
_ensure_base() {
  local base_env net
  base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
  net="$(grep -E '^AIBOX_BASE_NETWORK=' "${base_env}" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "${net}" ] || net="aibox-base"
  if [ ! -f "${base_env}" ] || ! docker network inspect "${net}" >/dev/null 2>&1; then
    die "shared base not running (compose needs the external network ${net}) — first: aibox base start"
  fi
}

# Auto-apply the generated server.secret: the Java manager-api GENERATES it at
# first boot (MySQL sys_params) while the Python server REFUSES to boot with an
# empty one (measured crash-loop). Unless the user already set one, fetch it
# from MySQL and write data/.config.yaml. BOUNDED RETRY: the console HTTP check
# passes as soon as nginx answers — BEFORE the Java finishes Liquibase + secret
# generation (measured live on the deploy host: first probe found sys_params
# empty while the secret landed ~1 min later).
_auto_secret() {
  local cur val waited=0 timeout_s
  cur="$(grep -A3 '^manager-api:' "$(config_file)" 2>/dev/null | sed -n 's/.*secret:[[:space:]]*//p' | tr -d '"')"
  if [ -n "${cur}" ] && [ "${cur}" != '""' ]; then
    log "server.secret already set (kept)"
    return 0
  fi
  timeout_s="${XIAOZHI_SECRET_TIMEOUT:-120}"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if val="$(_fetch_secret)"; then
      _write_secret "${val}"
      ok "server.secret auto-applied from the console (MySQL sys_params; ${waited}s)"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  warn "server.secret not fetchable within ${timeout_s}s — the server may crash-loop until it lands"
  warn "manual path: console 参数管理 → server.secret, then: aibox ${MODULE_NAME} secret <value>"
}

# Bounded wait for the console (nginx → Java) to answer HTTP. First boot runs
# MySQL init + Liquibase migrations — allow minutes.
_wait_console() {
  local port waited timeout_s
  port="${1}"
  timeout_s="${XIAOZHI_START_TIMEOUT:-300}"
  waited=0
  log "waiting for the console on :${port} (first boot runs migrations; timeout ${timeout_s}s)…"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if console_up "${port}"; then
      ok "console up: http://127.0.0.1:${port}"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then
      log "  still booting (${waited}s) — try 'aibox ${MODULE_NAME} logs' if stalled"
    fi
  done
  warn "console did not answer within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  return 1
}

# Bounded wait for the ws server to listen (TCP probe — a websocket endpoint
# cannot be health-checked with plain HTTP).
_wait_ws() {
  local port waited timeout_s
  port="${1}"
  timeout_s="${XIAOZHI_START_TIMEOUT:-300}"
  waited=0
  log "waiting for the ws server on :${port}…"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if ws_listening "${port}"; then
      ok "ws server listening on :${port}"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  warn "ws server did not listen within ${timeout_s}s — inspect: aibox ${MODULE_NAME} logs"
  return 1
}

# Staged bring-up: mysql + web first (the Java manager-api GENERATES
# server.secret at first boot), auto-apply the secret, THEN the server (it
# refuses to boot with an empty secret — upstream contract, measured live).
_staged_up() {
  local cport wport
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  # Stage 1: infrastructure + console.
  compose up -d xiaozhi-mysql xiaozhi-web
  _wait_console "${cport}" || return 1
  # Stage 2: the generated secret (idempotent — keeps a user-set value).
  _auto_secret
  # Stage 3: the ws server.
  compose up -d xiaozhi-server
  _wait_ws "${wport}" || return 1
  ok "xiaozhi is up: console http://127.0.0.1:${cport} · ws://127.0.0.1:${wport}/xiaozhi/v1/"
  log "Console   : http://127.0.0.1:${cport} — register the FIRST user (= super admin)"
  log "Providers : LLM/TTS/ASR configured in the console (stored in MySQL; the server pulls them from manager-api)"
  return 0
}

case "${action}" in
dashboard) render_dashboard ;;
start)
  _ensure_base
  # Source pools: ghcr (server/web) + docker.io (mysql) — bounded direct
  # probes first (healthy → compose pulls direct, zero overhead); dead/slow
  # routes → mirror pre-pull + tag (see lib.sh).
  # shellcheck disable=SC2046
  images_pool_prepull $(compose_images) || true
  _staged_up || exit 1
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
  images_pool_prepull $(compose_images) || true
  compose up -d --remove-orphans
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  if console_up "${cport}" && ws_listening "${wport}"; then
    ok "xiaozhi is up: console http://127.0.0.1:${cport} · ws://127.0.0.1:${wport}/xiaozhi/v1/"
  else
    _staged_up || exit 1
  fi
  ;;
status)
  compose ps
  cport="$(effective_console_port)"
  wport="$(effective_ws_port)"
  if server_running && web_running; then
    if console_up "${cport}" && ws_listening "${wport}"; then
      ok "console answers: http://127.0.0.1:${cport} · ws listening: :${wport}"
    else
      warn "containers up but not answering yet (first boot runs migrations, 1-3 min)"
    fi
    log "db/redis: bundled MySQL (xiaozhi_esp32_server) + shared base redis"
    secret_set="$(grep -A3 '^manager-api:' "$(config_file)" 2>/dev/null | sed -n 's/.*secret:[[:space:]]*//p' | tr -d '"')"
    if [ -n "${secret_set}" ] && [ "${secret_set}" != '""' ]; then
      ok "server.secret configured"
    else
      warn "server.secret NOT set (start re-applies it automatically; manual: aibox ${MODULE_NAME} secret <value>)"
    fi
  else
    warn "stack not running (start: aibox ${MODULE_NAME} start)"
  fi
  ;;
logs)
  compose logs --tail "${XIAOZHI_LOG_TAIL:-200}" "$@"
  ;;
credentials)
  ok "console: first registered user becomes the SUPER ADMIN"
  info "register at http://127.0.0.1:$(effective_console_port) (admin manages models/users/params)"
  info "server.secret (console 参数管理 → server.secret) is auto-applied by start; manual: aibox ${MODULE_NAME} secret <value>"
  info "MySQL root password lives in $(deploy_root)/.env (mode 600)"
  ;;
secret)
  # Manual override: write manager-api.secret into data/.config.yaml +
  # restart the server container (the config is bind-mounted; the app
  # re-reads it at boot).
  val="${1:-}"
  [ -n "${val}" ] || die "usage: aibox ${MODULE_NAME} secret <server.secret value>"
  _write_secret "${val}"
  ok "server.secret written to $(config_file)"
  if docker restart "${SERVER_CONTAINER}" >/dev/null 2>&1; then
    ok "server container restarted (config re-read at boot)"
  else
    log "server container not running — it will pick the secret up on next start"
  fi
  ;;
*)
  die "unknown action: ${action:-} — run: aibox xiaozhi --help"
  ;;
esac

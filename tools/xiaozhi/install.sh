#!/usr/bin/env bash
# xiaozhi module — install hook (contract: docs/module-spec.md §Hook contract).
# Runs AFTER the aibox preflight gate AND after ensure_services (module.yaml
# services: base:redis — aibox already started the shared base). Idempotent:
# the deploy .env and data/.config.yaml are written ONCE (never clobbered —
# the .config.yaml later holds the user's server.secret).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"
mkdir -p "${ROOT}"

# --- place the curated compose ---
cp "${DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
log "compose placed → ${ROOT}/docker-compose.yml"

# --- write the deploy .env once (idempotent: existing file is never clobbered) ---
if [ ! -f "${ROOT}/.env" ]; then
  # MySQL root password: hex (no shell/yaml/URL metacharacters; used by the
  # Java druid pool AND the mysql container init).
  gen_password() { openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

  mysql_password="${XIAOZHI_MYSQL_PASSWORD:-$(gen_password)}"

  cat >"${ROOT}/.env" <<ENV
# xiaozhi deploy env — written by aibox install xiaozhi (pinned to
# xiaozhi-esp32-server v0.9.6). Edit values here, then apply with:
#   aibox xiaozhi restart
# Redis connection info is NOT here — it is injected from base.env
# (written by \`aibox base start\`) via compose --env-file.

# ---- aibox overrides ----
# Host ports (upstream defaults; all three are free in this repo's registry).
XIAOZHI_WS_PORT=${XIAOZHI_WS_PORT:-${DEFAULT_WS_PORT}}
XIAOZHI_CONSOLE_PORT=${XIAOZHI_CONSOLE_PORT:-${DEFAULT_CONSOLE_PORT}}
XIAOZHI_HTTP_PORT=${XIAOZHI_HTTP_PORT:-${DEFAULT_HTTP_PORT}}
# Image tags (repo pins the floor; \`aibox upgrade xiaozhi\` floats them via
# the github-release resolver — see module.yaml upgrade:).
XIAOZHI_SERVER_IMAGE=${XIAOZHI_SERVER_IMAGE:-${DEFAULT_SERVER_IMAGE}}
XIAOZHI_WEB_IMAGE=${XIAOZHI_WEB_IMAGE:-${DEFAULT_WEB_IMAGE}}
XIAOZHI_MYSQL_IMAGE=${XIAOZHI_MYSQL_IMAGE:-${DEFAULT_MYSQL_IMAGE}}

# ---- security (auto-generated; treat as a secret — this file is mode 600) ----
XIAOZHI_MYSQL_PASSWORD=${mysql_password}

# ---- tuning ----
TZ=${TZ:-Asia/Shanghai}
XIAOZHI_START_TIMEOUT=${XIAOZHI_START_TIMEOUT:-300}
XIAOZHI_LOG_TAIL=${XIAOZHI_LOG_TAIL:-200}
ENV
  chmod 600 "${ROOT}/.env"
  log "wrote ${ROOT}/.env (MySQL root password generated, mode 600)"
else
  log "kept existing ${ROOT}/.env (secrets/user overrides live there)"
fi

# --- render data/.config.yaml ONCE (the server's console-managed config) ---
# .config.yaml overrides the image's baked config.yaml; this file is what the
# Python server reads at boot. Rendered from upstream's config_from_api.yaml
# contract: server endpoints + manager-api url/secret. The SECRET is filled in
# later (after the first console login) via: aibox xiaozhi secret <value>.
mkdir -p "${ROOT}/data"
if [ ! -f "${ROOT}/data/.config.yaml" ]; then
  load_env   # honor XIAOZHI_*_PORT overrides in the rendered addresses
  lan_ip="$(_lan_ip)"
  ws_port="$(effective_ws_port)"
  http_port="$(effective_http_port)"
  cat >"${ROOT}/data/.config.yaml" <<YAML
# xiaozhi server config — rendered by aibox install xiaozhi.
# This file overrides the image's baked config.yaml (upstream's contract:
# data/.config.yaml wins). Providers (LLM/TTS/ASR) are configured in the
# console (\u667a\u63a7\u53f0) — the server pulls them from manager-api.
# Edit freely; apply with: aibox xiaozhi restart
server:
  ip: 0.0.0.0
  # device websocket — devices connect FROM OUTSIDE, so this must be the
  # host's LAN address (auto-detected at install; fix here if wrong).
  port: ${ws_port}
  websocket: ws://${lan_ip}:${ws_port}/xiaozhi/v1/
  # http service (vision analysis + single-server OTA) — same outside rule.
  http_port: ${http_port}
  vision_explain: http://${lan_ip}:${http_port}/mcp/vision/explain
manager-api:
  # container-internal: the web service in this compose stack.
  url: http://aibox-xiaozhi-web:8002/xiaozhi
  # server.secret (console 参数管理 → server.secret) — AUTO-APPLIED by
  # `aibox xiaozhi start` (fetched from the console's MySQL sys_params).
  # Manual override/rotation: aibox xiaozhi secret <value>
  secret: ""
prompt_template: agent-base-prompt.txt
YAML
  log "rendered ${ROOT}/data/.config.yaml (ws:// to ${lan_ip}:${ws_port}; secret pending)"
else
  log "kept existing ${ROOT}/data/.config.yaml (holds your server.secret)"
fi

log "installed module files → ${ROOT}"
log "Start:    aibox xiaozhi start"
log "Next:     open the console, register the first user (= super admin) — server.secret is auto-applied at start"

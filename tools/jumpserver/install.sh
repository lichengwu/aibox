#!/usr/bin/env bash
# jumpserver module — install hook (contract: docs/module-spec.md §Hook contract).
# Runs AFTER the aibox preflight gate AND after ensure_services (module.yaml
# services: base:postgres#jumpserver + base:redis — aibox already started the
# shared base and created the `jumpserver` database). Idempotent: the deploy
# .env and certs/ are written ONCE (never clobbered — the .env holds the
# generated SECRET_KEY/BOOTSTRAP_TOKEN, which MUST survive every reinstall:
# data encrypted with a rotated SECRET_KEY is unreadable).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"
mkdir -p "${ROOT}"

# --- place the curated compose ---
install_managed_file "${DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
log "compose placed → ${ROOT}/docker-compose.yml"

# NOTE: no base ensure calls here — the manager's ensure_services (module.yaml
# services:) already started the base and created the `jumpserver` database
# BEFORE this hook runs, and the module's 4-wide Redis slot range is allocated
# at svc start (`ensure_shared_redis_db jumpserver 4` — see lib.sh; the first
# allocator defines the reserved range, and only the module knows the width).
# Nothing in install.sh needs the provider UP.

# --- write the deploy .env once (idempotent: existing file is never clobbered) ---
if [ ! -f "${ROOT}/.env" ]; then
  # Upstream installer generates: SECRET_KEY (50 chars), BOOTSTRAP_TOKEN (24).
  # hex only — no quote/URL metacharacters (JumpServer's own warning: DB
  # passwords must not contain quotes; the same class of hazard).
  gen_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

  secret_key="${JUMPSERVER_SECRET_KEY:-$(gen_hex 24)}"
  bootstrap_token="${JUMPSERVER_BOOTSTRAP_TOKEN:-$(gen_hex 12)}"

  cat >"${ROOT}/.env" <<ENV
# jumpserver deploy env — written by aibox install jumpserver (pinned to
# JumpServer v4.10.19-ce). Edit values here, then apply with:
#   aibox jumpserver restart
# PG/Redis connection info is NOT here — it is injected from base.env
# (written by \`aibox base start\`) via compose --env-file.

# ---- aibox overrides ----
# Host ports (upstream 80/2222 are privileged / collide with sshd).
JUMPSERVER_WEB_PORT=${JUMPSERVER_WEB_PORT:-${DEFAULT_WEB_PORT}}
JUMPSERVER_SSH_PORT=${JUMPSERVER_SSH_PORT:-${DEFAULT_SSH_PORT}}
# Image pins (repo pins the floor; \`aibox upgrade jumpserver\` floats all
# five via the dockerhub-tags resolver — see module.yaml upgrade:).
JUMPSERVER_CORE_IMAGE=${JUMPSERVER_CORE_IMAGE:-${DEFAULT_CORE_IMAGE}}
JUMPSERVER_WEB_IMAGE=${JUMPSERVER_WEB_IMAGE:-${DEFAULT_WEB_IMAGE}}
JUMPSERVER_KOKO_IMAGE=${JUMPSERVER_KOKO_IMAGE:-${DEFAULT_KOKO_IMAGE}}
JUMPSERVER_LION_IMAGE=${JUMPSERVER_LION_IMAGE:-${DEFAULT_LION_IMAGE}}
JUMPSERVER_CHEN_IMAGE=${JUMPSERVER_CHEN_IMAGE:-${DEFAULT_CHEN_IMAGE}}

# ---- security (auto-generated; treat as secrets — this file is mode 600) ----
# SECRET_KEY: Django session/crypto key. MUST be kept when migrating the data
# volume — data encrypted with a rotated key is unreadable.
JUMPSERVER_SECRET_KEY=${secret_key}
# BOOTSTRAP_TOKEN: core↔component registration token (koko/lion/chen).
JUMPSERVER_BOOTSTRAP_TOKEN=${bootstrap_token}

# ---- JumpServer knobs (upstream config.txt subset) ----
# Trusted domains: e.g. demo.example.com:31200 (empty = no restriction).
JUMPSERVER_DOMAINS=${JUMPSERVER_DOMAINS:-}
TZ=${TZ:-Asia/Shanghai}
JUMPSERVER_START_TIMEOUT=${JUMPSERVER_START_TIMEOUT:-900}
JUMPSERVER_LOG_TAIL=${JUMPSERVER_LOG_TAIL:-200}
ENV
  chmod 600 "${ROOT}/.env"
  log "wrote ${ROOT}/.env (SECRET_KEY + BOOTSTRAP_TOKEN generated, mode 600)"
else
  log "kept existing ${ROOT}/.env (SECRET_KEY/BOOTSTRAP_TOKEN live there — never rotated by aibox)"
fi

# --- operator certs dir (state_files: certs/) ---
# JumpServer reads /opt/jumpserver/data/certs (bind-mounted). Upstream's
# installer creates it empty; TLS certs are operator-provided (see README).
mkdir -p "${ROOT}/certs"
log "certs dir ready → ${ROOT}/certs (drop jumpserver-*.pem / koko-lion certs here)"

log "installed module files → ${ROOT}"
load_env   # pick up the ports we (or a previous install) just wrote
log "Start:    aibox jumpserver start"
log "Next:     open http://127.0.0.1:$(effective_web_port) — default login admin / ChangeMe"

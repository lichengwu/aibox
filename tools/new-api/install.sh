#!/usr/bin/env bash
# new-api module — install hook (contract: docs/module-spec.md §Hook contract).
# Runs AFTER the aibox preflight gate AND after ensure_services (module.yaml
# services: base:postgres#new_api + base:redis — aibox already started the
# shared base and created the new_api database). Idempotent: the deploy .env
# is written ONCE (never clobbers an existing one — secrets/user config live
# there).
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
  # SESSION_SECRET signs sessions. Pinned once so restarts keep sessions
  # stable (upstream auto-generates when unset; multi-node REQUIRES a shared
  # value — deterministic for single-node too).
  gen_secret() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

  session_secret="${NEW_API_SESSION_SECRET:-$(gen_secret)}"

  cat >"${ROOT}/.env" <<ENV
# new-api deploy env — written by aibox install new-api (pinned to
# calciumion/new-api v0.13.2). Edit values here, then apply with:
#   aibox new-api restart
# PG/Redis connection info is NOT here — it is injected from base.env
# (written by \`aibox base start\`) via compose --env-file.

# ---- aibox overrides ----
# Host port (upstream's default 3000 collides with the openmaic module —
# the aibox port registry uses 30300; container listens on 3000 internally).
NEW_API_PORT=${NEW_API_PORT:-${DEFAULT_PORT}}
# Image tag (repo pins the floor; \`aibox upgrade new-api\` floats it via the
# dockerhub-tags resolver — see module.yaml upgrade:).
NEW_API_IMAGE=${NEW_API_IMAGE:-${DEFAULT_IMAGE}}
NODE_NAME=${NODE_NAME:-aibox-new-api}

# ---- security (auto-generated; treat as a secret — this file is mode 600) ----
SESSION_SECRET=${session_secret}

# ---- app wiring ----
TZ=${TZ:-Asia/Shanghai}
ENV
  chmod 600 "${ROOT}/.env"
  log "wrote ${ROOT}/.env (SESSION_SECRET generated, mode 600)"
else
  log "kept existing ${ROOT}/.env (secrets/user overrides live there)"
fi

log "installed module files → ${ROOT}"
log "Start:    aibox new-api start"

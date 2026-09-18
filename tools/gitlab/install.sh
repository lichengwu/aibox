#!/usr/bin/env bash
# gitlab module — install hook (contract: docs/module-spec.md §Hook contract).
# Runs AFTER the aibox preflight gate; idempotent. Places the compose file and
# writes the deploy .env once (never clobbers an existing one).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
mkdir -p "$ROOT"

cp "$DIR/docker-compose.yml" "$ROOT/docker-compose.yml"
log "compose placed: $ROOT/docker-compose.yml"

if [ ! -f "$ROOT/.env" ]; then
  host_ip="$(detect_external_host)"
  http_port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  ssh_port="${GITLAB_SSH_PORT:-$DEFAULT_SSH_PORT}"
  ext_url="${GITLAB_EXTERNAL_URL:-http://${host_ip}:${http_port}}"
  cat >"$ROOT/.env" <<ENV
# gitlab deploy env — written by aibox install gitlab.
# Edit values here, then apply with: aibox gitlab restart
GITLAB_IMAGE=${GITLAB_IMAGE:-$DEFAULT_IMAGE}
GITLAB_HTTP_PORT=${http_port}
GITLAB_SSH_PORT=${ssh_port}
GITLAB_EXTERNAL_URL=${ext_url}
GITLAB_PUMA_WORKERS=${GITLAB_PUMA_WORKERS:-2}
GITLAB_SIDEKIQ_CONCURRENCY=${GITLAB_SIDEKIQ_CONCURRENCY:-10}
ENV
  chmod 600 "$ROOT/.env"
  log "wrote $ROOT/.env (external URL: ${ext_url})"
else
  log "kept existing $ROOT/.env (not clobbered)"
fi

log "installed → $ROOT"
log "Start     : aibox gitlab start   (first boot takes 3-5 min; needs >= 4GB RAM)"
log "Login     : root — initial password: aibox gitlab credentials"

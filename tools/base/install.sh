#!/usr/bin/env bash
# base module — install hook: places docker-compose.yml at the deploy root
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

log "Installing the base module (shared PG 18 + Redis 7)..."
mkdir -p "$(base_deploy_root)"
cp "$DIR/docker-compose.yml" "$COMPOSE_FILE"
log "compose placed: ${COMPOSE_FILE}"
echo
log "Start:    aibox base start"
log "Create DB: aibox base createdb <module> [usage]"
log "Deploy-type modules connect to the shared PG (network aibox-base + connection info injected via ${AIBOX_HOME}/base.env)"

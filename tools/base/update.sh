#!/usr/bin/env bash
# base module — update hook: refreshes the compose file.
# aibox passes through --restart/--no-restart — restarting the shared stack is the job of
# `base restart`, so those args are ignored here.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

mkdir -p "$(base_deploy_root)"
cp "$DIR/docker-compose.yml" "$COMPOSE_FILE"
log "compose updated (${COMPOSE_FILE})"
log "Apply changes: aibox base restart"

#!/usr/bin/env bash
# gitlab module — update hook (aibox passes --restart/--no-restart through).
# Refreshes the compose file; the deploy .env is NEVER clobbered. Image bumps
# are deliberate operations: edit GITLAB_IMAGE in .env after checking GitLab's
# required upgrade path (docs.gitlab.com/update — skipping majors breaks migrations).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
if [ -d "$ROOT" ]; then
  cp "$DIR/docker-compose.yml" "$ROOT/docker-compose.yml"
  log "compose refreshed ($ROOT/docker-compose.yml)"
else
  log "not deployed yet; nothing to refresh"
fi
log "apply changes: aibox gitlab restart"
log "image bump   : edit GITLAB_IMAGE in $ROOT/.env FIRST — GitLab requires a staged"
log "               upgrade path across majors (see docs.gitlab.com/update#upgrade-paths)"

#!/usr/bin/env bash
# gitlab module — uninstall hook (idempotent; GitLab data volumes are
# deliberately PRESERVED — repos/issues/CI history are irreversible to lose).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
if [ -f "$ROOT/docker-compose.yml" ]; then
  compose down --remove-orphans >/dev/null 2>&1 || true
  rm -f "$ROOT/docker-compose.yml"
  log "stopped containers and removed the compose file (data volumes retained)"
else
  log "nothing to uninstall (no compose file at $ROOT)"
fi
warn "GitLab data volumes are RETAINED (repos, issues, CI history)."
warn "To delete them permanently: docker volume rm gitlab_gitlab_config gitlab_gitlab_logs gitlab_gitlab_data"

#!/usr/bin/env bash
# base module — uninstall hook.
# Stops the service + removes the compose file only. **Deliberately does not touch** the
# data volumes (pg_data/redis_data) — the shared DB belongs to "this deployment"; accidental
# deletion is irreversible, so we only warn.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

if [ -f "$COMPOSE_FILE" ]; then
  compose down 2>/dev/null || true
  rm -f "$COMPOSE_FILE"
  log "Stopped shared PG/Redis and removed the compose file (data volumes retained in docker)"
else
  log "No compose file; nothing to uninstall"
fi
warn "Data volumes (pg_data/redis_data) are retained in docker; to clear them: docker volume rm aibox_pg_data aibox_redis_data"

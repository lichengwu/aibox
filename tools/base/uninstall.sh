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
# Purge contract (docs/module-spec.md): AIBOX_PURGE_DATA=1 — set by
# `aibox self uninstall --data=purge` — deletes this module's DATA too (volumes).
if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  log "AIBOX_PURGE_DATA=1: deleting data volumes ..."
  if docker volume rm "${AIBOX_BASE_PG_VOLUME:-aibox_pg_data}" "${AIBOX_BASE_REDIS_VOLUME:-aibox_redis_data}" >/dev/null 2>&1; then
    log "purged: ${AIBOX_BASE_PG_VOLUME:-aibox_pg_data} ${AIBOX_BASE_REDIS_VOLUME:-aibox_redis_data}"
  else
    warn "volume removal failed (already gone?)"
  fi
else
  warn "Data volumes are retained in docker; to clear them: docker volume rm ${AIBOX_BASE_PG_VOLUME:-aibox_pg_data} ${AIBOX_BASE_REDIS_VOLUME:-aibox_redis_data}"
fi

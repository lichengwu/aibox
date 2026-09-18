#!/usr/bin/env bash
# openmaic module — uninstall hook
# By default removes only the CLI and **deliberately leaves** /etc/openmaic (keys
# and config) and the deploy root $AIBOX_HOME/apps/openmaic (deploy directory,
# data volume mount points) untouched — they belong to "this deployment" rather
# than "this command"; mistaken deletion is irreversible, so we only warn.
# Purge contract (docs/module-spec.md): under AIBOX_PURGE_DATA=1 (set by
# `aibox self uninstall --data=purge`) the deployment IS cleaned: containers +
# volumes + deploy root + /etc/openmaic (+ best-effort shared-PG database drop).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ -f "${CLI_DEST}" ]; then
  rm -f "${CLI_DEST}"
  log "removed ${CLI_DEST}"
else
  log "${CLI_DEST} not found (CLI already gone)"
fi

# Deploy root derived per module-spec convention (same expression as in the CLI)
_deploy_root="$(openmaic_deploy_root)"
if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  log "AIBOX_PURGE_DATA=1: cleaning the openmaic deployment (containers, volumes, config) ..."
  if [ -f "${_deploy_root}/app/docker-compose.yml" ]; then
    (cd "${_deploy_root}/app" && docker compose down -v --remove-orphans) >/dev/null 2>&1 || true
  fi
  docker rm -f app-openmaic-1 app-postgres-1 app-render-service-1 >/dev/null 2>&1 || true
  docker volume rm app_openmaic-data app_openmaic-postgres >/dev/null 2>&1 || true
  # Shared-PG mode: the 'openmaic' database lives inside the base PG — drop it
  # best-effort (default base-profile container; other profiles: drop manually or
  # let base's own purge remove the whole volume).
  docker exec "${AIBOX_BASE_PG_CONTAINER:-aibox-base-postgres}" \
    psql -U "${AIBOX_BASE_POSTGRES_USER:-aibox}" -c 'DROP DATABASE IF EXISTS openmaic;' >/dev/null 2>&1 || true
  rm -rf "${_deploy_root}" /etc/openmaic
  log "purged: deploy root + volumes + /etc/openmaic (shared-PG database dropped if present)"
else
  if [ -d /etc/openmaic ]; then
    warn "kept /etc/openmaic (contains API Key and access password); to clean up, remove it manually"
  fi
  if [ -d "${_deploy_root}" ]; then
    warn "kept ${_deploy_root} (deploy directory and data volumes); to clean up use openmaic clean"
  fi
fi

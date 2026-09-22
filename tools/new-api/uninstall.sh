#!/usr/bin/env bash
# new-api module — uninstall hook (idempotent; data volumes + deploy .env are
# preserved by default). See docs/module-spec.md §Data-purge contract.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"

# Stop containers (best-effort; docker may be absent on a partial teardown,
# and the shared base network may already be gone).
if [ -f "${ROOT}/docker-compose.yml" ]; then
  compose down --remove-orphans >/dev/null 2>&1 || true
fi
# Belt-and-braces: the container name is fixed (aibox-new-api) — remove it
# even if compose state is inconsistent (e.g. the compose file was hand-edited).
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

# Remove the module's own PROGRAM artifacts. Data (volumes), the deploy root,
# and the .env (secrets) are PRESERVED by default — print the exact
# manual-removal commands.
rm -f "${ROOT}/docker-compose.yml"
log "stopped containers and removed the compose file"

if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  # Purge: also delete the named data volumes + the deploy root (incl .env).
  # Volume names are deterministic (compose: aibox_new_api_data/_logs).
  docker volume rm aibox_new_api_data aibox_new_api_logs >/dev/null 2>&1 || true
  rm -rf "${ROOT}"
  ok "purged data volumes + deploy root (${ROOT})"
else
  warn "data volumes retained (aibox_new_api_data / aibox_new_api_logs)"
  warn "deploy .env retained at ${ROOT}/.env (contains SESSION_SECRET; reinstall reuses it)"
  log "residue cleanup (volumes + .env): aibox purge new-api"
fi

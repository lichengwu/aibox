#!/usr/bin/env bash
# dify module — uninstall hook (idempotent; data volumes + deploy .env are
# preserved by default). See docs/module-spec.md §Data-purge contract.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"
load_env

# Stop containers (best-effort; docker may be absent on a partial teardown).
if [ -f "${ROOT}/docker-compose.yml" ]; then
  compose down --remove-orphans >/dev/null 2>&1 || true
fi

# Remove the module's own PROGRAM artifacts (compose + vendored config
# templates). Data (volumes), the deploy root, and the .env (secrets) are
# PRESERVED by default — print the exact manual-removal commands.
rm -f "${ROOT}/docker-compose.yml" "${ROOT}/docker-compose.shared.yml"
rm -rf "${ROOT}/nginx" "${ROOT}/ssrf_proxy"
log "stopped containers and removed compose + nginx/ssrf_proxy templates"

if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  # Purge: also delete the named data volumes + the deploy root (incl .env).
  for vol in dify_storage dify_db dify_redis dify_sandbox_deps dify_sandbox_conf dify_plugin_daemon dify_weaviate; do
    docker volume rm "${vol}" >/dev/null 2>&1 || true
  done
  rm -rf "${ROOT}"
  ok "purged data volumes + deploy root (${ROOT})"
else
  warn "data volumes retained (dify_storage/dify_db/dify_redis/dify_sandbox_*/dify_plugin_daemon/dify_weaviate)"
  warn "deploy .env retained at ${ROOT}/.env (contains secrets; reinstall reuses it)"
  log "residue cleanup (volumes + .env): aibox purge dify"
fi

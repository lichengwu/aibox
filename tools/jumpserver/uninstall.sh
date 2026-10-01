#!/usr/bin/env bash
# jumpserver module — uninstall hook (idempotent; data volumes + deploy .env +
# certs/ are preserved by default). See docs/module-spec.md §Data-purge contract.
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
# Belt-and-braces: container names are fixed — remove them even if compose
# state is inconsistent (e.g. the compose file was hand-edited).
for c in ${ALL_CONTAINERS}; do
  docker rm -f "${c}" >/dev/null 2>&1 || true
done

# Remove the module's own PROGRAM artifacts. Data (volumes, ./certs, the
# deploy .env with SECRET_KEY/BOOTSTRAP_TOKEN) are PRESERVED by default —
# print the exact manual-removal commands.
rm -f "${ROOT}/docker-compose.yml"
log "stopped containers and removed the compose file"

if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  # Purge: also delete the named data volumes + the deploy root (incl .env
  # with the secrets and ./certs). Volume names are deterministic (compose:
  # aibox_jumpserver_{core,koko,lion,chen,nginx_logs}).
  docker volume rm aibox_jumpserver_core aibox_jumpserver_koko aibox_jumpserver_lion aibox_jumpserver_chen aibox_jumpserver_nginx_logs >/dev/null 2>&1 || true
  rm -rf "${ROOT}"
  ok "purged data volumes + deploy root (${ROOT})"
else
  warn "data retained (volumes aibox_jumpserver_{core,koko,lion,chen,nginx_logs} + ${ROOT}/certs)"
  warn "deploy .env retained at ${ROOT}/.env (holds SECRET_KEY/BOOTSTRAP_TOKEN — data encrypted with a rotated key is unreadable; reinstall reuses it)"
  log "residue cleanup (volumes + .env): aibox autoclean jumpserver --apply"
fi

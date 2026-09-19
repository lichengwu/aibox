#!/usr/bin/env bash
# xiaozhi module — uninstall hook (idempotent; data volumes + deploy .env +
# data/.config.yaml are preserved by default). See docs/module-spec.md
# §Data-purge contract.
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
for c in "${SERVER_CONTAINER}" "${WEB_CONTAINER}" "${MYSQL_CONTAINER}"; do
  docker rm -f "${c}" >/dev/null 2>&1 || true
done

# Remove the module's own PROGRAM artifacts. Data (volumes, ./data with
# .config.yaml + the secret, the deploy .env) are PRESERVED by default —
# print the exact manual-removal commands.
rm -f "${ROOT}/docker-compose.yml"
log "stopped containers and removed the compose file"

if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  # Purge: also delete the named data volumes + the deploy root (incl .env
  # and data/.config.yaml). Volume names are deterministic (compose:
  # aibox_xiaozhi_models/_uploadfile/_mysql).
  docker volume rm aibox_xiaozhi_models aibox_xiaozhi_uploadfile aibox_xiaozhi_mysql >/dev/null 2>&1 || true
  rm -rf "${ROOT}"
  ok "purged data volumes + deploy root (${ROOT})"
else
  warn "data retained (volumes aibox_xiaozhi_models/_uploadfile/_mysql + ${ROOT}/data with .config.yaml)"
  warn "deploy .env retained at ${ROOT}/.env (contains the MySQL password; reinstall reuses it)"
  log "to delete everything: aibox uninstall xiaozhi --purge"
fi

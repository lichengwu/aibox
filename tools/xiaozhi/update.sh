#!/usr/bin/env bash
# xiaozhi module — update hook. Refreshes the deployed compose from the
# freshly-downloaded module cache; never clobbers the deploy .env or
# data/.config.yaml (the MySQL password / user's server.secret live there).
# aibox passes --restart/--no-restart through; recreate-restart is the
# module's choice.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"
[ -d "${ROOT}" ] || die "not installed (run: aibox install ${MODULE_NAME})"

# Refresh the curated compose (a version bump ships updated image floors here).
cp "${DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
log "refreshed compose → ${ROOT}/docker-compose.yml"
log "kept existing ${ROOT}/.env (XIAOZHI_*_IMAGE values there override the compose floor)"
log "kept existing ${ROOT}/data/.config.yaml (holds your server.secret)"

# Apply: recreate containers so the new compose/env take effect.
case "${1:-}" in
--restart)
  log "applying (--restart): recreating containers…"
  # ghcr + docker.io source pools: bounded direct probes (healthy → compose
  # pulls direct, zero overhead); dead routes → mirror pre-pull + tag.
  # shellcheck disable=SC2046
  images_pool_prepull $(compose_images) || true
  compose up -d --remove-orphans
  ok "recreated — see: aibox ${MODULE_NAME} status"
  ;;
--no-restart)
  log "deferred restart (--no-restart); apply later: aibox ${MODULE_NAME} restart"
  ;;
*)
  log "apply changes: aibox ${MODULE_NAME} restart"
  ;;
esac

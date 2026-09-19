#!/usr/bin/env bash
# dify module — update hook. Refreshes the deployed compose + vendored config
# templates from the freshly-downloaded module cache; never clobbers the
# deploy .env (secrets/user config live there). aibox passes
# --restart/--no-restart through; recreate-restart is the module's choice.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"
[ -d "${ROOT}" ] || die "not installed (run: aibox install ${MODULE_NAME})"
mkdir -p "${ROOT}/nginx/conf.d" "${ROOT}/ssrf_proxy" "${ROOT}/nginx/ssl"

# Refresh the curated compose + vendored templates (verbatim from the new
# module cache — a version bump ships updated image tags here).
cp "${DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
cp "${DIR}/docker-compose.shared.yml" "${ROOT}/docker-compose.shared.yml"
cp "${DIR}/nginx/nginx.conf.template" "${ROOT}/nginx/nginx.conf.template"
cp "${DIR}/nginx/proxy.conf.template" "${ROOT}/nginx/proxy.conf.template"
cp "${DIR}/nginx/https.conf.template" "${ROOT}/nginx/https.conf.template"
cp "${DIR}/nginx/conf.d/default.conf.template" "${ROOT}/nginx/conf.d/default.conf.template"
cp "${DIR}/nginx/docker-entrypoint.sh" "${ROOT}/nginx/docker-entrypoint.sh"
cp "${DIR}/ssrf_proxy/squid.conf.template" "${ROOT}/ssrf_proxy/squid.conf.template"
cp "${DIR}/ssrf_proxy/squid-common.conf.template" "${ROOT}/ssrf_proxy/squid-common.conf.template"
cp "${DIR}/ssrf_proxy/docker-entrypoint.sh" "${ROOT}/ssrf_proxy/docker-entrypoint.sh"
chmod +x "${ROOT}/nginx/docker-entrypoint.sh" "${ROOT}/ssrf_proxy/docker-entrypoint.sh"
log "refreshed compose + nginx/ssrf_proxy templates → ${ROOT}"
log "kept existing ${ROOT}/.env (image tags there override the compose defaults)"

# Apply: recreate containers so the new image tags/env take effect.
case "${1:-}" in
--restart)
  log "applying (--restart): recreating containers…"
  # shellcheck disable=SC2046
  docker_pool_prepull $(compose_images) || true
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

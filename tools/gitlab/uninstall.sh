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
# Purge contract (docs/module-spec.md): AIBOX_PURGE_DATA=1 — set by
# `aibox self uninstall --data=purge` — deletes GitLab DATA (repos/issues/CI history).
if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  log "AIBOX_PURGE_DATA=1: deleting GitLab data volumes + deploy root ..."
  docker volume rm gitlab_gitlab_config gitlab_gitlab_logs gitlab_gitlab_data >/dev/null 2>&1 \
    || warn "volume removal failed (already gone?)"
  rm -rf "$ROOT"
  log "purged volumes (repos/issues/CI history) + $ROOT"
else
  warn "GitLab data volumes are RETAINED (repos, issues, CI history)."
  warn "To delete them permanently: docker volume rm gitlab_gitlab_config gitlab_gitlab_logs gitlab_gitlab_data"
fi

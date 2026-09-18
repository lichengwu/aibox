#!/usr/bin/env bash
# windmill module — uninstall hook
# By default removes only the CLI and **deliberately leaves untouched**
# /etc/windmill/windmill.conf (host-level config) and deploy root
# $AIBOX_HOME/apps/windmill (database volumes, backups, credentials) — they belong
# to "this deployment" rather than "this command"; deletion is irreversible, so we
# only warn, never act.
# Purge contract (docs/module-spec.md): under AIBOX_PURGE_DATA=1 (set by
# `aibox self uninstall --data=purge`) the deployment IS destroyed: containers +
# project volumes + systemd units + deploy root + /etc/windmill.
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

_deploy_root="$(wm_deploy_root)"
if [ "${AIBOX_PURGE_DATA:-0}" = "1" ]; then
  log "AIBOX_PURGE_DATA=1: destroying the windmill deployment (containers, volumes, units, config) ..."
  if [ -f "${_deploy_root}/docker-compose.yml" ]; then
    ( cd "${_deploy_root}" && docker compose down -v --remove-orphans ) >/dev/null 2>&1 || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    for u in /etc/systemd/system/windmill-*; do
      [ -e "$u" ] || continue
      systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
      rm -f "$u"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -rf "${_deploy_root}" /etc/windmill
  log "purged: deploy root + project volumes + systemd units + /etc/windmill"
else
  if [ -f /etc/windmill/windmill.conf ]; then
    warn "kept /etc/windmill/windmill.conf (host-level config); remove manually if you want to clean up"
  fi
  if [ -d "${_deploy_root}" ]; then
    warn "kept ${_deploy_root} (deploy directory, database volumes, and backups); to clean up use windmill destroy --all"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    [ -f /etc/systemd/system/windmill-backup.timer ] && \
      warn "systemd units still present (windmill systemd remove can uninstall them)"
  fi
fi

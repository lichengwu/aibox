#!/usr/bin/env bash
# windmill module — uninstall hook
# Only removes the CLI itself. **Deliberately leaves untouched** /etc/windmill/windmill.conf (host-level config) and
# deploy root $AIBOX_HOME/apps/windmill (database volumes, backups, credentials) — they belong to
# "this deployment" rather than "this command"; deletion is irreversible, so we only warn, never act.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

if [ ! -f "${CLI_DEST}" ]; then
  log "${CLI_DEST} not found, nothing to uninstall"
  exit 0
fi

rm -f "${CLI_DEST}"
log "removed ${CLI_DEST}"

if [ -f /etc/windmill/windmill.conf ]; then
  warn "kept /etc/windmill/windmill.conf (host-level config); remove manually if you want to clean up"
fi
_deploy_root="$(wm_deploy_root)"
if [ -d "${_deploy_root}" ]; then
  warn "kept ${_deploy_root} (deploy directory, database volumes, and backups); to clean up use windmill destroy --all"
fi
if command -v systemctl >/dev/null 2>&1; then
  [ -f /etc/systemd/system/windmill-backup.timer ] && \
    warn "systemd units still present (windmill systemd remove can uninstall them)"
fi

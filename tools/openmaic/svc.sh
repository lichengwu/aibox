#!/usr/bin/env bash
# openmaic module — service action hook
# This module has no resident service of its own, so it only **passes through**:
#   aibox openmaic status   ->  openmaic status
#   aibox openmaic upgrade  ->  openmaic upgrade
# All real actions are performed by the local openmaic CLI (including its own confirmation, concurrency lock, and exit codes).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-}"
if [ -z "${action}" ]; then
  die "Usage: aibox openmaic <action> [args] (see: openmaic help)"
fi
shift

# Naming collision reminder: aibox's install/uninstall installs the "module", while openmaic's install/clean
# deploys/cleans OpenMAIC itself. The two differ only by word order, worth a one-time reminder.
case "${action}" in
install | clean)
  warn "note: openmaic ${action} here means 'deploy / clean OpenMAIC itself'"
  warn "      to install this module use: aibox install openmaic"
  ;;
esac

# Prefer the module install destination to avoid stale copies in PATH
CLI=""
if [ -x "${CLI_DEST}" ]; then
  CLI="${CLI_DEST}"
else
  CLI="$(command -v openmaic || true)"
fi
if [ -z "${CLI}" ]; then
  die "openmaic command not found, run first: aibox install openmaic"
fi

# dashboard maps to the CLI's own status (dispatch-only module — the CLI's
# output IS the rich view; no separate render here)
case "${action}" in
dashboard) action="status" ;;
esac

exec "${CLI}" "${action}" "$@"

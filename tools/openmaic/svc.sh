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
  usage_die "Usage: aibox openmaic <action> [args] (see: openmaic help)"
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

# status maps to the CLI's own status (dispatch-only module — the CLI's
# output IS the rich view; no separate render here)
case "${action}" in
# Standard lifecycle aliases: dispatch CLIs expose their own verbs (openmaic uses
# up/down), but `aibox <module> start|stop` must work everywhere (spec §CLI surface).
start)
  # First run: the app is built FROM SOURCE on this host (clone + docker build) —
  # `aibox install openmaic` installs the module only. Deploy on demand here, with the
  # declared note printed first; --no-prepare refuses (scripts/CI).
  for _a in "$@"; do [ "${_a}" = "--no-prepare" ] && AIBOX_NO_PREPARE=1; done
  # Sentinel = the CONFIG artifact (.env.local, rendered by the deploy's step 2), NOT
  # app/docker-compose.yml: that file ships inside the upstream clone, so a deploy killed
  # during step 1 (or a plain `git clone`) already has it — the guard then believed the app
  # was deployed and `up` died on the missing env_file (live: 50.55, after an interrupted
  # first run). `.env.local` is exactly the piece `docker compose up` cannot produce itself;
  # a deploy interrupted later (during the build) keeps it, and `up` finishes that job by
  # building the missing images.
  # An explicit OPENMAIC_TAG (conf file) pins the deployed version: re-deploys are then
  # deterministic and need no release lookup at all.
  # guarded: the conf need not exist (fresh host / tests) and `set -euo pipefail` would
  # otherwise abort the whole start arm on a missing file (caught by the suite).
  _omc_conf="${OPENMAIC_CONF_DIR:-/etc/openmaic}/openmaic.conf"
  _omc_tag=""
  [ -f "${_omc_conf}" ] && _omc_tag="$(sed -n 's/^OPENMAIC_TAG=//p' "${_omc_conf}" 2>/dev/null | head -1 || true)"
  # shellcheck disable=SC2086
  module_ensure_deployed openmaic "${DIR}/module.yaml" \
    "$(openmaic_deploy_root)/app/.env.local" \
    "aibox openmaic install${_omc_tag:+ --tag ${_omc_tag}}" || exit 30
  action="up" ;;
stop)   action="down" ;;
status) action="status" ;;
esac

exec "${CLI}" "${action}" "$@"

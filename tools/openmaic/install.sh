#!/usr/bin/env bash
# openmaic module — install hook: places the openmaic ops CLI on this host
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

log "installing openmaic ops CLI ..."
do_install
ensure_path
host_notice
echo
log "dest    : ${CLI_DEST}"
log "version : $(cli_version)"
log "check   : openmaic doctor"

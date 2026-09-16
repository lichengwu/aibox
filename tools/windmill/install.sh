#!/usr/bin/env bash
# windmill module — install hook: places the windmill ops CLI on this host
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

log "installing windmill ops CLI ..."
do_install
ensure_path
host_notice
echo
log "dest        : ${CLI_DEST}"
log "version     : $(cli_version)"
log "deploy root : $(wm_deploy_root) (destroy won't touch beyond it; aibox self uninstall has fail-closed protection)"
log "config      : /etc/windmill/windmill.conf (seeded, see above)"
log "next        : windmill doctor && windmill init --version <ver>"

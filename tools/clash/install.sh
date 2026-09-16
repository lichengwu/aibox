#!/usr/bin/env bash
# clash module — install hook: download the mihomo kernel + seed the deploy root.
# The subscription is configured by `aibox clash set`, not in this step.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

log "Installing the clash module (mihomo kernel)..."
if [ -x "${KERNEL_DEST}" ]; then
  log "mihomo already present: ${KERNEL_DEST} ($(installed_kernel_version || echo unknown))"
else
  download_mihomo
fi

# Seed the deploy root + an empty state (secret generated now; subscription/enabled await `clash set` / `clash on`).
mkdir -p "$(clash_deploy_root)" "$(providers_dir)" "$(log_dir)"
if [ ! -f "$(state_file)" ]; then
  tag="$(latest_mihomo_tag || echo "")"
  state_write "" "$(gen_secret)" "0" "${CLASH_PORT}" "${CLASH_API_PORT}" "0" "${tag}"
fi

echo
log "Binary   : ${KERNEL_DEST}"
log "Deploy to: $(clash_deploy_root)"
log "Next     : aibox clash set <subscription-url>  then  aibox clash on"

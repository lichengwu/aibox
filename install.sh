#!/usr/bin/env bash
# aibox one-line install (bootstrap)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
# Env vars:
#   AIBOX_BRANCH  (default main)        branch to install from
#   AIBOX_BIN_DIR (default ~/.local/bin) main CLI install dir
#   AIBOX_SHA256  (optional)           verify the downloaded bin/aibox against this checksum
#   AIBOX_VERIFY  (default 0)          if 1, fetch+check the release SHA256SUMS sidecar (graceful if absent)
# Idempotent: safe to re-run; also used by `aibox self update`.
set -euo pipefail

REPO="lichengwu/aibox"
BRANCH="${AIBOX_BRANCH:-main}"
RAW="${AIBOX_RAW:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
BIN_DIR="${AIBOX_BIN_DIR:-$HOME/.local/bin}"
HOME_DIR="${AIBOX_HOME:-$HOME/.aibox}"

log() { printf '\033[36m[aibox]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

log "Installing aibox from ${REPO}@${BRANCH} ..."

command -v curl >/dev/null 2>&1 || die "curl is required (ships with macOS)"

# Proxy: read the existing config so the bootstrap's first mile can go through the proxy
# (on first install the config doesn't exist yet, so direct-only — expected). If the env
# already specifies a proxy, don't override it.
CONFIG="$HOME_DIR/config"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG" 2>/dev/null || true
fi
if [ "${AIBOX_PROXY_ENABLED:-1}" = "1" ] && [ -n "${AIBOX_PROXY_URL:-}" ]; then
  if [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}" ]; then
    :
  else
    export http_proxy="$AIBOX_PROXY_URL" https_proxy="$AIBOX_PROXY_URL" all_proxy="$AIBOX_PROXY_URL"
    export HTTP_PROXY="$AIBOX_PROXY_URL" HTTPS_PROXY="$AIBOX_PROXY_URL"
    _np="${AIBOX_NO_PROXY:-localhost,127.0.0.1,::1}"
    export no_proxy="$_np" NO_PROXY="$_np"
    _pd=$(printf '%s' "$AIBOX_PROXY_URL" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#')
    log "Using proxy ${_pd}"
  fi
fi

mkdir -p "$BIN_DIR" "$HOME_DIR"

# Download to a TEMP file in $BIN_DIR (same filesystem) and atomically mv into place.
# NEVER overwrite a running bin/aibox in-place: the old bash process holds an open fd at a
# byte offset into the file; truncating the same inode (curl -o) makes it execute fragments
# of the NEW file as garbage when it next reads (observed during self-update:
# "line 1442: ugh: command not found" — a shard of e.g. "thro*ugh*"). rename(2) leaves the
# running process on the old inode, safely.
_TMP_BIN="$(mktemp "$BIN_DIR/.aibox.download.XXXXXX")"
trap 'rm -f "$_TMP_BIN"' EXIT

log "Downloading bin/aibox -> $BIN_DIR/aibox"
curl -fsSL --max-time 60 "$RAW/bin/aibox" -o "$_TMP_BIN"

# ---------- checksum verification (defense in depth) ----------
# Two modes, both optional and graceful:
#   AIBOX_SHA256=<hex> — pin: the downloaded file MUST match exactly.
#   AIBOX_VERIFY=1     — best-effort: fetch the release SHA256SUMS sidecar and check it;
#                        older releases without the sidecar just warn and proceed.
# NOTE: this verifies the payload bin/aibox, NOT install.sh itself — a curl|bash MITM
# can serve a malicious install.sh that skips the check. Inherent to curl|bash; for
# full assurance pin AIBOX_SHA256 from a trusted channel or use AIBOX_RAW=file://.
# Verified BEFORE the file ever lands at the final path; on failure the temp is removed
# (trap) and the existing install is left untouched.
# When AIBOX_VERIFY=1 fetches from releases/latest but AIBOX_RAW points at raw `main`
# (ahead of the latest release), a mismatch may occur — reliable right after a release.
verify_sha256() {
  local file="$1" want="${2:-}" got
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    warn "shasum/sha256sum not available; cannot verify checksum"
    return 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    got=$(sha256sum "$file" | awk '{print $1}')
  fi
  [ -n "$got" ] || {
    warn "checksum computation failed"
    return 1
  }
  if [ -n "$want" ]; then
    if [ "$got" = "$want" ]; then
      log "Checksum OK (pinned, ${got})"
      return 0
    fi
    die "Checksum mismatch: expected ${want}, got ${got}"
  fi
  printf '%s' "$got"
}

if [ -n "${AIBOX_SHA256:-}" ]; then
  verify_sha256 "$_TMP_BIN" "$AIBOX_SHA256" || die "Checksum verification failed"
elif [ "${AIBOX_VERIFY:-0}" = "1" ]; then
  # Best-effort: fetch the release's SHA256SUMS sidecar and check bin/aibox against it.
  _sums_url="https://github.com/${REPO}/releases/latest/download/SHA256SUMS"
  _sums_tmp="$(mktemp 2>/dev/null || echo "/tmp/aibox-sums.$$")"
  if curl -fsSL "$_sums_url" -o "$_sums_tmp" 2>/dev/null; then
    _want=$(awk '$2=="bin/aibox"{print $1}' "$_sums_tmp" 2>/dev/null)
    if [ -n "$_want" ]; then
      verify_sha256 "$_TMP_BIN" "$_want" || {
        rm -f "$_sums_tmp"
        die "Checksum verification failed"
      }
    else
      warn "SHA256SUMS found but no bin/aibox entry; skipping verification"
    fi
  else
    warn "No SHA256SUMS sidecar at latest release; skipping verification (set AIBOX_SHA256 to pin)"
  fi
  rm -f "$_sums_tmp"
fi

chmod 0755 "$_TMP_BIN"
mv -f "$_TMP_BIN" "$BIN_DIR/aibox"
trap - EXIT

# PATH check & auto-write
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
  warn "$BIN_DIR is not in your PATH"
  shell_rc=
  case "${SHELL##*/}" in
  zsh) shell_rc="$HOME/.zshrc" ;;
  bash) shell_rc="$HOME/.bashrc" ;;
  *) shell_rc="$HOME/.profile" ;;
  esac
  if [ -f "$shell_rc" ] && grep -qF "$BIN_DIR" "$shell_rc"; then
    log "$shell_rc already contains ${BIN_DIR}; reopen the shell or source it"
  else
    printf '\n# aibox\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >>"$shell_rc"
    log "Appended PATH to ${shell_rc}; run: source $shell_rc or reopen the terminal"
  fi
fi

log "Done. Now run: aibox help"
log "Install your first module: aibox install pi-web"

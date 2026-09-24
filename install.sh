#!/usr/bin/env bash
# aibox one-line install (bootstrap)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
# Env vars:
#   AIBOX_BRANCH  (default main)        branch to install from
#   AIBOX_BIN_DIR                   main CLI install dir (default: ~/.local/bin
#                                   when it is in PATH, else an in-PATH writable
#                                   system dir like /usr/local/bin, else ~/.local/bin)
#   AIBOX_SHA256  (optional)           verify the downloaded bin/aibox against this checksum
#   AIBOX_VERIFY  (default 0)          if 1, fetch+check the release SHA256SUMS sidecar (graceful if absent)
#   AIBOX_GH_POOL (default shipped)     GitHub-family download pool override ("direct" = no pool)
#   AIBOX_GH_MIRROR / CLASH_MIRROR     user mirror, joins the pool as a candidate
# Idempotent: safe to re-run; also used by `aibox self update`.
set -euo pipefail

REPO="lichengwu/aibox"
BRANCH="${AIBOX_BRANCH:-main}"
RAW="${AIBOX_RAW:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
# ---------- bin-dir selection ----------
# Precedence (spec §Install paths):
#   1. explicit AIBOX_BIN_DIR — always wins
#   2. `~/.local/bin` when it is ALREADY in PATH — no churn for existing setups
#   3. an in-PATH writable system dir (the deploy-host/root case: `~/.local/bin`
#      is not in root's PATH — installing to /usr/local/bin makes the command
#      work IMMEDIATELY, zero shell setup; live-caught annoyance: "<dir> is not
#      in your PATH" right after the one-line install)
#   4. `~/.local/bin` — last resort; the PATH block further down then persists
#      it to the shell rc files and prints the apply-now line
# AIBOX_SYSTEM_BIN_DIRS overrides the system-dir candidates (space-separated).
_in_path() { case ":${PATH}:" in *":$1:"*) return 0 ;; esac; return 1; }
if [ -n "${AIBOX_BIN_DIR:-}" ]; then
  BIN_DIR="$AIBOX_BIN_DIR"
elif _in_path "$HOME/.local/bin"; then
  BIN_DIR="$HOME/.local/bin"
else
  BIN_DIR=""
  for _bd in ${AIBOX_SYSTEM_BIN_DIRS:-/usr/local/bin /opt/homebrew/bin}; do
    if _in_path "${_bd}" && [ -d "${_bd}" ] && [ -w "${_bd}" ]; then
      BIN_DIR="${_bd}"
      break
    fi
  done
  [ -n "${BIN_DIR}" ] || BIN_DIR="$HOME/.local/bin"
fi
HOME_DIR="${AIBOX_HOME:-$HOME/.aibox}"

# Output helpers aligned with the manager's symbol system (bin/aibox):
# log = plain; warn = ⚠ (stderr); die = ✗ (stderr, exit 1). Raw ANSI here (the
# bootstrap runs before the CLI's color system exists; NO_COLOR honored).
_C_RST="$( [ "${NO_COLOR:-}" = "1" ] && printf '' || printf '\033[0m' )"
_C_DIM="$( [ "${NO_COLOR:-}" = "1" ] && printf '' || printf '\033[2m' )"
_C_YEL="$( [ "${NO_COLOR:-}" = "1" ] && printf '' || printf '\033[33m' )"
_C_RED="$( [ "${NO_COLOR:-}" = "1" ] && printf '' || printf '\033[31m' )"
log() { printf '%s\n' "$*"; }
warn() { printf '%s⚠%s  %s\n' "${_C_YEL}" "${_C_RST}" "$*" >&2; }
die() {
  printf '%s✗%s  %s\n' "${_C_RED}" "${_C_RST}" "$*" >&2
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

# ---------- download source pool (GitHub family; bootstrap-local) ----------
# Same pattern as the manager's pool (bin/aibox, gh_pool_fetch) — inlined because
# install.sh cannot source the manager (it downloads it). Live-verified candidates
# (measured on a CN mac AND an Aliyun deploy host): gh-proxy.com proxies raw +
# github releases; ghproxy.net raw; ghproxy.link / ghproxy.cn served CORRUPT
# content (truncated / wrong size) — excluded. RACE: direct + mirrors fetch
# concurrently, the FIRST success serves (a dead direct costs nothing). Non-GitHub
# URLs (file://, a pinned AIBOX_RAW mirror base) fetch direct — the user pinned
# their route. Checksum verification (AIBOX_SHA256 / AIBOX_VERIFY) still applies
# to whatever source wins.
fetch_pool() { # $1=url, $2=outfile → 0 on success
  local url="$1" out="$2"
  case "$url" in
  https://raw.githubusercontent.com/* | https://github.com/* | https://api.github.com/*) : ;;
  *)
    curl -fsSL --max-time 60 "$url" -o "$out"
    return $?
    ;;
  esac
  if [ "${AIBOX_GH_POOL:-}" = "direct" ]; then
    curl -fsSL --max-time 60 "$url" -o "$out"
    return $?
  fi
  local mirrors="" m tmpd i pid pids="" body="" deadline alive j
  m="${AIBOX_GH_MIRROR:-${CLASH_MIRROR:-}}"
  if [ -n "$m" ]; then mirrors="${m%/} "; fi
  mirrors="${mirrors}${AIBOX_GH_POOL:-https://gh-proxy.com https://ghproxy.net}"
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/aiboot.XXXXXX")" || return 1
  # fire: d0 = direct, d1..dN = mirrors (concurrent; first success wins)
  (
    curl -fsSL --max-time 30 "$url" -o "$tmpd/d0" 2>/dev/null && : >"$tmpd/d0.ok"
  ) &
  pids="$pids $!"
  i=0
  # shellcheck disable=SC2086
  for m in $mirrors; do
    i=$((i + 1))
    (
      curl -fsSL --max-time 30 "${m%/}/$url" -o "$tmpd/d$i" 2>/dev/null && : >"$tmpd/d$i.ok"
    ) &
    pids="$pids $!"
  done
  # poll until the first .ok appears, every worker exits, or the deadline hits
  deadline=$(( $(date +%s) + 30 ))
  while [ -z "$body" ]; do
    for ((j = 0; j <= i; j++)); do
      if [ -f "$tmpd/d$j.ok" ]; then
        body="$tmpd/d$j"
        break
      fi
    done
    if [ -n "$body" ]; then break; fi
    alive=0
    # shellcheck disable=SC2086
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    if [ "$alive" = 0 ]; then break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then break; fi
    sleep 0.25
  done
  # SIGTERM to workers FIRST, then orphaned curl children (the kill-order lesson).
  # The loop-level stderr redirect also silences bash's "Terminated: 15" job
  # notices (printed at reap time — cosmetic noise during the bootstrap).
  # shellcheck disable=SC2086
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done 2>/dev/null
  if [ -n "$body" ] && [ -s "$body" ]; then
    cp "$body" "$out"
    rm -rf "$tmpd"
    return 0
  fi
  rm -rf "$tmpd"
  return 1
}

mkdir -p "$BIN_DIR" "$HOME_DIR"

# Download to a TEMP file in $BIN_DIR (same filesystem) and atomically mv into place.
# NEVER overwrite a running bin/aibox in-place: the old bash process holds an open fd at a
# byte offset into the file; truncating the same inode (curl -o) makes it execute fragments
# of the NEW file as garbage when it next reads (observed during self-update:
# "line 1442: ugh: command not found" — a shard of e.g. "thro*ugh*"). rename(2) leaves the
# running process on the old inode, safely.
# First install or re-install/self-update? The tail copy differs — an update
# used to end with "Install your first module" (nonsense on a host that has
# modules already; live-caught on the deploy host).
_prev_ver=""
if [ -x "$BIN_DIR/aibox" ]; then
  # `|| true`: the previous binary may be un-runnable (truncated/corrupt) and
  # install.sh runs under pipefail — a bare capture would abort the re-install
  # with no message (caught by tests/install-sh.bats, the wrong-pin case).
  _prev_ver="$("$BIN_DIR/aibox" version 2>/dev/null | awk '{print $2}' || true)"
  if [ "$_prev_ver" = "unknown" ] || [ "$_prev_ver" = "aibox" ]; then _prev_ver=""; fi
fi

_TMP_BIN="$(mktemp "$BIN_DIR/.aibox.download.XXXXXX")"
trap 'rm -f "$_TMP_BIN"' EXIT

log "Downloading bin/aibox -> $BIN_DIR/aibox"
fetch_pool "$RAW/bin/aibox" "$_TMP_BIN" || die "Download failed: $RAW/bin/aibox (source pool tried: direct + mirrors; pin AIBOX_RAW, or AIBOX_GH_POOL=direct to bypass)"

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
  if fetch_pool "$_sums_url" "$_sums_tmp" 2>/dev/null; then
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
if _in_path "$BIN_DIR"; then
  log "$BIN_DIR already in PATH — aibox is immediately available"
else
  warn "$BIN_DIR is not in your PATH"
  # Persist to the shell rc files (the same marked "# aibox" block that
  # `aibox purge self` strips). bash users need BOTH: ~/.bashrc is read by
  # interactive shells, ~/.profile by LOGIN shells (the root/deploy-host case —
  # Debian's root login never reads ~/.bashrc). One block per file, idempotent.
  shell_rc=""
  case "${SHELL##*/}" in
  zsh) shell_rc="$HOME/.zshrc" ;;
  bash) shell_rc="$HOME/.bashrc $HOME/.profile" ;;
  *) shell_rc="$HOME/.profile" ;;
  esac
  written=""
  already=""
  for rc in ${shell_rc}; do
    if [ -f "$rc" ] && grep -qF "$BIN_DIR" "$rc"; then
      already="${already}${already:+ }${rc}"
    else
      printf '\n# aibox\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >>"$rc"
      written="${written}${written:+ }${rc}"
    fi
  done
  [ -n "${written}" ] && log "Appended PATH to: ${written} (new shells pick it up)"
  [ -n "${already}" ] && log "Already in: ${already}"
  # Immediate effect can't cross the process boundary (the one-liner runs this
  # script in a CHILD shell — the parent's PATH is untouchable); print the
  # one-line apply for THIS shell instead.
  log "apply now:  export PATH=\"${BIN_DIR}:\$PATH\"      (or: exec \$SHELL -l)"
fi

_new_ver="$("$BIN_DIR/aibox" version 2>/dev/null | awk '{print $2}' || true)"
if [ -n "$_prev_ver" ]; then
  if [ -n "$_new_ver" ] && [ "$_prev_ver" != "$_new_ver" ]; then
    log "Done. aibox updated: ${_prev_ver} → ${_new_ver}"
  else
    log "Done. aibox re-installed (${_new_ver:-${_prev_ver}}) — already up to date"
  fi
  log "Next: aibox dashboard   ·   refresh modules: aibox update --all"
else
  log "Done. Now run: aibox help"
  log "Install your first module: aibox install pi-web"
fi

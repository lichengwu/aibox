# ---------- config read/write ----------
load_config() {
  [ -f "$AIBOX_CONFIG" ] || return 0
  # Config is maintained by `aibox proxy`, plain KEY=VALUE; parse failure is non-fatal.
  # shellcheck disable=SC1090
  cfg_kv_load "$AIBOX_CONFIG"
  [ -n "${AIBOX_NO_PROXY:-}" ] || AIBOX_NO_PROXY="$AIBOX_NO_PROXY_DEFAULT"
  return 0
}

save_config() {
  mkdir -p "$AIBOX_HOME"
  local old_umask
  old_umask=$(umask)
  umask 077
  cat >"$AIBOX_CONFIG" <<EOF
# aibox config — maintained by 'aibox proxy', also hand-editable.
# May contain proxy credentials, hence mode 600.

# Proxy URL (supports http:// https:// socks5:// socks5h://)
AIBOX_PROXY_URL="$AIBOX_PROXY_URL"

# 1=enabled / 0=disabled (config retained when disabled)
AIBOX_PROXY_ENABLED="$AIBOX_PROXY_ENABLED"

# Addresses that bypass the proxy, comma-separated
AIBOX_NO_PROXY="$AIBOX_NO_PROXY"
EOF
  umask "$old_umask"
  chmod 600 "$AIBOX_CONFIG"
}

# Redact: http://user:pass@host:port -> http://user:***@host:port
mask_url() {
  printf '%s' "$1" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

# Complete scheme: allow bare host:port.
normalize_proxy_url() {
  case "${1:-}" in
    "")    printf '' ;;
    *://*) printf '%s' "$1" ;;
    *)     printf 'http://%s' "$1" ;;
  esac
}

# Probe whether the proxy is actually in effect. Judge by %{proxy_used}, not just
# the HTTP status — on a directly-reachable network the 200 comes from the direct
# connection, so status-only checks are always false positives.
# Result also written to PROBE_CONFIRMED (1=traffic confirmed going through the proxy).
proxy_probe() {
  local url="$1" target="${2:-$PROBE_TARGET}" out code used
  out=$(curl -s --max-time 15 -x "$url" -o /dev/null \
    -w '%{http_code} %{proxy_used}' "$target" 2>/dev/null) || out=""
  code="${out%% *}"
  used="${out##* }"
  # SC2034-exempt: consumed by tests/proxy.bats (cross-file contract).
  PROBE_CONFIRMED=0
  [ "$code" = "200" ] || return 1
  [ "$used" = "1" ] && PROBE_CONFIRMED=1
  return 0
}

# Interactive confirmation; non-interactive environments always decline (refuse),
# so scripts can't silently proceed.
ask_confirm() {
  [ -t 0 ] || {
    warn "Non-interactive environment, declining"
    return 1
  }
  local ans
  printf '%s⚠%s  %s [y/N] ' "$C_YEL" "$C_RST" "$1"
  read -r ans || return 1
  case "$ans" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# Detect whether the local clash pool is enabled. Reads apps/clash/state's
# CLASH_ENABLED + CLASH_MODE: internal (aibox's own mihomo on CLASH_PORT) or
# external (a local clash client — Clash Verge etc. — reused on CLASH_EXT_PORT).
# The egress port follows the mode; a stale state (kernel died / port changed)
# fails the probe and aibox falls back to direct (see _clash_stale_warn).
CLASH_PORT="7890"
clash_active() {
  local st="${AIBOX_HOME}/apps/clash/state"
  [ -f "$st" ] || return 1
  # shellcheck disable=SC1090
  cfg_kv_load "$st"
  [ "${CLASH_ENABLED:-0}" = "1" ] || return 1
  CLASH_PORT="${CLASH_PORT:-7890}"
  # mode-aware egress port: external (Verge etc.) → its own port
  if [ "${CLASH_MODE:-internal}" = "external" ] && [ -n "${CLASH_EXT_PORT:-}" ]; then
    CLASH_PORT="${CLASH_EXT_PORT}"
  fi
  # The state file can go stale: the kernel died, the app changed its port, or
  # another clash took over (measured live: mihomo process up but NOT listening
  # on 7890 — the CLI exported the dead proxy and EVERY curl failed instantly
  # with connection-refused). Probe the port; a configured-but-dead proxy is
  # not an egress.
  (exec 3<>"/dev/tcp/127.0.0.1/${CLASH_PORT}") 2>/dev/null || return 1
  return 0
}

# Stale-clash diagnostic: the state file says enabled but the port is dead —
# used at the egress-adoption point so the silent direct fallback is explainable.
_clash_stale_warn() {
  local st="${AIBOX_HOME}/apps/clash/state" port
  [ -f "$st" ] || return 0
  # shellcheck disable=SC1090
  cfg_kv_load "$st"
  [ "${CLASH_ENABLED:-0}" = "1" ] || return 0
  port="${CLASH_PORT:-7890}"
  if ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    warn "clash state says enabled but :${port} is not listening — using direct (fix: aibox clash restart / aibox clash off)"
  fi
  return 0
}

# Export the effective proxy as env vars, for this process and the module hooks it spawns.
# Both lowercase and uppercase: curl only honors lowercase http_proxy (uppercase
# HTTP_PROXY is ignored by it), while apt-style tools only honor uppercase — in practice
# the two sets differ. Whatever the source (config or env), everything is unified to a
# single AIBOX_PROXY_URL outlet, so modules needn't guess which standard var to read.
# Priority: local clash pool (mihomo) > static proxy > direct.
apply_proxy() {
  local eff="" no_p="$AIBOX_NO_PROXY"

  _clash_stale_warn   # explains the silent direct fallback when clash is configured-but-dead
  if clash_active; then
    eff="socks5://127.0.0.1:${CLASH_PORT}"
    export http_proxy="$eff" https_proxy="$eff" all_proxy="$eff"
    export HTTP_PROXY="$eff" HTTPS_PROXY="$eff"
    export no_proxy="$no_p" NO_PROXY="$no_p"
    AIBOX_PROXY_SOURCE="clash"
    AIBOX_PROXY_ENABLED=1
    return 0   # Don't overwrite AIBOX_PROXY_URL: keep the static value for clash-off fallback + `proxy show`.
  elif [ "$AIBOX_PROXY_ENABLED" = "1" ]; then
    if [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ] || [ -n "${all_proxy:-}" ] || [ -n "${ALL_PROXY:-}" ]; then
      # Already set in env -> respect it, don't usurp, only normalize-export.
      # ALL_PROXY (uppercase) counts too: curl honors it — a socks setup that
      # exports only the uppercase form is still "the env decided", not config.
      eff="${http_proxy:-${https_proxy:-${all_proxy:-${ALL_PROXY:-}}}}"
      no_p="${no_proxy:-$AIBOX_NO_PROXY}"
      AIBOX_PROXY_SOURCE="env"
    elif [ -n "$AIBOX_PROXY_URL" ]; then
      eff="$AIBOX_PROXY_URL"
      export http_proxy="$eff" https_proxy="$eff" all_proxy="$eff"
      export HTTP_PROXY="$eff" HTTPS_PROXY="$eff"
      export no_proxy="$no_p" NO_PROXY="$no_p"
      AIBOX_PROXY_SOURCE="config"
    fi
  fi

  if [ -z "$eff" ]; then
    if [ -n "$AIBOX_PROXY_URL" ]; then
      AIBOX_PROXY_SOURCE="disabled"
    else
      AIBOX_PROXY_SOURCE="none"
    fi
    export AIBOX_PROXY_ENABLED=0
    return 0
  fi

  export AIBOX_PROXY_URL="$eff" AIBOX_NO_PROXY="$no_p" AIBOX_PROXY_ENABLED=1
  return 0
}

# --no-proxy: bypass the proxy entirely for this invocation (even env-set ones).
# ALL_PROXY (uppercase) is on the unset list on purpose: curl READS it (socks
# setups export exactly that form), and it used to survive the bypass — the
# operator believed they had bypassed while every fetch still died inside the
# dead local proxy (live-caught on a deploy host: ALL_PROXY=socks5h://
# 127.0.0.1:20808 with hysteria listening but its tunnel dead).
bypass_proxy() {
  unset http_proxy https_proxy all_proxy ALL_PROXY HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY || true
  unset AIBOX_PROXY_URL AIBOX_NO_PROXY || true
  export AIBOX_PROXY_ENABLED=0
  AIBOX_PROXY_SOURCE="bypass"
  return 0
}


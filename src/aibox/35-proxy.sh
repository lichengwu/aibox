# ---------- proxy command domain ----------
cmd_proxy() {
  local sub="${1:-show}"
  case "$sub" in
    -h|--help) _verb_help proxy; return 0 ;;
    show)  cmd_proxy_show ;;
    set)   shift; cmd_proxy_set "$@" ;;
    unset) cmd_proxy_unset ;;
    on)    cmd_proxy_toggle 1 ;;
    off)   cmd_proxy_toggle 0 ;;
    check) shift; if [ $# -gt 0 ]; then cmd_proxy_test "$@"; else cmd_proxy_check; fi ;;
    test)  die "'proxy test' merged into: aibox proxy check <target-url> (single target + direct-connection control)" ;;
    env)   shift; cmd_proxy_env "$@" ;;
    *)     usage_die "Usage: aibox proxy {show|set <url>|unset|on|off|check [url]|env [--remote]}   (aibox proxy --help)" ;;
  esac
}

cmd_proxy_show() {
  # Clash pool takes priority: when on, show local mihomo (static proxy as fallback hint).
  printf '%s%s%s\n' "$C_BOLD" "proxy" "$C_RST"
  if clash_active; then
    info "config      ${AIBOX_CONFIG} + clash pool"
    info "egress      socks5://127.0.0.1:${CLASH_PORT} (local mihomo, takes priority over static proxy)"
    [ -n "$AIBOX_PROXY_URL" ] && info "static      $(mask_url "$AIBOX_PROXY_URL") (fallback after 'clash off')"
    info "clash       aibox clash status"
    return 0
  fi
  if [ -z "$AIBOX_PROXY_URL" ]; then
    info "config      none (direct connection)"
    info "set one     aibox proxy set http://host:port  ·  aibox clash set <subscription-url>"
    return 0
  fi
  local state="enabled"
  [ "$AIBOX_PROXY_ENABLED" = "1" ] || state="disabled"
  info "config      ${AIBOX_CONFIG}"
  info "proxy       $(mask_url "$AIBOX_PROXY_URL")"
  info "state       $state"
  info "no-proxy    $AIBOX_NO_PROXY"
  case "$AIBOX_PROXY_SOURCE" in
    env)      info "egress      $(mask_url "$AIBOX_PROXY_URL") (from env vars, takes priority over this config)" ;;
    config)   info "egress      $(mask_url "$AIBOX_PROXY_URL")" ;;
    disabled) info "egress      none (proxy disabled)" ;;
    *)        info "egress      none (direct connection)" ;;
  esac
  return 0
}

cmd_proxy_set() {
  local raw="${1:-}" no_test=0 no_check=0 url scheme a
  # Keep the old values: if the check is unsatisfactory we can roll back, including "was never set".
  local old_url="$AIBOX_PROXY_URL" old_enabled="$AIBOX_PROXY_ENABLED"

  if [ $# -gt 0 ]; then shift; fi
  for a in "$@"; do
    case "$a" in
      --no-test)  no_test=1 ;;
      --no-check) no_check=1 ;;
      *) die "Unknown option: ${a} (available: --no-test / --no-check)" ;;
    esac
  done
  # --no-test means "save fast, don't verify", so skip the full check too.
  if [ "$no_test" = "1" ]; then no_check=1; fi

  url=$(normalize_proxy_url "$raw")
  [ -n "$url" ] || usage_die "Usage: aibox proxy set <url>   e.g. aibox proxy set http://10.0.0.2:7897"

  scheme="${url%%://*}"
  case "$scheme" in
    http | https | socks5 | socks5h) ;;
    *) die "Unsupported proxy scheme: ${scheme} (supported: http / https / socks5 / socks5h)" ;;
  esac

  if [ "$no_test" = "0" ]; then
    log "Testing proxy $(mask_url "$url")..."
    if proxy_probe "$url"; then
      ok "Proxy reachable"
    else
      bad "Proxy test failed (target ${PROBE_TARGET})"
      ask_confirm "Save this proxy anyway?" || {
        log "Cancelled, config unchanged"
        return 1
      }
    fi
  fi

  AIBOX_PROXY_URL="$url"
  AIBOX_PROXY_ENABLED="1"
  save_config
  ok "Saved $(mask_url "$url")"
  info "Config: ${AIBOX_CONFIG} (mode 600)"

  if [ "$no_check" = "1" ]; then
    return 0
  fi

  # Verify right after saving. A single probe only proves "this url can reach out";
  # it doesn't prove "the sites you need are reachable" — proxies are often partially available.
  echo
  if cmd_proxy_check "$url"; then
    return 0
  fi

  echo
  if ask_confirm "Revert the proxy config just set?"; then
    AIBOX_PROXY_URL="$old_url"
    if [ -n "$old_url" ]; then
      AIBOX_PROXY_ENABLED="${old_enabled:-1}"
    fi
    save_config
    if [ -n "$old_url" ]; then
      warn "Reverted to $(mask_url "$old_url")"
    else
      warn "Reverted, proxy config cleared (back to direct connection)"
    fi
    return 1
  fi

  warn "Kept. Some sites failed; recheck anytime with 'aibox proxy check'"
  return 0
}

cmd_proxy_unset() {
  [ -n "$AIBOX_PROXY_URL" ] || {
    log "No proxy configured to begin with"
    return 0
  }
  AIBOX_PROXY_URL=""
  AIBOX_PROXY_ENABLED="1"
  save_config
  log "Proxy config cleared"
  return 0
}

cmd_proxy_toggle() {
  local want="$1"
  [ -n "$AIBOX_PROXY_URL" ] || die "No proxy configured yet (aibox proxy set <url>)"
  AIBOX_PROXY_ENABLED="$want"
  save_config
  if [ "$want" = "1" ]; then
    log "Enabled $(mask_url "$AIBOX_PROXY_URL")"
  else
    log "Disabled (config retained, 'aibox proxy on' restores it)"
  fi
  return 0
}

cmd_proxy_test() { # single-target reachability via the effective proxy route + direct control.
  # $1 = TARGET url (default: $PROBE_TARGET). Invoked as `aibox proxy check <url>` (v2.1
  # merge of the old `proxy test`). The proxy route resolves from config: static →
  # clash-pool fallback; to test a different proxy, set it first (aibox proxy set <url>).
  local target="${1:-$PROBE_TARGET}" url out code used
  url="$AIBOX_PROXY_URL"
  # No static proxy — fall back to the clash pool (local mihomo) if it's active.
  if [ -z "$url" ] && clash_active; then
    url="socks5://127.0.0.1:${CLASH_PORT}"
  fi
  [ -n "$url" ] || die "No proxy configured (nothing to route through) — set one first: aibox proxy set <url>"

  log "Proxy check (single target)"
  info "Proxy   $(mask_url "$url")"
  info "Target  $target"
  echo

  # Any HTTP answer (even 401/404) = reachable; only 000/empty = failure. proxy_used:
  # 1 = confirmed via proxy; 0 = answered DIRECT (warn — the proxy may be bypassed);
  # empty = this curl build lacks %{proxy_used} (say so, don't guess).
  local proxied=0
  out="$(curl -s --max-time 15 -x "$url" -o /dev/null -w '%{http_code} %{proxy_used}' "$target" 2>/dev/null)" || out=""
  code="${out%% *}"; used="${out##* }"
  [ -n "$code" ] || code="000"
  if [ "$code" != "000" ]; then
    if [ "$used" = "1" ]; then
      ok "Via proxy     ${code} (traffic confirmed going through the proxy)"
    elif [ -z "$used" ]; then
      ok "Via proxy     ${code} (curl lacks %{proxy_used}, can't confirm whether proxy was used)"
    else
      ok "Via proxy     ${code} (WARNING: proxy_used=0 — answered via DIRECT connection)"
    fi
    proxied=1
  else
    bad "Via proxy     failed (proxy unreachable, or the proxy cannot reach the target)"
  fi

  local dcode
  dcode=$(curl -s --max-time 10 --noproxy '*' -o /dev/null -w '%{http_code}' "$target" 2>/dev/null) || dcode=""
  [ -n "$dcode" ] || dcode="000"
  if [ "$dcode" != "000" ]; then
    info "Direct control ${dcode} — direct connection also answers here; the proxy isn't strictly required"
  else
    info "Direct control 000 — direct connection fails; the proxy is required"
  fi

  if [ "$proxied" = "1" ]; then return 0; else return 1; fi
}

cmd_proxy_env() {
  local remote=0 u
  [ "${1:-}" = "--remote" ] && remote=1
  [ -n "$AIBOX_PROXY_URL" ] || die "No proxy configured (aibox proxy set <url>)"
  [ "$AIBOX_PROXY_ENABLED" = "1" ] || {
    warn "Proxy is disabled (enable with 'aibox proxy on')"
    return 1
  }
  u="$AIBOX_PROXY_URL"

  if [ "$remote" = "1" ]; then
    # For shipping to a remote host: KEY=VALUE, sourceable, also passable as args.
    printf 'AIBOX_PROXY_URL=%s\n' "$u"
    printf 'http_proxy=%s\n' "$u"
    printf 'https_proxy=%s\n' "$u"
    printf 'all_proxy=%s\n' "$u"
    printf 'no_proxy=%s\n' "$AIBOX_NO_PROXY"
  else
    printf "export http_proxy='%s'\n" "$u"
    printf "export https_proxy='%s'\n" "$u"
    printf "export all_proxy='%s'\n" "$u"
    printf "export no_proxy='%s'\n" "$AIBOX_NO_PROXY"
  fi
  return 0
}

# ---------- connectivity check ----------
# "Proxy configured" != "proxy usable". Check right after `set` is better than
# discovering it's broken at install time.
#
# Site list: each line "label|url|group"; same group auto-collapses under one subheading.
# Full override: AIBOX_PROBE_SITES='label|url|group
# label|url|group'
AIBOX_PROBE_SITES_DEFAULT='github.com|https://github.com|Dev deps
api.github.com|https://api.github.com|Dev deps
raw.githubusercontent.com|https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh|Dev deps
docker hub|https://registry-1.docker.io/v2/|Dev deps
ghcr.io|https://ghcr.io/v2/|Dev deps
npm registry|https://registry.npmjs.org|Dev deps
pypi|https://pypi.org/simple/|Dev deps
go proxy|https://proxy.golang.org|Dev deps
google|https://www.google.com/generate_204|Dev deps
huggingface|https://huggingface.co|Dev deps
maven central|https://repo1.maven.org/maven2/|Dev deps
npmmirror|https://registry.npmmirror.com|CN mirrors
tuna|https://mirrors.tuna.tsinghua.edu.cn|CN mirrors
dashscope|https://dashscope.aliyuncs.com|CN mirrors'
AIBOX_PROBE_SITES="${AIBOX_PROBE_SITES:-$AIBOX_PROBE_SITES_DEFAULT}"
PROBE_TIMEOUT="${AIBOX_PROBE_TIMEOUT:-8}"

# Colors and TUI_TTY are set up globally (see "output / colors" above); the probe reuses them.
# --no-tui (in cmd_proxy_check) overrides TUI_TTY=0 to force a static dump.

# Probe results, indexed to match the site list. P_DONE=1 means the result is in.
P_LABEL=(); P_URL=(); P_GROUP=(); P_DONE=()
P_CODE=(); P_TIME=(); P_USED=(); P_GRADE=()
P_N=0
PROBE_PROXY=""
PROBE_DIR=""

probe_load_sites() {
  local line lab rest url grp
  P_LABEL=(); P_URL=(); P_GROUP=(); P_DONE=()
  P_CODE=(); P_TIME=(); P_USED=(); P_GRADE=()
  P_N=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    case "$line" in
      *'|'*'|'*) ;;
      *) warn "Malformed site list line, skipped: $line"; continue ;;
    esac
    lab="${line%%|*}"
    rest="${line#*|}"
    url="${rest%%|*}"
    grp="${rest#*|}"
    [ -n "$url" ] || continue
    P_LABEL[$P_N]="$lab"
    P_URL[$P_N]="$url"
    P_GROUP[$P_N]="$grp"
    P_DONE[$P_N]=0
    P_CODE[$P_N]=""
    P_TIME[$P_N]=""
    P_USED[$P_N]=""
    P_GRADE[$P_N]=""
    P_N=$((P_N + 1))
  done <<PROBE_SITES_EOF
$AIBOX_PROBE_SITES
PROBE_SITES_EOF
}

# Single-site probe. Runs in a background subprocess, so results land in files —
# the child can't mutate the parent's arrays.
# `env -u no_proxy`: an explicitly -x'd proxy can still be excluded by no_proxy, which
# would silently turn a "via-proxy check" into a "direct check" — making the result a lie.
probe_fetch() {
  local idx="$1" url="$2" dir="$3" out
  out=$(env -u no_proxy -u NO_PROXY curl -s -I --max-time "$PROBE_TIMEOUT" \
    -x "$PROBE_PROXY" -o /dev/null \
    -w '%{http_code} %{time_total} %{proxy_used}' "$url" 2>/dev/null) || out=""
  # On connection failure curl's -w emits nothing; must fall back, else the code becomes empty.
  [ -n "$out" ] || out="000 0.00 0"
  printf '%s\n' "$out" >"$dir/$idx"
}

# Verdict: any HTTP response counts as reachable.
# 401 (private registry needs auth), 404 (no content at root), 405 (no HEAD) all just mean
# the peer answered normally — the link is up; only connection-layer failure (000) is truly down.
# 5xx is "suspicious" — could be proxy-side fault or the peer itself being down.
probe_grade_of() {
  case "${1:-}" in
    ""|000) printf 'fail' ;;
    5??)    printf 'warn' ;;
    *)      printf 'ok' ;;
  esac
}

probe_fmt_time() {
  case "${1:-}" in
    ""|*[!0-9.]*) printf '0.00' ;;
    *)            printf '%.2f' "$1" 2>/dev/null || printf '0.00' ;;
  esac
}

# Read completed results back from files into the arrays.
probe_collect() {
  local i=0 line rest
  while [ "$i" -lt "$P_N" ]; do
    if [ "${P_DONE[$i]:-0}" != "1" ] && [ -f "$PROBE_DIR/$i" ]; then
      line="$(cat "$PROBE_DIR/$i" 2>/dev/null)"
      P_CODE[$i]="${line%% *}"
      rest="${line#* }"
      P_TIME[$i]="${rest%% *}"
      P_USED[$i]="${rest##* }"
      P_GRADE[$i]="$(probe_grade_of "${P_CODE[$i]}")"
      P_DONE[$i]=1
    fi
    i=$((i + 1))
  done
}

# Print one line (with its own leading clear); finished and waiting states differ.
probe_line() {
  local i="$1" frame="$2" grade code t mark note tcol
  if [ "${P_DONE[$i]:-0}" != "1" ]; then
    printf '%s  %s%s%s %-28s %swaiting%s\n' \
      "$C_CLR" "$C_DIM" "$frame" "$C_RST" "${P_LABEL[$i]:-}" "$C_DIM" "$C_RST"
    return 0
  fi
  grade="${P_GRADE[$i]:-ok}"
  code="${P_CODE[$i]:-000}"
  t="$(probe_fmt_time "${P_TIME[$i]:-}")"
  mark="${C_GRN}✓${C_RST}"
  note=""
  case "$grade" in
    warn) mark="${C_YEL}⚠${C_RST}"; note="server error" ;;
    fail) mark="${C_RED}✗${C_RST}"; note="connection failed or timed out" ;;
  esac
  tcol="$C_DIM"
  if [ "$grade" = "fail" ]; then
    tcol="$C_RED"
  elif [ "$grade" = "ok" ]; then
    # Over 3s is slow: works but drags every fetch.
    case "${t%%.*}" in
      ""|*[!0-9]*) ;;
      *) if [ "${t%%.*}" -ge 3 ]; then tcol="$C_YEL"; [ -n "$note" ] || note="slow"; fi ;;
    esac
  fi
  # The note is a suffix, not a fixed-width trailing column, to avoid trailing-space residue.
  local note_suf=""
  if [ -n "$note" ]; then note_suf="  $note"; fi
  printf '%s  %s %-28s %s%-5s%s %s%s%s%s\n' \
    "$C_CLR" "$mark" "${P_LABEL[$i]:-}" "$C_DIM" "$code" "$C_RST" \
    "$tcol" "${t}s" "$C_RST" "$note_suf"
  return 0
}

probe_render() {
  local frame="$1" i=0 prev="" g
  while [ "$i" -lt "$P_N" ]; do
    g="${P_GROUP[$i]:-}"
    if [ "$g" != "$prev" ]; then
      printf '%s  %s\n' "$C_CLR" "${C_BOLD}${C_CYA}${g}${C_RST}"
      prev="$g"
    fi
    probe_line "$i" "$frame"
    i=$((i + 1))
  done
}

# Lines to move up on redraw = site count + group heading count (constant throughout).
probe_line_count() {
  local i=0 prev="" g n=0
  while [ "$i" -lt "$P_N" ]; do
    g="${P_GROUP[$i]:-}"
    if [ "$g" != "$prev" ]; then n=$((n + 1)); prev="$g"; fi
    n=$((n + 1))
    i=$((i + 1))
  done
  printf '%s' "$n"
}

cmd_proxy_check() {
  local url="" a
  for a in "$@"; do
    case "$a" in
      --no-tui) TUI_TTY=0 ;;
      *) if [ -z "$url" ]; then url="$a"; fi ;;
    esac
  done
  url="$(normalize_proxy_url "$url")"
  if [ -z "$url" ]; then url="$AIBOX_PROXY_URL"; fi
  # --no-proxy clears the in-memory config; re-read the file in that case.
  if [ -z "$url" ] && [ -f "$AIBOX_CONFIG" ]; then
    url="$(grep '^AIBOX_PROXY_URL=' "$AIBOX_CONFIG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    url="$(normalize_proxy_url "$url")"
  fi
  # No static proxy configured — fall back to the clash pool (local mihomo) if it's active.
  if [ -z "$url" ] && clash_active; then
    url="socks5://127.0.0.1:${CLASH_PORT}"
  fi
  [ -n "$url" ] || die "No proxy configured — set one first: aibox proxy set <url> (the site matrix compares direct vs proxy)"

  probe_load_sites
  [ "$P_N" -gt 0 ] || die "Site list is empty (check AIBOX_PROBE_SITES)"

  PROBE_PROXY="$url"
  PROBE_DIR="$(mktemp -d)" || die "Cannot create temp dir"
  trap 'rm -rf "$PROBE_DIR"' EXIT

  local total
  total="$(probe_line_count)"
  printf '  Connectivity check (via proxy %s)\n' "$(mask_url "$url")"
  printf '  %sAny HTTP answer counts as reachable — 401/404/405 just mean the link reached the peer%s\n' "$C_DIM" "$C_RST"

  # All concurrent. Serial worst case is 13×8=104s; concurrent only waits for the slowest.
  local i=0
  while [ "$i" -lt "$P_N" ]; do
    probe_fetch "$i" "${P_URL[$i]:-}" "$PROBE_DIR" &
    i=$((i + 1))
  done

  local frame_i=0 first=1 running=1
  local -a SPIN
  # Take whole-string frames, no ${s:i:1} slicing — multibyte chars get sliced into half-bytes under a C locale.
  SPIN=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
  while [ "$running" = "1" ]; do
    probe_collect
    running=0
    i=0
    while [ "$i" -lt "$P_N" ]; do
      if [ "${P_DONE[$i]:-0}" != "1" ]; then running=1; break; fi
      i=$((i + 1))
    done
    if [ "$TUI_TTY" = "1" ]; then
      if [ "$first" != "1" ]; then printf '\033[%sA' "$total"; fi
      probe_render "${SPIN[$frame_i]}"
      frame_i=$(((frame_i + 1) % 10))
      first=0
    fi
    if [ "$running" = "1" ]; then sleep 0.12; fi
  done
  wait 2>/dev/null || true
  # Non-TTY: no redraw; print a single static dump after everything finishes.
  if [ "$TUI_TTY" != "1" ]; then probe_render ""; fi

  local okc=0 warnc=0 failc=0 failed_lines="" all_confirmed=1
  i=0
  while [ "$i" -lt "$P_N" ]; do
    case "${P_GRADE[$i]:-ok}" in
      ok)   okc=$((okc + 1)) ;;
      warn) warnc=$((warnc + 1)) ;;
      fail) failc=$((failc + 1)); failed_lines="${failed_lines}    ${P_LABEL[$i]:-}\n" ;;
    esac
    # Only if every site explicitly reports proxy_used=1 can we say "traffic confirmed via proxy".
    # The 000 fallback has used=0; checking "is it empty" would misreport "all proxy dead" as "all via proxy".
    if [ "${P_USED[$i]:-}" != "1" ]; then all_confirmed=0; fi
    i=$((i + 1))
  done

  printf '\n'
  printf '  %d items: %s%d ok%s' "$P_N" "$C_GRN" "$okc" "$C_RST"
  if [ "$warnc" -gt 0 ]; then printf ' · %s%d suspicious%s' "$C_YEL" "$warnc" "$C_RST"; fi
  if [ "$failc" -gt 0 ]; then printf ' · %s%d failed%s' "$C_RED" "$failc" "$C_RST"; fi
  printf '\n'

  if [ "$all_confirmed" = "1" ] && [ "$P_N" -gt 0 ]; then
    printf '  %sAll traffic confirmed via proxy (curl %%{proxy_used})%s\n' "$C_DIM" "$C_RST"
  fi

  if [ "$failc" -gt 0 ]; then
    printf '  %sunreachable:%s\n' "$C_RED" "$C_RST"
    printf '%b' "$failed_lines"
    info "Troubleshoot: 'aibox proxy check <url>' for the direct-connection control; or try another proxy"
    return 1
  fi
  return 0
}


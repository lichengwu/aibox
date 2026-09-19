# clash module shared library (sourced by hooks, not executed directly)
#
# Orchestrates the local mihomo kernel: subscription fetch / speed-test / switch are all
# delegated to mihomo; this module only downloads the binary, generates config, manages the
# process lifecycle, refreshes the fallback, and exposes the local mixed port to aibox.
#
# Why we don't parse the subscription yaml ourselves: mihomo's proxy-providers natively
# consume a subscription URL, fetching + parsing + refreshing on schedule; url-test/fallback
# groups auto-test for the fastest node and fail over. aibox doesn't reinvent this.

export CLI_NAME="clash"
KERNEL_NAME="mihomo"

# mihomo binary location
CLASH_BIN_DIR="${CLASH_BIN_DIR:-${AIBOX_BIN_DIR:-${HOME}/.local/bin}}"
KERNEL_DEST="${CLASH_BIN_DIR}/${KERNEL_NAME}"

# Default ports (overridable via state)
CLASH_PORT="${CLASH_PORT:-7890}"
CLASH_API_PORT="${CLASH_API_PORT:-9090}"

# Output helpers: colors are inherited from aibox via the exported C_* env vars (single
# source of truth); ${C_*:-} falls back to empty when this lib is sourced standalone.
# Prefix uses AIBOX_MODULE (injected by aibox) with the module name as a fallback.
log()  { printf '%s\n' "$*"; }
warn() { printf '%s⚠%s  %s\n' "${C_YEL:-}" "${C_RST:-}" "$*" >&2; }
die() {
  printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2
  exit 1
}
mask_url() { printf '%s' "${1:-}" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'; }

# ---------- deploy root / paths (module-spec deploy-type convention) ----------
clash_deploy_root() {
  if [ -n "${CLASH_BASE_DIR:-}" ]; then
    printf '%s' "${CLASH_BASE_DIR}"
    return 0
  fi
  local base="${AIBOX_APPS_ROOT:-}"
  if [ -z "${base}" ]; then
    base="${AIBOX_HOME:-${HOME:+${HOME}/.aibox}}/apps"
  fi
  printf '%s/clash' "${base}"
}
providers_dir() { printf '%s/providers' "$(clash_deploy_root)"; }
log_dir() { printf '%s/logs' "$(clash_deploy_root)"; }
state_file() { printf '%s/state' "$(clash_deploy_root)"; }
pid_file() { printf '%s/mihomo.pid' "$(clash_deploy_root)"; }
config_file() { printf '%s/config.yaml' "$(clash_deploy_root)"; }

# ---------- platform / version / download ----------
detect_asset() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
  x86_64 | amd64) arch="amd64" ;;
  arm64 | aarch64) arch="arm64" ;;
  i386 | i686) arch="386" ;;
  armv7l) arch="armv7" ;;
  *) die "Unsupported arch: $(uname -m) (download manually: https://github.com/MetaCubeX/mihomo/releases)" ;;
  esac
  printf 'mihomo-%s-%s' "$os" "$arch"
}

# ---------- GitHub download pool (module-local; same pattern as the manager's
# gh_pool_fetch — modules are self-contained, so the mechanism lives here in
# clash's shape). Candidates in CONFIGURED order: CLASH_MIRROR / AIBOX_GH_MIRROR
# (user mirror — RACED, not pinned: the fastest route serves), DIRECT, then the
# live-verified public pool (measured on a CN mac + an Aliyun deploy host:
# gh-proxy.com proxies github releases + api; ghproxy.net raw; ghproxy.link /
# ghproxy.cn served CORRUPT content — excluded). AIBOX_GH_POOL="url..." overrides
# the shipped list; "direct" disables the pool (direct-only).
CLASH_GH_POOL_DEFAULT="https://gh-proxy.com https://ghproxy.net"

_clash_gh_candidates() { # prints one candidate prefix per line (DIRECT = no prefix)
  local m
  m="${CLASH_MIRROR:-${AIBOX_GH_MIRROR:-}}"
  if [ -n "${m}" ]; then printf '%s\n' "${m%/}"; fi
  printf 'DIRECT\n'
  case "${AIBOX_GH_POOL:-}" in
  direct | none | off) : ;;
  "") # shellcheck disable=SC2086
    printf '%s\n' ${CLASH_GH_POOL_DEFAULT} ;;
  *) # shellcheck disable=SC2086
    printf '%s\n' ${AIBOX_GH_POOL} ;;
  esac
  return 0
}

# Full URL for a candidate prefix.
_clash_cand_url() { # $1=prefix $2=url
  if [ "$1" = "DIRECT" ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

# Small-file first-success race (version JSONs): every candidate fetches
# concurrently; the first complete response serves. A dead direct costs nothing.
clash_gh_get() { # $1=url → body on stdout; nonzero when every candidate fails
  local url="$1" tmpd pid pids="" body="" rounds i j p candurl
  case "${AIBOX_GH_POOL:-}" in
  direct)
    curl -fsSL --max-time "${CLASH_TAG_TIMEOUT:-10}" "$url" 2>/dev/null
    return $?
    ;;
  esac
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/clashget.XXXXXX")" || return 1
  i=0
  while read -r p; do
    i=$((i + 1))
    candurl="$(_clash_cand_url "$p" "$url")"
    printf '%s\n' "${candurl}" >"$tmpd/u${i}"
    (
      curl -fsSL --max-time "${CLASH_TAG_TIMEOUT:-10}" "${candurl}" -o "$tmpd/b${i}" 2>/dev/null &&
        : >"$tmpd/b${i}.ok"
    ) &
    pids="${pids} $!"
  done < <(_clash_gh_candidates)
  rounds=0
  while [ -z "${body}" ] && [ "${rounds}" -lt 80 ]; do
    for ((j = 1; j <= i; j++)); do
      if [ -f "$tmpd/b${j}.ok" ]; then body="$tmpd/b${j}"; break; fi
    done
    if [ -n "${body}" ]; then break; fi
    sleep 0.25
    rounds=$((rounds + 1))
  done
  # SIGTERM to workers FIRST, then orphaned curl children (kill-order lesson);
  # the loop-level 2>/dev/null also silences bash's job-termination notices.
  # shellcheck disable=SC2086
  for pid in $pids; do
    kill "${pid}" 2>/dev/null || true
    pkill -P "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done 2>/dev/null
  if [ -n "${body}" ] && [ -s "${body}" ]; then
    cat "${body}"
    rm -rf "${tmpd}"
    return 0
  fi
  rm -rf "${tmpd}"
  return 1
}

latest_mihomo_tag() {
  clash_gh_get "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" |
    grep -oE '"tag_name": *"v[^"]+"' | head -1 | sed -E 's/.*"v([^"]+)".*/\1/'
}

installed_kernel_version() {
  [ -x "${KERNEL_DEST}" ] || {
    printf ''
    return 1
  }
  "${KERNEL_DEST}" -v 2>/dev/null | grep -oE 'v[0-9][0-9.]*' | head -1 || return 1
}

# Rate-probe ONE candidate (background worker): bounded partial download of the
# ACTUAL asset — the exact file the download will fetch. Writes "RATE<TAB>URL"
# to the result file; dead/zero-rate → empty result file.
_clash_probe_one() { # $1=url $2=partial-file $3=result-file
  local url="$1" pf="$2" rf="$3" tstat size t rate
  tstat="$(curl -fsSL -o "$pf" -w '%{size_download} %{time_total}' --max-time "${CLASH_PROBE_TIME:-5}" "$url" 2>/dev/null || true)"
  size="${tstat%% *}"
  t="${tstat##* }"
  rate="$(printf '%s %s' "${size:-0}" "${t:-0}" | awk '{t=$2+0; if (t>0) printf "%d", $1/t; else print 0}')"
  if [ "${rate:-0}" -le 0 ] || [ ! -s "$pf" ]; then : >"$rf"; return 0; fi
  printf '%s\t%s\n' "${rate}" "${url}" >"$rf"
  return 0
}

# Rank download candidates by MEASURED rate (bounded partial downloads of the
# actual asset, concurrent). Writes full candidate URLs to $2, fastest first
# (dead candidates keep configured order behind them); sets CLASH_PROBE_PARTIAL
# to the winner's partial — a valid prefix that seeds the resumable download
# (on fast routes the probe may even complete the whole file).
# NOTE: called DIRECTLY (never inside $( )) — the CLASH_PROBE_PARTIAL global
# would be lost to the command-substitution subshell (the gh-pool lesson).
CLASH_PROBE_PARTIAL=""
clash_rank_candidates() { # $1=asset-url $2=ranked-outfile
  local url="$1" outf="$2" tmpd pid pids="" p i j u first k
  CLASH_PROBE_PARTIAL=""
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/clashrank.XXXXXX")" || { printf '%s\n' "$url" >"$outf"; return 0; }
  i=0
  while read -r p; do
    i=$((i + 1))
    u="$(_clash_cand_url "$p" "$url")"
    printf '%s\n' "${u}" >"$tmpd/c${i}.url"
    _clash_probe_one "${u}" "$tmpd/c${i}.part" "$tmpd/c${i}.res" &
    pids="${pids} $!"
  done < <(_clash_gh_candidates)
  # shellcheck disable=SC2086
  for pid in $pids; do wait "${pid}" 2>/dev/null || true; done
  # rank: successful probes by rate (descending), then the dead ones in
  # configured order — every reachable source stays a failover candidate.
  : >"$outf"
  cat "$tmpd"/c*.res 2>/dev/null | sort -rn | cut -f2 | grep . >>"$outf" || true
  for ((j = 1; j <= i; j++)); do
    if [ ! -s "$tmpd/c${j}.res" ]; then cat "$tmpd/c${j}.url" >>"$outf"; fi
  done
  first="$(head -n 1 "$outf")"
  if [ -n "${first}" ]; then
    for ((k = 1; k <= i; k++)); do
      if [ "$(cat "$tmpd/c${k}.url" 2>/dev/null)" = "${first}" ] && [ -s "$tmpd/c${k}.part" ]; then
        mv "$tmpd/c${k}.part" "${tmpd}.keep" 2>/dev/null || true
        CLASH_PROBE_PARTIAL="${tmpd}.keep"
        break
      fi
    done
  fi
  rm -rf "${tmpd}"
  return 0
}

download_mihomo() {
  local ver asset url tmp attempt cands cand ok rankf psz tsz
  ver="${1:-$(latest_mihomo_tag)}"
  [ -n "$ver" ] || die "Cannot get the latest mihomo version (network? every source-pool candidate failed — set a proxy (run: aibox proxy set) and retry, or pin AIBOX_GH_POOL)"
  asset="$(detect_asset)-v${ver}.gz"
  url="https://github.com/MetaCubeX/mihomo/releases/download/v${ver}/${asset}"
  log "Downloading mihomo v${ver} -> ${asset}"
  mkdir -p "${CLASH_BIN_DIR}"
  # Versioned temp file: a stale partial of a DIFFERENT version must never be
  # resumed into corruption (curl -C - would request a bogus byte range).
  tmp="${CLASH_BIN_DIR}/mihomo-${ver}.gz"
  # Source pool: rank the candidates by MEASURED download rate (bounded partial
  # downloads of the actual asset, concurrent). Called directly + ranked via a
  # file (a $( ) capture would lose the CLASH_PROBE_PARTIAL global).
  rankf="$(mktemp "${TMPDIR:-/tmp}/clashrank.out.XXXXXX")" || rankf="/tmp/clashrank.out.$$"
  clash_rank_candidates "$url" "$rankf"
  cands="$(cat "$rankf")"
  rm -f "$rankf"
  [ -n "$cands" ] || die "no download candidates for ${url}"
  # Seed the resumable tmp with the probe winner's partial — ONLY when it is
  # larger than any partial already on disk (a previous attempt's progress
  # must not be clobbered by a smaller probe partial).
  if [ -n "${CLASH_PROBE_PARTIAL}" ] && [ -s "${CLASH_PROBE_PARTIAL}" ]; then
    psz="$(wc -c <"${CLASH_PROBE_PARTIAL}" | tr -d ' ')"
    tsz=0
    if [ -f "$tmp" ]; then tsz="$(wc -c <"$tmp" | tr -d ' ')"; fi
    if [ "${psz:-0}" -gt "${tsz:-0}" ]; then
      cp -f "${CLASH_PROBE_PARTIAL}" "$tmp"
      if gunzip -t "$tmp" 2>/dev/null; then
        log "  fast route: the rate probe already fetched the whole file"
      fi
    fi
  fi
  # Resumable failover loop: throttled release CDNs (measured: ~21KB/s on
  # Aliyun direct) cannot finish inside one --max-time window — partials carry
  # across attempts AND across sources (mirrors proxy the identical asset).
  # Per-source attempt windows (CLASH_DOWNLOAD_ATTEMPTS, now per source,
  # default 2) then fail over down the measured ranking; every reachable source
  # is tried before dying.
  ok=0
  # shellcheck disable=SC2086
  for cand in $cands; do
    if [ -f "$tmp" ] && gunzip -t "$tmp" 2>/dev/null; then ok=1; break; fi
    log "  source: ${cand}"
    attempt=0
    until { [ -f "$tmp" ] && gunzip -t "$tmp" 2>/dev/null; } ||
      curl -fsSL -C - --max-time "${CLASH_DOWNLOAD_TIMEOUT:-120}" "$cand" -o "$tmp"; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge "${CLASH_DOWNLOAD_ATTEMPTS:-2}" ]; then
        warn "  ${cand}: interrupted ×${attempt} — failing over to the next source"
        break
      fi
      warn "  attempt $((attempt + 1)) interrupted — resuming partial download..."
    done
    if [ -f "$tmp" ] && gunzip -t "$tmp" 2>/dev/null; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || die "Download failed on every source tried ($(printf '%s' "$cands" | tr '\n' ' ')); $(du -h "$tmp" 2>/dev/null | cut -f1) partial retained
  Hint: a HTTP/SOCKS proxy →  aibox proxy set <url>
        pin a mirror       →  CLASH_MIRROR=https://gh-proxy.com aibox install clash"
  gunzip -f "$tmp" || die "Decompress failed (mihomo .gz)"
  mv -f "${tmp%.gz}" "$KERNEL_DEST"
  chmod 0755 "${KERNEL_DEST}"
  "${KERNEL_DEST}" -v >/dev/null 2>&1 || die "Downloaded binary won't run (arch mismatch?)"
  log "Placed mihomo v${ver} -> ${KERNEL_DEST}"
}

# ---------- state (sub URL / secret / ports / last refresh / kernel version) ----------
state_load() {
  [ -f "$(state_file)" ] || return 0
  # shellcheck disable=SC1090
  . "$(state_file)" 2>/dev/null || true
  CLASH_PORT="${CLASH_PORT:-7890}"
  CLASH_API_PORT="${CLASH_API_PORT:-9090}"
  CLASH_MODE="${CLASH_MODE:-internal}"
}

# state_write <sub_url> <secret> <enabled> <port> <api_port> <last_refresh> <tag> [mode] [ext_port]
# mode: internal (aibox runs its own mihomo) | external (reuse a local clash
# client — Clash Verge etc. — on ext_port; no kernel of our own).
state_write() {
  mkdir -p "$(clash_deploy_root)"
  local old_umask
  old_umask=$(umask)
  umask 077
  cat >"$(state_file)" <<EOF
# clash module state (maintained by aibox clash; contains subscription token, mode 600)
SUB_URL="$1"
CLASH_SECRET="$2"
CLASH_ENABLED="$3"
CLASH_PORT="${4:-7890}"
CLASH_API_PORT="${5:-9090}"
LAST_REFRESH="${6:-0}"
KERNEL_TAG="${7:-}"
CLASH_MODE="${8:-internal}"
CLASH_EXT_PORT="${9:-}"
EOF
  umask "$old_umask"
  chmod 600 "$(state_file)"
}

# Rewrite ONLY the mode fields (keeps the 9-positional-arg call sites stable).
_state_set_mode() { # $1=mode $2=ext_port
  state_load
  state_write "${SUB_URL:-}" "${CLASH_SECRET:-}" "${CLASH_ENABLED:-0}" \
    "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}" "${1:-internal}" "${2:-}"
}

# ---------- external clash detection (Clash Verge / ClashX / other kernels) ----------
# Other clash clients run their own mihomo on their own ports (Verge mixed default:
# 7897). aibox must KNOW: dual kernels double the subscription traffic and the
# egress gets ambiguous (measured live: state said enabled/7890 while Verge ran
# on 7897 and aibox's own kernel was dead — the stale-clash egress bug).
# Prints "<pid>\t<desc>" lines for NON-aibox clash processes; empty when none.
detect_external_clash() {
  local own_pid="" line pid desc
  [ -f "$(pid_file)" ] && own_pid="$(cat "$(pid_file)" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    pid="${line%% *}"
    desc="${line#* }"
    [ "${pid}" = "${own_pid}" ] && continue          # our own kernel
    case "${desc}" in
    *".aibox"* | *"${AIBOX_BIN_DIR:-/nonexistent}"*) continue ;;  # our binary path
    esac
    printf '%s\t%s\n' "${pid}" "${desc}"
  done <<EXTCLASH
$(pgrep -fl 'mihomo|clash-meta|clash-verge' 2>/dev/null || true)
EXTCLASH
}

# Probe an external mixed port (TCP connect; Verge answers SOCKS/HTTP there).
ext_port_alive() { # $1=port
  (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null
}

# Guess the external app from the process description.
ext_app_name() { # $1=desc
  case "${1}" in
  *"Clash Verge"* | *clash-verge*) printf 'Clash Verge' ;;
  *"ClashX"*) printf 'ClashX' ;;
  *) printf 'clash kernel' ;;
  esac
}

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 2>/dev/null
  else
    od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n'
  fi
}

# ---------- config generation (heredoc template; injects subscription / secret / ports) ----------
gen_config() {
  mkdir -p "$(clash_deploy_root)" "$(providers_dir)" "$(log_dir)"
  # Don't parse the subscription yaml: write it straight into proxy-providers; mihomo fetches/parses/tests/switches.
  cat >"$(config_file)" <<EOF
# Generated by aibox clash (don't hand-edit; overwritten by: aibox clash set/refresh)
mixed-port: ${CLASH_PORT}
external-controller: 127.0.0.1:${CLASH_API_PORT}
secret: "${CLASH_SECRET}"
allow-lan: false
mode: rule
log-level: warning

proxy-providers:
  pool:
    type: http
    url: "${SUB_URL}"
    interval: 86400
    path: $(providers_dir)/pool.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: AUTO
    type: url-test
    use: [pool]
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
  - name: FALLBACK
    type: fallback
    use: [pool]
    url: https://www.gstatic.com/generate_204
    interval: 300

rules:
  - MATCH,AUTO
EOF
}

# ---------- mihomo process (nohup + pid, simple cross-platform daemon) ----------
kernel_running() {
  [ -f "$(pid_file)" ] || return 1
  local pid
  pid="$(cat "$(pid_file)" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_kernel() {
  kernel_running && {
    log "mihomo already running (pid $(cat "$(pid_file)"))"
    return 0
  }
  [ -x "${KERNEL_DEST}" ] || die "mihomo not installed (first: aibox install clash)"
  [ -f "$(config_file)" ] || die "No config (first: aibox clash set <subscription-url>)"
  state_load
  [ -n "${SUB_URL:-}" ] || die "No subscription configured (first: aibox clash set <subscription-url>)"
  log "Starting mihomo ..."
  nohup "${KERNEL_DEST}" -d "$(clash_deploy_root)" -f "$(config_file)" \
    >"$(log_dir)/mihomo.log" 2>&1 &
  echo $! >"$(pid_file)"
  sleep 1
  if kernel_running; then
    log "mihomo started (pid $(cat "$(pid_file)"), mixed port ${CLASH_PORT})"
    # Mark enabled: aibox apply_proxy sees CLASH_ENABLED=1 and points egress at the local port.
    state_write "${SUB_URL}" "${CLASH_SECRET}" "1" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  else
    rm -f "$(pid_file)"
    die "mihomo failed to start; see log: $(log_dir)/mihomo.log"
  fi
}

stop_kernel() {
  kernel_running || {
    log "mihomo not running"
    rm -f "$(pid_file)"
    return 0
  }
  local pid
  pid="$(cat "$(pid_file)")"
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$(pid_file)"
  state_load
  state_write "${SUB_URL:-}" "${CLASH_SECRET:-}" "0" "${CLASH_PORT}" "${CLASH_API_PORT}" "${LAST_REFRESH:-0}" "${KERNEL_TAG:-}"
  log "mihomo stopped (aibox egress fell back to static proxy or direct connection)"
}

# ---------- mihomo REST API (external-controller) ----------
api_get() { # $1=path
  curl -fsSL -H "Authorization: Bearer ${CLASH_SECRET}" \
    "http://127.0.0.1:${CLASH_API_PORT}$1" 2>/dev/null
}
api_put() { # $1=path $2=body
  curl -fsSL -X PUT -H "Authorization: Bearer ${CLASH_SECRET}" \
    -H 'Content-Type: application/json' \
    --data "$2" "http://127.0.0.1:${CLASH_API_PORT}$1" 2>/dev/null
}

reload_config() {
  api_put '/configs?force=true' "{\"path\":\"$(config_file)\"}" &&
    log "Reloaded config" || warn "Reload failed (mihomo not running?)"
}

# ---------- dashboard (the module's rich view: state + nodes + latency) ----------
# Nodes come from mihomo's own proxy-provider view (the kernel parses the
# subscription, tests every node, and keeps the latency history — aibox only
# RENDERS it). Parsed without jq (project rule): split the provider JSON on
# `"name":` boundaries; per object keep the LAST "delay" (latest test) and
# "alive".
_nodes_lines() { # → "delay|alive|name" lines, sorted by delay (dead last)
  local json
  json="$(api_get /providers/proxies/pool 2>/dev/null || true)"
  [ -n "${json}" ] || return 0
  printf '%s' "${json}" | awk '
    {
      gsub(/"name":/, "\n")
      n = split($0, objs, "\n")
      # i starts at 3: chunk 2 is the PROVIDER header name ("pool") — its line
      # also embeds the first node fields, so alive/delay would mis-attribute.
      for (i = 3; i <= n; i++) {
        line = objs[i]
        # the chunk starts with the name OPENING quote: "name",... — extract
        # between the first and the following quote (a leading-quote sub would
        # cut the whole line — measured).
        name = ""
        if (match(line, /^"[^"]*"/)) name = substr(line, 2, RLENGTH - 2)
        if (name == "") continue
        # exclude mihomo builtin groups (they also appear in some provider views)
        if (name == "AUTO" || name == "DIRECT" || name == "REJECT" || name == "GLOBAL") continue
        alive = (line ~ /"alive":true/) ? 1 : 0
        delay = ""
        rest = line
        while (match(rest, /"delay":[0-9]+/)) {
          delay = substr(rest, RSTART + 9, RLENGTH - 9)
          rest = substr(rest, RSTART + RLENGTH)
        }
        printf "%s|%d|%s\n", (delay == "" ? "999999" : delay), alive, name
      }
    }' | sort -t'|' -k1,1n
}

# Render the module dashboard (invoked by `aibox clash dashboard`).
render_dashboard() {
  state_load
  local mode="${CLASH_MODE:-internal}" egress_port="${CLASH_PORT:-7890}"
  [ "${mode}" = "external" ] && egress_port="${CLASH_EXT_PORT:-${CLASH_PORT}}"
  printf '%s%s clash%s %s· %s mode%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${mode}" "${C_RST:-}"

  # --- state rows ---
  if [ "${mode}" = "external" ]; then
    local ext="$(detect_external_clash | head -1)" app="clash kernel"
    [ -n "${ext}" ] && app="$(ext_app_name "${ext#*\t}")"
    printf '  %s%-9s %s (external clash client — node control via its own app)\n' "${C_DIM:-}" "kernel:" "${app} on 127.0.0.1:${egress_port}"
  elif kernel_running; then
    printf '  %s%-9s mihomo v%s · pid %s\n' "${C_DIM:-}" "kernel:" "${KERNEL_TAG:-unknown}" "$(cat "$(pid_file)" 2>/dev/null)"
  else
    printf '  %s%-9s %snot running (aibox clash on)%s\n' "${C_DIM:-}" "kernel:" "${C_YEL:-}" "${C_RST:-}"
  fi
  printf '  %s%-9s 127.0.0.1:%s\n' "${C_DIM:-}" "egress:" "${egress_port}"
  [ "${mode}" = "internal" ] && printf '  %s%-9s 127.0.0.1:%s (secret %s)\n' "${C_DIM:-}" "api:" "${CLASH_API_PORT}" "$( [ -n "${CLASH_SECRET}" ] && printf 'set' || printf 'unset')"
  if [ -n "${SUB_URL:-}" ]; then
    local host="${SUB_URL#*://}"; host="${host%%/*}"
    printf '  %s%-9s %s · refreshed %s\n' "${C_DIM:-}" "sub:" "${host}" "$( [ -n "${LAST_REFRESH:-}" ] && [ "${LAST_REFRESH}" != "0" ] && date -r "${LAST_REFRESH}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'never')"
  else
    printf '  %s%-9s %snone (aibox clash set <subscription-url>)%s\n' "${C_DIM:-}" "sub:" "${C_YEL:-}" "${C_RST:-}"
  fi

  # --- nodes (internal mode only — external mode has no API access) ---
  if [ "${mode}" = "internal" ] && kernel_running; then
    local cur="" auto
    auto="$(api_get /proxies/AUTO 2>/dev/null || true)"
    [ -n "${auto}" ] && cur="$(printf '%s' "${auto}" | grep -oE '"now":[[:space:]]*"[^"]*"' | sed 's/.*: *"//; s/"$//')"
    echo
    local total="0" shown="0" line delay alive name mark
    while IFS='|' read -r delay alive name; do
      [ -n "${name}" ] || continue
      total=$((total + 1))
    done <<NODES
$(_nodes_lines)
NODES
    if [ "${total}" -gt 0 ]; then
      printf '  %s#  %-24s %-8s%s\n' "${C_DIM:-}" "node" "latency" "${C_RST:-}"
      while IFS='|' read -r delay alive name; do
        [ -n "${name}" ] || continue
        [ "${shown}" -ge 15 ] && continue
        shown=$((shown + 1))
        if [ "${name}" = "${cur}" ]; then mark="${C_GRN:-}✓${C_RST:-}"; else mark=""; fi
        # Full names, NO byte-truncation: printf %.Ns / ${name:0:N} count BYTES
        # in a C locale and cut multibyte CJK mid-character (mojibake — pitfall
        # #6). The column goes ragged for wide names; correctness wins.
        if [ "${alive}" = "1" ] && [ "${delay}" != "999999" ]; then
          printf '  %-3s %-24s %-8s %s\n' "${shown}" "${name}" "${delay}ms" "${mark}"
        else
          printf '  %-3s %-24s %-8s %s\n' "${shown}" "${name}" "${C_DIM:-}—${C_RST:-}" "${mark}"
        fi
      done <<NODES2
$(_nodes_lines)
NODES2
      [ "${total}" -gt "${shown}" ] && printf '  %s… %d more (full list: aibox clash select)\n' "${C_DIM:-}" "$((total - shown))"
      printf '\n  %scurrent %s · switch: aibox clash select <name>%s\n' "${C_DIM:-}" "${cur:-none}" "${C_RST:-}"
    else
      printf '\n  %sno nodes loaded yet (first refresh: aibox clash refresh)\n' "${C_DIM:-}"
    fi
  elif [ "${mode}" = "external" ]; then
    echo
    printf '  %snode list unavailable in external mode (managed by the clash app itself)\n' "${C_DIM:-}"
  fi
}

# Have mihomo immediately fetch the subscription (skip cache).
refresh_providers() {
  api_put '/providers/proxies/pool' '{"path":"pool","force":true}' >/dev/null 2>&1 || true
}

# ---------- subscription refresh (>1 week fallback: re-pull when found stale) ----------
WEEK=$((7 * 24 * 3600))
ensure_fresh() {
  state_load
  [ -n "${SUB_URL:-}" ] || return 0
  local now last stale
  now="$(date +%s)"
  last="${LAST_REFRESH:-0}"
  stale=0
  if [ "$last" = "0" ]; then
    stale=1
  else
    [ $((now - last)) -ge "$WEEK" ] && stale=1
  fi
  if [ "$stale" = "1" ]; then
    log "Subscription cache is over 1 week old (or never refreshed); re-fetching ..."
    refresh_now
  fi
}

# Force refresh: aibox fetches the subscription itself to overwrite pool.yaml + triggers mihomo reload.
refresh_now() {
  state_load
  [ -n "${SUB_URL:-}" ] || die "No subscription configured (first: aibox clash set <subscription-url>)"
  log "Fetching subscription $(mask_url "${SUB_URL}") ..."
  if curl -fsSL --max-time 30 "${SUB_URL}" -o "$(providers_dir)/pool.yaml.tmp" 2>/dev/null; then
    mv "$(providers_dir)/pool.yaml.tmp" "$(providers_dir)/pool.yaml"
    log "Updated $(providers_dir)/pool.yaml"
  else
    warn "aibox-side subscription fetch failed; leaving it to mihomo's internal interval retry"
  fi
  if kernel_running; then
    reload_config
    refresh_providers
  fi
  state_write "${SUB_URL}" "${CLASH_SECRET}" "${CLASH_ENABLED}" "${CLASH_PORT}" "${CLASH_API_PORT}" "$(date +%s)" "${KERNEL_TAG:-}"
  log "Refresh complete"
}

# ---------- status query ----------
show_status() {
  state_load
  if kernel_running; then
    log "mihomo running (pid $(cat "$(pid_file)"))"
    log "mixed port   127.0.0.1:${CLASH_PORT}"
    log "API          127.0.0.1:${CLASH_API_PORT}"
    [ -n "${SUB_URL:-}" ] && log "subscription $(mask_url "${SUB_URL}")"
    [ -n "${KERNEL_TAG:-}" ] && log "kernel ver    v${KERNEL_TAG}"
    log "last refresh ${LAST_REFRESH:-never}"
    local auto cur
    auto="$(api_get /proxies/AUTO 2>/dev/null || true)"
    if [ -n "$auto" ]; then
      cur="$(printf '%s' "$auto" | grep -oE '"now":[[:space:]]*"[^"]*"' | sed 's/.*: *"//; s/"$//')"
      log "current node ${cur:-none selected}"
    fi
  else
    warn "mihomo not running"
    [ -n "${SUB_URL:-}" ] && log "subscription $(mask_url "${SUB_URL}") (configured; start with: aibox clash on)"
    return 1
  fi
}

# ---------- probe via the local port ----------
probe_via_clash() {
  local url code used out
  url="${1:-https://www.gstatic.com/generate_204}"
  out="$(curl -s --max-time 8 -x "socks5://127.0.0.1:${CLASH_PORT}" \
    -o /dev/null -w '%{http_code} %{proxy_used}' "$url" 2>/dev/null)" || out=""
  [ -n "$out" ] || out="000 0"
  code="${out%% *}"
  used="${out##* }"
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    # curl <8.4 leaves %{proxy_used} empty — omit the field rather than print "proxy_used="
    log "Via mihomo    ${code}${used:+ (proxy_used=${used})}"
  else
    warn "Via mihomo    ${code} (proxy may be unavailable)"
  fi
}

# Dashboard interface (called by `aibox dashboard`): outputs endpoint/credential/log/health.
dashboard_info() {
  state_load
  echo "endpoint=socks5://127.0.0.1:${CLASH_PORT}"
  echo "credential=API secret ${CLASH_SECRET:-unset}"
  echo "log=$(log_dir)/mihomo.log"
  echo "health=curl -s -H 'Authorization: Bearer ${CLASH_SECRET}' http://127.0.0.1:${CLASH_API_PORT}/proxies/AUTO"
}

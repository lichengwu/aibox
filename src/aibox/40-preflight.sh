# ---------- preflight checks (MANDATORY contract for every module; docs/module-spec.md) ----------
# Every module declares its checks in module.yaml:
#   checks:
#     disk_gb: N            minimum free disk (GB) at $AIBOX_HOME's filesystem
#     domains: [host...]    domains that must be reachable (probed as https://<host>/)
#     docker_images: [ref]  when ALL are present locally, domain probes are skipped (offline)
#     commands: [cmd@plat]  binaries that must exist (OS facilities; no auto-install)
# install/update ENFORCE these (hard fail). --skip-checks / AIBOX_SKIP_CHECKS=1 bypasses.
# On network failure the engine tries the CONFIGURED alternative routes (direct / clash pool /
# static proxy) and adopts the first route that makes ALL failed domains reachable — for this
# run only; the warning tells you how to make it permanent.
# services: dependencies (base:postgres#db) are checked recursively: base must be installed;
# if its stack isn't running, base's own preflight decides whether install can proceed
# (ensure_services auto-starts it) or must fail.

_preflight_url() { case "$1" in http://*|https://*|file://*) printf '%s' "$1" ;; *) printf 'https://%s/' "$1" ;; esac; }

# Probe one URL via a named route. Any HTTP response (even 401/404) = reachable;
# only connection-level failure (000/empty) = unreachable (same philosophy as proxy check).
_preflight_probe_route() {
  local route="$1" url t code=""
  url="$(_preflight_url "$2")"
  t="${AIBOX_CHECK_TIMEOUT:-8}"
  case "$route" in
    current) code="$(curl -s -o /dev/null --max-time "$t" -w '%{http_code}' "$url" 2>/dev/null)" ;;
    direct)  code="$(curl -s --noproxy '*' -o /dev/null --max-time "$t" -w '%{http_code}' "$url" 2>/dev/null)" ;;
    clash)
      local st="${AIBOX_HOME}/apps/clash/state" p
      [ -f "$st" ] || return 1
      # shellcheck source=/dev/null
      p="$( . "$st" 2>/dev/null; printf '%s' "${CLASH_PORT:-7890}" )"
      code="$(curl -s -x "socks5://127.0.0.1:${p}" -o /dev/null --max-time "$t" -w '%{http_code}' "$url" 2>/dev/null)" ;;
    proxy)
      [ -n "${AIBOX_PROXY_URL:-}" ] || return 1
      code="$(curl -s -x "$AIBOX_PROXY_URL" -o /dev/null --max-time "$t" -w '%{http_code}' "$url" 2>/dev/null)" ;;
    mirror)
      # GitHub-family domains via a gh-proxy-style URL-prefix mirror (CLASH_MIRROR /
      # AIBOX_GH_MIRROR). Bootstrap paradox solver: on CN networks github.com may be
      # unreachable while the mirror is fine — and clash (the network fixer) itself
      # downloads from GitHub. Prefix mirrors fetch ANY https URL as <mirror>/<url>.
      local mp="${CLASH_MIRROR:-${AIBOX_GH_MIRROR:-}}"
      [ -n "$mp" ] || return 1
      case "$url" in
        https://github.com/*|https://raw.githubusercontent.com/*|https://objects.githubusercontent.com/*|https://release-assets.githubusercontent.com/*) ;;
        *) return 1 ;;
      esac
      code="$(curl -s -o /dev/null --max-time "$t" -w '%{http_code}' "${mp%/}/${url}" 2>/dev/null)" ;;
    *) return 1 ;;
  esac
  [ -n "$code" ] && [ "$code" != "000" ]
}

# Switch THIS process's egress to a route (run-scoped; hint says how to persist).
_preflight_adopt() {
  local route="$1" st p eff
  case "$route" in
    direct)
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
      export no_proxy="*" NO_PROXY="*"
      warn "adopting direct connection for this run (current route failed); persist: aibox proxy off / aibox clash off" ;;
    clash)
      st="${AIBOX_HOME}/apps/clash/state"; p=7890
      # shellcheck source=/dev/null
      [ -f "$st" ] && p="$( . "$st" 2>/dev/null; printf '%s' "${CLASH_PORT:-7890}" )"
      eff="socks5://127.0.0.1:${p}"
      export http_proxy="$eff" https_proxy="$eff" all_proxy="$eff" HTTP_PROXY="$eff" HTTPS_PROXY="$eff"
      warn "adopting clash pool (${eff}) for this run; persist: aibox clash on" ;;
    proxy)
      export http_proxy="$AIBOX_PROXY_URL" https_proxy="$AIBOX_PROXY_URL" all_proxy="$AIBOX_PROXY_URL" \
             HTTP_PROXY="$AIBOX_PROXY_URL" HTTPS_PROXY="$AIBOX_PROXY_URL"
      warn "adopting static proxy $(mask_url "$AIBOX_PROXY_URL") for this run; persist: aibox proxy on" ;;
    mirror)
      # Nothing to export: a prefix mirror is not a proxy. Modules must honor
      # CLASH_MIRROR themselves (the clash module's downloader does).
      warn "GitHub-family domains reachable only via mirror ${CLASH_MIRROR:-${AIBOX_GH_MIRROR:-}} — module downloads must honor CLASH_MIRROR/AIBOX_GH_MIRROR (clash does)" ;;
  esac
  AIBOX_PROXY_SOURCE="preflight-${route}"
}

# Free disk (integer GB) at a path (walks up to the nearest existing ancestor).
_disk_free_gb() {
  local d="$1" kb
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  kb="$(df -k "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  printf '%s' "$(( ${kb:-0} / 1048576 ))"
}

# deps, strict: missing after an auto-install attempt → FAIL (old check_deps only warned).
# Which package-manager invocation satisfies a dep command — several dep
# entries can share ONE install (docker covers docker-compose; node covers npm).
_dep_install_unit() { # $1=dep command
  case "$1" in
    docker|docker-compose) printf 'docker' ;;
    node|npm)              printf 'node' ;;
    *)                     printf '%s' "$1" ;;
  esac
}

_preflight_deps() {
  local name="$1" deps plat dep cmd ptag ver fail=0 os unit attempted=""
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  plat="$(module_field "$name" platform)"
  if [ -n "$plat" ] && [ "$plat" != "$os" ]; then return 0; fi
  deps="$(module_field "$name" deps)"
  [ -n "$deps" ] || return 0
  for dep in $deps; do
    cmd="$dep"; ptag=""; ver=""
    case "$dep" in
      *@*) cmd="${dep%@*}"; ptag="${dep#*@}" ;;
    esac
    case "$cmd" in
      *:*) ver="${cmd#*:}"; cmd="${cmd%%:*}" ;;
    esac
    if [ -n "$ptag" ] && [ "$ptag" != "$os" ]; then
      info "  - ${cmd}@${ptag} (skipped on $(uname -s))"
      continue
    fi
    if dep_satisfied "$cmd" "$ver"; then
      info "✓ ${cmd}${ver:+ (>=${ver})}"
    else
      # AIBOX_NO_AUTO_DEPS gates PM auto-installs too (it used to gate only
      # service-dep installs, so `install x` with the knob set still shelled
      # out to apt — surprising for the users who set it to stay manual)
      if [ "${AIBOX_NO_AUTO_DEPS:-0}" = "1" ]; then
        bad "${cmd}${ver:+ (>=${ver})} not satisfied (required by ${name}; auto-install disabled: AIBOX_NO_AUTO_DEPS=1)"
        fail=1
        continue
      fi
      # One package install can cover SEVERAL dep entries (docker.io +
      # docker-compose-v2 covers docker AND docker-compose; nodejs+npm covers
      # node AND npm) — a second attempt in the same run is pure waste
      # (live-caught: the identical apt command ran twice per preflight)
      unit="$(_dep_install_unit "$cmd")"
      case " ${attempted} " in
      *" ${unit} "*)
        bad "${cmd}${ver:+ (>=${ver})} not satisfied (required by ${name}; the ${unit} install was already attempted this run)"
        fail=1
        continue ;;
      esac
      attempted="${attempted}${attempted:+ }${unit}"
      warn "${cmd} missing — attempting auto-install..."
      install_dep "$cmd" "$ver" || true
      if dep_satisfied "$cmd" "$ver"; then
        info "✓ ${cmd} (auto-installed)"
      else
        bad "${cmd}${ver:+ (>=${ver})} not satisfied (required by ${name})"
        fail=1
      fi
    fi
  done
  return $fail
}

# checks.commands — must exist; no auto-install (OS facilities like systemctl/launchctl).
_preflight_commands() {
  local name="$1" cmds c cmd ptag os fail=0
  cmds="$(module_field "$name" checks_commands)"
  [ -n "$cmds" ] || return 0
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  for c in $cmds; do
    cmd="$c"; ptag=""
    case "$c" in *@*) cmd="${c%@*}"; ptag="${c#*@}" ;; esac
    if [ -n "$ptag" ] && [ "$ptag" != "$os" ]; then continue; fi
    if command -v "$cmd" >/dev/null 2>&1; then
      info "✓ $cmd"
    else
      bad "$cmd not found (required by ${name})"
      fail=1
    fi
  done
  return $fail
}

# checks.disk_gb — free space at $AIBOX_HOME's filesystem.
_preflight_disk() {
  local name="$1" req free
  req="$(module_field "$name" checks_disk_gb)"
  [ -n "$req" ] || return 0
  free="$(_disk_free_gb "$AIBOX_HOME")"
  if [ "$free" -lt "$req" ]; then
    bad "disk: ${free}G free at ${AIBOX_HOME}, ${name} requires ${req}G"
    return 1
  fi
  info "✓ disk: ${free}G free (requires ${req}G)"
}

# Shared short-circuit: all checks.docker_images present locally?
_preflight_images_cached() {
  local name="$1" imgs i
  imgs="$(module_field "$name" checks_docker_images)"
  [ -n "$imgs" ] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  for i in $imgs; do docker image inspect "$i" >/dev/null 2>&1 || return 1; done
  return 0
}

# Probe the CURRENT route with one immediate retry: transient hiccups are common
# right after `clash on` (mihomo node health-checks still settling — measured live:
# a single api.github.com probe failed, then 8/8 passed seconds later). One retry
# prevents a blip from flipping the whole run onto a fallback route.
_preflight_probe_current() {
  _preflight_probe_route current "$1" && return 0
  sleep 1
  _preflight_probe_route current "$1"
}

# checks.domains — HOST-curl semantics (for git/npm/curl consumers), with the
# docker_images cache short-circuit + configured-route fallback/adoption.
# NOTE: do NOT declare registry domains whose consumer is the docker daemon —
# host egress diverges from daemon egress (Docker Desktop VM, daemon.json
# mirrors, daemon proxy). Use checks.docker_pull for those.
_preflight_domains() {
  local name="$1" doms d failed="" route still
  doms="$(module_field "$name" checks_domains)"
  [ -n "$doms" ] || return 0
  if _preflight_images_cached "$name"; then
    info "✓ docker images cached — skipping domain probes"
    return 0
  fi
  for d in $doms; do
    if _preflight_probe_current "$d"; then
      info "✓ ${d} reachable"
    else
      failed="${failed} ${d}"
    fi
  done
  [ -z "$failed" ] && return 0
  warn "unreachable via current route:${failed} — trying configured alternatives (direct/clash/static proxy)..."
  for route in direct clash mirror proxy; do
    still=""
    for d in $failed; do
      _preflight_probe_route "$route" "$d" || still="${still} ${d}"
    done
    if [ -z "$still" ]; then
      _preflight_adopt "$route"
      info "✓ all domains reachable via ${route}"
      return 0
    fi
  done
  bad "unreachable domains:${failed}"
  info "    fix: aibox proxy set <url>  /  aibox clash set <sub> + aibox clash on  /  check network"
  return 1
}

# checks.docker_pull — DAEMON-routed registry probe (tiny image, e.g. hello-world).
# Proves the docker daemon's actual pull path works (its proxy/mirrors differ
# from the host's — aibox proxy/clash settings do NOT apply to the daemon).
_preflight_docker_pull() {
  local name="$1" img
  img="$(module_field "$name" checks_docker_pull)"
  [ -n "$img" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0   # absence is reported by deps
  if _preflight_images_cached "$name"; then
    info "✓ docker images cached — skipping pull probe"
    return 0
  fi
  info "probing daemon registry path (docker pull ${img}) ..."
  if docker pull -q "$img" >/dev/null 2>&1; then
    info "✓ docker daemon can pull images (${img})"
    return 0
  fi
  bad "docker daemon cannot pull ${img}"
  info "    daemon egress ≠ host egress: configure /etc/docker/daemon.json registry-mirrors (Linux)"
  info "    or Docker Desktop → Settings → Resources → Proxies. aibox proxy/clash settings do NOT affect the daemon."
  return 1
}

# services: base:<component>#<res> → base installed + running (or recoverable).
_preflight_services() {
  local name="$1" svcs svc component suffix cname prof fail=0 checked_ok="" checked_bad="" missed=""
  svcs="$(module_field "$name" services)"
  [ -n "$svcs" ] || return 0
  prof="${AIBOX_PROFILE:-base}"; suffix=""
  [ "$prof" != "base" ] && suffix="-${prof}"
  for svc in $svcs; do
    case "$svc" in base:*) ;; *) continue ;; esac
    component="${svc#base:}"; component="${component%%#*}"
    if ! is_installed base; then
      case " ${missed} " in
        *" base "*) bad "base:${component} not ready (base not installed — see above)" ;;
        *)
          bad "service dep base not installed (fix: aibox${suffix:+ --profile ${prof}} install base)"
          missed="${missed} base" ;;
      esac
      fail=1
      continue
    fi
    cname="aibox-base${suffix}-${component}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
      info "✓ base:${component} ready (${cname})"
      continue
    fi
    # Not running — recoverable? Check base's own preflight (once per run).
    case " ${checked_ok} " in *" base "*) info "✓ base:${component} startable (base verified above)"; continue ;; esac
    case " ${checked_bad} " in *" base "*) bad "base:${component} not ready (base preflight failed above)"; fail=1; continue ;; esac
    warn "base:${component} not running (${cname}) — checking base's own requirements..."
    if preflight_module base; then
      checked_ok="${checked_ok} base"
      info "✓ base is startable — install will bring it up (ensure_services)"
    else
      checked_bad="${checked_bad} base"
      bad "base:${component} not ready and base's own preflight failed"
      fail=1
    fi
  done
  return $fail
}

# Full preflight for one module — the install/update gate.
preflight_module() {
  local name="$1" fail=0 hard=0
  if [ "${PREFLIGHT_SKIP:-0}" = "1" ]; then
    warn "Preflight skipped for ${name} (--skip-checks)"
    return 0
  fi
  log "Preflight: ${name}"
  # hard = not bypassable (missing deps/commands/services); soft = environment
  # conditions (disk/network/pull) where --skip-checks is a real option. The
  # old single hint suggested --skip-checks even for missing hard deps, which
  # only deferred the failure to a confusing mid-install crash (live-caught).
  _preflight_deps       "$name" || { fail=1; hard=1; }
  _preflight_commands   "$name" || { fail=1; hard=1; }
  _preflight_disk       "$name" || fail=1
  _preflight_domains    "$name" || fail=1
  _preflight_docker_pull "$name" || fail=1
  _preflight_services   "$name" || { fail=1; hard=1; }
  if [ "$fail" != "0" ]; then
    if [ "$hard" = "1" ]; then
      bad "Preflight FAILED: ${name} — fix the issues above (missing dependencies/services can't be bypassed; --skip-checks would only defer the failure)"
      # 3 = dependency missing, 4 = precheck failed (docs/module-spec.md §Exit codes)
      return 3
    fi
    bad "Preflight FAILED: ${name} — fix the issues above, or re-run with --skip-checks to bypass"
    return 4
  fi
  ok "Preflight passed: ${name}"
}

# `aibox check` — environment check; `aibox check <module>` — that module's preflight.
cmd_check() {
  local target="" want_json=0 a
  for a in "$@"; do
    case "${a}" in
      -h | --help) _verb_help check; return 0 ;;
      --json) want_json=1 ;;
      *) [ -z "${target}" ] && target="${a}" || usage_die "Usage: aibox check <module>|self [--json]" ;;
    esac
  done
  [ -n "$target" ] || usage_die "Usage: aibox check <module>|self [--json]   (self = environment check)"
  if [ "${want_json}" = "1" ]; then
    # machine-readable envelope: the same verdict the human path exits with, plus
    # the human detail lines as an array (probes print prose; the envelope is the
    # contract: module, ok, exit, details).
    local out rc=0
    out="$(cmd_check_inner "${target}" 2>&1)" || rc=$?
    printf '{\n'
    json_kv_str module "${target}"; printf ',\n'
    json_kv_bool ok "$([ "${rc}" -eq 0 ] && printf 1 || printf 0)"; printf ',\n'
    json_kv_num exit "${rc}"; printf ',\n'
    printf '"details": ['
    local line first=1
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      [ "${first}" = "1" ] || printf ','
      printf '\n    %s' "$(json_str "${line}")"
      first=0
    done <<DETAILS
${out}
DETAILS
    [ "${first}" = "1" ] && printf ']' || printf '\n  ]'
    printf '\n}\n'
    return "${rc}"
  fi
  cmd_check_inner "${target}"
}

cmd_check_inner() { # $1=module|self → the human check (shared by --json and plain)
  local target="$1"
  if [ "$target" = self ]; then cmd_self_check; return $?; fi
  load_registry
  module_exists "$target" || die_unknown_module "$target"
  preflight_module "$target"
}

# Environment check = the manager's own preflight ("self is a module too").
cmd_self_check() {
  printf '%s%s%s\n' "$C_BOLD" "aibox environment check" "$C_RST"
  case "${AIBOX_PROXY_SOURCE:-}" in
    clash)    info "egress:      clash pool (socks5://127.0.0.1:${CLASH_PORT:-7890})" ;;
    config)   info "egress:      static proxy $(mask_url "${AIBOX_PROXY_URL:-}")" ;;
    env)      info "egress:      environment proxy $(mask_url "${AIBOX_PROXY_URL:-}")" ;;
    disabled) info "egress:      direct (proxy configured but disabled)" ;;
    *)        info "egress:      direct" ;;
  esac
  local core="raw.githubusercontent.com api.github.com" d failed="" route still
  for d in $core; do
    if _preflight_probe_current "$d"; then
      info "✓ ${d}"
    else
      failed="${failed} ${d}"
    fi
  done
  if [ -n "$failed" ]; then
    warn "unreachable via current route:${failed} — trying alternatives"
    for route in direct clash mirror proxy; do
      still=""
      for d in $failed; do _preflight_probe_route "$route" "$d" || still="${still} ${d}"; done
      if [ -z "$still" ]; then _preflight_adopt "$route"; failed=""; break; fi
    done
    [ -n "$failed" ] && bad "core domains unreachable:${failed}"
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
  else
    warn "docker not available$(_needed_note docker)"
  fi
  # node/npm matter to pi-web but were never checked here (live-caught: the
  # first hint of a missing node was a failed install 10 minutes in)
  for _tool in node npm; do
    if command -v "${_tool}" >/dev/null 2>&1; then
      info "✓ ${_tool}"
    else
      warn "${_tool} not available$(_needed_note "${_tool}")"
    fi
  done
  info "disk free:    $(_disk_free_gb "$AIBOX_HOME")G at AIBOX_HOME"
  info "module preflight: aibox check <module>"
  [ -z "$failed" ]
}

# ---------- dependency check + auto-install ----------
# Retry-with-backoff package install: the Aliyun internal mirror was measured
# throwing transient "Empty reply" (curl error 52) on individual .rpm files AND
# repomd.xml, with flaky windows lasting minutes — a single immediate retry can
# land in the same window. 3 attempts (0s/5s/20s backoff) rode through it live.
# Retry-with-backoff package install, BOUNDED: the old version could hang
# unbounded with no output (live-caught: `install pi-web` sat 10+ minutes inside
# a node auto-install with no progress line). Output goes to a log — replayed as
# a tail on failure — and a heartbeat every 30s shows it's still alive.
# AIBOX_PM_TIMEOUT=0 disables the bound.
_pm_install() {
  local pm="$1" n=0 wait_s timeout_s waited timed_out pid rc logf
  shift
  timeout_s="${AIBOX_PM_TIMEOUT:-600}"
  while :; do
    n=$((n+1))
    log "  ${pm} install -y $*  (bounded ${timeout_s}s — downloads can take minutes)"
    logf="$(mktemp "${TMPDIR:-/tmp}/pm-install.XXXXXX")" || logf=""
    if [ -n "$logf" ]; then ${pm} install -y "$@" >"$logf" 2>&1 & else ${pm} install -y "$@" & fi
    pid=$!
    waited=0; timed_out=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "${timeout_s}" -gt 0 ] && [ "$waited" -ge "$timeout_s" ]; then timed_out=1; break; fi
      sleep 5; waited=$(( waited + 5 ))
      [ $(( waited % 30 )) -eq 0 ] && log "  … still installing (${waited}s)"
    done
    rc=0
    if [ "$timed_out" = "1" ]; then
      # children FIRST, then the parent — parent-first lets untrapped child
      # shells reparent to init and keep running (the orphan-kill lesson)
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      warn "  ${pm} install timed out after ${timeout_s}s — killed (raise: AIBOX_PM_TIMEOUT=<seconds>; 0 = unlimited)"
      if [ -n "$logf" ]; then tail -3 "$logf" >&2; rm -f "$logf"; fi
      return 1
    fi
    wait "$pid" || rc=$?
    if [ "$rc" -eq 0 ]; then if [ -n "$logf" ]; then rm -f "$logf"; fi; return 0; fi
    if [ -n "$logf" ]; then tail -3 "$logf" >&2; rm -f "$logf"; fi
    [ "$n" -ge 3 ] && return 1
    wait_s=$((n*n*5))
    warn "  ${pm} install failed (transient mirror error?) — retry ${n}/2 in ${wait_s}s..."
    sleep "$wait_s"
  done
}

# deps field format: command name, optional @platform or :version.
# deps examples: "docker@linux docker-compose python3" "node:22 npm" ""
# @platform: only checked on that platform (docker@linux = check on Linux only)
# :version: version constraint (node:22 = major version >= 22)
# Check whether a dependency command is satisfied (incl. version constraint).
dep_satisfied() {
  local cmd="$1" ver="${2:-}" cur
  case "$cmd" in
    docker-compose)
      docker compose version >/dev/null 2>&1 && return 0
      command -v docker-compose >/dev/null 2>&1 && return 0
      return 1 ;;
    *)
      command -v "$cmd" >/dev/null 2>&1 || return 1
      [ -z "$ver" ] && return 0
      cur="$("$cmd" -v 2>/dev/null | grep -oE '[0-9]+' | head -1)"
      [ -n "$cur" ] && [ "$cur" -ge "$ver" ] 2>/dev/null && return 0
      return 1 ;;
  esac
}

# ---------- node-dist source pool (for nvm installs) ----------
# nodejs.org is slow/blocked on CN networks (measured: 1.7-5.1s for the dist
# index vs 0.05-0.12s on the mainstream mirrors). Live-verified mirrors
# (byte-identical on FIXED-version paths — hash-checked d67cdb735b… ×3):
# npmmirror.com/mirrors/node (Alibaba), mirrors.aliyun.com/nodejs-release.
# tencent EXCLUDED — its index.json content diverges (measured 329756B vs
# 331021B). Probes the REAL file nvm fetches first (<base>/index.json, ~330KB)
# concurrently, bounded; the fastest VALID response (≥ 100KB — a 404 error page
# is small AND fast, which would fake a high rate) wins and is exported as
# NVM_NODEJS_ORG_MIRROR (nvm's documented env). A mirror only wins by
# MEASUREMENT — healthy networks keep nodejs.org.
# Knobs: AIBOX_NODE_POOL (override list; "direct" = disabled), AIBOX_NODE_MIRROR
# (user mirror, raced first), AIBOX_NODE_PROBE_TIMEOUT (default 8s).
NODE_DIST_POOL_DEFAULT="https://npmmirror.com/mirrors/node https://mirrors.aliyun.com/nodejs-release"

_node_dist_pick() { # → the winning dist base URL (DIRECT = https://nodejs.org/dist)
  local cands u tmpd pid pids="" i best tstat size t rate
  case "${AIBOX_NODE_POOL:-}" in
  direct | none | off)
    printf 'https://nodejs.org/dist'
    return 0
    ;;
  esac
  cands="https://nodejs.org/dist"
  if [ -n "${AIBOX_NODE_MIRROR:-}" ]; then cands="${AIBOX_NODE_MIRROR%/} ${cands}"; fi
  # shellcheck disable=SC2086
  for u in ${AIBOX_NODE_POOL:-${NODE_DIST_POOL_DEFAULT}}; do cands="${cands} ${u%/}"; done
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/nodedist.XXXXXX")" || { printf 'https://nodejs.org/dist'; return 0; }
  i=0
  # shellcheck disable=SC2086
  for u in $cands; do
    i=$((i + 1))
    (
      tstat="$(curl -sL -o /dev/null -w '%{size_download} %{time_total}' --max-time "${AIBOX_NODE_PROBE_TIMEOUT:-8}" "${u}/index.json" 2>/dev/null || true)"
      size="${tstat%% *}"
      t="${tstat##* }"
      rate="$(printf '%s %s' "${size:-0}" "${t:-0}" | awk '{t=$2+0; if (t>0) printf "%d", $1/t; else print 0}')"
      if [ "${size:-0}" -ge 100000 ] && [ "${rate:-0}" -gt 0 ]; then
        printf '%s\t%s\n' "${rate}" "${u}" >"${tmpd}/r${i}.res"
      fi
    ) &
    pids="${pids} $!"
  done
  # shellcheck disable=SC2086
  for pid in $pids; do wait "${pid}" 2>/dev/null || true; done
  best="$(cat "${tmpd}"/*.res 2>/dev/null | sort -rn | head -1 | cut -f2)"
  rm -rf "${tmpd}"
  [ -n "${best}" ] || best="https://nodejs.org/dist"
  printf '%s' "${best}"
}

# Auto-install deps by platform. Lightweight / has a package manager -> install; needs sudo
# or GUI interaction -> print the manual command.
install_dep() {
  local cmd="$1" ver="${2:-}" os pm eng comp root
  os="$(uname -s)"
  root=0; [ "$(id -u)" = "0" ] && root=1
  info "Auto-installing ${cmd} ..."
  if [ "$os" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1; then pm="brew"
    else warn "  No Homebrew (install brew and retry: https://brew.sh)"; return 1; fi
  elif command -v apt-get >/dev/null 2>&1; then pm="apt-get"
  elif command -v dnf >/dev/null 2>&1; then pm="dnf"
  elif command -v yum >/dev/null 2>&1; then pm="yum"
  else warn "  No apt/yum/dnf; install ${cmd} manually"; return 1; fi
  case "$cmd" in
    docker|docker-compose)
      if [ "$os" = "Darwin" ]; then
        info "brew install --cask docker (Docker Desktop, includes compose v2)"
        brew install --cask docker || { warn "  Docker Desktop install failed (download manually: https://docker.com)"; return 1; }
        warn "  After install, start Docker.app and accept the license (can't be fully automated)"
      elif [ "$root" = "1" ]; then
        # Root: no privilege escalation needed — actually install (policy: never
        # SILENTLY sudo; running as root is not sudo). Package-name fallbacks:
        # docker-ce (get.docker.com repo) → moby-engine (RHEL9/AlibabaCloudLinux
        # native, measured on AL4) → docker.io (Debian-family). Compose v2 comes
        # from the plugin package (dep_satisfied accepts `docker compose`).
        case "$pm" in
          apt-get) eng="docker.io"; comp="docker-compose-v2" ;;
          *)       eng="docker-ce"; comp="docker-compose-plugin" ;;
        esac
        info "${pm} install -y ${eng} ${comp} (running as root)"
        _pm_install "$pm" "$eng" "$comp" 2>/dev/null \
          || ${pm} install -y moby-engine docker-compose-plugin 2>/dev/null \
          || ${pm} install -y docker.io docker-compose-v2 2>/dev/null \
          || { warn "  package install failed (tried ${eng}+${comp}, moby-engine, docker.io variants)"; return 1; }
        # Only claim "installed" once the CLI actually exists — the old flow
        # announced "docker installed but the daemon didn't start" even when
        # no binary ever appeared (live-caught on a mirror that lied).
        if ! command -v docker >/dev/null 2>&1; then
          warn "  the install commands returned but no docker CLI appeared — see the package manager output above"
          return 1
        fi
        # AL4/RHEL-family moby-engine ships WITHOUT the docker group, but
        # docker.socket has SocketGroup=docker → socket fails → service fails
        # in a dependency cascade (measured live on Alibaba Cloud Linux 4).
        getent group docker >/dev/null 2>&1 || groupadd docker 2>/dev/null || true
        if ! { systemctl --now enable docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1; }; then
          warn "  docker CLI installed, but the daemon isn't running — run: systemctl --now enable docker"
        fi
      else
        warn "  docker needs sudo, run: sudo ${pm} install -y docker.io docker-compose-v2 && sudo systemctl --now enable docker"
        warn "  (RHEL-family without the docker-ce repo: sudo ${pm} install -y moby-engine docker-compose-plugin)"
        return 1
      fi ;;
    node|npm)
      if [ -s "$HOME/.nvm/nvm.sh" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.nvm/nvm.sh"
        # node-dist source pool: the fastest dist mirror serves (measured on the
        # REAL index.json nvm fetches; DIRECT stays default on healthy networks).
        # A failed pick must NOT silently export an empty mirror (nvm's :-
        # default would mask it) — warn so the fallback is diagnosable. Deliberate
        # AIBOX_NODE_POOL=direct skips the pick WITHOUT the warn. Empty → unset
        # (semantically "use nvm's default"), not export "".
        node_mirror=""
        if [ "${AIBOX_NODE_POOL:-}" != "direct" ]; then
          node_mirror="$(_node_dist_pick 2>/dev/null || true)"
          [ -n "${node_mirror}" ] || warn "  node-dist pool unavailable — nvm will fetch from nodejs.org directly"
        fi
        if [ -n "${node_mirror}" ]; then
          export NVM_NODEJS_ORG_MIRROR="${node_mirror}"
        else
          unset NVM_NODEJS_ORG_MIRROR
        fi
        info "node dist: ${NVM_NODEJS_ORG_MIRROR:-nodejs.org (direct)}"
        nvm install 22 && nvm use 22 >/dev/null
      elif [ "$pm" = "brew" ]; then brew install node@22
      elif [ "$root" = "1" ]; then
        # A distro nodejs frequently predates the required major (measured:
        # Ubuntu 24.04 ships 18 vs the declared node:22) — installing it and
        # rechecking burns minutes and still fails. When the candidate is
        # knowably too old, skip straight to the reliable path with the exact
        # command the user needs (this was a hard dead end: "not satisfied"
        # with no way forward).
        local cand="" cmaj=""
        if [ -n "$ver" ] && [ "$pm" = "apt-get" ] && command -v apt-cache >/dev/null 2>&1; then
          cand="$(apt-cache policy nodejs 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
        fi
        if [ -n "$cand" ]; then
          cmaj="${cand%%.*}"
          case "$cmaj" in ''|*[!0-9]*) cmaj="" ;; esac
        fi
        if [ -n "$cmaj" ] && [ "$cmaj" -lt "${ver:-0}" ]; then
          warn "  the distro nodejs candidate is v${cmaj} (< required ${ver}) — installing it would not satisfy the check"
          warn "  install node ${ver} via nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && nvm install ${ver}"
          warn "  (script host blocked? prefix a mirror, e.g. https://gh-proxy.com/)"
          return 1
        fi
        _pm_install "$pm" nodejs npm || ${pm} install -y nodejs \
          || warn "  distro nodejs unavailable; prefer nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash (raw blocked? prefix a mirror, e.g. https://gh-proxy.com/)"
        return 1   # preflight rechecks the version (distro nodejs may be < 22)
      else warn "  Install node via nvm (curl nvm | bash) or: sudo ${pm} install nodejs"; return 1; fi ;;
    python3)
      if [ "$os" = "Darwin" ]; then warn "  macOS ships python3 (/usr/bin/python3); if missing install Xcode CLT: xcode-select --install"
      elif [ "$root" = "1" ]; then _pm_install "$pm" python3 || { warn "  python3 install failed"; return 1; }
      else warn "  Run: sudo ${pm} install -y python3"; return 1; fi ;;
    git)
      if [ "$os" = "Darwin" ]; then warn "  macOS ships git (Xcode CLT); if missing: xcode-select --install"
      elif [ "$root" = "1" ]; then _pm_install "$pm" git || { warn "  git install failed"; return 1; }
      else warn "  Run: sudo ${pm} install -y git"; return 1; fi ;;
    *) warn "  Unknown dependency ${cmd}; install manually"; return 1 ;;
  esac
}


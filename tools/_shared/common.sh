# aibox shared module library — output helpers + docker.io download source pool.
# Repo: tools/_shared/common.sh (single source). Ships INTO each module cache as
# _common.sh (declared via `includes: [common]` in module.yaml) — modules stay
# self-contained per-directory; the repo stays single-source. Sourced by lib.sh:
#   LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${LIB_SELF}/_common.sh"
# (no shebang / no strict-mode line — it is a sourced library, like lib.sh)

# ---------- output helpers ----------
# Colors are inherited from aibox via exported C_* env vars (single source of
# truth); ${C_*:-} falls back to plain output standalone. Symbols: ⚠ warn / ✓ ok
# / ✗ die, two-space gap (spec §Output conventions).
log() { printf '%s\n' "$*"; }
warn() { printf '%s⚠%s  %s\n' "${C_YEL:-}" "${C_RST:-}" "$*" >&2; }
ok() { printf '%s✓%s  %s\n' "${C_GRN:-}" "${C_RST:-}" "$*"; }
info() { printf '%s  %s%s\n' "${C_DIM:-}" "$*" "${C_RST:-}"; }
die() {
  printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2
  exit 1
}

# Guard for docker-dependent actions. Without it a missing docker binary
# surfaced as a raw shell error from a deep lib line (live-caught:
# `aibox base status` → "tools/base/lib.sh: line 138: docker: command not
# found", exit 127) with no hint about what the action actually needs.
require_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  die "docker CLI not found — this action needs it (install docker, then: aibox check ${AIBOX_MODULE:-<module>})"
}

# Path to the sibling base module's svc.sh. In the dispatched cache layout the
# manager injects AIBOX_MOD_DIR, which is authoritative — its absence means base
# is NOT installed. Direct repo execution (bats / dev) falls back to the sibling
# dir: _common.sh sits next to lib.sh in the cache and in tools/_shared in the
# repo, both exactly one level below the sibling module dir.
shared_base_svc_path() {
  if [ -n "${AIBOX_MOD_DIR:-}" ]; then
    printf '%s/base/svc.sh' "${AIBOX_MOD_DIR}"
    return 0
  fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/../base/svc.sh' "${d}"
}

# Idempotent "the shared base must be UP for this action" — the action-time
# twin of the manager's ensure_services. Live-caught: `aibox xiaozhi start`
# died with "shared base not running … first: aibox base start" — two commands
# for one intent. base already up → silent no-op; installed but down → start it
# (compose up -d is idempotent) and wait for the network; not installed or not
# startable → die (without the provider the module cannot run at all).
ensure_shared_base() {
  require_docker
  local svc base_env net waited=0 timeout_s
  svc="$(shared_base_svc_path)"
  [ -f "$svc" ] || die "the shared base module is not installed — first: aibox install base"
  base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
  net="$(grep -E '^AIBOX_BASE_NETWORK=' "$base_env" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "${net}" ] || net="aibox-base"
  # both are written by `base start` and are what the consumer's compose needs
  if [ -f "$base_env" ] && docker network inspect "${net}" >/dev/null 2>&1; then
    return 0
  fi
  info "shared base is not running — starting it (this action needs the ${net} network)…"
  AIBOX_MODULE=base bash "$svc" start || die "shared base failed to start — check: aibox base logs"
  timeout_s="${AIBOX_BASE_WAIT_TIMEOUT:-120}"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if [ -f "$base_env" ] && docker network inspect "${net}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  die "the shared base did not become ready within ${timeout_s}s — check: aibox base status"
}

# ---------- shared diagnostics (`doctor`) ----------
# Every module exposes a `doctor` action with the SAME shape (the audit found
# doctor/check/diagnose/-none across modules and a hint pointing at a
# non-existent `aibox base doctor`). Checks: declared deps, docker when declared,
# the module's own reported state, and the declared port listeners — all local
# (no network). Exit: 0 healthy · 3 a dependency is missing · 30 not ready
# (docs/module-spec.md §Exit codes); 1 for a partial report.
port_listening() { # $1=port → 0 when something listens
  local p="$1" lsof ss
  lsof="$(command -v lsof 2>/dev/null || true)"; [ -x "${lsof}" ] || lsof="/usr/sbin/lsof"
  ss="$(command -v ss 2>/dev/null || true)";     [ -x "${ss}" ] || ss="/usr/sbin/ss"
  if [ -x "${lsof}" ]; then "${lsof}" -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1
  elif [ -x "${ss}" ]; then [ -n "$("${ss}" -Htln "sport = :${p}" 2>/dev/null)" ]
  else return 1; fi
}

module_doctor() { # $1=module name (defaults to $AIBOX_MODULE)
  local m="${1:-${AIBOX_MODULE:-}}" yaml="" deps="" d dcmd ptag os info="" ver="" state="" ep="" health=""
  local miss=0 notready=0 dself
  dself="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  yaml="${dself}/module.yaml"
  [ -f "${yaml}" ] || yaml="${dself}/../${m}/module.yaml"
  deps="$(awk '/^deps:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); gsub(/^"|"$/,""); printf "%s ", $0}' "${yaml}" 2>/dev/null || true)"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  log "${m} doctor  ${C_DIM:-}$(date '+%Y-%m-%d %H:%M')${C_RST:-}"
  # 1) declared deps (docker gets a daemon probe, not just a CLI check)
  if [ -n "${deps}" ]; then
    for d in ${deps}; do
      dcmd="${d}"; ptag=""
      dcmd="${dcmd%\"}"; dcmd="${dcmd#\"}"   # quoted entries ("node:22")
      case "${dcmd}" in *@*) ptag="${dcmd##*@}"; dcmd="${dcmd%@*}" ;; esac
      [ -n "${ptag}" ] && [ "${ptag}" != "${os}" ] && continue
      case "${dcmd}" in *:*) dcmd="${dcmd%%:*}" ;; esac
      if command -v "${dcmd}" >/dev/null 2>&1; then
        case "${dcmd}" in
        docker) if docker info >/dev/null 2>&1; then ok "dep         docker (daemon reachable)"
                else warn "dep         docker — CLI present but the daemon is UNREACHABLE (start docker)"; miss=1; fi ;;
        *)      ok "dep         ${dcmd}" ;;
        esac
      else
        warn "dep         ${dcmd} MISSING — fix: aibox install ${m} (preflight auto-installs deps)"
        miss=1
      fi
    done
  else
    info "dep         (none declared)"
  fi
  # 2) the module's own state report (dashboard_info is the module's contract)
  if type dashboard_info >/dev/null 2>&1; then
    info="$(dashboard_info 2>/dev/null || true)"
    ver="$(printf '%s\n' "${info}" | sed -n 's/^version=//p' | head -1)"
    state="$(printf '%s\n' "${info}" | sed -n 's/^state=//p' | head -1)"
    ep="$(printf '%s\n' "${info}" | sed -n 's/^endpoint=//p' | head -1)"
    health="$(printf '%s\n' "${info}" | sed -n 's/^health=//p' | head -1)"
    case "${state}" in
    ok)        ok "state       ok${ver:+ (app ${ver})}" ;;
    starting)  warn "state       starting (container up, health pending)"; notready=1 ;;
    stopped)   warn "state       stopped — fix: aibox ${m} start"; notready=1 ;;
    na)        info "state       n/a (CLI module — no resident service)" ;;
    "")        info "state       (module reports no state)" ;;
    esac
    [ -n "${ep}" ] && info "endpoint    ${ep}${health:+ ${C_DIM:-}· ${C_RST:-}${health}}"
  else
    info "state       (module has no dashboard_info)"
  fi
  # 3) declared ports
  local ports="" entry
  ports="$(awk '/^ports:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); printf "%s ", $0}' "${yaml}" 2>/dev/null || true)"
  for entry in ${ports}; do
    local pnum="${entry%%/*}"
    case "${pnum}" in ''|*[!0-9]*) continue ;; esac
    if port_listening "${pnum}"; then ok "port        ${entry} listening"
    else info "port        ${entry} — (not listening)"; fi
  done
  [ -n "${ports}" ] || info "port        (none declared)"
  # verdict
  if [ "${miss}" = "1" ]; then printf '%s✗  not healthy: a dependency is missing (aibox install %s)%s\n' "${C_RED:-}" "${m}" "${C_RST:-}"; return 3; fi
  if [ "${notready}" = "1" ]; then printf '%s⚠  not ready: the service is not running (aibox %s start)%s\n' "${C_YEL:-}" "${m}" "${C_RST:-}"; return 30; fi
  ok "all checks passed"
  return 0
}

# Usage errors in module hooks are exit 2 (same convention as the manager).
usage_die() { printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2; exit 2; }

# ---------- dashboard keyline template (spec §Dashboard template) ----------

# Shared render helpers for module-owned rich views (render_dashboard); the
# manager (bin/aibox, a single-file CLI that cannot source this file) inlines
# the SAME shapes — keep them in sync via the spec. Plain (NO_COLOR) shapes:
#   <name> <appver> · ✓ running
#   ─────────────────────────────────────────────────────────────────
#     service    launchd · pid 38243
#     module     1.3.5 · ~/.aibox/modules/<name>/        (whole row dim)
# Colors inherit aibox's exported C_* (empty standalone → plain). Rule width:
# TTY → tput cols clamped [40,72]; non-TTY → 64 (pipes/tests get a stable
# shape). NOTE: the [ -t 1 ] check MUST run in the function's own body —
# never inside $(…): command substitution turns stdout into a pipe and the
# TTY branch would never fire (live-caught by review: width was dead-fixed
# 64 everywhere). Rules repeat COMPLETE ─ literals — never sliced (#6).

_dash_w() { # prints the rule width; $1 = stdout-is-tty flag ("1"/"0")
  local w=64
  if [ "${1:-0}" = "1" ]; then
    # stty talks to the CONTROLLING terminal via /dev/tty — works even inside
    # $(…) (tput's stdout would be the substitution pipe, not the tty, and
    # ncurses would fall back to terminfo's cols — live-measured: 80 on an
    # xterm pty set to 50 cols).
    local sz
    sz="$(stty size </dev/tty 2>/dev/null || true)"
    case "${sz}" in
    *" "*) w="${sz##* }" ;;
    esac
  fi
  case "${w}" in '' | *[!0-9]*) w=64 ;; esac
  [ "${w}" -lt 40 ] && w=40
  [ "${w}" -gt 72 ] && w=72
  printf '%s' "${w}"
}

# state word → colored "<icon> <word>" segment; empty for na/unknown words
_dash_state_seg() { # $1=state word (ok|running|starting|stopped|na|"")
  case "${1:-}" in
  ok | running) printf '%s✓ %s%s' "${C_GRN:-}" "${1}" "${C_RST:-}" ;;
  starting) printf '%s⚠ %s%s' "${C_YEL:-}" "${1}" "${C_RST:-}" ;;
  stopped) printf '%s○ %s%s' "${C_DIM:-}" "${1}" "${C_RST:-}" ;;
  *) printf '' ;;
  esac
}

dash_header() { # $1=name $2=app_version (""=omit) $3=state word (see _dash_state_seg)
  local seg
  printf '%s%s%s' "${C_BOLD:-}" "${1}" "${C_RST:-}"
  [ -n "${2}" ] && printf ' %s%s%s' "${C_CYA:-}" "${2}" "${C_RST:-}"
  seg="$(_dash_state_seg "${3:-}")"
  [ -n "${seg}" ] && printf ' %s·%s %s' "${C_DIM:-}" "${C_RST:-}" "${seg}"
  printf '\n'
  dash_rule
}

dash_row() { # $1=label (ASCII, ≤10 chars) $2=value (verbatim; may embed color spans)
  printf '  %s%-10s%s %s\n' "${C_DIM:-}" "${1}" "${C_RST:-}" "${2}"
}

dash_module_row() { # $1=module_version $2=module_dir — sunk, whole row dim
  printf '  %s%-10s %s · %s%s\n' "${C_DIM:-}" "module" "${1:-?}" "${2:-}" "${C_RST:-}"
}

dash_rule() { # the dim horizontal rule (width per the header comment)
  local w i=0 out=""
  if [ -t 1 ] 2>/dev/null; then
    w="$(_dash_w 1)"
  else
    w=64
  fi
  while [ "${i}" -lt "${w}" ]; do
    out="${out}─"
    i=$(( i + 1 ))
  done
  printf '%s%s%s\n' "${C_DIM:-}" "${out}" "${C_RST:-}"
}

dash_secheader() { # $1=title (ASCII) → "── title ───…" to the rule width
  local w n i=0 out=""
  if [ -t 1 ] 2>/dev/null; then
    w="$(_dash_w 1)"
  else
    w=64
  fi
  n=$(( w - ${#1} - 6 ))
  [ "${n}" -lt 3 ] && n=3
  while [ "${i}" -lt "${n}" ]; do
    out="${out}─"
    i=$(( i + 1 ))
  done
  printf '%s%s── %s%s%s %s%s%s\n' \
    "${C_DIM:-}" "" "${C_BOLD:-}${C_CYA:-}" "${1}" "${C_RST:-}" \
    "${C_DIM:-}" "${out}" "${C_RST:-}"
}

# ---------- docker.io download source pool (pull-via-mirror + tag) ----------
# Compose images are pulled by the docker DAEMON — whose egress differs from
# the host's (spec §Preflight: host-curl probes of docker.io are unreliable;
# probe through the daemon itself). Priority (spec §Docker source selector,
# user-pinned): ① the DEFAULT route — `docker pull` direct, which inherently
# tries the daemon's own registry-mirrors first (docker info .RegistryConfig.
# Mirrors = the LOCAL addresses the host already has) ② the user knob
# (AIBOX_DOCKER_MIRROR, tried first in the pool) ③ the ranked mirror pool
# below — engaged ONLY when the default route times out or dies; mirrors are
# RANKED by concurrent bounded hello-world pulls (measured through the daemon
# — the real channel), then uncached docker.io images are pre-pulled from the
# ranked order with per-source failover and `docker tag`-ed to their official
# names (mirrors proxy IDENTICAL digests — the windmill WM_HUB_MIRROR
# technique), so `compose up` finds them cached.
# The ranking survives runs: $AIBOX_HOME/dockerpool.cache (families PULL/GHCR
# shared with the manager's TAGS twin), TTL AIBOX_DOCKER_POOL_TTL (600s),
# self-healing (all-fail → invalidate → re-race; mirrors die and revive,
# networks change — dockerproxy.net measured swinging within one day).
# Other registries (cr.weaviate.io …) stay direct-only — the mirrors proxy
# docker.io. Knobs: AIBOX_DOCKER_POOL (mirror list override; "direct" =
# disabled), AIBOX_DOCKER_MIRROR (user mirror, first), AIBOX_DOCKER_FORCE_POOL=1
# (skip the direct probe — always engage), AIBOX_DOCKER_PROBE_TIMEOUT (15),
# AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT (30), AIBOX_DOCKER_PULL_TIMEOUT (1800),
# AIBOX_DOCKER_POOL_TTL (600).
# Live-verified DIRECT (no proxy), 2026-09-23, authoritative multi-source
# (1panel status / juejin measured / DaoCloud docs / aliyun articles);
# per-CHANNEL capability diverges (measured): daocloud = pull-only (tags API
# 401), 1panel.live = dual, hub3/hub4/367231 = tags-only — the per-family
# probes prune automatically, nothing is hardcoded. dockerproxy.net swings
# alive↔dead — documented example, NOT in the default. dockerpull.org /
# docker.xuanyuan.me / docker.hpcloud.cloud excluded (user veto / dead).
DOCKER_POOL_MIRRORS="docker.1ms.run hub.rat.dev docker.1panel.live hub.1panel.dev proxy.vvvv.ee docker.m.daocloud.io hub3.nat.tf hub4.nat.tf docker.367231.xyz docker.apiba.cn"

# Is this image ref served by docker.io? A ref WITH a slash has a
# host-or-namespace first segment — dots/colons there mean a foreign registry
# (cr.weaviate.io/…, localhost:5000/…). A ref WITHOUT a slash is name[:tag] on
# the DEFAULT registry (postgres:15-alpine) — its colon is the TAG separator,
# not a port (tag-stripping first would misread localhost:5000/foo's port).
_dk_is_dockerio() {
  case "${1}" in
  docker.io/*) return 0 ;; # explicit default-registry form is still docker.io
  */*)
    case "${1%%/*}" in
    *.* | *:*) return 1 ;;
    *) return 0 ;;
    esac
    ;;
  *) return 0 ;;
  esac
}

# Mirror-prefixed ref (official images live under library/).
_dk_pool_ref() { # $1=mirror-host $2=image-ref
  # Branch order matters: docker.io/* must come before the wildcard */*.
  case "${2}" in
  docker.io/*) printf '%s/%s' "${1}" "${2#docker.io/}" ;;
  */*) printf '%s/%s' "${1}" "${2}" ;;
  *) printf '%s/library/%s' "${1}" "${2}" ;;
  esac
}

# Bounded docker command with a wall-clock watchdog (docker pull has no
# timeout of its own; a hung registry would hang the install forever).
# Returns docker's rc, or 124 on timeout. AIBOX_DOCKER_POLL (default 5s) is the
# watchdog's poll interval (tests tighten it); the deadline is date-based so
# the interval never distorts the timeout budget (the accumulated-counter form
# broke when the poll was tightened — measured: 0.2s polls fired 15s timeouts
# in ~0.6s).
_dk_bounded() { # $1=timeout_s, rest = docker args
  local t="${1}"
  shift
  local logf pid deadline
  logf="$(mktemp "${TMPDIR:-/tmp}/dkpool.XXXXXX")" || return 1
  docker "$@" >"${logf}" 2>&1 &
  pid=$!
  deadline=$(($(date +%s) + t))
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      kill "${pid}" 2>/dev/null || true
      pkill -P "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null
      rm -f "${logf}"
      return 124
    fi
    sleep "${AIBOX_DOCKER_POLL:-5}"
  done
  rc=0
  wait "${pid}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    tail -3 "${logf}" >&2 2>/dev/null || true
  fi
  rm -f "${logf}"
  return "${rc}"
}

# Docker source selector shared ranking cache: $AIBOX_HOME/dockerpool.cache,
# lines "FAMILY<TAB>token token …", mode 600, TTL AIBOX_DOCKER_POOL_TTL
# (default 600s). Families: PULL (daemon-side docker.io), GHCR (daemon-side
# ghcr.io), TAGS (host-side dockerhub tag resolution — the manager inlines a
# twin of these helpers; SAME file, SAME grammar). Token grammar: "direct" =
# the official/default route is known good (probe it when reached — honest
# priority); a mirror host = try that mirror (failover down the list); the
# ABSENCE of "direct" = the official route is known dead within this TTL —
# skip its timeout tax until the TTL re-probes it (mirrors die AND revive,
# networks change; dockerproxy.net measured swinging within one day).
_dkcache_path() { printf '%s/dockerpool.cache' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"; }

_dkcache_fresh() { # $1=file → 0 when fresh (TTL-bounded)
  [ -f "$1" ] || return 1
  local now mtime age
  now="$(date +%s)"
  mtime="$(date -r "$1" +%s 2>/dev/null || stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)"
  age=$(( now - ${mtime:-0} ))
  [ "${age}" -lt "${AIBOX_DOCKER_POOL_TTL:-600}" ]
}

_dkcache_read() { # $1=family → the candidate line ("" when missing/stale)
  local f line
  f="$(_dkcache_path)"
  [ -n "${f}" ] || return 0
  _dkcache_fresh "${f}" || return 0
  line="$(awk -v fam="$1" -F'\t' '$1==fam {print $2; exit}' "${f}" 2>/dev/null || true)"
  printf '%s' "${line}"
}

_dkcache_write() { # $1=family $2=candidates ("" = invalidate the entry)
  local f tmp others line
  f="$(_dkcache_path)"
  [ -n "${f}" ] || return 0
  mkdir -p "$(dirname "${f}")" 2>/dev/null || true
  tmp="$(mktemp "${f}.tmp.XXXXXX")" || return 0
  # normalize the token line: squeeze/trim spaces (builders like `tr '\n' ' '
  # append a trailing space; the readers do exact matching)
  line="$(printf '%s' "${2}" | tr -s ' ' | sed 's/^ //; s/ $//')"
  # awk on a MISSING file exits 2 — guarded like the gh-pool twin (an unguarded
  # call under set -e kills this function with status 2).
  others=""
  if [ -f "${f}" ]; then
    others="$(awk -v fam="$1" -F'\t' '$1!=fam {print}' "${f}" 2>/dev/null || true)"
  fi
  {
    if [ -n "${line}" ]; then printf '%s\t%s\n' "$1" "${line}"; fi
    if [ -n "${others}" ]; then printf '%s\n' "${others}"; fi
  } >"${tmp}"
  mv "${tmp}" "${f}"
  chmod 600 "${f}" 2>/dev/null || true
  return 0
}

# Pre-pull uncached docker.io images through the mirror pool. No-op (fast
# probe) when the daemon's direct route is healthy.

docker_pool_prepull() { # $@ = image refs
  case "${AIBOX_DOCKER_POOL:-}" in
  direct | none | off) return 0 ;;
  esac
  local img uncached="" m mirrors cands pid pids="" tmpd i t0 done1 rc_all=0 full
  local cached order=""
  # 1. filter: cached images + non-docker.io refs (mirrors don't proxy other
  #    registries — those stay direct)
  for img in "$@"; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    _dk_is_dockerio "${img}" || continue
    uncached="${uncached}${uncached:+ }${img}"
  done
  [ -n "${uncached}" ] || return 0
  # 2. fresh PULL ranking: walk it. "direct" first = probe the official route
  #    (docker pull inherently tries the daemon's registry-mirrors first —
  #    the LOCAL addresses the host already has); a mirror list = the official
  #    route is known dead within the TTL → skip its timeout tax.
  cached="$(_dkcache_read PULL)"
  if [ -n "${cached}" ]; then
    case "${cached%% *}" in
    direct)
      if [ "${AIBOX_DOCKER_FORCE_POOL:-0}" != "1" ]; then
        docker rmi hello-world >/dev/null 2>&1 || true
        if _dk_bounded "${AIBOX_DOCKER_PROBE_TIMEOUT:-15}" pull hello-world >/dev/null 2>&1; then
          log "docker: direct daemon route OK — compose will pull ${uncached} directly"
          return 0
        fi
        warn "docker: direct route went dead — engaging the mirror pool for: ${uncached}"
      fi
      order="${cached#direct }"
      ;;
    *)
      order="${cached}"
      log "docker: using the cached mirror ranking (TTL-bound): ${order}"
      ;;
    esac
  fi
  if [ -z "${order}" ] && [ -z "${cached}" ] && [ "${AIBOX_DOCKER_FORCE_POOL:-0}" != "1" ]; then
    # 3. no fresh cache: probe the default route first (hello-world is rmi'd
    #    first so the probe is honest — a cached probe proves nothing).
    docker rmi hello-world >/dev/null 2>&1 || true
    if _dk_bounded "${AIBOX_DOCKER_PROBE_TIMEOUT:-15}" pull hello-world >/dev/null 2>&1; then
      log "docker: direct daemon route OK — compose will pull ${uncached} directly"
      _dkcache_write PULL "direct"
      return 0
    fi
    warn "docker: direct route unusable — engaging the mirror pool for: ${uncached}"
  fi
  if [ -z "${order}" ]; then
    # 4. rank mirrors by concurrent bounded hello-world pulls (real daemon channel)
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/dkrank.XXXXXX")" || return 0
    mirrors="${AIBOX_DOCKER_MIRROR:-}"
    mirrors="${mirrors}${mirrors:+ }${AIBOX_DOCKER_POOL:-${DOCKER_POOL_MIRRORS}}"
    i=0
    # shellcheck disable=SC2086
    for m in ${mirrors}; do
      i=$((i + 1))
      (
        t0=$(date +%s)
        if _dk_bounded "${AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT:-30}" pull "$(_dk_pool_ref "${m}" hello-world)" >/dev/null 2>&1; then
          printf '%s\t%s\n' "$(($(date +%s) - t0))" "${m}" >"${tmpd}/r${i}.res"
        fi
      ) &
      pids="${pids} $!"
    done
    # shellcheck disable=SC2086
    for pid in ${pids}; do wait "${pid}" 2>/dev/null || true; done
    cands="$(cat "${tmpd}"/r*.res 2>/dev/null | sort -n | cut -f2 || true)"
    rm -rf "${tmpd}"
    if [ -z "${cands}" ]; then
      warn "docker: every mirror probe failed — compose will try direct"
      _dkcache_write PULL ""
      return 0
    fi
    log "docker mirror ranking: $(printf '%s' "${cands}" | tr '\n' ' ')"
    order="${cands}"
  fi
  _dkcache_write PULL "${order}"
  # 5. pre-pull the uncached images from the order, per-source failover
  # shellcheck disable=SC2086
  for img in ${uncached}; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    done1=0
    # shellcheck disable=SC2086
    for m in ${order}; do
      full="$(_dk_pool_ref "${m}" "${img}")"
      log "docker pull ${full} (mirror ${m}, watchdog ${AIBOX_DOCKER_PULL_TIMEOUT:-1800}s)"
      if _dk_bounded "${AIBOX_DOCKER_PULL_TIMEOUT:-1800}" pull "${full}"; then
        docker tag "${full}" "${img}" || {
          warn "docker tag failed: ${full} → ${img}"
          continue
        }
        docker rmi "${full}" >/dev/null 2>&1 || true
        ok "pulled ${img} via ${m}"
        done1=1
        break
      fi
      warn "docker: mirror ${m} failed for ${img} — trying the next"
    done
    if [ "${done1}" != "1" ]; then
      warn "docker: no mirror could pull ${img} — compose will try direct"
      rc_all=1
    fi
  done
  # self-heal: an order that could not serve the real images is not trusted
  # for the next round (invalidate → re-resolve: direct re-probed, re-ranked)
  if [ "${rc_all}" != "0" ]; then
    _dkcache_write PULL ""
  fi
  return "${rc_all}"
}

# ---------- docker source selector: GHCR family (ghcr.io, pull-via-mirror + tag) ----------
# Migrated from tools/xiaozhi/lib.sh (spec §Docker source selector — one
# selector, per-family transport). ghcr.io is a DIFFERENT registry family
# than docker.io (the docker.io mirrors do NOT proxy it). Mechanism (the
# windmill WM_GHCR_MIRROR technique): mirrors transparently proxy IDENTICAL
# digests, so pull `<mirror>/<path>` then `docker tag` it as the official
# ghcr.io/<path> — compose keeps official refs and finds the images cached.
# Priority: ① ghcr.io direct (bounded — the default address; fast links
# finish with zero overhead, slow-but-alive links get cut harmlessly and fall
# through) ② the user mirror (AIBOX_GHCR_MIRROR) ③ the pool below in order.
# The WINNING mirror is STICKY: recorded in dockerpool.cache (GHCR family,
# TTL) — the next run skips the known-dead direct route and leads with the
# winner ("fastest first, failover to the next" in the big-image regime,
# where concurrent duplicate pulls through every mirror would multiply
# traffic); all-fail invalidates (self-heal).
# Knobs: AIBOX_GHCR_POOL (mirror list override; "direct" = pool disabled),
# AIBOX_GHCR_MIRROR (your mirror, tried first), AIBOX_GHCR_DIRECT_TIMEOUT
# (120), AIBOX_GHCR_PULL_TIMEOUT (1800), AIBOX_DOCKER_POLL (watchdog
# interval), AIBOX_DOCKER_POOL_TTL (sticky-record TTL).
# Live-verified DIRECT 2026-09-23: ghcr.nju.edu.cn (NJU — the only mirror
# serving arbitrary ghcr repos: 140 tags + a real 5s pull of the xiaozhi web
# image), ghcr.1ms.run (fast 0.26s but LAZY — popular repos only, e.g. 0 tags
# for the xiaozhi repo → second). ghcr.dockerproxy.net swung dead the same
# day → documented example, NOT default. ghcr.m.daocloud.io 401s the
# anonymous v2 API (sync-allowlist registry).
GHCR_POOL_MIRRORS="ghcr.nju.edu.cn ghcr.1ms.run"

# Mirror-prefixed ref for a ghcr.io image (empty for non-ghcr refs).
_ghcr_mirror_ref() { # $1=mirror-host $2=image-ref
  case "${2}" in
  ghcr.io/*) printf '%s/%s' "${1}" "${2#ghcr.io/}" ;;
  *) printf '%s' "" ;;
  esac
}

# Pre-pull uncached ghcr.io images through the mirror pool.
ghcr_pool_prepull() { # $@ = image refs
  case "${AIBOX_GHCR_POOL:-}" in
  direct | none | off) return 0 ;;
  esac
  local img uncached="" cached order=""
  # 1. filter: cached images + non-ghcr refs
  for img in "$@"; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    case "${img}" in
    ghcr.io/*) uncached="${uncached}${uncached:+ }${img}" ;;
    esac
  done
  [ -n "${uncached}" ] || return 0
  # 2. sticky-winner record: a mirror order means the direct route is known
  #    dead within the TTL → skip its timeout tax and lead with the winner;
 #    a "direct" record (or no record) keeps the honest direct-first flow.
  cached="$(_dkcache_read GHCR)"
  if [ -n "${cached}" ] && [ "${cached%% *}" != "direct" ]; then
    order="${cached}"
    log "ghcr: using the cached mirror ranking (TTL-bound): ${order}"
  fi
  # 3. per image: direct (bounded) when the order is unknown, else the mirrors
  # shellcheck disable=SC2086
  for img in ${uncached}; do
    if [ -z "${order}" ]; then
      if _dk_bounded "${AIBOX_GHCR_DIRECT_TIMEOUT:-120}" pull "${img}"; then
        ok "pulled ${img} (direct)"
        _dkcache_write GHCR "direct"
        continue
      fi
      warn "ghcr: direct route slow/unusable for ${img} — engaging the mirror pool"
    fi
    if _ghcr_mirror_pull "${img}" "${order}"; then
      # lead with the proven winner for the remaining images of this run
      order="$(_dkcache_read GHCR)"
    else
      warn "ghcr: mirror pool could not pull ${img} — compose will try direct"
    fi
  done
}

# Pull ONE image via the ordered mirror list, per-source failover + retag;
# records the sticky winner (promoted to the front) on success, invalidates
# on total failure.
_ghcr_mirror_pull() { # $1 = official ghcr.io ref, $2 = order override ("" = default list)
  local img="$1" m mirrors full done1 won others
  if [ -n "${2}" ]; then
    mirrors="${2}"
  else
    mirrors="${AIBOX_GHCR_MIRROR:-}"
    mirrors="${mirrors}${mirrors:+ }${AIBOX_GHCR_POOL:-${GHCR_POOL_MIRRORS}}"
  fi
  done1=0
  won=""
  # shellcheck disable=SC2086
  for m in ${mirrors}; do
    full="$(_ghcr_mirror_ref "${m}" "${img}")"
    [ -n "${full}" ] || continue
    log "docker pull ${full} (mirror ${m}, watchdog ${AIBOX_GHCR_PULL_TIMEOUT:-1800}s)"
    if _dk_bounded "${AIBOX_GHCR_PULL_TIMEOUT:-1800}" pull "${full}"; then
      docker tag "${full}" "${img}" || {
        warn "docker tag failed: ${full} → ${img}"
        continue
      }
      docker rmi "${full}" >/dev/null 2>&1 || true
      ok "pulled ${img} via ${m}"
      done1=1
      won="${m}"
      break
    fi
    warn "ghcr: mirror ${m} failed for ${img} — trying the next"
  done
  if [ "${done1}" = "1" ]; then
    # sticky winner: promote it to the front of the full candidate list
    others="$(printf '%s\n' ${mirrors} | grep -vxF "${won}" | tr '\n' ' ' || true)"
    _dkcache_write GHCR "${won}${others:+ ${others}}"
  else
    # self-heal: a dead order is not trusted for the next round (direct retried)
    _dkcache_write GHCR ""
  fi
  [ "${done1}" = "1" ]
}

# Unified pre-pull entry: routes each image to its registry family's pool
# (ghcr → ghcr pool; docker.io → docker.io pool; other registries → direct).
images_pool_prepull() { # $@ = image refs
  local imgs_all="$*"
  # shellcheck disable=SC2086
  ghcr_pool_prepull ${imgs_all} || true
  # shellcheck disable=SC2086
  docker_pool_prepull ${imgs_all} || true
}

# ---------- config store helpers (spec §Configuration) ----------
# The deploy's store is the single source of truth; env vars are install-time
# seeds only ("seed at install, store after"). One generic shape covers the
# KEY=value stores (.env for compose modules, /etc/<m>/<m>.conf for CLI
# modules); service-defined modules (pi-web) regenerate their whole service
# definition instead of piecemeal edits.

# Does this KEY hold a secret? (masked in `config` listings; get returns it)
cfg_secret_p() { # $1=KEY
  case "$1" in
  *PASSWORD* | *SECRET* | *TOKEN*) return 0 ;;
  *KEY) return 0 ;;
  *) return 1 ;;
  esac
}

cfg_mask() { printf '%s' "••••••••"; }

# KEY=value store reader. Accepts quoted and bare values; "" when unset.
cfg_kv_get() { # $1=file $2=KEY
  [ -n "${CFG_STORE:-}" ] || CFG_STORE="$1"
  [ -f "$1" ] || return 0
  sed -nE "s/^$2=\"?([^\"]*)\"?\$/\1/p" "$1" | head -1
}

# KEY=value store writer: replaces the FIRST matching line in place (comments,
# order and mode preserved), appends when the key is new. Idempotent.
cfg_kv_set() { # $1=file $2=KEY $3=value
  local f="$1" k="$2" v="$3" tmp mode
  [ -n "$k" ] || return 0
  tmp="${f}.cfgtmp.$$"
  if [ ! -f "$f" ]; then
    (
      umask 077
      printf '%s="%s"\n' "$k" "$v" >"$f"
    ) || {
      warn "cannot write $f"
      return 1
    }
    return 0
  fi
  # keys are [A-Z_0-9] (validator-enforced) — no awk-regex metachars
  awk -v k="$k" -v v="$v" '
    $0 ~ "^"k"=" && !done { print k "=\"" v "\""; done = 1; next }
    { print }
    END { if (!done) print k "=\"" v "\"" }
  ' "$f" >"$tmp" || {
    rm -f "$tmp"
    warn "cannot rewrite $f"
    return 1
  }
  mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo 600)"
  mv -f "$tmp" "$f"
  chmod "${mode}" "$f" 2>/dev/null || true
  return 0
}

# Remove every KEY= line (back to the declared default).
cfg_kv_unset() { # $1=file $2=KEY
  local f="$1" k="$2" tmp mode
  [ -f "$f" ] || return 0
  tmp="${f}.cfgtmp.$$"
  grep -vE "^${k}=" "$f" >"$tmp" || true
  mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo 600)"
  mv -f "$tmp" "$f"
  chmod "${mode}" "$f" 2>/dev/null || true
  return 0
}

# Parse the module.yaml env: declaration into lines of "KEY<TAB>default<TAB>desc<TAB>flags".
# $1 = the module.yaml path. Value shape: "default — description [flags]".
cfg_env_declare() { # $1=module.yaml → declaration lines on stdout
  [ -f "$1" ] || return 0
  # ONE awk pass extracts KEY<TAB>value pairs (the fork-elimination win — was
  # one sed per key). The value SPLITTING stays in bash: the " — " separator
  # is a 3-byte em-dash, and C-locale awk's index/substr counts BYTES while
  # UTF-8 awk counts CHARS — a portability divergence (measured: desc got cut
  # mid-character on the dev Mac). Bash string ops handle UTF-8 uniformly.
  awk '
    /^env:/ { inenv = 1; next }
    inenv && /^[a-zA-Z]/ { inenv = 0 }
    inenv && /^  [A-Z_][A-Z0-9_]*: *"/ {
      key = $0
      sub(/^  /, "", key); sub(/: *"/, "\t", key); sub(/"$/, "", key)
      print key
    }
  ' "$1" | while IFS="$(printf '\t')" read -r k v; do
    def="${v%% —*}"
    [ "${def}" = "${v}" ] && def="${v%%—*}"
    rest="${v#* —}"
    [ "${rest}" = "${v}" ] && rest="${v}"
    flags=""
    case "${v}" in
    *"["*"]"*) flags="$(printf '%s' "${v}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')" ;;
    esac
    desc="${rest%%\[*}"
    printf '%s\t%s\t%s\t%s\n' "${k}" "${def}" "$(printf '%s' "${desc}" | sed 's/^ *//; s/ *$//')" "${flags}"
  done
}

# Generic `config` action for KEY=value-store modules (spec §Configuration).
# Requires: CFG_YAML (module.yaml path), CFG_STORE (the .env/.conf file),
# CFG_APPLY (the apply command shown/offered, e.g. "aibox dify restart") or
# empty for apply-at-next-invocation modules.
# Sub-actions: (list) | get KEY | set KEY VALUE | unset KEY
cfg_action() { # $@ = config sub-args
  local mode="${1:-list}" k="${2:-}" v="${3:-}"
  case "${mode}" in
  list)
    local key def desc flags cur shown
    while IFS="$(printf '\t')" read -r key def desc flags; do
      [ -n "$key" ] || continue
      case " ${flags} " in *" knob "*) continue ;; esac
      cur="$(cfg_kv_get "${CFG_STORE}" "${key}")"
      if [ -n "${cur}" ]; then
        if cfg_secret_p "${key}" || case " ${flags} " in *" secret "*) true ;; *) false ;; esac then
          shown="$(cfg_mask)"
        else
          shown="${cur}"
        fi
        printf '  %-26s %-14s %s\n' "${key}" "${shown}" "${desc}"
      else
        printf '  %-26s %-14s %s\n' "${key}" "(default: ${def})" "${desc}"
      fi
    done < <(cfg_env_declare "${CFG_YAML}")
    if [ -n "${CFG_APPLY}" ]; then
      log "apply changes: ${CFG_APPLY}"
    else
      log "changes apply at the next invocation (no restart needed)"
    fi
    ;;
  get)
    [ -n "$k" ] || die "usage: config get <KEY> (keys: aibox ${AIBOX_MODULE:-module} --help)"
    cfg_kv_get "${CFG_STORE}" "$k" || true
    [ -n "$(cfg_kv_get "${CFG_STORE}" "$k")" ] || warn "(unset — default: $(cfg_env_declare "${CFG_YAML}" | awk -F'\t' -v k="$k" '$1==k{print $2}'))"
    ;;
  set)
    [ -n "$k" ] && [ -n "$v" ] || die "usage: config set <KEY> <VALUE>"
    cfg_kv_set "${CFG_STORE}" "$k" "$v" || return 1
    ok "set ${k} in ${CFG_STORE}"
    if [ -n "${CFG_APPLY}" ]; then
      if [ -t 0 ] && cfg_confirm_apply; then
        # shellcheck disable=SC2086
        ${CFG_APPLY}
      else
        log "apply when ready: ${CFG_APPLY}"
      fi
    else
      log "applies at the next invocation"
    fi
    ;;
  unset)
    [ -n "$k" ] || die "usage: config unset <KEY>"
    cfg_kv_unset "${CFG_STORE}" "$k"
    local def
    def="$(cfg_env_declare "${CFG_YAML}" | awk -F'\t' -v k="$k" '$1==k{print $2}')"
    ok "unset ${k} (back to default: ${def:-<builtin>})"
    [ -n "${CFG_APPLY}" ] && log "apply when ready: ${CFG_APPLY}"
    ;;
  *)
    die "usage: aibox ${AIBOX_MODULE:-module} config [get|set|unset] [KEY] [VALUE]"
    ;;
  esac
}

# The apply confirm for `config set` (default Y — writing config implies
# wanting it live); non-interactive takes the no-apply path with the hint.
cfg_confirm_apply() {
  local ans
  printf '%s⚠%s  apply now? [Y/n] ' "${C_YEL:-}" "${C_RST:-}"
  read -r ans || return 1
  case "$ans" in n | N | no | NO) return 1 ;; *) return 0 ;; esac
}

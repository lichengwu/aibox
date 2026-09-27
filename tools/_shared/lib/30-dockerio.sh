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


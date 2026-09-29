# ---------- download source pool (GitHub family: raw / api / releases) ----------
# Same pattern as pi-web's npm registry pick and windmill's ghcr route probe:
# a maintained pool of mainstream acceleration sources, RACED against the actual
# download (concurrent, per-candidate bounded), the measured winner serves the
# run; later fetches walk the measured ranking with per-fetch failover.
#
# Live-verified pool (measured on a CN mac AND an Aliyun deploy host):
#   gh-proxy.com  — proxies BOTH raw and api
#   ghproxy.net   — raw ok, api 403 from some networks
#   ghproxy.link / ghproxy.cn — served CORRUPT content (truncated / wrong size)
#   → EXCLUDED: a mirror that corrupts content is worse than a slow one.
# DIRECT always races: on healthy networks it wins and no proxy is ever used.
#
# Scope: the manager's SMALL files (module.yaml, hooks, install.sh, bin/aibox,
# upgrade mappings) — the race downloads the file once per candidate (~N × size,
# fine at these sizes). Large binaries (clash's ~20MB mihomo) use bounded partial
# rate probes in their own module instead. Families rank SEPARATELY (raw / api /
# releases) — a proxy can be great for raw and useless for api (measured). For
# raw URLs an extra "ghapi" pseudo-candidate rewrites to the api.github.com
# contents API — survives networks where raw is blocked but the api host is
# reachable even when every public proxy is down (measured live).
#
# Knobs: AIBOX_GH_POOL="<url>..." overrides the default pool; "direct" disables
# it (direct-only). AIBOX_GH_POOL_TIMEOUT (default 10s) bounds each candidate.
# The user's CLASH_MIRROR / AIBOX_GH_MIRROR joins as a high-priority candidate.
# Non-GitHub hosts (hub.docker.com etc.): direct, plus the user mirror if set.
GH_POOL_ORDER_RAW=""
GH_POOL_ORDER_API=""
GH_POOL_ORDER_REL=""
AIBOX_GH_POOL_DEFAULT="https://gh-proxy.com https://ghproxy.net"

# Family of a URL: RAW / API / REL / OTHER.
_gh_pool_family() {
  case "$1" in
  https://raw.githubusercontent.com/*) printf RAW ;;
  https://api.github.com/*) printf API ;;
  https://github.com/*) printf REL ;;
  *) printf OTHER ;;
  esac
}

# Ranking cache FILE: "$AIBOX_HOME/ghpool.cache", lines "FAM<TAB>cand cand ...",
# mode 600, TTL AIBOX_GH_POOL_TTL (default 600s). The in-process globals do NOT
# survive gh_pool_fetch's usual $( ) command-substitution subshells — the file
# cache is the real per-run (TTL-bounded) ranking store.
_gh_pool_cache_path() {
  printf '%s/ghpool.cache' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
}

_gh_pool_cache_read() { # $1 = family → candidates line (empty when missing/stale)
  local f line
  f="$(_gh_pool_cache_path)"
  [ -n "${f}" ] || return 0
  if ! _cache_fresh "${f}" "${AIBOX_GH_POOL_TTL:-600}"; then return 0; fi
  line="$(awk -v fam="$1" -F'\t' '$1==fam {print $2; exit}' "${f}" 2>/dev/null || true)"
  printf '%s' "${line}"
}

_gh_pool_cache_write() { # $1 = family, $2 = candidates ("" = invalidate the entry)
  local f tmp others
  f="$(_gh_pool_cache_path)"
  [ -n "${f}" ] || return 0
  mkdir -p "$(dirname "${f}")"
  tmp="$(mktemp "${f}.tmp.XXXXXX")" || return 0
  # awk on a MISSING file exits 2 — under set -e that killed this function with
  # status 2 in unguarded call contexts (live runs survived only via the callers'
  # `|| die` exemption; the bats tests run unguarded and exposed it).
  others=""
  if [ -f "${f}" ]; then
    others="$(awk -v fam="$1" -F'\t' '$1!=fam {print}' "${f}" 2>/dev/null || true)"
  fi
  {
    printf '%s\t%s\n' "$1" "$2"
    if [ -n "${others}" ]; then printf '%s\n' "${others}"; fi
  } >"${tmp}"
  mv "${tmp}" "${f}"
  chmod 600 "${f}" 2>/dev/null || true
  return 0
}

# Candidates in CONFIGURED order (user mirror, direct, pool, ghapi-for-RAW).
# Prints "kind|location" lines: direct|  prefix|<mirror-url>  ghapi|
_gh_pool_candidates() { # $1 = family
  local u
  u="${CLASH_MIRROR:-${AIBOX_GH_MIRROR:-}}"
  if [ -n "${u}" ]; then printf 'prefix|%s\n' "${u%/}"; fi
  printf 'direct|\n'
  case "${AIBOX_GH_POOL:-}" in
  direct | none | off) return 0 ;; # pool disabled: direct (+ user mirror) only — no ghapi either
  "") # shellcheck disable=SC2086
    printf 'prefix|%s\n' ${AIBOX_GH_POOL_DEFAULT} ;;
  *) # shellcheck disable=SC2086
    printf 'prefix|%s\n' ${AIBOX_GH_POOL} ;;
  esac
  if [ "$1" = "RAW" ]; then printf 'ghapi|\n'; fi
  return 0
}

# Fetch ONE candidate (race worker): body → $4, curl time_total → $5; rc = fetch status.
_gh_pool_one() { # kind loc url bodyfile timefile
  local kind="$1" loc="$2" url="$3" body="$4" tf="$5" t rc=0
  case "${kind}" in
  direct)
    t="$(curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" -o "${body}" -w '%{time_total}' "${url}" 2>/dev/null)" || rc=$?
    ;;
  prefix)
    t="$(curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" -o "${body}" -w '%{time_total}' "${loc%/}/${url}" 2>/dev/null)" || rc=$?
    ;;
  ghapi)
    local o r ref path b json
    o="$(printf '%s' "${url#https://raw.githubusercontent.com/}" | cut -d/ -f1)"
    r="$(printf '%s' "${url#https://raw.githubusercontent.com/}" | cut -d/ -f2)"
    ref="$(printf '%s' "${url#https://raw.githubusercontent.com/}" | cut -d/ -f3)"
    path="$(printf '%s' "${url#https://raw.githubusercontent.com/}" | cut -d/ -f4-)"
    if [ -z "${o}" ] || [ -z "${r}" ] || [ -z "${ref}" ] || [ -z "${path}" ]; then
      rc=1
    else
      json="${body}.api"
      t="$(curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" -o "${json}" -w '%{time_total}' \
        "https://api.github.com/repos/${o}/${r}/contents/${path}?ref=${ref}" 2>/dev/null)" || rc=$?
      if [ "${rc}" = 0 ]; then
        b="$(grep -oE '"content": *"[^"]*"' "${json}" 2>/dev/null | cut -d'"' -f4 | sed 's/\\n//g')"
        if [ -n "${b}" ] && printf '%s' "${b}" | base64 -d 2>/dev/null >"${body}"; then
          :
        else
          rc=1
          t=""
        fi
      fi
    fi
    ;;
  esac
  printf '%s' "${t:-999}" >"${tf}"
  return "${rc}"
}

# Fetch one candidate to stdout (sequential path).
_gh_pool_cand_get() { # kind loc url
  case "$1" in
  direct) curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" "$3" 2>/dev/null ;;
  prefix) curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" "${2%/}/$3" 2>/dev/null ;;
  ghapi) _gh_api_fetch "$3" 2>/dev/null ;;
  esac
}

# ---------- dead-proxy diagnosis (the pool's no-winner path) ----------
# A shell-exported proxy var (ALL_PROXY / all_proxy / http_proxy / https_proxy /
# HTTPS_PROXY) drags EVERY pool candidate through it — curl honors the env for
# direct, mirror AND api candidates alike — so ONE dead local proxy fails the
# whole pool while the network is fine, and the generic "network?" hint sends
# the operator to fix the wrong thing. Live-caught on a deploy host: zsh
# exported ALL_PROXY=socks5h://127.0.0.1:20808 (hysteria listening, tunnel
# dead); every candidate died with "Can't complete SOCKS5 connection" while
# all four routes were 200 without the var. Uppercase ALL_PROXY is the sneaky
# one: curl reads it, but it slipped past both bypass_proxy() and apply_proxy()'s
# env check while they only looked at the lowercase twin.
_gh_pool_proxy_env_vars() { # → space-separated names of the SET proxy env vars
  local v out=""
  for v in all_proxy ALL_PROXY http_proxy https_proxy HTTPS_PROXY; do
    if printenv "${v}" >/dev/null 2>&1; then
      out="${out:+${out} }${v}"
    fi
  done
  printf '%s' "${out}"
  return 0
}

# Control fetch: the pool's own candidate walk with the user's proxy env
# REMOVED — decides "network down" vs "your shell's proxy is the culprit".
# Runs only on the no-winner path WITH a proxy var set (already a failure;
# the extra fetches cost nothing). A passing control proves the pool would
# have worked without the env — so name the var instead of hinting "network?".
_gh_pool_control_ok() { # $1 = url → 0 when any candidate succeeds WITHOUT the proxy env
  local url="$1" fam cand kind loc
  fam="$(_gh_pool_family "${url}")"
  # shellcheck disable=SC2086
  for cand in $(_gh_pool_candidates "${fam}"); do
    kind="${cand%%|*}"
    loc="${cand#*|}"
    if (
      unset all_proxy ALL_PROXY http_proxy https_proxy HTTPS_PROXY no_proxy NO_PROXY
      _gh_pool_cand_get "${kind}" "${loc}" "${url}" >/dev/null
    ); then
      return 0
    fi
  done
  return 1
}

# Fetch a URL through the source pool. First fetch of a family RACES all
# candidates on the actual URL (concurrent, bounded): the fastest successful
# candidate serves the fetch, its measured ranking is cached for the run, and
# later fetches walk the ranking with per-fetch failover. Non-GitHub-family
# URLs: direct, plus the user mirror if configured.
gh_pool_fetch() { # $1 = url → content on stdout; nonzero when everything failed
  require_curl
  local url="$1" fam order um
  fam="$(_gh_pool_family "${url}")"

  if [ "${fam}" = "OTHER" ]; then
    if curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" "${url}" 2>/dev/null; then
      return 0
    fi
    um="${CLASH_MIRROR:-${AIBOX_GH_MIRROR:-}}"
    if [ -n "${um}" ] && curl -fsSL --max-time "${AIBOX_GH_POOL_TIMEOUT:-10}" "${um%/}/${url}" 2>/dev/null; then
      return 0
    fi
    return 1
  fi

  # Cached ranking (per family): in-process global first, then the cache FILE
  # (globals die with the $( ) subshell; the file survives, TTL-bounded).
  order=""
  case "${fam}" in
  RAW) order="${GH_POOL_ORDER_RAW}" ;;
  API) order="${GH_POOL_ORDER_API}" ;;
  REL) order="${GH_POOL_ORDER_REL}" ;;
  esac
  if [ -z "${order}" ]; then
    order="$(_gh_pool_cache_read "${fam}")"
  fi
  if [ -n "${order}" ]; then
    local cand kind loc
    # shellcheck disable=SC2086
    for cand in ${order}; do
      kind="${cand%%|*}"
      loc="${cand#*|}"
      if _gh_pool_cand_get "${kind}" "${loc}" "${url}"; then
        return 0
      fi
    done
    # Every cached candidate failed since the race — invalidate the entry and
    # re-race now (self-healing: mirrors die, networks change).
    _gh_pool_cache_write "${fam}" ""
    case "${fam}" in
    RAW) GH_POOL_ORDER_RAW="" ;;
    API) GH_POOL_ORDER_API="" ;;
    REL) GH_POOL_ORDER_REL="" ;;
    esac
  fi

  # First fetch of the family: RACE all candidates on this actual URL.
  local tmpd cands cand i=0 pids="" pid total rounds done_all i2 t rc line first=1 winner="" ranked="" candstr
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/ghpool.XXXXXX")" || return 1
  cands="$(_gh_pool_candidates "${fam}")"
  # shellcheck disable=SC2086
  for cand in ${cands}; do
    i=$((i + 1))
    printf '%s\n' "${cand}" >"${tmpd}/c${i}.cand"
    (
      rc=0
      _gh_pool_one "${cand%%|*}" "${cand#*|}" "${url}" "${tmpd}/c${i}.body" "${tmpd}/c${i}.time" || rc=$?
      echo "${rc}" >"${tmpd}/c${i}.rc"
    ) &
    pids="${pids} $!"
  done
  total="${i}"

  # Poll until every candidate finished, or the race budget (one candidate's
  # max fetch time) elapses; stragglers are killed (worker SIGTERM first, then
  # orphaned curl children — the pi-web kill-order lesson).
  rounds=0
  while [ "${rounds}" -lt "$(( (${AIBOX_GH_POOL_TIMEOUT:-10}) * 4 ))" ]; do
    done_all=1
    for ((i2 = 1; i2 <= total; i2++)); do
      if [ ! -f "${tmpd}/c${i2}.rc" ]; then
        done_all=0
        break
      fi
    done
    if [ "${done_all}" = 1 ]; then
      break
    fi
    sleep 0.25
    rounds=$((rounds + 1))
  done
  # shellcheck disable=SC2086
  for pid in ${pids}; do
    kill "${pid}" 2>/dev/null || true
    pkill -P "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done

  # Rank: successful candidates (rc=0 AND a non-empty body) by measured time;
  # failed/unfinished ones keep their configured order behind them.
  : >"${tmpd}/rank"
  for ((i2 = 1; i2 <= total; i2++)); do
    rc="$(cat "${tmpd}/c${i2}.rc" 2>/dev/null || echo 1)"
    if [ "${rc}" = 0 ] && [ -s "${tmpd}/c${i2}.body" ]; then
      t="$(cat "${tmpd}/c${i2}.time" 2>/dev/null || echo 999)"
      printf '%s %s\n' "${t:-999}" "${i2}" >>"${tmpd}/rank"
    fi
  done
  while read -r line; do
    [ -n "${line}" ] || continue
    i2="${line##* }"
    candstr="$(cat "${tmpd}/c${i2}.cand" 2>/dev/null)"
    if [ "${first}" = 1 ]; then
      winner="${i2}"
      first=0
    fi
    ranked="${ranked:+${ranked} }${candstr}"
  done < <(sort -sn "${tmpd}/rank")
  for ((i2 = 1; i2 <= total; i2++)); do
    rc="$(cat "${tmpd}/c${i2}.rc" 2>/dev/null || echo 1)"
    if [ "${rc}" = 0 ] && [ -s "${tmpd}/c${i2}.body" ]; then continue; fi
    candstr="$(cat "${tmpd}/c${i2}.cand" 2>/dev/null)"
    ranked="${ranked:+${ranked} }${candstr}"
  done

  if [ -n "${winner}" ] && [ -s "${tmpd}/c${winner}.body" ]; then
    case "${fam}" in
    RAW) GH_POOL_ORDER_RAW="${ranked}" ;;
    API) GH_POOL_ORDER_API="${ranked}" ;;
    REL) GH_POOL_ORDER_REL="${ranked}" ;;
    esac
    _gh_pool_cache_write "${fam}" "${ranked}"
    # stderr only — stdout is the fetched content, often captured in $( ).
    # NB: log to stderr as a notice, not warn — it's informational (which mirror won).
    printf '%s  source pool (%s): %s won the race (%ss; %s candidate(s) tried)%s\n' \
      "${C_DIM:-}" "${fam}" "$(printf '%s' "$(cat "${tmpd}/c${winner}.cand")" | awk -F'|' '{print ($2=="" ? $1 : $2)}')" \
      "$(cat "${tmpd}/c${winner}.time" 2>/dev/null)" "${total}" "${C_RST:-}" >&2
    cat "${tmpd}/c${winner}.body"
    rm -rf "${tmpd}"
    return 0
  fi
  # No winner: do not cache a failed ranking — the next fetch re-races.
  # Explicit stderr diagnostic: this path used to return 1 SILENTLY (measured
  # live: `update self` failed with zero output — callers without their own
  # die left the user with nothing). One dim line; callers add their context.
  # Dead-proxy diagnosis FIRST: with a proxy env var set, every candidate above
  # ran THROUGH it; one control fetch without the env separates a dead proxy
  # from a dead network — and stops the generic "network?" hint from sending
  # the operator to fix the wrong thing.
  local pvars
  pvars="$(_gh_pool_proxy_env_vars)"
  if [ -n "${pvars}" ] && _gh_pool_control_ok "${url}"; then
    printf '%s  gh pool: no source could fetch %s — but it is reachable WITHOUT your shell proxy (%s set; every candidate ran through it). unset it, or run: aibox --no-proxy <command>%s\n' \
      "${C_DIM:-}" "${url}" "${pvars}" "${C_RST:-}" >&2
  else
    printf '%s  gh pool: no source could fetch %s (%s candidate(s) tried; hints: aibox clash on, AIBOX_GH_MIRROR=<mirror>)%s\n' \
      "${C_DIM:-}" "${url}" "${total}" "${C_RST:-}" >&2
  fi
  rm -rf "${tmpd}"
  return 1
}


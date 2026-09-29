# ---------- dashboard: sampler (P1) ----------
# The interactive UI must never block, so nothing in this file runs inside the UI
# loop: a separate process (`aibox __dashboard-sample`) samples the world, publishes
# a snapshot ATOMICALLY, and the UI only ever reads the newest file. The rationale is
# in this repo's own incident log: pool/probe races fail silently when they run inside
# command substitutions or nested subshells (that is why __status-probe exists), and
# sampling inside a UI loop has exactly that shape.
#
# Snapshot format v1 — line records, space-separated k=v (values never contain
# spaces; multi-valued fields are comma-joined). Pure-bash parseable (no awk per
# field), diffable, and DATA — never sourced (spec §State model):
#   #aibox-dashboard-snapshot 1
#   SNAPSHOT  ts=… cost_ms=… stale=0|1 docker=ok|down load=… interval=…
#   MODULE    name=… profile=… mver=… aver=… state=… health=… endpoint=…
#             ports=… listening=… upgrade=… age=…
#   CONTAINER name=… image=… cpu=… mem=… uptime=… restarts=… health=… ports=…
#   RESIDUE   dangling=… buildcache=… volumes=… staletags=… total=… note=…

_dash_dir() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "${root}" ] || return 1
  printf '%s/dashboard' "${root}"
}

_dash_self() { # path to the CLI so child processes can re-enter its hidden verbs
  if [ -n "${AIBOX_SELF:-}" ] && [ -f "${AIBOX_SELF}" ]; then
    printf '%s' "${AIBOX_SELF}"
    return 0
  fi
  printf '%s' "${0}"
}

_dash_sanitize() { # $1=text → single token (whitespace → _, bounded)
  local s="${1:-}"
  s="$(printf '%s' "${s}" | tr '\n\r\t' '   ' | tr ' ' '_')"
  printf '%s' "${s:0:120}"
}

_dash_kv_get() { # $1="k=v k=v …" $2=key → value or ""
  local kv k
  for kv in $1; do
    k="${kv%%=*}"
    [ "${k}" = "$2" ] && { printf '%s' "${kv#*=}"; return 0; }
  done
  return 0
}

_dash_latest_snapshot() { # $1=dir → newest snapshot file (honours AIBOX_DASH_SNAPSHOT)
  local dir="$1" a b
  if [ -n "${AIBOX_DASH_SNAPSHOT:-}" ] && [ -f "${AIBOX_DASH_SNAPSHOT}" ]; then
    printf '%s' "${AIBOX_DASH_SNAPSHOT}"
    return 0
  fi
  a="${dir}/snapshot.1"
  b="${dir}/snapshot.2"
  if [ -f "${a}" ] && [ -f "${b}" ]; then
    if [ "${a}" -nt "${b}" ]; then printf '%s' "${a}"; else printf '%s' "${b}"; fi
    return 0
  fi
  if [ -f "${a}" ]; then printf '%s' "${a}"; return 0; fi
  if [ -f "${b}" ]; then printf '%s' "${b}"; return 0; fi
  return 1
}

_dash_host_load() { # 1-minute load average, portable ("?" when unavailable)
  local up
  up="$(uptime 2>/dev/null || true)"
  case "${up}" in
  *"load average:"* | *"load averages:"*)
    up="${up##*load average}"
    up="${up#*:}"
    up="${up%%,*}"
    printf '%s' "$(printf '%s' "${up}" | tr -d ' ')"
    ;;
  *) printf '?' ;;
  esac
}

# One listener capture per sample (lsof on macOS, ss on Linux): a per-port lsof call
# is ~20ms and modules declare several ports, so a single capture keeps the 2s budget.
_dash_listening_set() {
  local lsof ss
  lsof="$(command -v lsof 2>/dev/null || true)"
  if [ -z "${lsof}" ] && [ -x /usr/sbin/lsof ]; then lsof=/usr/sbin/lsof; fi
  ss="$(command -v ss 2>/dev/null || true)"
  # The `|| true` matters: under `set -o pipefail` a failing lsof/ss would abort the
  # whole CLI from inside this command substitution.
  if [ -n "${lsof}" ] && [ -x "${lsof}" ]; then
    { "${lsof}" -nP -iTCP -sTCP:LISTEN 2>/dev/null |
      sed -nE 's/.*:([0-9]+) \(LISTEN\)$/\1/p' | sort -u | tr '\n' ' '; } || true
  elif [ -n "${ss}" ] && [ -x "${ss}" ]; then
    { "${ss}" -Htln 2>/dev/null | sed -nE 's/.*[:.]([0-9]+)[[:space:]]+.*/\1/p' | sort -u | tr '\n' ' '; } || true
  else
    printf ''
  fi
}

_dash_module_lines() { # $1=listening set (" 80 443 ") → MODULE records
  local pairs listen m prof ver info state health aver endpoint ports plist
  local mver upgrade upfile pnum lit one nports
  listen=" $1 "
  pairs="$(_installed_pairs)"
  [ -n "${pairs}" ] || return 0
  while read -r m prof ver; do
    [ -n "${m}" ] || continue
    info=""
    if [ -f "${AIBOX_MOD_DIR}/${m}/lib.sh" ]; then
      info="$(AIBOX_MODULE="${m}" AIBOX_HOME="${AIBOX_HOME}" \
        bash -c ". '${AIBOX_MOD_DIR}/${m}/lib.sh' 2>/dev/null && type status_info >/dev/null 2>&1 && status_info 2>/dev/null || true" 2>/dev/null)"
    fi
    state="$(printf '%s\n' "${info}" | sed -n 's/^state=//p' | head -1)"
    aver="$(printf '%s\n' "${info}" | sed -n 's/^version=//p' | head -1)"
    health="$(printf '%s\n' "${info}" | sed -n 's/^health=//p' | head -1)"
    endpoint="$(printf '%s\n' "${info}" | sed -n 's/^endpoint=//p' | head -1)"
    [ -n "${state}" ] || state=na
    [ -n "${health}" ] || health=-
    state="$(printf '%s' "${state}" | awk '{print $1}')"
    health="$(printf '%s' "${health}" | awk '{print $1}')"
    # declared ports (module.yaml) — numbers only, at most four
    plist=""
    nports=0
    ports="$(meta_field "${AIBOX_MOD_DIR}/${m}/module.yaml" ports 2>/dev/null || true)"
    for pnum in ${ports}; do
      pnum="${pnum%%/*}"
      case "${pnum}" in *[!0-9]* | '') continue ;; esac
      plist="${plist:+${plist},}${pnum}"
      nports=$((nports + 1))
      [ "${nports}" -ge 4 ] && break
    done
    # which declared ports actually listen (fact vs declaration)
    lit=""
    for one in $(printf '%s' "${plist}" | tr ',' ' '); do
      case "${listen}" in
      *" ${one} "*) lit="${lit:+${lit},}${one}" ;;
      esac
    done
    mver="${ver:-}"
    [ -n "${mver}" ] || mver="$(_module_version_local "${m}" 2>/dev/null || true)"
    upgrade=""
    upfile="$(_dash_dir)/upgrade/${m}.latest"
    [ -f "${upfile}" ] && upgrade="$(head -1 "${upfile}" 2>/dev/null || true)"
    printf 'MODULE name=%s profile=%s mver=%s aver=%s state=%s health=%s endpoint=%s ports=%s listening=%s upgrade=%s age=%s\n' \
      "$(_dash_sanitize "${m}")" "$(_dash_sanitize "${prof}")" "$(_dash_sanitize "${mver:--}")" \
      "$(_dash_sanitize "${aver:--}")" "${state}" "${health}" \
      "$(_dash_sanitize "${endpoint:--}")" "${plist:--}" "${lit:--}" \
      "$(_dash_sanitize "${upgrade:--}")" "0"
  done <<DASHPAIRS
${pairs}
DASHPAIRS
}

_dash_container_lines() { # $1=1 when docker stats are due this pass
  local want_stats="$1" ps_out inspect_out stats_out ids
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  ps_out="$(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null || true)"
  [ -n "${ps_out}" ] || return 0
  ids="$(docker ps -q 2>/dev/null || true)"
  inspect_out=""
  if [ -n "${ids}" ]; then
    # shellcheck disable=SC2086  # the ids are a list; word splitting is intended
    inspect_out="$(docker inspect -f '{{.Name}}|{{.RestartCount}}|{{.Config.Image}}' ${ids} 2>/dev/null || true)"
  fi
  stats_out=""
  if [ "${want_stats}" = 1 ]; then
    stats_out="$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)"
  fi
  local name image status ports restarts health cpu mem up
  while IFS='|' read -r name image status ports; do
    [ -n "${name}" ] || continue
    case "${status}" in
    *"(healthy)"*) health=healthy ;;
    *"(unhealthy)"*) health=unhealthy ;;
    *"health: starting"*) health=starting ;;
    *) health='-' ;;
    esac
    up="${status#Up }"
    up="${up%% (*}"
    restarts="$(printf '%s\n' "${inspect_out}" | sed -n "s#^/${name}|\([0-9]*\)|.*#\1#p" | head -1)"
    cpu="-"
    mem="-"
    if [ -n "${stats_out}" ]; then
      cpu="$(printf '%s\n' "${stats_out}" | sed -n "s#^${name}|\([^|]*\)|.*#\1#p" | head -1)"
      mem="$(printf '%s\n' "${stats_out}" | sed -n "s#^${name}|[^|]*|\([^|]*\)#\1#p" | head -1)"
      mem="$(printf '%s' "${mem}" | tr -d ' ' | tr '/' '/')"
      [ -n "${cpu}" ] || cpu="-"
      [ -n "${mem}" ] || mem="-"
    fi
    printf 'CONTAINER name=%s image=%s cpu=%s mem=%s uptime=%s restarts=%s health=%s ports=%s\n' \
      "$(_dash_sanitize "${name}")" "$(_dash_sanitize "${image}")" "$(_dash_sanitize "${cpu}")" \
      "$(_dash_sanitize "${mem}")" "$(_dash_sanitize "${up}")" "${restarts:-0}" \
      "${health}" "$(_dash_sanitize "$(printf '%s' "${ports}" | tr ' ' ',')")"
  done <<DASHPS
${ps_out}
DASHPS
  return 0
}

_dash_residue_lines() { # 60s cadence: what `aibox autoclean --apply` could free
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  local dangling cache vols tags total n
  n="$(reclaim_dangling_images 2>/dev/null | grep -c . || true)"
  dangling="${n:-0}"
  cache="$(docker system df --format '{{.Type}}={{.Size}}' 2>/dev/null | sed -n 's/^Build[ _]Cache=//p' | head -1)"
  [ -n "${cache}" ] || cache='-'
  n="$(reclaim_orphan_volumes 2>/dev/null | grep -c . || true)"
  vols="${n:-0}"
  n="$(reclaim_stale_tags 2>/dev/null | grep -c . || true)"
  tags="${n:-0}"
  total="$(reclaim_df_summary 2>/dev/null || true)"
  total="$(printf '%s' "${total}" | tr ' ' ',')"
  [ -n "${total}" ] || total='-'
  printf 'RESIDUE dangling=%s buildcache=%s volumes=%s staletags=%s total=%s note=%s\n' \
    "${dangling}" "$(_dash_sanitize "${cache}")" "${vols}" "${tags}" \
    "$(_dash_sanitize "${total}")" "read-only-preview"
}

# Upgrade availability is CACHED and refreshed by separate probe processes (the
# existing __status-probe machinery), never by the UI: 15-minute cadence, one bounded
# process per module, and the check itself is a cheap file-mtime test.
_dash_upgrade_probes() { # $1=dir  $2=installed pairs
  local dir="$1" m prof ver updir f now mt
  updir="${dir}/upgrade"
  mkdir -p "${updir}" 2>/dev/null || return 0
  now="$(date +%s)"
  [ -n "${2}" ] || return 0
  while read -r m prof ver; do
    [ -n "${m}" ] || continue
    f="${updir}/${m}.latest"
    mt=""
    if [ -f "${f}" ]; then
      mt="$(date -r "${f}" +%s 2>/dev/null || stat -f %m "${f}" 2>/dev/null || true)"
    fi
    case "${mt}" in '' | *[!0-9]*) mt="" ;; esac
    if [ -z "${mt}" ] || [ $((now - mt)) -ge "${AIBOX_DASH_UPGRADE_INTERVAL:-900}" ]; then
      bash "$(_dash_self)" __status-probe "${m}" "${f}" >/dev/null 2>&1 &
    fi
  done <<DASHUP
${2}
DASHUP
}

_dash_publish() { # $1=dir  $2=content-file → atomic move into the OLDER slot
  local dir="$1" src="$2" a b dst
  a="${dir}/snapshot.1"
  b="${dir}/snapshot.2"
  # Fill an EMPTY slot first, then alternate: readers always keep one complete
  # snapshot while the next one is being published (double buffering).
  if [ ! -f "${a}" ]; then
    dst="${a}"
  elif [ ! -f "${b}" ]; then
    dst="${b}"
  elif [ "${a}" -nt "${b}" ]; then
    dst="${b}"
  else
    dst="${a}"
  fi
  mv "${src}" "${dst}" 2>/dev/null || return 1
  return 0
}

_dash_sample_once() { # $1=dir $2=interval $3=stats(0|1) $4=residue(0|1) → cost ms
  local dir="$1" interval="$2" want_stats="$3" want_residue="$4"
  local t0 t1 tmp body stale=0 docker_state=ok listen pairs
  t0="$(date +%s)"
  mkdir -p "${dir}" 2>/dev/null || return 1
  tmp="${dir}/snapshot.tmp.$$"
  body="${tmp}.body"
  listen="$(_dash_listening_set)"
  pairs="$(_installed_pairs)"
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || docker_state=down
  {
    _dash_module_lines "${listen}"
    if [ "${docker_state}" = ok ]; then
      _dash_container_lines "${want_stats}" 2>/dev/null || docker_state=down
    fi
    [ "${want_residue}" = 1 ] && _dash_residue_lines 2>/dev/null
  } >"${body}" 2>/dev/null
  t1="$(date +%s)"
  {
    printf '#aibox-dashboard-snapshot 1\n'
    printf 'SNAPSHOT ts=%s cost_ms=%s stale=%s docker=%s load=%s interval=%s\n' \
      "${t0}" "$(((t1 - t0) * 1000))" "${stale}" "${docker_state}" \
      "$(_dash_host_load)" "${interval}"
    cat "${body}" 2>/dev/null || true
  } >"${tmp}" 2>/dev/null
  rm -f "${body}" 2>/dev/null || true
  [ -s "${tmp}" ] || { rm -f "${tmp}"; return 1; }
  _dash_publish "${dir}" "${tmp}" || { rm -f "${tmp}"; return 1; }
  printf '%s\n' "$(((t1 - t0) * 1000))"
  return 0
}

# The sampler's process entry (invoked as `aibox __dashboard-sample <dir> [flags]`).
# `--once` runs a single pass (used by --once, the degrade path and the tests); the
# default is the long-lived loop the interactive UI spawns.
_dash_cmd_sample() {
  local dir="${1:-}"
  [ $# -gt 0 ] && shift
  local once=0 interval="${AIBOX_DASH_INTERVAL:-2}" stats_every=4 residue_every=30
  while [ $# -gt 0 ]; do
    case "$1" in
    --once) once=1 ;;
    --interval) shift; interval="${1:-2}" ;;
    *) : ;;
    esac
    shift
  done
  [ -n "${dir}" ] || dir="$(_dash_dir)"
  case "${interval}" in '' | *[!0-9]*) interval=2 ;; esac
  [ "${interval}" -ge 1 ] || interval=1
  if [ "${once}" = 1 ]; then
    _dash_sample_once "${dir}" "${interval}" 1 1 >/dev/null
    return 0
  fi
  trap 'exit 0' TERM INT HUP
  local n=0 want_stats want_residue pairs
  while :; do
    n=$((n + 1))
    want_stats=0
    want_residue=0
    [ $((n % stats_every)) -eq 1 ] && want_stats=1
    [ $((n % residue_every)) -eq 1 ] && want_residue=1
    _dash_sample_once "${dir}" "${interval}" "${want_stats}" "${want_residue}" >/dev/null 2>&1 || true
    pairs="$(_installed_pairs)"
    _dash_upgrade_probes "${dir}" "${pairs}" >/dev/null 2>&1 || true
    sleep "${interval}"
  done
}

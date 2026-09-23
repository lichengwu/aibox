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
# probe through the daemon itself). DIRECT is tried first with a real
# daemon-routed probe (docker pull hello-world, bounded): healthy networks
# keep the zero-overhead default (compose pulls directly). Only when the
# direct route is dead does the pool engage: mirrors are RANKED by concurrent
# bounded hello-world pulls (measured through the daemon — the real channel),
# then uncached docker.io images are pre-pulled from the ranked order and
# `docker tag`-ed to their official names (mirrors proxy IDENTICAL digests —
# the windmill WM_HUB_MIRROR technique), so `compose up` finds them cached.
# Other registries (cr.weaviate.io …) stay direct-only — the mirrors proxy
# docker.io. Knobs: AIBOX_DOCKER_POOL (mirror list override; "direct" =
# disabled), AIBOX_DOCKER_MIRROR (user mirror, first), AIBOX_DOCKER_FORCE_POOL=1
# (skip the direct probe — always engage), AIBOX_DOCKER_PROBE_TIMEOUT (15),
# AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT (30), AIBOX_DOCKER_PULL_TIMEOUT (1800).
# Live-verified mirrors (Aliyun deploy host, real pulls): docker.1ms.run,
# docker.m.daocloud.io, dockerproxy.net, hub.rat.dev; docker.xuanyuan.me /
# dockerpull.org dead — excluded.
DOCKER_POOL_MIRRORS="docker.1ms.run docker.m.daocloud.io dockerproxy.net hub.rat.dev"

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

# Pre-pull uncached docker.io images through the mirror pool. No-op (fast
# probe) when the daemon's direct route is healthy.

docker_pool_prepull() { # $@ = image refs
  case "${AIBOX_DOCKER_POOL:-}" in
  direct | none | off) return 0 ;;
  esac
  local img uncached="" m mirrors cands pid pids="" tmpd i t0 done1 rc_all=0 full
  # 1. filter: cached images + non-docker.io refs (mirrors don't proxy other
  #    registries — those stay direct)
  for img in "$@"; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    _dk_is_dockerio "${img}" || continue
    uncached="${uncached}${uncached:+ }${img}"
  done
  [ -n "${uncached}" ] || return 0
  # 2. direct daemon-route probe: healthy → compose pulls direct (zero overhead).
  #    hello-world is rmi'd first so the probe is honest (a cached probe proves
  #    nothing about the route).
  if [ "${AIBOX_DOCKER_FORCE_POOL:-0}" != "1" ]; then
    docker rmi hello-world >/dev/null 2>&1 || true
    if _dk_bounded "${AIBOX_DOCKER_PROBE_TIMEOUT:-15}" pull hello-world >/dev/null 2>&1; then
      log "docker: direct daemon route OK — compose will pull ${uncached} directly"
      return 0
    fi
  fi
  warn "docker: direct route unusable — engaging the mirror pool for: ${uncached}"
  # 3. rank mirrors by concurrent bounded hello-world pulls (real daemon channel)
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
    return 0
  fi
  log "docker mirror ranking: $(printf '%s' "${cands}" | tr '\n' ' ')"
  # 4. pre-pull the uncached images from the ranked order, per-source failover
  # shellcheck disable=SC2086
  for img in ${uncached}; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    done1=0
    # shellcheck disable=SC2086
    for m in ${cands}; do
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
  return "${rc_all}"
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

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

# Usage errors are exit 2 everywhere (manager and module hooks) — automation can
# tell "you called it wrong" (2) from "it ran and failed" (1).
usage_die() { printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2; exit 2; }
# Arbitrary stable exit codes are part of the hook contract (3 deps missing /
# 4 precheck failed / 10 rolled back / 20 manual / 30/40/50) — spec §Exit codes.
die_code() { local _c="$1"; shift; printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2; exit "${_c}"; }
# ---------- shared base linking (profile-aware) ----------
# base writes ONE connection env file per profile: `base.env` for the default
# "base" profile, `base-<profile>.env` for named ones (base/lib.sh
# _profile_load). EVERY consumer link must resolve the same paths through these
# helpers — a hardcoded `base.env` silently attached consumers to the DEFAULT
# profile's instance (wrong network/credentials/ports): the P0 of the 2026-09
# dependency review.
# The profile SUFFIX, generally usable (base's container/env names AND every
# consumer's deploy root use it): "" for the default profile, else "-<profile>".
profile_suffix() {
  case "${AIBOX_PROFILE:-base}" in
  '' | base) printf '' ;;
  *)        printf '%s' "-${AIBOX_PROFILE}" ;;
  esac
}

base_profile_suffix() { profile_suffix; }

base_env_file() { # the profile's connection env file, written by `base start`
  printf '%s/base%s.env' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}" "$(base_profile_suffix)"
}

base_pg_container()    { printf 'aibox-base%s-postgres' "$(base_profile_suffix)"; }
base_redis_container() { printf 'aibox-base%s-redis' "$(base_profile_suffix)"; }

base_network_name() { # from the env file when present, else the derived name
  local env net
  env="$(base_env_file)"
  net="$(grep -E '^AIBOX_BASE_NETWORK=' "${env}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
  [ -n "${net}" ] || net="aibox-base$(base_profile_suffix)"
  printf '%s' "${net}"
}

# The base.env contract version THIS library understands. Bump here AND in
# base's write_base_env together when the shape changes incompatibly; consumers
# then fail with a fix hint instead of reading empty values into a compose file.
BASE_ENV_VERSION_SUPPORTED="1"

base_env_check() { # 0 = usable; 1 + actionable message otherwise
  local env ver
  env="$(base_env_file)"
  if [ ! -f "${env}" ]; then
    warn "shared base env missing: ${env} (run: aibox base start)"
    return 1
  fi
  ver="$(grep -E '^AIBOX_BASE_ENV_VERSION=' "${env}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
  if [ -n "${ver}" ] && [ "${ver}" != "${BASE_ENV_VERSION_SUPPORTED}" ]; then
    warn "shared base env contract mismatch: ${env} declares v${ver}, this module expects v${BASE_ENV_VERSION_SUPPORTED}"
    warn "  fix: aibox update base && aibox base restart   (or update this module: aibox update <module>)"
    return 1
  fi
  # pre-contract file (written before 0.19): keys are a strict subset, so the
  # documented defaults still hold — say it once, don't fail
  [ -n "${ver}" ] || info "shared base env is pre-contract (no AIBOX_BASE_ENV_VERSION) — run: aibox base restart to refresh it"
  return 0
}

# Per-consumer Redis logical DB file (`AIBOX_REDIS_DB`), written by the manager's
# ensure_services / `aibox base create redis <module>`. Consumers add it with
# --env-file so compose interpolation sees the module's own slot instead of
# silently sharing index 0 with every other module.
redis_env_file() { # $1=module
  [ -n "${1:-}" ] || return 0
  printf '%s/redis%s-%s.env' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}" "$(base_profile_suffix)" "$1"
}

# Idempotent "the module's database exists in the shared base": a hand-dropped DB
# used to surface as a cryptic application error at start. Runs the sibling base
# module's own `create` (single implementation), quiet on the happy path.
ensure_shared_db() { # $1=db name
  local db="${1:-}" svc
  [ -n "${db}" ] || return 0
  svc="$(shared_base_svc_path)"
  [ -f "${svc}" ] || die "the shared base module is not installed — first: aibox install base"
  if ! AIBOX_MODULE=base bash "${svc}" create postgres "${db}" >/dev/null 2>&1; then
    warn "could not ensure the shared database '${db}' — create it manually: aibox base create postgres ${db}"
    return 1
  fi
  return 0
}

# Ensure the module's Redis logical DB slot exists (idempotent; writes the
# consumer's redis env file so compose can interpolate AIBOX_REDIS_DB instead of
# silently sharing index 0 with every other module).
ensure_shared_redis_db() { # $1=module [$2=slots]
  local m="${1:-}" slots="${2:-1}" svc
  [ -n "${m}" ] || return 0
  svc="$(shared_base_svc_path)"
  [ -f "${svc}" ] || die "the shared base module is not installed — first: aibox install base"
  if ! AIBOX_MODULE=base bash "${svc}" create redis "${m}" "${slots}" >/dev/null 2>&1; then
    warn "could not allocate the shared Redis DB for '${m}' — run: aibox base create redis ${m}"
    return 1
  fi
  return 0
}

# Idempotent "the shared base must be UP for this action" — the action-time
# the action-time counterpart of the manager's ensure_services (both use the
# shared helpers). Live-caught: `aibox xiaozhi start`
# died with "shared base not running … first: aibox base start" — two commands
# for one intent. base already up → silent no-op; installed but down → start it
# (compose up -d is idempotent) and wait for the network; not installed or not
# startable → die (without the provider the module cannot run at all).
ensure_shared_base() {
  require_docker
  local svc env net waited=0 timeout_s
  svc="$(shared_base_svc_path)"
  [ -f "$svc" ] || die "the shared base module is not installed — first: aibox install base"
  env="$(base_env_file)"
  net="$(base_network_name)"
  # fast path: the env file exists AND its network is up (both written by base start)
  if shared_base_up; then
    base_env_check || die "shared base env is unusable — see the hint above"
    return 0
  fi
  info "shared base (profile ${AIBOX_PROFILE:-base}) is not running — starting it (this action needs the ${net} network)…"
  AIBOX_MODULE=base bash "$svc" start || die "shared base failed to start — check: aibox base logs"
  timeout_s="${AIBOX_BASE_WAIT_TIMEOUT:-120}"
  while [ "${waited}" -lt "${timeout_s}" ]; do
    if [ -f "$env" ] && docker network inspect "${net}" >/dev/null 2>&1; then
      base_env_check || true
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  die "the shared base did not become ready within ${timeout_s}s — check: aibox base status"
}

# Quiet predicate: "the profile's base is UP" — the contract file exists AND its
# docker network is up (both written by `base start`). Action takers call
# ensure_shared_base (which starts it when needed); observers call this.
shared_base_up() {
  local env net
  env="$(base_env_file)"
  [ -f "${env}" ] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  net="$(base_network_name)"
  docker network inspect "${net}" >/dev/null 2>&1
}

# ---------- one config, read at runtime (spec §Dependency contract) ----------
# Credentials and endpoints live in the PROVIDER's contract (base[-<profile>].env)
# and nowhere else. Consumers read it at runtime; nobody keeps a second copy — a
# rendered copy goes stale the moment base rotates its secret (live-caught: a 5-char
# legacy default baked into .env vs the 32-char contract password, the app dying in
# a crash-loop on "password authentication failed").

# Load the contract into THIS process and export it, so every child — a sibling hook,
# a dispatched CLI, `docker compose`'s interpolation environment — reads the same
# values. Silent no-op when the contract is absent (standalone deployments).
base_contract_export() {
  local f
  f="$(base_env_file)"
  [ -n "${f}" ] && [ -f "${f}" ] || return 0
  cfg_kv_load_export "${f}" AIBOX_
  AIBOX_POSTGRES_USER="${AIBOX_POSTGRES_USER:-aibox}"
  AIBOX_POSTGRES_HOST="${AIBOX_POSTGRES_HOST:-aibox-base-postgres}"
  AIBOX_POSTGRES_PORT="${AIBOX_POSTGRES_PORT:-5432}"
  AIBOX_REDIS_HOST="${AIBOX_REDIS_HOST:-aibox-base-redis}"
  AIBOX_REDIS_PORT="${AIBOX_REDIS_PORT:-6379}"
  export AIBOX_POSTGRES_USER AIBOX_POSTGRES_HOST AIBOX_POSTGRES_PORT
  export AIBOX_REDIS_HOST AIBOX_REDIS_PORT
  return 0
}

# Derived connection strings — ONE implementation, evaluated at CALL time, never
# written into a module's files (writing them is how the stale copy happened).
base_pg_url() { # $1 = database name
  local db="${1:-}"
  [ -n "${db}" ] || return 0
  printf 'postgres://%s:%s@%s:%s/%s' "${AIBOX_POSTGRES_USER:-aibox}" "${AIBOX_POSTGRES_PASSWORD:-}" \
    "${AIBOX_POSTGRES_HOST:-aibox-base-postgres}" "${AIBOX_POSTGRES_PORT:-5432}" "${db}"
}

base_redis_url() { # $1 = logical database index
  printf 'redis://:%s@%s:%s/%s' "${AIBOX_REDIS_PASSWORD:-}" \
    "${AIBOX_REDIS_HOST:-aibox-base-redis}" "${AIBOX_REDIS_PORT:-6379}" "${1:-0}"
}

# Generic drift scan for any KEY=VALUE state a module keeps (its deploy .env, a host
# conf): does it hold a COPY of a connection fact that no longer matches the contract?
# Prints one line per drifted key ("" = consistent, no contract, or nothing to check).
contract_drift_report() { # $1 = module state file
  local f="${1:-}" cf line key val want wu wh got gu gp rest gh
  cf="$(base_env_file)"
  if [ -z "${f}" ] || [ ! -f "${f}" ] || [ -z "${cf}" ] || [ ! -f "${cf}" ]; then return 0; fi
  while IFS= read -r line; do
    case "${line}" in '' | '#'*) continue ;; esac
    case "${line}" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "${key}" in
    AIBOX_POSTGRES_PASSWORD | AIBOX_REDIS_PASSWORD)
      want="$(cfg_kv_get "${cf}" "${key}")"
      if [ -n "${want}" ] && [ "${val}" != "${want}" ]; then
        printf '%s: stale copy in %s — restart the module to pick up %s\n' "${key}" "$(basename "${f}")" "${cf}"
      fi
      ;;
    *URL* | *DSN* | *CONN_STRING*)
      case "${val}" in *'://'*'@'*) ;; *) continue ;; esac
      got="${val#*://}"
      gu="${got%%:*}"
      gp="${got#*:}"; gp="${gp%%@*}"
      rest="${val#*@}"; gh="${rest%%[:/]*}"
      case "${key}" in
      *REDIS*)
        want="$(cfg_kv_get "${cf}" AIBOX_REDIS_PASSWORD)"
        wu="$(cfg_kv_get "${cf}" AIBOX_REDIS_USER)"
        wh="$(cfg_kv_get "${cf}" AIBOX_REDIS_HOST)"
        ;;
      *)
        want="$(cfg_kv_get "${cf}" AIBOX_POSTGRES_PASSWORD)"
        wu="$(cfg_kv_get "${cf}" AIBOX_POSTGRES_USER)"
        wh="$(cfg_kv_get "${cf}" AIBOX_POSTGRES_HOST)"
        ;;
      esac
      if [ -n "${want}" ] && { [ "${gp}" != "${want}" ] || { [ -n "${wh}" ] && [ "${gh}" != "${wh}" ]; }; }; then
        printf '%s: embeds a stale connection fact in %s (contract says %s@%s) — restart the module, or: aibox <module> deploy --recreate\n' \
          "${key}" "$(basename "${f}")" "${wu:-<user>}" "${wh}"
      fi
      ;;
    esac
  done <"${f}"
  return 0
}
# Host ports must live in the aibox RESERVED BAND (spec §Port allocation):
# 31000-31999 services, 32000-32999 infrastructure. Three zones are refused:
# privileged (<1024), Linux's ephemeral range (32768-60999 — the kernel hands
# those to outbound connections first) and the common-service conventions
# (3000/5000/8080/8443/8888/9000/9090/7890 …), which collide with whatever else
# runs on the host. Prints a one-line reason for a non-compliant port ("" = ok).
port_policy_hint() { # $1=port
  local p="${1:-}"
  case "${p}" in *[!0-9]*) return 0 ;; esac
  if [ "${p}" -lt 1024 ]; then
    printf 'privileged port (<1024) — needs CAP_NET_BIND and collides with real services'
    return 0
  fi
  if [ "${p}" -ge 32768 ] && [ "${p}" -le 60999 ]; then
    printf "inside Linux's ephemeral range (32768-60999) — the kernel may hand it to an outbound connection first"
    return 0
  fi
  case "${p}" in
  3000 | 3128 | 3306 | 4000 | 5000 | 5432 | 5555 | 6379 | 7000 | 7890 | 8000 | 8002 | 8003 | 8080 | 8081 | 8088 | 8443 | 8888 | 8929 | 9000 | 9090 | 10000)
    printf 'a common service convention — likely to collide with another service on this host' ;;
  esac
  return 0
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
  # 2) the module's own state report (status_info is the module's contract)
  if type status_info >/dev/null 2>&1; then
    info="$(status_info 2>/dev/null || true)"
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
    info "state       (module has no status_info)"
  fi
  # 3) declared ports
  local ports="" entry
  ports="$(awk '/^ports:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); printf "%s ", $0}' "${yaml}" 2>/dev/null || true)"
  for entry in ${ports}; do
    local pnum="${entry%%/*}"
    case "${pnum}" in ''|*[!0-9]*) continue ;; esac
    if port_listening "${pnum}"; then ok "port        ${entry} listening"
    local _phint; _phint="$(port_policy_hint "${pnum}")"
    [ -n "${_phint}" ] && warn "port        ${pnum} is ${_phint} (spec §Port allocation: 31000-31999 services / 32000-32999 infra)"
    else info "port        ${entry} — (not listening)"; fi
  done
  [ -n "${ports}" ] || info "port        (none declared)"
  # verdict
  if [ "${miss}" = "1" ]; then printf '%s✗  not healthy: a dependency is missing (aibox install %s)%s\n' "${C_RED:-}" "${m}" "${C_RST:-}"; return 3; fi
  if [ "${notready}" = "1" ]; then printf '%s⚠  not ready: the service is not running (aibox %s start)%s\n' "${C_YEL:-}" "${m}" "${C_RST:-}"; return 30; fi
  ok "all checks passed"
  return 0

  # ONE config: does this module's own state keep a stale copy of a connection fact?
  local _drift="" _deproot=""
  if type -t deploy_root >/dev/null 2>&1; then _deproot="$(deploy_root 2>/dev/null || true)"; fi
  if [ -n "${_deproot}" ] && [ -f "${_deproot}/.env" ]; then
    _drift="$(contract_drift_report "${_deproot}/.env")"
    [ -n "${_drift}" ] && printf '%s\n' "${_drift}" | while IFS= read -r l; do warn "  ${l}"; done
  fi
}

# Usage errors in module hooks are exit 2 (same convention as the manager).

# ---------- status keyline template (spec §Status template) ----------

# Shared render helpers for module-owned rich views (render_status); the
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

_status_w() { # prints the rule width; $1 = stdout-is-tty flag ("1"/"0")
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
_status_state_seg() { # $1=state word (ok|running|starting|stopped|na|"")
  case "${1:-}" in
  ok | running) printf '%s✓ %s%s' "${C_GRN:-}" "${1}" "${C_RST:-}" ;;
  starting) printf '%s⚠ %s%s' "${C_YEL:-}" "${1}" "${C_RST:-}" ;;
  stopped) printf '%s○ %s%s' "${C_DIM:-}" "${1}" "${C_RST:-}" ;;
  *) printf '' ;;
  esac
}

status_header() { # $1=name $2=app_version (""=omit) $3=state word (see _status_state_seg)
  local seg
  printf '%s%s%s' "${C_BOLD:-}" "${1}" "${C_RST:-}"
  [ -n "${2}" ] && printf ' %s%s%s' "${C_CYA:-}" "${2}" "${C_RST:-}"
  seg="$(_status_state_seg "${3:-}")"
  [ -n "${seg}" ] && printf ' %s·%s %s' "${C_DIM:-}" "${C_RST:-}" "${seg}"
  printf '\n'
  status_rule
}

status_row() { # $1=label (ASCII, ≤10 chars) $2=value (verbatim; may embed color spans)
  printf '  %s%-10s%s %s\n' "${C_DIM:-}" "${1}" "${C_RST:-}" "${2}"
}

status_module_row() { # $1=module_version $2=module_dir — sunk, whole row dim
  printf '  %s%-10s %s · %s%s\n' "${C_DIM:-}" "module" "${1:-?}" "${2:-}" "${C_RST:-}"
}

status_rule() { # the dim horizontal rule (width per the header comment)
  local w i=0 out=""
  if [ -t 1 ] 2>/dev/null; then
    w="$(_status_w 1)"
  else
    w=64
  fi
  while [ "${i}" -lt "${w}" ]; do
    out="${out}─"
    i=$(( i + 1 ))
  done
  printf '%s%s%s\n' "${C_DIM:-}" "${out}" "${C_RST:-}"
}

status_secheader() { # $1=title (ASCII) → "── title ───…" to the rule width
  local w n i=0 out=""
  if [ -t 1 ] 2>/dev/null; then
    w="$(_status_w 1)"
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
# shared with the TAGS family in 32-docker-tags.sh), TTL AIBOX_DOCKER_POOL_TTL (600s),
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
# counterpart of these helpers; SAME file, SAME grammar). Token grammar: "direct" =
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
  # awk on a MISSING file exits 2 — guarded the same way as the gh-pool reader (an unguarded
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

# ---------- docker hub tag resolution (the TAGS family) ----------
# Shared: both the manager (component upgrades, statuss) and module hooks
# (upgrade stanzas) resolve a repo's tag list through the same direct →
# local-mirror → pool order the image pulls use, with the sticky winner cached
# in $AIBOX_HOME/dockerpool.cache.
DK_TAGS_POOL_DEFAULT="docker.1ms.run hub.rat.dev docker.1panel.live hub.1panel.dev proxy.vvvv.ee docker.m.daocloud.io hub3.nat.tf hub4.nat.tf docker.367231.xyz docker.apiba.cn"

dockerhub_tags_fetch() { # $1=repo (e.g. gitlab/gitlab-ce) → tag names, one per line
  local repo="$1" cached order m tags seen_direct=0 pool
  local tmo="${AIBOX_DOCKER_TAGS_TIMEOUT:-8}"
  pool=""
  case "${AIBOX_DOCKER_POOL:-}" in
  direct | none | off) ;;
  *) pool="${AIBOX_DOCKER_POOL:-${DK_TAGS_POOL_DEFAULT}}" ;;
  esac
  # 1. walk the cached order (failover; demote a dead official route)
  cached="$(_dkcache_read TAGS)"
  if [ -n "${cached}" ]; then
    for m in ${cached}; do
      if [ "${m}" = "direct" ]; then
        seen_direct=1
        if tags="$(_dk_tags_direct "${repo}")"; then
          _dkcache_write TAGS "direct"
          printf '%s\n' "${tags}"
          return 0
        fi
        continue
      fi
      if tags="$(_dk_tags_mirror "${m}" "${repo}")"; then
        # death-cache: an official route that failed in front of the winner is
        # dropped from the order until the TTL re-probes it
        if [ "${seen_direct}" = "1" ]; then
          _dkcache_write TAGS "$(printf '%s\n' ${cached} | awk -v m="${m}" '$0==m {f=1; print; next} f {print}' | tr '\n' ' ')"
        fi
        printf '%s\n' "${tags}"
        return 0
      fi
    done
    _dkcache_write TAGS ""   # everything failed → self-heal: re-resolve now
  fi
  # 2. ① the default address (hub.docker.com direct)
  if tags="$(_dk_tags_direct "${repo}")"; then
    _dkcache_write TAGS "direct"
    printf '%s\n' "${tags}"
    return 0
  fi
  # 3. ② local addresses: the user knob + the daemon's registry-mirrors
  local locals=""
  [ -n "${AIBOX_DOCKER_MIRROR:-}" ] && locals="${AIBOX_DOCKER_MIRROR}"
  locals="${locals}${locals:+ }$(_dk_tags_local_mirrors)"
  # shellcheck disable=SC2086
  for m in ${locals}; do
    if tags="$(_dk_tags_mirror "${m}" "${repo}")"; then
      _dkcache_write TAGS "${m}"
      printf '%s\n' "${tags}"
      return 0
    fi
  done
  # 4. ③ the acceleration pool: concurrent race on the ACTUAL repo (the same
  #    t bounds each candidate), rank by measured response time
  [ -n "${pool}" ] || return 1
  local tmpd pid pids="" i=0
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/dktags.XXXXXX")" || return 1
  # shellcheck disable=SC2086
  for m in ${pool}; do
    i=$(( i + 1 ))
    (
      t="$(curl -fsSL --max-time "${tmo}" -o /dev/null -w '%{time_total}' \
        "https://${m}/v2/${repo}/tags/list" 2>/dev/null)" || exit 0
      printf '%s %s\n' "${t}" "${m}" >"${tmpd}/r${i}.res"
    ) &
    pids="${pids} $!"
  done
  # shellcheck disable=SC2086
  for pid in ${pids}; do wait "${pid}" 2>/dev/null || true; done
  order="$(cat "${tmpd}"/r*.res 2>/dev/null | sort -n | awk '{print $2}' | tr '\n' ' ' || true)"
  rm -rf "${tmpd}" 2>/dev/null || true
  [ -n "${order}" ] || return 1
  _dkcache_write TAGS "${order}"
  # the winner serves this fetch (one bounded re-fetch — simpler than wiring
  # the race bodies through; ~0.3s on the measured mirrors)
  if tags="$(_dk_tags_mirror "${order%% *}" "${repo}")"; then
    printf '%s\n' "${tags}"
    return 0
  fi
  return 1
}

_dk_tags_direct() { # $1=repo → tags on stdout; rc 1 when dead/empty
  local body
  body="$(curl -fsSL --max-time "${AIBOX_DOCKER_TAGS_TIMEOUT:-8}" \
    "https://hub.docker.com/v2/repositories/${1}/tags?page_size=100&ordering=last_updated" 2>/dev/null)" || return 1
  printf '%s' "${body}" | grep -oE '"name": *"[^"]+"' | cut -d'"' -f4 | grep -v '^$' || return 1
}

_dk_tags_mirror() { # $1=mirror-host $2=repo → tags on stdout; rc 1 when dead/empty
  local body
  body="$(curl -fsSL --max-time "${AIBOX_DOCKER_TAGS_TIMEOUT:-8}" \
    "https://${1}/v2/${2}/tags/list" 2>/dev/null)" || return 1
  printf '%s' "${body}" | sed -e 's/.*"tags": *\[//' -e 's/\].*//' \
    | tr ',' '\n' | tr -d ' "[]' | grep -v '^$' || return 1
}

_dk_tags_local_mirrors() {
  local out
  command -v docker >/dev/null 2>&1 || return 0
  out="$(docker info --format '{{.RegistryConfig.Mirrors}}' 2>/dev/null || true)"
  printf '%s\n' "${out}" | tr ' ' '\n' | tr -d '[]' \
    | sed -E 's#^https?://##; s#/$##' | grep -v '^$' || true
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

# Load a KEY=VALUE data file into shell variables WITHOUT executing it: data is
# not code, and a corrupted (or hostile) config/state/registry file must never
# run. Keys must look like identifiers (optionally filtered by a prefix); values
# are taken literally (surrounding double quotes stripped) and assigned with
# printf -v (no eval, no command substitution, no expansion).
cfg_kv_load() { # $1=file [$2=key prefix]
  local f="${1:-}" prefix="${2:-}" line key val
  [ -n "${f}" ] && [ -f "${f}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in '' | '#'*) continue ;; esac
    case "${line}" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "${key}" in '' | *[!A-Za-z0-9_]*) continue ;; esac
    case "${key}" in [A-Za-z_]*) ;; *) continue ;; esac
    if [ -n "${prefix}" ]; then
      case "${key}" in "${prefix}"*) ;; *) continue ;; esac
    fi
    case "${val}" in '"'*'"') val="${val#\"}"; val="${val%\"}" ;; esac
    printf -v "${key}" '%s' "${val}"
  done < "${f}"
  return 0
}

# Same, but exported (deploy .env files feed compose interpolation).
cfg_kv_load_export() { # $1=file [$2=key prefix]
  local f="${1:-}" prefix="${2:-}" line key
  cfg_kv_load "${f}" "${prefix}"
  [ -n "${f}" ] && [ -f "${f}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in '' | '#'* | *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    case "${key}" in '' | *[!A-Za-z0-9_]*) continue ;; esac
    case "${key}" in [A-Za-z_]*) ;; *) continue ;; esac
    if [ -n "${prefix}" ]; then
      case "${key}" in "${prefix}"*) ;; *) continue ;; esac
    fi
    export "${key}"
  done < "${f}"
  return 0
}

# ---------- managed vs state files (update must not clobber user edits) ----------
# A deploy root holds two kinds of files:
#   MANAGED (templates/code shipped by the module: compose files, conf templates)
#     — safe to refresh on update, as long as the user has not edited them
#   STATE (`.env`, data, anything the user owns: `state_files:` in module.yaml)
#     — never overwritten
# Historically install hooks did a plain `cp`, so an edited compose file was
# silently replaced by the next `aibox update`. install_managed_file records the
# hash of what it installed and keeps a user-modified copy (writing the new
# version next to it as `<name>.new`).

managed_manifest() { # $1=deploy root → the hash manifest path
  printf '%s/.managed.sha256' "${1:-}"
}

# Install/refresh one managed file (always 0 when it did its job — keeping the
# user's edit included; only a real copy failure is fatal).
install_managed_file() { # $1=source $2=destination
  local src="${1:-}" dst="${2:-}" root mf want have tmp
  [ -n "${src}" ] && [ -f "${src}" ] || return 0
  [ -n "${dst}" ] || return 0
  root="$(dirname "${dst}")"
  mkdir -p "${root}"
  mf="$(managed_manifest "${root}")"
  want="$(sha256_of "${src}")"
  if [ -f "${dst}" ]; then
    have="$(sha256_of "${dst}")"
    if [ "${have}" != "${want}" ]; then
      # the file on disk differs from what we ship: is it OUR previous version
      # (safe to refresh) or the user's edit (keep it)?
      if [ "$(manifest_digest "${mf}" "${dst}")" = "${have}" ]; then
        cp "${src}" "${dst}"
        _managed_record "${mf}" "${dst}" "${want}"
        return 0
      fi
      # accepted-update path: the file currently equals the "<dst>.new" we shipped
      # last time (the user took the update) — safe to refresh
      if [ "$(manifest_digest "${mf}" "${dst}.new")" = "${have}" ]; then
        cp "${src}" "${dst}"
        _managed_record "${mf}" "${dst}" "${want}"
        return 0
      fi
      cp "${src}" "${dst}.new"
      _managed_record "${mf}" "${dst}.new" "${want}"
      warn "$(basename "${dst}") was modified by you — kept it; the updated version is $(basename "${dst}").new"
      # 0: keeping the user's file IS the success case (a hook must not abort)
      return 0
    fi
    _managed_record "${mf}" "${dst}" "${have}"
    return 0
  fi
  cp "${src}" "${dst}"
  _managed_record "${mf}" "${dst}" "${want}"
  return 0
}

_managed_record() { # $1=manifest $2=path $3=sha256
  local mf="${1:-}" p="${2:-}" h="${3:-}" tmp
  [ -n "${mf}" ] && [ -n "${h}" ] || return 0
  tmp="$(mktemp)"
  [ -f "${mf}" ] && grep -v "  ${p}\$" "${mf}" >"${tmp}" 2>/dev/null || true
  printf '%s  %s\n' "${h}" "${p}" >>"${tmp}"
  sort -o "${tmp}" "${tmp}"
  mv "${tmp}" "${mf}"
  return 0
}
# ---------- module.yaml readers (ONE implementation of the dialect) ----------
# The registry dialect is a tiny YAML subset (scalars, flat lists, two-space
# maps) and it used to be parsed in five places — the manager's registry loader,
# three status readers, the validator, and seven module libs. Every copy was
# a place where the dialect's semantics could drift (and the validator's copy was
# never even defined: parse_one died silently, so its cross-module rules were
# no-ops). Readers:
#   parse_yaml_module_stdin <mu>   registry vars for a whole file (manager/validator)
#   meta_field <yaml> <field>      scalar value, else flat list joined by spaces
#   meta_map_value <yaml> <k> <c>  two-space map member (e.g. usage.<action>)
#   meta_version <yaml>            the version field (module libs / display)

# Capability version of the manager↔module CONTRACT SURFACE: the status_info
# keys, the residue: stanza, the upgrade: stanza and the hook behaviour. Bump it
# on any RENAME/REMOVAL in that surface (additions do not need a bump); a module
# declares the version it targets via module_iface in module.yaml. The manager
# exports this to hooks and warns when a module targets something newer.
AIBOX_IFACE_SUPPORTED="1"
#
parse_yaml_module_stdin() {
  awk -v NAME="$1" '
    BEGIN { parent=""; subparent=""; listkey=""; listval="" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      content=$0
      while (substr(content,1,1)==" ") content=substr(content,2)
      indent=length($0)-length(content)
      if (substr(content,1,1)=="-") {
        item=substr(content,2); sub(/^ +/, "", item)
        if (listkey=="") listkey=(subparent!="" ? NAME"_"parent"_"subparent : NAME"_"parent)
        listval=(listval=="" ? "" : listval" ") stripq(item)
        next
      }
      colon=index(content,":")
      if (colon>0) {
        k=substr(content,1,colon-1); v=substr(content,colon+1)
        sub(/^ +/, "", v); sub(/ +$/, "", v)
        if (listkey!="") { printvar(listkey,listval); listkey=""; listval="" }
        if (indent==0) {
          parent=""; subparent=""
          if (v=="") parent=k; else printvar(NAME"_"k, stripq(v))
        } else {
          if (v=="") subparent=k
          else if (parent=="hooks") printvar(NAME"_"k, stripq(v))  # hooks.install -> _install (module_field compat)
          else if (parent!="") printvar(NAME"_"parent"_"k, stripq(v))
        }
      }
    }
    END { if (listkey!="") printvar(listkey,listval) }
    function esc(s,   r) { r=s; gsub(/\\/, "\\\\", r); gsub(/"/, "\\\"", r); gsub(/\$/, "\\$", r); gsub(/`/, "\\`", r); return r }
    function printvar(k,v) { gsub(/-/, "_", k); printf "AIBOX_MODULE_%s=\"%s\"\n", k, esc(v) }
    function stripq(s) {
      if (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") return substr(s,2,length(s)-2)
      return s
    }
  '
}

# Scalar field value, else the flat list under it joined by spaces ("" when the
# file or the field is absent — callers decide the fallback: registry, installed
# marker, or nothing).
meta_field() { # $1 = module.yaml path, $2 = field
  local f="${1:-}" field="${2:-}" v
  [ -n "${f}" ] && [ -n "${field}" ] && [ -f "${f}" ] || return 0
  v="$(sed -n "s/^${field}: *\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "${f}" 2>/dev/null | head -1)"
  [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  awk -v f="${field}" '
    $0 == f ":" { inl = 1; next }
    inl && /^[ ]+- / {
      sub(/^[ ]+- /, ""); gsub(/^"|"$/, "")
      printf "%s%s", sep, $0; sep = " "; next
    }
    inl { inl = 0 }
  ' "${f}" 2>/dev/null
}

# Value of a two-space map member: `usage:` → `  <action>: "text"`.
meta_map_value() { # $1 = module.yaml path, $2 = parent key, $3 = member key
  local f="${1:-}" pk="${2:-}" ck="${3:-}"
  [ -n "${f}" ] && [ -n "${pk}" ] && [ -n "${ck}" ] && [ -f "${f}" ] || return 0
  awk -v pk="${pk}" -v ck="${ck}" '
    $0 == pk ":" { inb = 1; next }
    inb && /^[^ ]/ { inb = 0 }
    inb {
      line = $0; sub(/^[ ]+/, "", line)
      if (index(line, ck ":") == 1) {
        v = substr(line, length(ck) + 2); sub(/^ +/, "", v); gsub(/^"|"$/, "", v)
        print v; exit
      }
    }
  ' "${f}" 2>/dev/null
}

# The version field — the ONE reader for module libs (the manager injects
# AIBOX_MODULE_VERSION on dispatch, so this covers direct execution).
meta_version() { # $1 = module.yaml path
  meta_field "${1:-}" version
}

# A nested child value under a top-level parent: scalar (`parent:` → `  child: v`)
# or the flat list under it (`parent:` → `  child:` → `    - item`), joined.
meta_sub_field() { # $1 = module.yaml path, $2 = parent key, $3 = child key
  local f="${1:-}" pk="${2:-}" ck="${3:-}"
  [ -n "${f}" ] && [ -n "${pk}" ] && [ -n "${ck}" ] && [ -f "${f}" ] || return 0
  awk -v pk="${pk}" -v ck="${ck}" '
    $0 == pk ":" { inb = 1; next }
    inb && /^[^ ]/ { inb = 0 }
    inb {
      line = $0; sub(/^[ ]+/, "", line)
      if (line == ck ":") { inl = 1; next }
      if (inl && line ~ /^- /) {
        sub(/^- /, "", line); gsub(/^"|"$/, "", line)
        printf "%s%s", sep, line; sep = " "; next
      }
      if (index(line, ck ":") == 1) {
        v = substr(line, length(ck) + 2); sub(/^ +/, "", v); gsub(/^"|"$/, "", v)
        print v; exit
      }
      inl = 0
    }
  ' "${f}" 2>/dev/null
}
# ---------- JSON emission (bash 3.2, no jq/python) ----------
# Machine-readable output is a first-class surface for a manager whose main
# consumers are scripts, timers and CI (`aibox status --json`,
# `aibox check --json`). These helpers keep the escaping in ONE place; callers
# own the shape. stdout carries JSON only — colors/log lines go to stderr.

# Escape a string for a JSON string literal (quotes, backslashes, control chars).
json_escape() { # $1 = raw text → escaped text (no surrounding quotes)
  # LC_ALL=C on purpose: under a non-UTF-8 locale (CI macOS runs bats with C)
  # bash's substring expansion counts BYTES, so a multibyte character would be
  # sliced into invalid UTF-8 and the JSON would not parse. Byte-wise iteration
  # passes any byte >= 0x80 through untouched — valid UTF-8 either way.
  local LC_ALL=C
  local s="${1:-}" out="" i=0 c ord
  while [ "${i}" -lt "${#s}" ]; do
    c="${s:${i}:1}"
    case "${c}" in
    '"') out="${out}\\\"" ;;
    '\') out="${out}\\\\" ;;
    $'\n') out="${out}\\n" ;;
    $'\r') out="${out}\\r" ;;
    $'\t') out="${out}\\t" ;;
    *)
      # Any OTHER control byte (ESC from brew/apt colour output, BEL, …) is
      # illegal raw inside a JSON string — live-caught: the macOS preflight
      # auto-install of docker injected ESC and the whole --json envelope
      # stopped parsing. Escape every control byte as \uXXXX (LC_ALL=C above
      # makes c exactly one byte, so the ordinal is the byte value).
      ord="$(printf '%d' "'${c}" 2>/dev/null)" || ord=""
      case "${ord}" in
      '' | *[!0-9]*) out="${out}${c}" ;;
      *)
        if [ "${ord}" -lt 32 ]; then
          out="${out}\u$(printf '%04x' "${ord}")"
        else
          out="${out}${c}"
        fi ;;
      esac ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s' "${out}"
}

json_str() { # $1 = raw text → "quoted JSON string"
  printf '"%s"' "$(json_escape "${1:-}")"
}

# Key: value pairs for scalars — json_kv name "string" / json_num name 3
json_kv_str() { printf '%s: %s' "$(json_str "${1:-}")" "$(json_str "${2:-}")"; }
json_kv_num() { printf '%s: %s' "$(json_str "${1:-}")" "${2:-0}"; }
json_kv_bool() {
  local b="false"
  case "${2:-}" in 1 | true | yes | ok) b="true" ;; esac
  printf '%s: %s' "$(json_str "${1:-}")" "${b}"
}
# Array of strings: json_arr name a b c  → "name": ["a","b"]
json_arr() { # $1 = key, rest = items
  local key="$1" first=1 item
  shift
  printf '%s: [' "$(json_str "${key}")"
  for item in "$@"; do
    [ "${first}" = "1" ] || printf ', '
    printf '%s' "$(json_str "${item}")"
    first=0
  done
  printf ']'
}
# ---------- content checksums (supply-chain) ----------
# Module scripts are code that runs as the user. The release publishes
# modules.SHA256SUMS (scripts/manifest.sh) covering every fetched file; the
# downloader verifies against it unless AIBOX_VERIFY=0.

# sha256 of a file — shasum (macOS) or sha256sum (Linux); empty when neither exists.
sha256_of() { # $1 = file → hex digest ("" when unavailable)
  local f="${1:-}"
  [ -n "${f}" ] && [ -f "${f}" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${f}" 2>/dev/null | awk '{print $1}'
  fi
}

# The digest recorded for one repo-relative path in a manifest ("" when absent).
manifest_digest() { # $1 = manifest file, $2 = repo-relative path
  local mf="${1:-}" p="${2:-}"
  [ -n "${mf}" ] && [ -f "${mf}" ] && [ -n "${p}" ] || return 0
  awk -v p="${p}" '$2 == p { print $1; exit }' "${mf}" 2>/dev/null
}

# Verify one downloaded file. 0 = ok/skipped, 1 = mismatch (caller decides).
verify_download() { # $1 = file, $2 = manifest ("" = skip), $3 = repo-relative path
  local f="${1:-}" mf="${2:-}" rel="${3:-}" want got
  [ "${AIBOX_VERIFY:-1}" = "0" ] && return 0
  [ -n "${mf}" ] && [ -f "${mf}" ] || return 0
  want="$(manifest_digest "${mf}" "${rel}")"
  [ -n "${want}" ] || return 0        # not covered (new file, branch ahead): nothing to check
  got="$(sha256_of "${f}")"
  [ -n "${got}" ] || return 0         # no sha tool on this host: nothing to check with
  [ "${want}" = "${got}" ] && return 0
  printf '%s' "sha256 mismatch for ${rel}: manifest ${want}, downloaded ${got}" >&2
  return 1
}
# ---------- profiles (name → deterministic ports, registered + conflict-checked) ----------
# A "profile" is a second instance of a module family (base, pi-web, …). Ports are
# DERIVED from the name so the same name means the same ports on every machine —
# but derived is not the same as free: two names can hash into the same slot, and a
# profile's port may already be taken by something else. So every profile is
# REGISTERED in $AIBOX_HOME/ports.conf and checked against live listeners before a
# stack starts. (Derivation used to be copied in base/pi-web/CLIs; one copy now.)

profile_hash() { # $1=profile name → deterministic hash (stable across machines)
  local name="${1:-}" sum=0 i=0 ch
  while [ "${i}" -lt "${#name}" ]; do
    ch="${name:${i}:1}"
    sum=$(( sum + $(printf '%d' "'${ch}") * (i + 1) ))
    i=$(( i + 1 ))
  done
  printf '%d' "${sum}"
}

# Port families: fixed ranges inside the aibox reserved band (spec §Port allocation —
# never Linux's ephemeral 32768-60999) keep a family's instances far apart, and the +hash
# offsets spread instances inside the range. The DEFAULT profile never uses these
# (it keeps the module's declared ports).
profile_port() { # $1=family (pg|redis|web) $2=hash → port
  local fam="${1:-}" h="${2:-0}"
  case "${fam}" in
  pg)    printf '%d' $(( 32100 + h % 332 )) ;;
  redis) printf '%d' $(( 32600 + h % 279 )) ;;
  web)   printf '%d' $(( 31150 + h % 100 )) ;;
  *) return 1 ;;
  esac
}

profile_ports_file() { printf '%s/ports.conf' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"; }

# Register a profile's derived ports (idempotent; plain KEY=VALUE data).
profile_register() { # $1=profile name
  local name="${1:-}" h pf line pg rd wb tmp
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  pg="$(profile_port pg "${h}")"
  rd="$(profile_port redis "${h}")"
  wb="$(profile_port web "${h}")"
  pf="$(profile_ports_file)"
  mkdir -p "$(dirname "${pf}")"
  line="${name} pg=${pg} redis=${rd} web=${wb}"
  tmp="$(mktemp)"
  [ -f "${pf}" ] && grep -v "^${name} " "${pf}" >"${tmp}" 2>/dev/null || true
  printf '%s\n' "${line}" >>"${tmp}"
  sort -o "${tmp}" "${tmp}"
  mv "${tmp}" "${pf}"
  chmod 600 "${pf}" 2>/dev/null || true
  return 0
}

profile_owner() { # $1=port → the profile that registered it ("" when none)
  local port="${1:-}" pf name pg rd wb
  pf="$(profile_ports_file)"
  [ -n "${port}" ] && [ -f "${pf}" ] || return 0
  while read -r name pg rd wb; do
    case "${pg}" in "pg=${port}") printf '%s' "${name}"; return 0 ;; esac
    case "${rd}" in "redis=${port}") printf '%s' "${name}"; return 0 ;; esac
    case "${wb}" in "web=${port}") printf '%s' "${name}"; return 0 ;; esac
  done <"${pf}"
  return 0
}

# Conflicts for a profile: a derived port is a conflict when it is LIVE and NOT
# registered to this profile.
#
#   registry says another profile → conflict, that profile is named
#   registry says this profile    → fine (idempotent re-start of a running stack)
#   registry says nothing         → conflict with an "unknown" holder: the port is
#                                   held by something we cannot attribute, and the
#                                   stack could not bind anyway. This is the case
#                                   that used to surface as docker's raw
#                                   "Bind for 127.0.0.1:35177 failed: port is
#                                   already allocated" (a real deployment on the
#                                   same host holding the slot).
#
# Ownership comes from the registry + the live listener probe ONLY. It used to ask
# `docker ps --filter publish=<port>`, which returned UNRELATED containers as the
# owner on two different machines (CI runner, dev host) — a wrong "owner" is worse
# than no owner.
# Prints "<holder> <port>" per conflict ("" = clean).
profile_conflicts() { # $1=profile name
  local name="${1:-}" h pg rd wb p other
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  pg="$(profile_port pg "${h}")"
  rd="$(profile_port redis "${h}")"
  wb="$(profile_port web "${h}")"
  for p in "${pg}" "${rd}" "${wb}"; do
    port_listening "${p}" || continue
    other="$(profile_owner "${p}")"
    [ "${other}" = "${name}" ] && continue
    printf '%s %s\n' "${other:-unknown}" "${p}"
  done
  return 0
}

# Ensure the profile exists (conf file + registration) and refuse to start into a
# LIVE port owned by another profile (exit 4 = precheck failed, spec §Exit codes).
profile_ensure() { # $1=profile name $2=conf path
  local name="${1:-}" conf="${2:-}" h conflicts
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  if [ ! -f "${conf}" ]; then
    mkdir -p "$(dirname "${conf}")"
    cat >"${conf}" <<CONF
# aibox profile: ${name}
# Auto-generated deterministically from the profile name.
# Same name → same values on every machine. Edit to override.
PROFILE_NAME=${name}
PROFILE_HASH=${h}
CONF
    log "Created profile '${name}' (hash=${h})"
    _PROFILE_JUST_CREATED=1
  fi
  # Check BEFORE registering: a squatted port must not look like "ours" just
  # because we are about to claim it. A re-start of an already-registered profile
  # still sees its own entry (owner == us) and stays clean.
  conflicts="$(profile_conflicts "${name}")"
  if [ -n "${conflicts}" ]; then
    warn "profile '${name}' cannot use its derived ports — they are already taken:"
    printf '%s\n' "${conflicts}" | while read -r other p; do
      if [ "${other}" = "unknown" ]; then
        warn "  ${p} is in use, but no aibox profile registered it (another service? pick another profile name)"
      else
        warn "  ${p} belongs to profile '${other}' (pick another profile name, or stop that stack)"
      fi
    done
    die_code 4 "profile '${name}' cannot start: port collision on $(printf '%s' "${conflicts}" | head -1 | cut -d' ' -f2) (holder: $(printf '%s' "${conflicts}" | head -1 | cut -d' ' -f1))"
  fi
  profile_register "${name}"
  return 0
}
# ---------- platform service units (one implementation of the shapes) ----------
# Two modules (pi-web, windmill) generate launchd plists and systemd units. The
# CONTENT differs per module (user-level UI vs system-level oneshot/timer), but
# the SHAPES — plist keys, systemd section order, the quoting of Environment= —
# are the same knowledge written twice, which is exactly what drifts. These
# renderers own the shapes; callers supply the content.

# launchd plist for a user agent.
#   $1=label $2=workdir $3=log dir $4=log name $5=throttle seconds
#   $6=run-at-load (0|1) $7=keep-alive (0|1) $8=program path, $9...=program args
#   env pairs come through the ENV_PAIRS variable ("K=V K=V"; values are quoted
#   for the plist — keep them shell-safe, the caller builds them from conf).
svc_render_launchd_plist() {
  local label="$1" workdir="$2" logdir="$3" logname="$4" throttle="$5"
  local run_at_load="$6" keep_alive="$7" program="$8"
  shift 8
  local arg pair k v
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>'
  printf '    <key>Label</key><string>%s</string>\n' "${label}"
  printf '%s\n' '    <key>ProgramArguments</key>' '    <array>'
  printf '        <string>%s</string>\n' "${program}"
  for arg in "$@"; do
    printf '        <string>%s</string>\n' "${arg}"
  done
  printf '%s\n' '    </array>'
  if [ -n "${ENV_PAIRS:-}" ]; then
    printf '%s\n' '    <key>EnvironmentVariables</key>' '    <dict>'
    for pair in ${ENV_PAIRS}; do
      k="${pair%%=*}"
      v="${pair#*=}"
      printf '        <key>%s</key><string>%s</string>\n' "${k}" "${v}"
    done
    printf '%s\n' '    </dict>'
  fi
  printf '    <key>WorkingDirectory</key><string>%s</string>\n' "${workdir}"
  [ "${run_at_load}" = "1" ] && printf '%s\n' '    <key>RunAtLoad</key><true/>'
  [ "${keep_alive}" = "1" ] && printf '%s\n' '    <key>KeepAlive</key><true/>'
  [ -n "${throttle}" ] && [ "${throttle}" != "0" ] &&
    printf '    <key>ThrottleInterval</key><integer>%s</integer>\n' "${throttle}"
  printf '    <key>StandardOutPath</key><string>%s/%s.log</string>\n' "${logdir}" "${logname}"
  printf '    <key>StandardErrorPath</key><string>%s/%s.err.log</string>\n' "${logdir}" "${logname}"
  printf '%s\n' '</dict>' '</plist>'
}

# systemd unit.
#   $1=scope (user|system) $2=description $3=exec line $4=workdir $5=log dir
#   $6=log name $7=type (simple|oneshot) $8=restart secs ("" = none)
#   $9=extra [Service] lines ("" = none; may contain newlines)
#   $10=extra [Unit] lines ("" = none) $11=install target ("" = scope default)
#   $12... argv to append to the exec line (one per argument)
#   env pairs come through the ENV_PAIRS variable ("K=V K=V").
svc_render_systemd_unit() {
  local scope="$1" desc="$2" exec_line="$3" workdir="$4" logdir="$5" logname="$6"
  local type="$7" restart="$8" extra_service="$9" extra_unit="${10}" install_target="${11}"
  shift 11 2>/dev/null || shift $#
  local arg pair k v target
  # the install target follows the SCOPE unless the caller overrides it
  if [ -n "${install_target}" ]; then
    target="${install_target}"
  elif [ "${scope}" = "user" ]; then
    target="default.target"
  else
    target="multi-user.target"
  fi
  printf '%s\n' '[Unit]'
  printf 'Description=%s\n' "${desc}"
  [ -n "${extra_unit}" ] && printf '%s\n' "${extra_unit}"
  printf '\n%s\n' '[Service]'
  printf 'Type=%s\n' "${type}"
  if [ "${scope}" = "system" ]; then printf '%s\n' 'User=root'; fi
  if [ -n "${ENV_PAIRS:-}" ]; then
    for pair in ${ENV_PAIRS}; do
      k="${pair%%=*}"
      v="${pair#*=}"
      printf 'Environment="%s=%s"\n' "${k}" "${v}"
    done
  fi
  printf 'ExecStart=%s' "${exec_line}"
  for arg in "$@"; do
    printf ' %s' "${arg}"
  done
  printf '\n'
  [ -n "${workdir}" ] && printf 'WorkingDirectory=%s\n' "${workdir}"
  if [ -n "${restart}" ]; then
    printf 'Restart=always\nRestartSec=%s\n' "${restart}"
  fi
  if [ -n "${logdir}" ]; then
    printf 'StandardOutput=append:%s/%s.log\n' "${logdir}" "${logname}"
    printf 'StandardError=append:%s/%s.err.log\n' "${logdir}" "${logname}"
  fi
  [ -n "${extra_service}" ] && printf '%s\n' "${extra_service}"
  printf '\n%s\n' '[Install]'
  printf 'WantedBy=%s\n' "${target}"
}
# ---------- safe reclamation (the `aibox autoclean` engine) ----------
# What may be reclaimed automatically is defined by TWO proofs:
#   1. OWNERSHIP — aibox can prove the object is ours (a module's residue
#      declaration now, or the residue.conf captured at install time);
#   2. NON-REFERENCE — nothing needs it: no container (running OR stopped)
#      references it, no module pins it, no upgrade/rollback point needs it.
# Anything failing either proof is left alone (foreign volumes, data of an
# installed module, images required for a rollback). These helpers only LIST
# what passed both proofs; the apply helpers receive that list verbatim.

# docker system df summary line ("" when the daemon is unreachable)
reclaim_df_summary() {
  command -v docker >/dev/null 2>&1 || return 0
  docker system df --format '{{.Type}}={{.Size}}' 2>/dev/null | tr '\n' ' '
  return 0
}

# bytes → human (1.2G)
reclaim_human_size() { # $1=bytes
  local b="${1:-0}"
  case "${b}" in '' | *[!0-9]*) printf '?'; return 0 ;; esac
  if [ "${b}" -ge 1073741824 ]; then
    awk -v b="${b}" 'BEGIN{printf "%.1fG", b/1073741824}'
  elif [ "${b}" -ge 1048576 ]; then
    awk -v b="${b}" 'BEGIN{printf "%.0fM", b/1048576}'
  elif [ "${b}" -ge 1024 ]; then
    awk -v b="${b}" 'BEGIN{printf "%.0fK", b/1024}'
  else
    printf '%sB' "${b}"
  fi
}

# image IDs that carry a tag (used to keep the NEWEST tags per repo)
_reclaim_tagged_ids() {
  docker image ls --format '{{.ID}}' 2>/dev/null | sort -u || true
}

# dangling (untagged, unreferenced) images → "<id> <size>"
reclaim_dangling_images() {
  command -v docker >/dev/null 2>&1 || return 0
  local id size
  for id in $(docker image ls --filter dangling=true -q 2>/dev/null | sort -u); do
    size="$(docker image inspect --format '{{.Size}}' "${id}" 2>/dev/null | head -1)"
    printf '%s %s\n' "${id}" "$(reclaim_human_size "${size}")"
  done
  return 0
}

# Build cache: nothing references it and no data lives there.
reclaim_build_cache() {
  command -v docker >/dev/null 2>&1 || return 0
  local n
  n="$(docker builder du 2>/dev/null | tail -1 | awk '{print $NF}')"
  [ -n "${n}" ] && printf '%s\n' "${n}"
  return 0
}
reclaim_apply_build_cache() {
  docker builder prune -f --filter until=24h >/dev/null 2>&1 || true
  return 0
}

# Image tags nothing needs: not used by any container (running or stopped), not a
# module's pin (.env/conf), not an upgrade/rollback point (upgrades/*.state,
# .env.bak.*). The newest <keep> tags per repository stay as a buffer.
reclaim_stale_tags() { # $1=keep per repo (default 2)
  command -v docker >/dev/null 2>&1 || return 0
  local keep="${1:-2}"
  local protected ref repo tag size
  protected=""
  # live/stopped containers
  protected="${protected} $(docker ps -a --format '{{.Image}}' 2>/dev/null | tr '\n' ' ')"
  # module pins + rollback knowledge
  local f pf
  for f in "$AIBOX_HOME"/apps/*/.env; do
    [ -f "${f}" ] || continue
    protected="${protected} $(grep -hE '^[A-Z_]*IMAGE=|^[A-Z_]*_IMAGE=|^[A-Z_]*_TAG=' "${f}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr '\n' ' ')"
  done
  if [ -d "${AIBOX_HOME}/upgrades" ]; then
    for f in "$AIBOX_HOME"/upgrades/*.state; do
      [ -f "${f}" ] || continue
      protected="${protected} $(grep -hE '^(from|to|live)=' "${f}" 2>/dev/null | cut -d= -f2- | tr '\n' ' ')"
    done
  fi
  for f in "$AIBOX_HOME"/apps/*/.env.bak.*; do
    [ -f "${f}" ] || continue
    protected="${protected} $(grep -hE '_IMAGE=|_TAG=' "${f}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr '\n' ' ')"
  done
  # newest `keep` tags per repo
  local keepers
  keepers="$(docker image ls --format '{{.Repository}}:{{.Tag}} {{.CreatedAt}}' 2>/dev/null |
    grep -v '<none>' | sort -k1,1 -k2,2r | awk -v k="${keep}" '{ if (!(seen[$1]++ < k)) next; print $1 }' || true)"
  # space-separated: the membership test below is a " ref " substring match, and a
  # newline between entries would make the trailing space never match (same family
  # as the profile-conflict bug: a separator mismatch makes a check a no-op)
  keepers="$(printf '%s' "${keepers}" | tr '\n' ' ')"
  while IFS= read -r ref; do
    [ -n "${ref}" ] || continue
    repo="${ref%%:*}"
    tag="${ref#*:}"
    case "${ref}" in *'<none>'*) continue ;; esac
    case " ${protected} " in *" ${ref} "*) continue ;; *" ${tag} "*) continue ;; esac
    # the newest `keep` per repo are the buffer — never listed
    case " ${keepers} " in *" ${ref} "*) continue ;; esac
    size="$(docker image inspect --format '{{.Size}}' "${ref}" 2>/dev/null | head -1)"
    printf '%s %s\n' "${ref}" "$(reclaim_human_size "${size}")"
  done <<TAGS
$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | sort -u)
TAGS
  return 0
}

# Volumes that are provably aibox's AND nobody's: attributable to a module whose
# residue we know (declaration or residue.conf), zero container references, and
# the owning module is NOT installed any more. A stopped-but-installed module's
# volumes are DATA and stay.
reclaim_orphan_volumes() {
  command -v docker >/dev/null 2>&1 || return 0
  local v owner size
  for v in $(docker volume ls -q 2>/dev/null | sort -u); do
    [ -n "${v}" ] || continue
    # referenced by any container (running or stopped)? → keep
    [ -n "$(docker ps -aq --filter "volume=${v}" 2>/dev/null)" ] && continue
    # attributable to an aibox module?
    owner=""
    local m
    for m in $(_reclaim_known_modules); do
      local vpat
      vpat="$(residue_volume_patterns "${m}")"
      [ -n "${vpat}" ] || continue
      if printf '%s' "${v}" | grep -qE "${vpat}"; then owner="${m}"; break; fi
    done
    [ -n "${owner}" ] || continue           # not ours → never touch
    # still installed → its data, keep
    local moddir="${AIBOX_MOD_DIR:-${AIBOX_HOME}/modules}"
    local instf="${AIBOX_INSTALLED:-${AIBOX_HOME}/installed.sh}"
    if [ -f "${moddir}/${owner}/module.yaml" ] ||
      { [ -f "${instf}" ] && grep -q "^AIBOX_INSTALLED_$(printf '%s' "${owner}" | tr '-' '_')" "${instf}" 2>/dev/null; }; then
      continue
    fi
    size="$(docker volume inspect --format '{{.Mountpoint}}' "${v}" 2>/dev/null | head -1)"
    printf '%s %s %s\n' "${v}" "$(reclaim_dir_bytes "${size}")" "${owner}"
  done
  return 0
}

_reclaim_known_modules() {
  { local moddir="${AIBOX_MOD_DIR:-${AIBOX_HOME}/modules}"
    for d in "${moddir}"/*/; do [ -f "${d}module.yaml" ] && basename "${d}"; done
    if [ -f "${AIBOX_HOME}/residue.conf" ]; then
      awk -F'_residue_' '/^[a-z0-9][a-z0-9-]*_residue_/ { print $1 }' "$AIBOX_HOME/residue.conf"
    fi
  } 2>/dev/null | grep -E '^[a-z0-9][a-z0-9-]*$' | sort -u
}

reclaim_dir_bytes() { # $1=path → human size of that subtree ("" → ?)
  local p="${1:-}"
  [ -n "${p}" ] && [ -d "${p}" ] || { printf '?'; return 0; }
  if command -v du >/dev/null 2>&1; then
    du -sk "${p}" 2>/dev/null | awk '{printf "%.0fM", $1/1024}'
  else
    printf '?'
  fi
}

# Stale .env backups (plain copies — never the live .env). Keeps the newest N per
# deploy root, which is exactly what the rollback machinery may still want.
reclaim_stale_env_backups() { # $1=keep (default 2)
  local keep="${1:-2}" root f
  for root in "$AIBOX_HOME"/apps/*/; do
    [ -d "${root}" ] || continue
    ls -1t "${root}".env.bak.* 2>/dev/null | tail -n "+$((keep + 1))" | while IFS= read -r f; do
      [ -f "${f}" ] || continue
      printf '%s %s\n' "${f}" "$(reclaim_human_size "$(wc -c <"${f}" 2>/dev/null | tr -d ' ')")"
    done
  done
  return 0
}

# ---- apply helpers (only ever called with a list that passed the proofs) ----
reclaim_apply_images() { # args: image refs/ids
  local r
  for r in "$@"; do
    [ -n "${r}" ] || continue
    docker image rm "${r}" >/dev/null 2>&1 || true
  done
  return 0
}
reclaim_apply_volumes() { # args: volume names
  local v
  for v in "$@"; do
    [ -n "${v}" ] || continue
    docker volume rm "${v}" >/dev/null 2>&1 || true
  done
  return 0
}
reclaim_apply_paths() { # args: file paths
  local p
  for p in "$@"; do
    [ -n "${p}" ] || continue
    rm -f "${p}" 2>/dev/null || true
  done
  return 0
}

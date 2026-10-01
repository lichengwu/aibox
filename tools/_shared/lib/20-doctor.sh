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
      # docker-compose: the preflight's dep_satisfied accepts the compose v2
      # PLUGIN (`docker compose version`) as satisfying the dep — the doctor
      # used a bare `command -v`, so every plugin-only host (docker-compose-v2
      # without the standalone symlink — the aibox test image, most minimal
      # installs) got a FALSE "dependency missing" + exit 3 from a healthy
      # module (live-caught on the jumpserver smoke). One implementation of
      # the rule, mirrored from src/aibox/40-preflight.sh dep_satisfied.
      if command -v "${dcmd}" >/dev/null 2>&1 \
        || { [ "${dcmd}" = "docker-compose" ] && docker compose version >/dev/null 2>&1; }; then
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
  # The module may know its EFFECTIVE ports (an operator can override them in the
  # deploy .env — gitlab does: 80/443 instead of the declared 31110/31143). Probing
  # the declared defaults then reports "not listening" for a service that is
  # actually public: the module's own answer wins when it provides one.
  local ports="" entry declared=1
  if type doctor_ports >/dev/null 2>&1; then
    ports="$(doctor_ports 2>/dev/null || true)"
    [ -n "${ports}" ] && declared=0
  fi
  [ -n "${ports}" ] || ports="$(awk '/^ports:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); printf "%s ", $0}' "${yaml}" 2>/dev/null || true)"
  for entry in ${ports}; do
    local pnum="${entry%%/*}"
    case "${pnum}" in ''|*[!0-9]*) continue ;; esac
    if port_listening "${pnum}"; then ok "port        ${entry} listening"
    local _phint; _phint="$(port_policy_hint "${pnum}")"
    # The policy governs module DEFAULTS; an operator's deliberate deployment port
    # (privileged 80/443 for a public service) is reported, not policed.
    [ -n "${_phint}" ] && [ "${declared}" = 1 ] && warn "port        ${pnum} is ${_phint} (spec §Port allocation: 31000-31999 services / 32000-32999 infra)"
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


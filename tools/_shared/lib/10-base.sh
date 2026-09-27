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
# twin of the manager's ensure_services. Live-caught: `aibox xiaozhi start`
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

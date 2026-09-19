# new-api module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/new-api.

MODULE_NAME="new-api"
COMPOSE_PROJECT="new-api"
CONTAINER="aibox-new-api"
DEFAULT_PORT="30300"
DEFAULT_IMAGE="calciumion/new-api:v0.13.2"

# Output helpers: symbols align with the manager's output system (bin/aibox):
# log = plain action line; warn/ok/die = symbol prefix (⚠/✓/✗, two-space gap);
# colors are inherited from aibox via exported C_* env vars (single source of
# truth); ${C_*:-} falls back to plain output when this lib is sourced standalone.
log()  { printf '%s\n' "$*"; }
warn() { printf '%s⚠%s  %s\n' "${C_YEL:-}" "${C_RST:-}" "$*" >&2; }
ok()   { printf '%s✓%s  %s\n' "${C_GRN:-}" "${C_RST:-}" "$*"; }
info() { printf '%s  %s%s\n' "${C_DIM:-}" "$*" "${C_RST:-}"; }
die()  { printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2; exit 1; }

# Deploy root per the aibox convention ($AIBOX_HOME/apps/<name>; module-spec
# §Deploy directory). The guard is mandatory: systemd service contexts may
# lack HOME, and path derivation must fail loudly rather than produce "/apps/...".
deploy_root() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "$root" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  printf '%s' "$root/apps/$MODULE_NAME"
}

# Load the deploy .env into the environment so hooks/svc see NEW_API_PORT /
# NEW_API_IMAGE / SESSION_SECRET, etc.
# NOTE: parse with docker env_file semantics (split at the FIRST '=', the whole
# rest of line is the value) — NOT bash sourcing. Values may contain spaces,
# glob chars, braces; `source`ing those breaks bash.
load_env() {
  local envf line k
  envf="$(deploy_root)/.env"
  [ -f "${envf}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    k="${line%%=*}"
    case "${k}" in
      '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    export "${k}=${line#*=}"
  done < "${envf}"
}

# compose wrapper: always runs in the deploy root. This module REQUIRES the
# shared base (module.yaml services: base:postgres + base:redis): the PG/Redis
# connection vars are injected from base.env via --env-file (the base module's
# single source of truth, written by `aibox base start`). The deploy .env is
# loaded into the SHELL environment by load_env() — compose interpolation
# precedence: shell env > --env-file, so user overrides win.
compose() {
  local root base_env args
  root="$(deploy_root)"
  [ -f "${root}/docker-compose.yml" ] || die "not installed (run: aibox install ${MODULE_NAME})"
  base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
  args=(--project-name "${COMPOSE_PROJECT}" -f "${root}/docker-compose.yml")
  if [ -f "${base_env}" ]; then
    args+=(--env-file "${base_env}")
  else
    # Not fatal at parse time (uninstall during teardown), but every real
    # lifecycle command needs the base — say so.
    warn "base.env missing (${base_env}) — run: aibox base start"
  fi
  (cd "${root}" && docker compose "${args[@]}" "$@")
}

# Image list from the compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
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
# Knobs: AIBOX_DOCKER_POOL (mirror list override; "direct" = disabled),
# AIBOX_DOCKER_MIRROR (user mirror, first), AIBOX_DOCKER_FORCE_POOL=1
# (skip the direct probe — always engage), AIBOX_DOCKER_PROBE_TIMEOUT (15),
# AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT (30), AIBOX_DOCKER_PULL_TIMEOUT (1800).
# Live-verified mirrors (Aliyun deploy host, real pulls): docker.1ms.run,
# docker.m.daocloud.io, dockerproxy.net, hub.rat.dev; docker.xuanyuan.me /
# dockerpull.org dead — excluded.
DOCKER_POOL_MIRRORS="docker.1ms.run docker.m.daocloud.io dockerproxy.net hub.rat.dev"

# Is this image ref served by docker.io? A ref WITH a slash has a
# host-or-namespace first segment — dots/colons there mean a foreign registry
# (ghcr.io/…, localhost:5000/…). A ref WITHOUT a slash is name[:tag] on the
# DEFAULT registry (postgres:15-alpine) — its colon is the TAG separator,
# not a port (tag-stripping first would misread localhost:5000/foo's port).
_dk_is_dockerio() {
  case "${1}" in
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
  case "${2}" in
  */*) printf '%s/%s' "${1}" "${2}" ;;
  *) printf '%s/library/%s' "${1}" "${2}" ;;
  esac
}

# Bounded docker command with a wall-clock watchdog (docker pull has no
# timeout of its own; a hung registry would hang the install forever).
# Returns docker's rc, or 124 on timeout. AIBOX_DOCKER_POLL (default 5s) is the
# watchdog's poll interval (tests tighten it); the deadline is date-based so
# the interval never distorts the timeout budget.
_dk_bounded() { # $1=timeout_s, rest = docker args
  local t="${1}"; shift
  local logf pid deadline rc
  logf="$(mktemp "${TMPDIR:-/tmp}/dkpool.XXXXXX")" || return 1
  docker "$@" >"${logf}" 2>&1 &
  pid=$!
  deadline=$(( $(date +%s) + t ))
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
        printf '%s\t%s\n' "$(( $(date +%s) - t0 ))" "${m}" >"${tmpd}/r${i}.res"
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
        docker tag "${full}" "${img}" || { warn "docker tag failed: ${full} → ${img}"; continue; }
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

# The app is up when /api/status answers success (upstream's own healthcheck
# contract — the same endpoint the container-internal wget probe uses; we curl
# it from the host through the published port).
api_up() {
  local port body
  port="${1:-$(effective_port)}"
  body="$(curl -s --max-time 5 "http://127.0.0.1:${port}/api/status" 2>/dev/null || true)"
  printf '%s' "${body}" | grep -q '"success":\s*true'
}

# Is the container running? (docker ps + fixed container name — same pattern as
# the gitlab module; the name is hardcoded in the compose, not env-tunable.)
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

# Effective host port (deploy .env overrides the module default).
effective_port() {
  printf '%s' "${NEW_API_PORT:-${DEFAULT_PORT}}"
}

# Dashboard interface (called by `aibox dashboard new-api`).
dashboard_info() {
  local port url ver
  load_env
  port="$(effective_port)"
  url="http://127.0.0.1:${port}"
  ver="${NEW_API_IMAGE:-${DEFAULT_IMAGE}}"
  echo "version=${ver##*:}"
  echo "endpoint=${url}"
  echo "credential=first login: root / 123456 (change it immediately)"
  echo "db=shared base (PG database new_api + Redis via base.env)"
  if container_running 2>/dev/null; then
    if api_up "${port}"; then
      echo "health=ok (api answers on :${port})"
    else
      echo "health=starting (container up, api not ready yet)"
    fi
  else
    echo "health=stopped"
  fi
}

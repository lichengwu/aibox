# dify module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/dify.

MODULE_NAME="dify"
COMPOSE_PROJECT="dify"
CONTAINER_NGINX="dify-nginx-1"
DEFAULT_PORT="8088"
DEFAULT_NGINX_INTERNAL_PORT="80"
DEFAULT_API_IMAGE="langgenius/dify-api:1.17.1"
DEFAULT_WEB_IMAGE="langgenius/dify-web:1.17.1"
DEFAULT_SANDBOX_IMAGE="langgenius/dify-sandbox:0.2.15"
DEFAULT_PLUGIN_DAEMON_IMAGE="langgenius/dify-plugin-daemon:0.6.10-local"
DEFAULT_AGENT_BACKEND_IMAGE="langgenius/dify-agent-backend:1.17.1"
DEFAULT_DB_IMAGE="postgres:15-alpine"
DEFAULT_REDIS_IMAGE="redis:6-alpine"
DEFAULT_WEAVIATE_IMAGE="cr.weaviate.io/semitechnologies/weaviate:1.39.2"

# Output helpers: colors are inherited from aibox via exported C_* env vars
# (single source of truth); ${C_*:-} falls back to plain output standalone.
log()  { printf '%s\n' "$*"; }
warn() { printf '%s⚠%s  %s\n' "${C_YEL:-}" "${C_RST:-}" "$*" >&2; }
ok()   { printf '%s✓%s  %s\n' "${C_GRN:-}" "${C_RST:-}" "$*"; }
die() {
  printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2
  exit 1
}

# Deploy root per the aibox convention ($AIBOX_HOME/apps/<name>; module-spec
# §Deploy directory). The guard is mandatory: systemd service contexts may
# lack HOME, and path derivation must fail loudly rather than produce "/apps/...".
deploy_root() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "${root}" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  printf '%s' "${root}/apps/${MODULE_NAME}"
}

# Load the deploy .env into the environment so hooks/svc see DIFY_WEB_PORT /
# DIFY_SHARED_BASE / image tags, etc.
# NOTE: parse with docker env_file semantics (split at the FIRST '=', the whole
# rest of line is the value) — NOT bash sourcing. Values may contain spaces
# (upstream ports LOG_DATEFORMAT="%Y-%m-%d %H:%M:%S"), glob chars, braces;
# `source`ing those breaks bash (measured live: "fg: no job control").
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

# Whether shared-base mode is enabled (DIFY_SHARED_BASE=1 in the deploy .env).
# When on, compose is invoked with the shared override + base.env.
shared_base_enabled() {
  [ "${DIFY_SHARED_BASE:-0}" = "1" ]
}

# compose wrapper: always runs in the deploy root. In shared-base mode it adds
# the shared override file + --env-file base.env (the base module's connection
# info; injected values like AIBOX_POSTGRES_HOST are referenced by the override).
compose() {
  local root base_env args
  root="$(deploy_root)"
  [ -f "${root}/docker-compose.yml" ] || die "not installed (run: aibox install ${MODULE_NAME})"
  args=(--project-name "${COMPOSE_PROJECT}" -f "${root}/docker-compose.yml")
  if shared_base_enabled; then
    [ -f "${root}/docker-compose.shared.yml" ] || die "DIFY_SHARED_BASE=1 but docker-compose.shared.yml missing"
    args+=(-f "${root}/docker-compose.shared.yml")
    base_env="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}/base.env"
    if [ -f "${base_env}" ]; then
      args+=(--env-file "${base_env}")
    else
      warn "DIFY_SHARED_BASE=1 but ${base_env} not found (run: aibox base start)"
    fi
  fi
  (cd "${root}" && docker compose "${args[@]}" "$@")
}

# Image list from the (mode-aware) compose definition — what `up` would pull.
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
  docker.io/*) return 0 ;;   # explicit default-registry form is still docker.io
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
  local t="${1}"; shift
  local logf pid deadline
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

# The stack is up when the API answers THROUGH nginx (GET /console/api/setup →
# 2xx/3xx). Probing `/` (the web frontend) is NOT enough — the frontend answers
# immediately while the api (migrations + gunicorn) lags 30-60s behind; the
# upgrade gate specifically must prove the NEW api serves (measured live: two
# upgrades passed the `/` gate while /console/api was still 502).
http_up() {
  local port code
  port="${1:-${DIFY_WEB_PORT:-${DEFAULT_PORT}}}"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/console/api/setup" 2>/dev/null || true)"
  [ -z "${code}" ] && code="000"
  case "${code}" in
  2?? | 3??) return 0 ;;
  *) return 1 ;;
  esac
}

# Any dify container running? (compose ps is the source of truth — there is no
# single "the" container like gitlab's one-shot omnibus.)
containers_running() {
  local n
  n="$(compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -c . || true)"
  [ "${n}" -gt 0 ]
}

# Effective web port (deploy .env overrides the module default). NOTE: the knob is
# DIFY_WEB_PORT — upstream's DIFY_PORT means the api's gunicorn port (5001).
effective_port() {
  printf '%s' "${DIFY_WEB_PORT:-${DEFAULT_PORT}}"
}

# Dashboard interface (called by `aibox dashboard`).
dashboard_info() {
  local port url ver
  load_env
  port="$(effective_port)"
  url="http://127.0.0.1:${port}"
  ver="${DIFY_API_IMAGE:-${DEFAULT_API_IMAGE}}"
  echo "version=${ver##*:}"
  echo "endpoint=${url}"
  echo "credential=first visit sets the admin password (INIT_PASSWORD; see: aibox ${MODULE_NAME} credentials)"
  if shared_base_enabled; then
    echo "db=shared base (postgres18/redis7 via base.env)"
  else
    echo "db=bundled postgres:15-alpine / redis:6-alpine"
  fi
  if containers_running 2>/dev/null; then
    if http_up "${port}"; then
      echo "health=ok (HTTP up on :${port})"
    else
      echo "health=starting (containers up, web not answering yet; first boot 1-2 min)"
    fi
  else
    echo "health=stopped"
  fi
}

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  load_env
  local port n=""
  port="$(effective_port)"
  printf '%s%sdify%s %s· module %s%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${MODULE_VERSION:-1.17.2}" "${C_RST:-}"
  n="$(docker ps --filter "name=dify-" --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
  if [ "${n}" -gt 0 ]; then
    printf '  %s%-9s %s containers · %s\n' "${C_DIM:-}" "stack:" "${n}" "$(docker ps --filter 'name=dify-' --filter 'status=running' --format '{{.Names}}' 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')…"
  else
    printf '  %s%-9s %snot running (aibox dify start)%s\n' "${C_DIM:-}" "stack:" "${C_YEL:-}" "${C_RST:-}"
  fi
  if http_up "${port}"; then
    printf '  %s%-9s http://127.0.0.1:%s · %s✓ HTTP up%s\n' "${C_DIM:-}" "console:" "${port}" "${C_GRN:-}" "${C_RST:-}"
  elif [ "${n}" -gt 0 ]; then
    printf '  %s%-9s http://127.0.0.1:%s · %sstarting (1-2 min)%s\n' "${C_DIM:-}" "console:" "${port}" "${C_YEL:-}" "${C_RST:-}"
  fi
  if shared_base_enabled; then
    printf '  %s%-9s shared base (PG + redis via base.env)\n' "${C_DIM:-}" "db:"
  else
    printf '  %s%-9s bundled postgres/redis\n' "${C_DIM:-}" "db:"
  fi
  printf '  %s%-9s first-visit INIT_PASSWORD (see: aibox dify credentials)\n' "${C_DIM:-}" "auth:"
}

# gitlab module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/gitlab.

MODULE_NAME="gitlab"
CONTAINER_NAME="aibox-gitlab"
DEFAULT_HTTP_PORT="8929"
DEFAULT_SSH_PORT="8922"
DEFAULT_IMAGE="gitlab/gitlab-ce:19.2.6-ce.0"

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
  [ -n "$root" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  printf '%s' "$root/apps/$MODULE_NAME"
}

# Load the deploy .env (KEY=VALUE, written by the install hook) into the
# environment so hooks/svc see GITLAB_HTTP_PORT / GITLAB_IMAGE / etc.
load_env() {
  local envf
  envf="$(deploy_root)/.env"
  [ -f "$envf" ] || return 0
  # shellcheck disable=SC1090
  set -a
  . "$envf"
  set +a
}

# Best-effort LAN IP for external_url (clone URLs embed it); overridable via
# GITLAB_EXTERNAL_URL at install time. Falls back to localhost.
detect_external_host() {
  local ip=""
  case "$(uname -s)" in
  Linux) ip="$(hostname -I 2>/dev/null | awk '{print $1}')" ;;
  Darwin) ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)" ;;
  esac
  [ -n "$ip" ] || ip="localhost"
  printf '%s' "$ip"
}

# compose wrapper: always runs in the deploy root (project name = "gitlab",
# so named volumes become gitlab_gitlab_{config,logs,data}).
compose() {
  local root
  root="$(deploy_root)"
  [ -f "$root/docker-compose.yml" ] || die "not installed (run: aibox install gitlab)"
  (cd "$root" && docker compose "$@")
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


# GitLab answers 200 on the sign-in page once rails+puma are up (302 on /).
http_up() {
  local port code
  port="${1:-$DEFAULT_HTTP_PORT}"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/users/sign_in" 2>/dev/null || true)"
  case "$code" in
  200 | 302) return 0 ;;
  *) return 1 ;;
  esac
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

# Effective image: the deploy .env overrides the module default.
effective_image() {
  printf '%s' "${GITLAB_IMAGE:-$DEFAULT_IMAGE}"
}

# SSH clone base URL (host part best-effort; the authoritative value is the
# clone button in the GitLab UI — external_url controls what GitLab renders).
ssh_clone_url() {
  local host port
  host="$(detect_external_host)"
  port="${GITLAB_SSH_PORT:-$DEFAULT_SSH_PORT}"
  printf 'ssh://git@%s:%s' "$host" "$port"
}

# Dashboard interface (called by `aibox dashboard`; see docs/module-spec.md).
dashboard_info() {
  local port url health
  load_env
  port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  url="http://127.0.0.1:${port}"
  echo "endpoint=${url}"
  echo "credential=root / initial password via: aibox gitlab credentials"
  if container_running; then
    health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
    if http_up "$port"; then
      echo "health=ok HTTP 200 (${health})"
    else
      echo "health=starting (${health}; first boot takes 3-5 min)"
    fi
  else
    echo "health=stopped"
  fi
}

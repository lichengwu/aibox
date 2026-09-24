# gitlab module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/gitlab.

MODULE_NAME="gitlab"
# Module version — read from module.yaml next to this lib (cache and repo
# layouts agree; empty on a missing file → callers fall back to dim ?).
MODULE_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$(dirname "${BASH_SOURCE[0]}")/module.yaml" 2>/dev/null | head -1 || true)"
CONTAINER_NAME="aibox-gitlab"
DEFAULT_HTTP_PORT="8929"
DEFAULT_SSH_PORT="8922"
DEFAULT_IMAGE="gitlab/gitlab-ce:19.2.6-ce.0"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"

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

# Deterministic root password (replaces the fragile initial_root_password file
# mechanism — live-caught on a deploy host: the file's password is REGENERATED
# by every reconfigure while the DB keeps the first-seed one, so the file
# becomes a lie; official docker docs: the file is best-effort only).
# Model: install seeds GITLAB_ROOT_PASSWORD into the deploy .env; the compose
# passes it to the container where ENV wins over random generation (omnibus
# source: initial_root_password = ENV['GITLAB_ROOT_PASSWORD'] || random).
# It APPLIES at first boot with fresh volumes; volumes seeded earlier ignore
# it — `credentials` verifies against the live account and says so.
ensure_root_password() { # seeds GITLAB_ROOT_PASSWORD into the .env when missing OR empty (never rotates a real value)
  local envf pw cur tmp
  envf="$(deploy_root)/.env"
  [ -f "${envf}" ] || return 0
  cur="$(sed -n 's/^GITLAB_ROOT_PASSWORD=//p' "${envf}" | head -1)"
  [ -n "${cur}" ] && return 0
  # missing OR EMPTY: an empty value would seed a BLANK root password (Ruby
  # treats "" as truthy in ENV['GITLAB_ROOT_PASSWORD'] || random — the env
  # still wins, with nothing in it). Strip the blank line, then (re)seed so
  # exactly ONE key line remains.
  if grep -q '^GITLAB_ROOT_PASSWORD=$' "${envf}" 2>/dev/null; then
    tmp="$(mktemp "${envf}.tmp.XXXXXX")" || return 0
    grep -v '^GITLAB_ROOT_PASSWORD=$' "${envf}" >"${tmp}" 2>/dev/null || true
    cat "${tmp}" >"${envf}"   # write into the original inode: the 600 mode survives
    rm -f "${tmp}"
  fi
  pw="$(openssl rand -hex 16 2>/dev/null || true)"
  if [ -z "${pw}" ]; then
    pw="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [ -n "${pw}" ] || return 0
  chmod 600 "${envf}"
  printf '\n# seeded by aibox gitlab — applies at first boot with fresh volumes\nGITLAB_ROOT_PASSWORD=%s\n' "${pw}" >>"${envf}"
}

# Verify a password against the LIVE root account (the truth — never trust
# a file). Prints "true" / "false" / "" (probe failed: container down or
# rails busy — NOT a verdict). Passwords with single quotes would break the
# runner string; hex seeds and sane user values are safe, and a broken probe
# just degrades to "unverified".
root_password_verify() { # $1=password
  local out
  out="$(docker exec "$CONTAINER_NAME" gitlab-rails runner "puts User.find_by(username: 'root').valid_password?('${1}')" 2>/dev/null || true)"
  case "${out}" in
  *true*) printf 'true' ;;
  *false*) printf 'false' ;;
  *) printf '' ;;
  esac
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
  require_docker
  (cd "$root" && docker compose "$@")
}

# Image list from the (mode-aware) compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}

# GitLab answers 200 on the sign-in page once rails+puma are up (302 on /).
http_up() {
  local port code
  port="${1:-$DEFAULT_HTTP_PORT}"
  # --noproxy: this probes 127.0.0.1 — an inherited http_proxy env (manual
  # exports; aibox's own proxy flow already sets no_proxy) would route the
  # loopback probe through the proxy and return 000 (measured live).
  code="$(curl -s --noproxy '*' -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/users/sign_in" 2>/dev/null || true)"
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

# Deployed app version: the gitlab-ce image tag.
app_version() {
  local img tag
  load_env
  img="${GITLAB_IMAGE:-$DEFAULT_IMAGE}"
  tag="${img##*:}"
  printf '%s' "${tag#v}"
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
  echo "version=$(app_version)"
  echo "endpoint=${url}"
  echo "credential=root / password: aibox gitlab credentials (verified live)"
  if container_running; then
    health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
    if http_up "$port"; then
      echo "state=ok"
      echo "health=ok HTTP 200 (${health})"
    else
      echo "state=starting"
      echo "health=starting (${health}; first boot takes 3-5 min)"
    fi
  else
    echo "state=stopped"
    echo "health=stopped"
  fi
}

# ---------- dashboard (the module's rich view — keyline template) ----------
render_dashboard() {
  load_env
  local port st state code
  port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  st="$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1 || true)"
  if [ -n "${st}" ]; then
    if http_up "${port}"; then
      state="ok"
    else
      state="starting"
    fi
  else
    state="stopped"
  fi
  dash_header "gitlab" "$(app_version)" "${state}"
  if [ -n "${st}" ]; then
    dash_row "container" "${st}"
    code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    [ -z "${code}" ] && code="000"
    case "${code}" in
    2?? | 3?? | 401) dash_row "web" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓ HTTP ${code}${C_RST:-}" ;;
    *) dash_row "web" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_YEL:-}HTTP ${code}${C_RST:-}" ;;
    esac
    dash_row "ssh" ":${GITLAB_SSH_PORT:-8922} (git over SSH)"
  else
    dash_row "container" "${C_YEL:-}not running (aibox gitlab start)${C_RST:-}"
  fi
  dash_row "auth" "root / password (see: aibox gitlab credentials, verified live)"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/gitlab/"
}

# ---------- GitLab upgrade path (required upgrade stops) ----------
# Official rule (docs.gitlab.com/update/upgrade_paths): cross-version upgrades
# must pass through every required upgrade stop between current and target;
# each hop lands on the LATEST PATCH of that minor; background migrations must
# finish before the next hop. Data source decision: the pre-17.5 stops are a
# FROZEN historical table (verified line-by-line against gitlab-org/gitlab
# config/upgrade_path.yml); from 18.0 the official cadence is fixed (x.2/x.5/
# x.8/x.11) so future stops are DERIVED — no table chasing, no network needed
# for path computation.
#
# Contract: the manager's upgrade engine sources this lib and calls
# upgrade_stops() when present → multi-hop upgrades engage. Modules without
# this function keep the single-hop behavior (module-spec §Component upgrades).
upgrade_stops() { # $1=cur_major.minor $2=tgt_major.minor (range for derivation)
  local cur="${1:-0.0}" tgt="${2:-0.0}"
  # Frozen history ≤17.4 (upstream config/upgrade_path.yml; conditional stops
  # 16.0/16.1/16.2/17.1 included — safe default, they only cost minutes)
  printf '%s\n' 8.11 8.12 8.17 9.5 10.0 10.8 11.0 11.11 \
    12.0 12.1 12.10 13.0 13.1 13.8 13.12 \
    14.0 14.3 14.9 14.10 15.0 15.4 15.11 \
    16.0 16.1 16.2 16.3 16.7 16.11 17.1 17.3 17.5 17.8 17.11
  # ≥18: derived from the official cadence — generate x.2/x.5/x.8/x.11 for
  # every major from 18 up to the target's major (one extra major is harmless).
  local cmin tmin cmaj tmaj mj mn
  cmaj="${cur%%.*}"
  cmin="${cur#*.}"
  [ "${cmin}" = "${cur}" ] && cmin=0
  tmaj="${tgt%%.*}"
  tmin="${tgt#*.}"
  [ "${tmin}" = "${tgt}" ] && tmin=0
  for ((mj = 18; mj <= tmaj; mj++)); do
    for mn in 2 5 8 11; do
      printf '%s.%s\n' "${mj}" "${mn}"
    done
  done
}

# Hop gate: omnibus /-/readiness (includes the db-migrations checks) — enabled
# by monitoring_whitelist in the compose config (see docker-compose.yml).
# MEASURED: the whitelist is 127.0.0.1, and the host's port-mapped requests
# arrive with the docker-bridge source IP — rejected with 404. So the probe
# runs FROM INSIDE the container (docker exec → source 127.0.0.1; same exec
# pattern as the credentials flow). Falls back to http_up when the exec probe
# is unavailable (older deploys without the whitelist, curl-less images) so
# the gate never BLOCKS an otherwise-healthy hop.
http_up_readiness() {
  local port="${1:-$DEFAULT_HTTP_PORT}" code
  code="$(docker exec "${CONTAINER_NAME}" curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:8080/-/readiness" 2>/dev/null || true)"
  case "$code" in
  200) return 0 ;;
  *) http_up "${port}" ;;
  esac
}

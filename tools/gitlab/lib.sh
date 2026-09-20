# gitlab module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/gitlab.

MODULE_NAME="gitlab"
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

# ---------- dashboard (the module's rich view) ----------
render_dashboard() {
  load_env
  local port
  port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  printf '%s%sgitlab%s %s· module %s%s\n' "${C_BOLD:-}" "" "${C_RST:-}" "${C_DIM:-}" "${MODULE_VERSION:-1.2.1}" "${C_RST:-}"
  local st=""
  st="$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1)"
  if [ -n "${st}" ]; then
    printf '  %s%-9s %s\n' "${C_DIM:-}" "container:" "${st}"
    local code
    code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    [ -z "${code}" ] && code="000"
    case "${code}" in
    2?? | 3?? | 401) printf '  %s%-9s http://127.0.0.1:%s · %s✓ HTTP %s%s\n' "${C_DIM:-}" "web:" "${port}" "${C_GRN:-}" "${code}" "${C_RST:-}" ;;
    *) printf '  %s%-9s http://127.0.0.1:%s · %sHTTP %s%s\n' "${C_DIM:-}" "web:" "${port}" "${C_YEL:-}" "${code}" "${C_RST:-}" ;;
    esac
    printf '  %s%-9s :%s (git over SSH)\n' "${C_DIM:-}" "ssh:" "${GITLAB_SSH_PORT:-8922}"
  else
    printf '  %s%-9s %snot running (aibox gitlab start)%s\n' "${C_DIM:-}" "container:" "${C_YEL:-}" "${C_RST:-}"
  fi
  printf '  %s%-9s root / initial password (see: aibox gitlab credentials)\n' "${C_DIM:-}" "auth:"
}

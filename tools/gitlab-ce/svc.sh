#!/usr/bin/env bash
# gitlab-ce module — service ops hook: aibox gitlab-ce <action> [args]
# Actions: start | stop | restart | status | logs | credentials
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

action="${1:-status}"
[ $# -gt 0 ] && shift
load_env

case "$action" in
  start)
    compose up -d "$@"
    port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    timeout_s="${GITLAB_START_TIMEOUT:-600}"
    waited=0
    log "waiting for GitLab to boot (first boot 3-5 min; timeout ${timeout}s)..."
    while [ "$waited" -lt "$timeout_s" ]; do
      if http_up "$port"; then
        ok "GitLab is up: http://127.0.0.1:${port}"
        log "SSH clone  : $(ssh_clone_url)/<group>/<project>.git"
        log "Login      : root — initial password: aibox gitlab-ce credentials"
        exit 0
      fi
      sleep 10
      waited=$((waited + 10))
      if [ $((waited % 60)) -eq 0 ]; then
        state="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo booting)"
        log "  still booting (${waited}s, health: ${state})"
      fi
    done
    warn "GitLab did not answer within ${timeout_s}s — inspect: aibox gitlab-ce logs | docker logs $CONTAINER_NAME"
    exit 1
    ;;
  stop)
    compose stop "$@"
    ok "stopped (data volumes untouched)"
    ;;
  restart)
    compose restart "$@"
    ok "restarted (the entrypoint re-runs omnibus reconfigure on boot)"
    ;;
  status)
    compose ps
    port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    if container_running; then
      health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
      log "image : $(effective_image)"
      log "health: ${health}"
      if http_up "$port"; then
        ok "UI answers: http://127.0.0.1:${port}"
      else
        warn "UI not answering yet on :${port} (first boot takes 3-5 min)"
      fi
    else
      warn "container ${CONTAINER_NAME} is not running (start: aibox gitlab-ce start)"
    fi
    ;;
  logs)
    compose logs --tail "${GITLAB_LOG_TAIL:-200}" "$@"
    ;;
  credentials)
    pw="$(docker exec "$CONTAINER_NAME" grep '^Password:' /etc/gitlab/initial_root_password 2>/dev/null | awk '{print $2}' || true)"
    if [ -n "$pw" ]; then
      ok "user    : root"
      ok "password: ${pw}"
      warn "the initial-password file is auto-deleted 24h after first boot"
    else
      warn "initial password unavailable (file deleted after 24h, or container not running)"
      log "reset it: docker exec -it ${CONTAINER_NAME} gitlab-rake gitlab:password:reset USERNAME=root"
    fi
    ;;
  *)
    die "unknown action: $action (declared: start stop restart status logs credentials)"
    ;;
esac

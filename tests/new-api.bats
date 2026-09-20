#!/usr/bin/env bats
# new-api module tests — fully OFFLINE.
# File-op tests (install .env once / uninstall retention) need no docker;
# pool + status tests use the same fake-docker shim pattern as
# tests/dify-docker-pool.bats (image inspect / pull / rmi / tag / compose
# config --images, per-route MODE/DELAY env knobs, PULLLOG/TAGLOG recorders).

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-newapi.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  unset AIBOX_DOCKER_POOL AIBOX_DOCKER_MIRROR AIBOX_DOCKER_FORCE_POOL \
    AIBOX_DOCKER_PROBE_TIMEOUT AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT \
    AIBOX_DOCKER_PULL_TIMEOUT AIBOX_DOCKER_POLL \
    FAKE_DOCKER_1MS_MODE FAKE_DOCKER_DAOCLOUD_MODE \
    FAKE_DOCKER_DIRECT_MODE NEW_API_PORT NEW_API_IMAGE || true
  export AIBOX_DOCKER_POLL=0.2
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # deploy root so compose() is satisfied (the fake docker does the parsing)
  mkdir -p "$AIBOX_HOME/apps/new-api"
  : >"$AIBOX_HOME/apps/new-api/docker-compose.yml"
  export FAKE_COMPOSE_IMAGES="calciumion/new-api:v0.13.2"

  export FAKE_DOCKER_CACHED="$SANDBOX/cached"
  export FAKE_DOCKER_TAGLOG="$SANDBOX/taglog"
  export FAKE_DOCKER_PULLLOG="$SANDBOX/pulllog"
  : >"$FAKE_DOCKER_CACHED"
  : >"$FAKE_DOCKER_TAGLOG"
  : >"$FAKE_DOCKER_PULLLOG"

  FAKEBIN="$SANDBOX/bin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/docker" <<'SHIM'
#!/usr/bin/env bash
cmd="${1:-}"; shift
case "$cmd" in
image)
  ref="${2:-}"
  if [ -f "$FAKE_DOCKER_CACHED" ] && grep -qxF "$ref" "$FAKE_DOCKER_CACHED"; then exit 0; fi
  exit 1
  ;;
pull)
  ref="$1"
  r="DIRECT"
  case "$ref" in
  docker.1ms.run/*) r=1MS ;;
  docker.m.daocloud.io/*) r=DAOCLOUD ;;
  dockerproxy.net/*) r=DOCKERPROXY ;;
  hub.rat.dev/*) r=RATDEV ;;
  esac
  printf 'PULL %s\n' "$ref" >>"$FAKE_DOCKER_PULLLOG"
  mode="ok"; delay=0
  eval "mode=\${FAKE_DOCKER_${r}_MODE:-ok}"
  eval "delay=\${FAKE_DOCKER_${r}_DELAY:-0}"
  if [ "$mode" = "dead" ]; then exit 1; fi
  if [ "${delay:-0}" -gt 0 ]; then sleep "$delay"; fi
  printf '%s\n' "$ref" >>"$FAKE_DOCKER_CACHED"
  exit 0
  ;;
rmi)
  ref="${!#}"
  if [ -f "$FAKE_DOCKER_CACHED" ]; then
    grep -vxF "$ref" "$FAKE_DOCKER_CACHED" >"$FAKE_DOCKER_CACHED.tmp" 2>/dev/null || true
    mv "$FAKE_DOCKER_CACHED.tmp" "$FAKE_DOCKER_CACHED"
  fi
  exit 0
  ;;
tag)
  printf '%s %s\n' "$1" "$2" >>"$FAKE_DOCKER_TAGLOG"
  printf '%s\n' "$2" >>"$FAKE_DOCKER_CACHED"
  exit 0
  ;;
ps)
  # container_running greps docker ps output for the fixed container name;
  # empty output (default) = not running. FAKE_DOCKER_PS overrides.
  # shellcheck disable=SC2086
  printf '%s\n' ${FAKE_DOCKER_PS:-}
  exit 0
  ;;
compose)
  prev=""
  for a in "$@"; do
    if [ "$prev" = "config" ] && [ "$a" = "--images" ]; then
      # shellcheck disable=SC2086
      printf '%s\n' ${FAKE_COMPOSE_IMAGES:-}
      exit 0
    fi
    prev="$a"
  done
  exit 0
  ;;
esac
exit 1
SHIM
  chmod +x "$FAKEBIN/docker"
  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/tools/new-api/lib.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
  pkill -f "http.server 183" 2>/dev/null || true
}

# Deterministic test-server shutdown (same fix as test_helper.bash — this file
# builds its own sandbox, so it carries its own copy).
_kill_srv() { # $1 = pid
  kill "$1" 2>/dev/null || true
  sleep 1
  kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# Bounded readiness wait (same fix as test_helper.bash; this file is standalone).
_wait_http() { # $1 = port
  local waited=0
  until curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${1}/" 2>/dev/null; do
    [ "${waited}" -ge 20 ] && return 1
    sleep 0.5
    waited=$((waited + 1))
  done
  return 0
}

@test "install: places compose + writes .env once (idempotent), secret generated, mode 600" {
  export PATH="$FAKEBIN:$PATH"
  run bash "$REPO_ROOT/tools/new-api/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$AIBOX_HOME/apps/new-api/docker-compose.yml" ]
  [ -f "$AIBOX_HOME/apps/new-api/.env" ]
  # SESSION_SECRET generated (hex-ish, non-empty)
  secret="$(grep -E '^SESSION_SECRET=' "$AIBOX_HOME/apps/new-api/.env" | cut -d= -f2-)"
  [ -n "$secret" ]
  [ "${#secret}" -ge 32 ]
  # mode 600
  # GNU-first order: GNU stat -f prints filesystem garbage with exit 0 (the BSD
  # meaning of -f differs) — see tests/upgrade.bats for the proven pattern.
  [ "$(stat -c '%a' "$AIBOX_HOME/apps/new-api/.env" 2>/dev/null || stat -f '%Lp' "$AIBOX_HOME/apps/new-api/.env")" = "600" ]
  # defaults present
  grep -q '^NEW_API_PORT=30300$' "$AIBOX_HOME/apps/new-api/.env"
  grep -q '^NEW_API_IMAGE=calciumion/new-api:v0.13.2$' "$AIBOX_HOME/apps/new-api/.env"

  # --- second run: .env is never clobbered (secrets preserved) ---
  echo "# user marker" >>"$AIBOX_HOME/apps/new-api/.env"
  run bash "$REPO_ROOT/tools/new-api/install.sh"
  [ "$status" -eq 0 ]
  grep -q '^# user marker$' "$AIBOX_HOME/apps/new-api/.env"
}

@test "effective_port: default 30300, NEW_API_PORT override honored" {
  [ "$(effective_port)" = "30300" ]
  NEW_API_PORT=30399
  [ "$(effective_port)" = "30399" ]
}

@test "api_up: answers on /api/status with success:true; dead port fails" {
  # Serve the upstream health contract from a file named api/status
  docroot="$SANDBOX/docroot"
  mkdir -p "$docroot/api"
  printf '{"success": true, "data": {"version": "v0.13.2"}}' >"$docroot/api/status"
  python3 -m http.server 18300 --bind 127.0.0.1 --directory "$docroot" >/dev/null 2>&1 &
  srv=$!
  _wait_http 18300
  api_up 18300
  rc=$?
  _kill_srv "$srv"
  [ "$rc" -eq 0 ]

  # dead port → not up
  ! api_up 18301
}

@test "api_up: success:false body is NOT up (the contract is success:true, not 200)" {
  docroot="$SANDBOX/docroot2"
  mkdir -p "$docroot/api"
  printf '{"success": false}' >"$docroot/api/status"
  python3 -m http.server 18302 --bind 127.0.0.1 --directory "$docroot" >/dev/null 2>&1 &
  srv=$!
  _wait_http 18302
  ! api_up 18302
  rc=$?
  _kill_srv "$srv"
}

@test "dashboard_info: emits version/endpoint/credential/db/health fields" {
  unset NEW_API_PORT || true
  out="$(dashboard_info)"
  printf '%s\n' "$out" | grep -q '^version=v0\.13\.2$'
  printf '%s\n' "$out" | grep -q '^endpoint=http://127\.0\.0\.1:30300$'
  printf '%s\n' "$out" | grep -q '^credential=first login: root / 123456'
  printf '%s\n' "$out" | grep -q '^db=shared base'
  printf '%s\n' "$out" | grep -q '^health=stopped'   # fake docker ps: empty
}

@test "uninstall: removes compose, PRESERVES root/.env by default" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/new-api/install.sh" >/dev/null 2>&1
  run bash "$REPO_ROOT/tools/new-api/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$AIBOX_HOME/apps/new-api/docker-compose.yml" ]
  [ -f "$AIBOX_HOME/apps/new-api/.env" ]          # secrets preserved
  [ -d "$AIBOX_HOME/apps/new-api" ]               # deploy root preserved
}

@test "uninstall --purge (AIBOX_PURGE_DATA=1): removes the deploy root entirely" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/new-api/install.sh" >/dev/null 2>&1
  AIBOX_PURGE_DATA=1 run bash "$REPO_ROOT/tools/new-api/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -d "$AIBOX_HOME/apps/new-api" ]
}

@test "docker pool: everything cached → no-op, zero pulls" {
  printf '%s\n' "calciumion/new-api:v0.13.2" >>"$FAKE_DOCKER_CACHED"
  run docker_pool_prepull calciumion/new-api:v0.13.2
  [ "$status" -eq 0 ]
  [ "$(grep -c PULL "$FAKE_DOCKER_PULLLOG")" = "0" ]
}

@test "docker pool: direct dead → mirror pre-pull + tag to the official name" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_DOCKER_PROBE_TIMEOUT=2 AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT=5
  run docker_pool_prepull calciumion/new-api:v0.13.2
  [ "$status" -eq 0 ]
  # hello-world probes raced the mirrors (ranking), then the image came via a mirror
  grep -qE 'PULL (docker\.1ms\.run|docker\.m\.daocloud\.io|dockerproxy\.net|hub\.rat\.dev)/calciumion/new-api:v0\.13\.2$' "$FAKE_DOCKER_PULLLOG"
  # and was tagged back to the official ref (compose up finds it cached)
  grep -qE '^[a-z0-9.]+/calciumion/new-api:v0\.13\.2 calciumion/new-api:v0\.13\.2$' "$FAKE_DOCKER_TAGLOG"
}

@test "docker pool: registryref off docker.io (ghcr.io/…) stays direct (not mirror-prefixed)" {
  _dk_is_dockerio "ghcr.io/windmill-labs/windmill:latest" && exit 1 || true
  _dk_is_dockerio "calciumion/new-api:v0.13.2"
}

@test "compose: joins the external base network + injects base.env vars (compose file contract)" {
  # Static contract checks on the curated compose: the service references the
  # base.env-injected vars and the external aibox-base network.
  y="$REPO_ROOT/tools/new-api/docker-compose.yml"
  grep -q 'SQL_DSN=postgresql://\${AIBOX_POSTGRES_USER}:\${AIBOX_POSTGRES_PASSWORD}@\${AIBOX_POSTGRES_HOST}:\${AIBOX_POSTGRES_PORT}/new_api' "$y"
  grep -q 'REDIS_CONN_STRING=redis://\${AIBOX_REDIS_HOST}:\${AIBOX_REDIS_PORT}' "$y"
  grep -q 'name: \${AIBOX_BASE_NETWORK:-aibox-base}' "$y"
  grep -q 'external: true' "$y"
  grep -q 'name: \${NEW_API_DATA_VOLUME:-aibox_new_api_data}' "$y"
  grep -q 'name: \${NEW_API_LOGS_VOLUME:-aibox_new_api_logs}' "$y"
  grep -q '"\${NEW_API_PORT:-30300}:3000"' "$y"
  # no hardcoded credentials (validator also scans; assert here)
  ! grep -qE '(PASSWORD|SECRET_KEY|API_KEY)=[^$]' "$y"
}

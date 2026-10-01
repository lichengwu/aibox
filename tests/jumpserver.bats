#!/usr/bin/env bats
# jumpserver module tests — fully OFFLINE.
# File-op tests (install .env once / uninstall retention) need no docker; the
# pool + compose-contract tests use the fake-docker shim pattern from
# tests/xiaozhi.bats (image inspect / pull per-route MODE/DELAY / rmi / tag /
# compose config --images / ps).

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-jumpserver.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  unset AIBOX_DOCKER_POOL AIBOX_DOCKER_MIRROR AIBOX_DOCKER_FORCE_POOL \
    AIBOX_DOCKER_PROBE_TIMEOUT AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT \
    AIBOX_DOCKER_PULL_TIMEOUT AIBOX_DOCKER_POOL_TTL AIBOX_DOCKER_POLL \
    JUMPSERVER_WEB_PORT JUMPSERVER_SSH_PORT JUMPSERVER_CORE_IMAGE \
    JUMPSERVER_WEB_IMAGE JUMPSERVER_KOKO_IMAGE JUMPSERVER_LION_IMAGE \
    JUMPSERVER_CHEN_IMAGE JUMPSERVER_SECRET_KEY JUMPSERVER_BOOTSTRAP_TOKEN \
    JUMPSERVER_DOMAINS JUMPSERVER_REDIS_DB_CELERY JUMPSERVER_REDIS_DB_CACHE \
    JUMPSERVER_REDIS_DB_SESSION JUMPSERVER_REDIS_DB_WS AIBOX_REDIS_DB || true
  export AIBOX_DOCKER_POLL=0.2
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # deploy root so compose() is satisfied (the fake docker does the parsing)
  mkdir -p "$AIBOX_HOME/apps/jumpserver"
  : >"$AIBOX_HOME/apps/jumpserver/docker-compose.yml"
  export FAKE_COMPOSE_IMAGES="jumpserver/core:v4.10.19-ce jumpserver/web:v4.10.19-ce jumpserver/koko:v4.10.19-ce jumpserver/lion:v4.10.19-ce jumpserver/chen:v4.10.19-ce"

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
  # shellcheck disable=SC2086
  printf '%s\n' ${FAKE_DOCKER_PS:-}
  exit 0
  ;;
inspect)
# docker inspect -f '{{.Config.Image}}' <c> / -f '{{.State.Health.Status}}' <c>
# only answers for "running" containers (FAKE_DOCKER_PS) — a stopped/absent
# container must fail like real docker would
fmt=""; target=""
while [ $# -gt 0 ]; do
case "$1" in
-f) fmt="$2"; shift 2 ;;
*) target="$1"; shift ;;
esac
done
case " ${FAKE_DOCKER_PS:-} " in
*" ${target} "*) ;;
*) exit 1 ;;
esac
case "${fmt}" in
  *Config.Image*)
    case "${target}" in
    aibox-jumpserver-core) printf 'jumpserver/core:%s\n' "${FAKE_CORE_TAG:-v4.10.19-ce}"; exit 0 ;;
    esac
    ;;
  *Health*)
    case "${target}" in
    aibox-jumpserver-core) printf '%s\n' "${FAKE_CORE_HEALTH:-healthy}"; exit 0 ;;
    esac
    ;;
  esac
  exit 1
  ;;
network)
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
  source "$REPO_ROOT/tools/jumpserver/lib.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "install: places compose + writes .env once + certs dir (idempotent)" {
  export PATH="$FAKEBIN:$PATH"
  run bash "$REPO_ROOT/tools/jumpserver/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/apps/jumpserver/docker-compose.yml" ]
  [ -f "$AIBOX_HOME/apps/jumpserver/.env" ]
  [ -d "$AIBOX_HOME/apps/jumpserver/certs" ]

  # secrets generated: hex (24→48 chars, 12→24 chars), no metacharacters
  sk="$(grep -E '^JUMPSERVER_SECRET_KEY=' "$AIBOX_HOME/apps/jumpserver/.env" | cut -d= -f2-)"
  bt="$(grep -E '^JUMPSERVER_BOOTSTRAP_TOKEN=' "$AIBOX_HOME/apps/jumpserver/.env" | cut -d= -f2-)"
  [ "${#sk}" -ge 48 ]
  [ "${#bt}" -ge 24 ]
  case "${sk}${bt}" in
  *[!0-9a-f]*) false ;;
  esac
  # .env mode 600
  # GNU-first order: GNU stat -f prints filesystem garbage with exit 0 (the BSD
  # meaning of -f differs) — see tests/upgrade.bats for the proven pattern.
  [ "$(stat -c '%a' "$AIBOX_HOME/apps/jumpserver/.env" 2>/dev/null || stat -f '%Lp' "$AIBOX_HOME/apps/jumpserver/.env")" = "600" ]
  # ports + image pins from the defaults
  grep -q '^JUMPSERVER_WEB_PORT=31200$' "$AIBOX_HOME/apps/jumpserver/.env"
  grep -q '^JUMPSERVER_SSH_PORT=31202$' "$AIBOX_HOME/apps/jumpserver/.env"
  grep -q '^JUMPSERVER_CORE_IMAGE=jumpserver/core:v4.10.19-ce$' "$AIBOX_HOME/apps/jumpserver/.env"
  grep -q '^JUMPSERVER_CHEN_IMAGE=jumpserver/chen:v4.10.19-ce$' "$AIBOX_HOME/apps/jumpserver/.env"

  # --- second run: .env is never clobbered ---
  echo "# user marker" >>"$AIBOX_HOME/apps/jumpserver/.env"
  run bash "$REPO_ROOT/tools/jumpserver/install.sh"
  [ "$status" -eq 0 ]
  grep -q '^# user marker$' "$AIBOX_HOME/apps/jumpserver/.env"
}

@test "install: JUMPSERVER_SECRET_KEY/BOOTSTRAP_TOKEN env seeds are honored" {
  export PATH="$FAKEBIN:$PATH"
  JUMPSERVER_SECRET_KEY="aabbccddeeff00112233445566778899aabbccdd" \
  JUMPSERVER_BOOTSTRAP_TOKEN="1234567890abcdef12345678" \
    run bash "$REPO_ROOT/tools/jumpserver/install.sh"
  [ "$status" -eq 0 ]
  grep -q '^JUMPSERVER_SECRET_KEY=aabbccddeeff00112233445566778899aabbccdd$' "$AIBOX_HOME/apps/jumpserver/.env"
  grep -q '^JUMPSERVER_BOOTSTRAP_TOKEN=1234567890abcdef12345678$' "$AIBOX_HOME/apps/jumpserver/.env"
}

@test "effective ports: defaults + JUMPSERVER_*_PORT overrides honored" {
  [ "$(effective_web_port)" = "31200" ]
  [ "$(effective_ssh_port)" = "31202" ]
  JUMPSERVER_WEB_PORT=18100 JUMPSERVER_SSH_PORT=18102
  [ "$(effective_web_port)" = "18100" ]
  [ "$(effective_ssh_port)" = "18102" ]
}

@test "_redis_db_remap: 4 consecutive DBs from the allocated slot (env OR the redis env file); garbage = no-op" {
  AIBOX_REDIS_DB=9
  unset JUMPSERVER_REDIS_DB_CELERY JUMPSERVER_REDIS_DB_CACHE JUMPSERVER_REDIS_DB_SESSION JUMPSERVER_REDIS_DB_WS || true
  _redis_db_remap
  [ "$JUMPSERVER_REDIS_DB_CELERY" = "9" ]
  [ "$JUMPSERVER_REDIS_DB_CACHE" = "10" ]
  [ "$JUMPSERVER_REDIS_DB_SESSION" = "11" ]
  [ "$JUMPSERVER_REDIS_DB_WS" = "12" ]
  # the slot index lives in the redis env FILE (compose --env-file does not put
  # it in the shell env — the remap must read the file itself; live-caught:
  # the compose defaults 3/4/5/6 silently leaked through)
  mkdir -p "$AIBOX_HOME"
  printf 'AIBOX_REDIS_DB=5\nAIBOX_REDIS_SLOTS=4\n' >"$AIBOX_HOME/redis-jumpserver.env"
  AIBOX_REDIS_DB=""
  unset JUMPSERVER_REDIS_DB_CELERY JUMPSERVER_REDIS_DB_CACHE JUMPSERVER_REDIS_DB_SESSION JUMPSERVER_REDIS_DB_WS || true
  _redis_db_remap
  [ "$JUMPSERVER_REDIS_DB_CELERY" = "5" ]
  [ "$JUMPSERVER_REDIS_DB_CACHE" = "6" ]
  [ "$JUMPSERVER_REDIS_DB_SESSION" = "7" ]
  [ "$JUMPSERVER_REDIS_DB_WS" = "8" ]
  rm -f "$AIBOX_HOME/redis-jumpserver.env"
  # no allocation anywhere → upstream defaults stay in charge (compose fallbacks 3/4/5/6)
  AIBOX_REDIS_DB=""
  unset JUMPSERVER_REDIS_DB_CELERY JUMPSERVER_REDIS_DB_CACHE JUMPSERVER_REDIS_DB_SESSION JUMPSERVER_REDIS_DB_WS || true
  _redis_db_remap
  [ -z "${JUMPSERVER_REDIS_DB_CELERY:-}" ]
  AIBOX_REDIS_DB="not-a-number"
  _redis_db_remap
  [ -z "${JUMPSERVER_REDIS_DB_CELERY:-}" ] || false
}

@test "app_version: live container image tag; falls back to the .env/compose pin" {
  export PATH="$FAKEBIN:$PATH"
  # no container, no .env: the declared default pin
  [ "$(app_version)" = "v4.10.19-ce" ]
  # .env pin wins over the compose default (load_env mirrors the hooks)
  bash "$REPO_ROOT/tools/jumpserver/install.sh" >/dev/null 2>&1
  sed -i.bak 's|^JUMPSERVER_CORE_IMAGE=.*|JUMPSERVER_CORE_IMAGE=jumpserver/core:v4.10.5-ce|' "$AIBOX_HOME/apps/jumpserver/.env" && rm -f "$AIBOX_HOME/apps/jumpserver/.env.bak"
  [ "$(app_version)" = "v4.10.5-ce" ]
  # live container tag wins over everything
  export FAKE_DOCKER_PS="aibox-jumpserver-core"
  export FAKE_CORE_TAG="v4.10.19-ce"
  [ "$(app_version)" = "v4.10.19-ce" ]
}

@test "status_info: emits version/endpoint/credential/ssh/db + state (stopped; ok; starting)" {
  export PATH="$FAKEBIN:$PATH"
  out="$(status_info)"
  printf '%s\n' "$out" | grep -q '^version=v4\.10\.19-ce$'
  printf '%s\n' "$out" | grep -q '^endpoint=http://127\.0\.0\.1:31200$'
  printf '%s\n' "$out" | grep -q '^credential=admin / ChangeMe'
  printf '%s\n' "$out" | grep -q '^ssh=ssh -p 31202 admin@<host>'
  printf '%s\n' "$out" | grep -q '^db=shared base PG (jumpserver) + shared base redis'
  printf '%s\n' "$out" | grep -q '^state=stopped$'
  printf '%s\n' "$out" | grep -q '^health=stopped$'
  # NOTE: status_info's probes (stack_running/core_healthy/api_health_up) use
  # curl + docker ps/inspect; with the fake docker reporting core up + healthy
  # but no HTTP listener, the honest composite is starting.
  export FAKE_DOCKER_PS="aibox-jumpserver-core aibox-jumpserver-web"
  export FAKE_CORE_HEALTH="healthy"
  out="$(status_info)"
  printf '%s\n' "$out" | grep -q '^state=starting$'
}

@test "render_status: keyline header (app version) + sunk module row" {
  run bash -c ". '$REPO_ROOT/tools/jumpserver/lib.sh'; render_status"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"jumpserver v4.10.19-ce"* ]] || false
  [[ "$output" == *"module"*"·"*"modules/jumpserver/"* ]] || false
  # all six services render rows
  for svc in core celery web koko lion chen; do
    [[ "$output" == *"$(printf '%s' "$svc")"* ]] || false
  done
}

@test "render_status: no docker → degrades, exit 0 under set -euo pipefail" {
  run bash -c "set -euo pipefail; PATH=/usr/bin:/bin; . '$REPO_ROOT/tools/jumpserver/lib.sh'; render_status"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"(stopped — aibox jumpserver start)"* ]] || false
}

@test "uninstall: removes compose, PRESERVES .env + certs by default" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/jumpserver/install.sh" >/dev/null 2>&1
  run bash "$REPO_ROOT/tools/jumpserver/uninstall.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$AIBOX_HOME/apps/jumpserver/docker-compose.yml" ]
  [ -f "$AIBOX_HOME/apps/jumpserver/.env" ]                    # SECRET_KEY/BOOTSTRAP_TOKEN preserved
  [ -d "$AIBOX_HOME/apps/jumpserver/certs" ]
}

@test "uninstall --purge (AIBOX_PURGE_DATA=1): removes the deploy root entirely" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/jumpserver/install.sh" >/dev/null 2>&1
  AIBOX_PURGE_DATA=1 run bash "$REPO_ROOT/tools/jumpserver/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -d "$AIBOX_HOME/apps/jumpserver" ]
}

@test "docker.io pool: jumpserver images go through the ranked-mirror pool when direct is dead" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_DOCKER_PROBE_TIMEOUT=2 AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT=5 AIBOX_DOCKER_PULL_TIMEOUT=5
  run docker_pool_prepull "jumpserver/core:v4.10.19-ce"
  [ "$status" -eq 0 ]
  grep -qE 'PULL (docker\.1ms\.run|docker\.m\.daocloud\.io|dockerproxy\.net|hub\.rat\.dev)/jumpserver/core:v4\.10\.19-ce$' "$FAKE_DOCKER_PULLLOG"
  grep -qE '^[a-z0-9.]+/jumpserver/core:v4\.10\.19-ce jumpserver/core:v4\.10\.19-ce$' "$FAKE_DOCKER_TAGLOG"
}

@test "compose: joins the external base network + injects base.env vars (compose file contract)" {
  y="$REPO_ROOT/tools/jumpserver/docker-compose.yml"
  # core: shared-base PG from base.env (DB_NAME literal = the declared service resource)
  grep -q 'DB_HOST=\${AIBOX_POSTGRES_HOST}' "$y" || false
  grep -q 'DB_PORT=\${AIBOX_POSTGRES_PORT}' "$y" || false
  grep -q 'DB_USER=\${AIBOX_POSTGRES_USER}' "$y" || false
  grep -q 'DB_PASSWORD=\${AIBOX_POSTGRES_PASSWORD}' "$y" || false
  grep -q 'DB_NAME=jumpserver' "$y" || false
  # redis auth + the four remapped logical DBs (no silent defaults on shared creds)
  grep -q 'REDIS_HOST=\${AIBOX_REDIS_HOST}' "$y" || false
  grep -q 'REDIS_PORT=\${AIBOX_REDIS_PORT}' "$y" || false
  grep -q 'REDIS_PASSWORD=\${AIBOX_REDIS_PASSWORD}' "$y" || false
  grep -q 'REDIS_DB_CELERY=\${JUMPSERVER_REDIS_DB_CELERY:-3}' "$y" || false
  grep -q 'REDIS_DB_CACHE=\${JUMPSERVER_REDIS_DB_CACHE:-4}' "$y" || false
  grep -q 'REDIS_DB_SESSION=\${JUMPSERVER_REDIS_DB_SESSION:-5}' "$y" || false
  grep -q 'REDIS_DB_WS=\${JUMPSERVER_REDIS_DB_WS:-6}' "$y" || false
  # celery must repeat the whole contract (upstream: same image, own env)
  n="$(grep -c 'DB_HOST=\${AIBOX_POSTGRES_HOST}' "$y")"
  [ "$n" -ge 2 ]
  # base network external
  grep -q 'name: \${AIBOX_BASE_NETWORK:-aibox-base}' "$y"
  grep -q 'external: true' "$y"
  # six services, aibox container names, host ports in the reserved band
  for c in core celery web koko lion chen; do
    grep -q "container_name: aibox-jumpserver-${c}" "$y" || false
  done
  grep -q '"\${JUMPSERVER_WEB_PORT:-31200}:80"' "$y"
  grep -q '"\${JUMPSERVER_SSH_PORT:-31202}:2222"' "$y"
  # secrets from the deploy .env (never literals)
  grep -q 'SECRET_KEY=\${JUMPSERVER_SECRET_KEY}' "$y" || false
  grep -q 'BOOTSTRAP_TOKEN=\${JUMPSERVER_BOOTSTRAP_TOKEN}' "$y" || false
  # components register with core (upstream config_safe contract)
  grep -q 'CORE_HOST=http://core:8080' "$y" || false
  # deterministic volume names
  grep -q 'name: \${JUMPSERVER_CORE_VOLUME:-aibox_jumpserver_core}' "$y" || false
  grep -q 'name: \${JUMPSERVER_NGINX_VOLUME:-aibox_jumpserver_nginx_logs}' "$y" || false
  # upstream-faithful bits: healthchecks, docker.sock, privileged celery/koko
  grep -q 'check_celery' "$y" || false
  grep -q 'api/health/' "$y" || false
  grep -q 'koko/health/' "$y" || false
  grep -q 'lion/health/' "$y" || false
  grep -q 'chen/healthy' "$y" || false
  grep -q '/var/run/docker.sock:/var/run/docker.sock:z' "$y" || false
  [ "$(grep -c 'privileged: true' "$y")" = "2" ]
  # restart policy durable-stop
  [ "$(grep -c 'restart: unless-stopped' "$y")" = "6" ]
  # no hardcoded credentials (validator also scans; assert here)
  ! grep -qE '(PASSWORD|SECRET|TOKEN)=[^$]' "$y"
}

@test "restart: full container cycle — down WITHOUT -v (data survives), then up (nginx re-resolves core)" {
  s="$REPO_ROOT/tools/jumpserver/svc.sh"
  # the full-cycle contract: compose down (no -v!) then up — a partial
  # up -d recreate leaves the web nginx 502-ing on core's dead IP (measured)
  grep -q 'compose down --remove-orphans' "$s" || false
  # the down must NOT remove volumes (-v deletes named data volumes — a
  # data-killer; upstream jmsctl uses bind mounts so its down -v is safe)
  ! grep -q 'compose down -v' "$s"
  # restart goes through the full cycle, start/up does not
  grep -A2 '^restart)' "$s" | grep -q '_full_cycle' || false
}

@test "install_managed_file: user-edited compose is KEPT, new version lands as .new" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/jumpserver/install.sh" >/dev/null 2>&1
  dst="$AIBOX_HOME/apps/jumpserver/docker-compose.yml"
  echo "# user edit" >>"$dst"
  run bash "$REPO_ROOT/tools/jumpserver/install.sh"
  [ "$status" -eq 0 ]
  grep -q '^# user edit$' "$dst"
  [ -f "${dst}.new" ]
}

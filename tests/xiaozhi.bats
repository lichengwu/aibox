#!/usr/bin/env bats
# xiaozhi module tests — fully OFFLINE.
# File-op tests (install .env once / .config.yaml render / uninstall
# retention) need no docker; pool + status tests use the fake-docker shim
# pattern from tests/dify-docker-pool.bats (image inspect / pull per-route
# MODE/DELAY / rmi / tag / compose config --images / ps), extended with a
# ghcr-mirror route (ghcr.nju.edu.cn / ghcr.dockerproxy.net refs).

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-xiaozhi.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  unset AIBOX_DOCKER_POOL AIBOX_DOCKER_MIRROR AIBOX_DOCKER_FORCE_POOL \
    AIBOX_DOCKER_PROBE_TIMEOUT AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT \
    AIBOX_DOCKER_PULL_TIMEOUT AIBOX_DOCKER_POLL \
    AIBOX_GHCR_POOL AIBOX_GHCR_MIRROR AIBOX_GHCR_DIRECT_TIMEOUT \
    AIBOX_GHCR_PULL_TIMEOUT \
    XIAOZHI_WS_PORT XIAOZHI_CONSOLE_PORT XIAOZHI_HTTP_PORT \
    XIAOZHI_SERVER_IMAGE XIAOZHI_WEB_IMAGE AIBOX_DOCKER_POOL_TTL || true
  export AIBOX_DOCKER_POLL=0.2
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # deploy root so compose() is satisfied (the fake docker does the parsing)
  mkdir -p "$AIBOX_HOME/apps/xiaozhi"
  : >"$AIBOX_HOME/apps/xiaozhi/docker-compose.yml"
  export FAKE_COMPOSE_IMAGES="ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_0.9.6 ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6 mysql:8.0"

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
  ghcr.nju.edu.cn/*) r=GHCRNJU ;;
  ghcr.dockerproxy.net/*) r=GHDPROXY ;;
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
exec)
  # docker exec <container> mysql … -e "SELECT param_value FROM sys_params…"
  # → FAKE_MYSQL_SECRET (empty/'null' = not generated yet)
  case "$*" in
  *sys_params*server.secret*) printf '%s\n' "${FAKE_MYSQL_SECRET:-}"; exit 0 ;;
  esac
  exit 1
  ;;
restart)
  printf 'RESTART %s\n' "${1:-}" >>"$FAKE_DOCKER_PULLLOG"
  exit 0
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
  source "$REPO_ROOT/tools/xiaozhi/lib.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "install: places compose + writes .env once + renders data/.config.yaml once (idempotent)" {
  export PATH="$FAKEBIN:$PATH"
  run bash "$REPO_ROOT/tools/xiaozhi/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$AIBOX_HOME/apps/xiaozhi/docker-compose.yml" ]
  [ -f "$AIBOX_HOME/apps/xiaozhi/.env" ]
  [ -f "$AIBOX_HOME/apps/xiaozhi/data/.config.yaml" ]
  # MySQL password generated (hex, 32 chars)
  pw="$(grep -E '^XIAOZHI_MYSQL_PASSWORD=' "$AIBOX_HOME/apps/xiaozhi/.env" | cut -d= -f2-)"
  [ "${#pw}" -ge 32 ]
  # .env mode 600
  # GNU-first order: GNU stat -f prints filesystem garbage with exit 0 (the BSD
  # meaning of -f differs) — see tests/upgrade.bats for the proven pattern.
  [ "$(stat -c '%a' "$AIBOX_HOME/apps/xiaozhi/.env" 2>/dev/null || stat -f '%Lp' "$AIBOX_HOME/apps/xiaozhi/.env")" = "600" ]
  # .config.yaml contract: manager-api url → the web container, secret empty,
  # device-facing ws URL with a LAN IP, ports from the defaults
  cfg="$AIBOX_HOME/apps/xiaozhi/data/.config.yaml"
  grep -q '^  websocket: ws://[0-9.]*:8000/xiaozhi/v1/$' "$cfg"
  grep -q '^  http_port: 8003$' "$cfg"
  grep -q '^  vision_explain: http://[0-9.]*:8003/mcp/vision/explain$' "$cfg"
  grep -q '^  url: http://aibox-xiaozhi-web:8002/xiaozhi$' "$cfg"
  grep -q '^  secret: ""$' "$cfg"
  # regression: the heredoc is UNQUOTED — unescaped backticks in comments would
  # run as command substitution and eat the text (measured live on the deploy
  # host: `aibox xiaozhi start` executed → die → empty comment)
  grep -q 'aibox xiaozhi start' "$cfg"

  # --- second run: .env AND .config.yaml are never clobbered ---
  echo "# user marker" >>"$AIBOX_HOME/apps/xiaozhi/.env"
  echo "# user marker" >>"$cfg"
  run bash "$REPO_ROOT/tools/xiaozhi/install.sh"
  [ "$status" -eq 0 ]
  grep -q '^# user marker$' "$AIBOX_HOME/apps/xiaozhi/.env"
  grep -q '^# user marker$' "$cfg"
}

@test "effective ports: defaults + XIAOZHI_*_PORT overrides honored" {
  [ "$(effective_ws_port)" = "8000" ]
  [ "$(effective_console_port)" = "8002" ]
  [ "$(effective_http_port)" = "8003" ]
  XIAOZHI_WS_PORT=18000 XIAOZHI_CONSOLE_PORT=18002 XIAOZHI_HTTP_PORT=18003
  [ "$(effective_ws_port)" = "18000" ]
  [ "$(effective_console_port)" = "18002" ]
  [ "$(effective_http_port)" = "18003" ]
}

@test "_ghcr_mirror_ref: only ghcr.io refs get mirror-prefixed; docker.io/ form handled by the docker.io pool" {
  [ "$(_ghcr_mirror_ref ghcr.nju.edu.cn "ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_0.9.6")" = "ghcr.nju.edu.cn/xinnan-tech/xiaozhi-esp32-server:server_0.9.6" ]
  [ -z "$(_ghcr_mirror_ref ghcr.nju.edu.cn "mysql:8.0")" ]
  [ -z "$(_ghcr_mirror_ref ghcr.nju.edu.cn "docker.io/library/mysql:8.0")" ]
  # regression: the explicit docker.io/ prefix is the default registry (not
  # foreign) and its mirror ref strips the prefix (windmill's branch-order rule)
  _dk_is_dockerio "docker.io/library/mysql:8.0"
  [ "$(_dk_pool_ref docker.1ms.run "docker.io/library/mysql:8.0")" = "docker.1ms.run/library/mysql:8.0" ]
}

@test "ghcr pool: everything cached → no-op, zero pulls" {
  printf '%s\n' "ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_0.9.6" "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6" >>"$FAKE_DOCKER_CACHED"
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_0.9.6" "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  [ "$(grep -c PULL "$FAKE_DOCKER_PULLLOG")" = "0" ]
}

@test "ghcr pool: direct dead → mirror pre-pull + tag to the official refs" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_GHCR_DIRECT_TIMEOUT=2 AIBOX_GHCR_PULL_TIMEOUT=5
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  # came via a ghcr mirror…
  grep -qE 'PULL (ghcr\.nju\.edu\.cn|ghcr\.dockerproxy\.net)/xinnan-tech/xiaozhi-esp32-server:web_0\.9\.6$' "$FAKE_DOCKER_PULLLOG"
  # …and was tagged back to the official ref
  grep -qE '^[a-z.]+/xinnan-tech/xiaozhi-esp32-server:web_0\.9\.6 ghcr\.io/xinnan-tech/xiaozhi-esp32-server:web_0\.9\.6$' "$FAKE_DOCKER_TAGLOG"
}

@test "ghcr pool: first mirror dead → failover to the second" {
  export FAKE_DOCKER_DIRECT_MODE=dead FAKE_DOCKER_GHCRNJU_MODE=dead
  export AIBOX_GHCR_POOL="ghcr.nju.edu.cn ghcr.dockerproxy.net"
  export AIBOX_GHCR_DIRECT_TIMEOUT=2 AIBOX_GHCR_PULL_TIMEOUT=5
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  grep -q 'PULL ghcr.nju.edu.cn/' "$FAKE_DOCKER_PULLLOG"
  grep -q 'PULL ghcr.dockerproxy.net/xinnan-tech/xiaozhi-esp32-server:web_0.9.6' "$FAKE_DOCKER_PULLLOG"
  grep -qE 'ghcr\.dockerproxy\.net/xinnan-tech/xiaozhi-esp32-server:web_0\.9\.6 ghcr\.io/xinnan-tech/xiaozhi-esp32-server:web_0\.9\.6$' "$FAKE_DOCKER_TAGLOG"
}

@test "ghcr pool: non-ghcr refs (mysql) are NOT routed through the ghcr pool" {
  run ghcr_pool_prepull "mysql:8.0"
  [ "$status" -eq 0 ]
  [ "$(grep -c PULL "$FAKE_DOCKER_PULLLOG")" = "0" ]   # filtered out, nothing pulled
}

@test "docker.io pool: mysql goes through the ranked-mirror pool when direct is dead" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_DOCKER_PROBE_TIMEOUT=2 AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT=5 AIBOX_DOCKER_PULL_TIMEOUT=5
  run docker_pool_prepull "mysql:8.0"
  [ "$status" -eq 0 ]
  grep -qE 'PULL (docker\.1ms\.run|docker\.m\.daocloud\.io|dockerproxy\.net|hub\.rat\.dev)/library/mysql:8\.0$' "$FAKE_DOCKER_PULLLOG"
  grep -qE '^[a-z0-9.]+/library/mysql:8\.0 mysql:8\.0$' "$FAKE_DOCKER_TAGLOG"
}

@test "_fetch_secret: generated value returned; 'null'/empty → unavailable" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/xiaozhi/install.sh" >/dev/null 2>&1
  # needs the deploy .env (password) — install created it.
  # FAKE_MYSQL_SECRET must be EXPORTED: the fake docker shim is a subprocess.
  export FAKE_MYSQL_SECRET="80c156-secret-value-0123456789"
  [ "$(_fetch_secret)" = "80c156-secret-value-0123456789" ]
  export FAKE_MYSQL_SECRET=""
  ! _fetch_secret
  export FAKE_MYSQL_SECRET="null"
  ! _fetch_secret
  unset FAKE_MYSQL_SECRET
}

@test "_write_secret + auto-apply flow: empty secret → filled from MySQL; user-set → kept" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/xiaozhi/install.sh" >/dev/null 2>&1
  cfg="$AIBOX_HOME/apps/xiaozhi/data/.config.yaml"
  # auto-apply: .config.yaml secret empty → fetched value lands in the file
  FAKE_MYSQL_SECRET="generated-secret-abc"
  bash "$REPO_ROOT/tools/xiaozhi/svc.sh" secret "generated-secret-abc" >/dev/null 2>&1 || true
  _write_secret "generated-secret-abc"
  grep -q '^  secret: "generated-secret-abc"$' "$cfg"
  # replace (not duplicate) on a second write
  _write_secret "rotated-secret-xyz"
  [ "$(grep -c '  secret:' "$cfg")" = "1" ]
  grep -q '^  secret: "rotated-secret-xyz"$' "$cfg"
}

@test "secret action: writes manager-api.secret + restarts the server container" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/xiaozhi/install.sh" >/dev/null 2>&1
  export FAKE_DOCKER_PS="aibox-xiaozhi-server aibox-xiaozhi-web"
  run bash "$REPO_ROOT/tools/xiaozhi/svc.sh" secret my-secret-value-123
  [ "$status" -eq 0 ]
  grep -q '^  secret: "my-secret-value-123"$' "$AIBOX_HOME/apps/xiaozhi/data/.config.yaml"
  grep -q 'RESTART aibox-xiaozhi-server' "$FAKE_DOCKER_PULLLOG"
  # re-set: replaces (does not duplicate) the secret line
  run bash "$REPO_ROOT/tools/xiaozhi/svc.sh" secret newer-value-456
  [ "$status" -eq 0 ]
  [ "$(grep -c '  secret:' "$AIBOX_HOME/apps/xiaozhi/data/.config.yaml")" = "1" ]
  grep -q '^  secret: "newer-value-456"$' "$AIBOX_HOME/apps/xiaozhi/data/.config.yaml"
}

@test "secret action: no value → usage error" {
  run bash "$REPO_ROOT/tools/xiaozhi/svc.sh" secret
  [ "$status" -ne 0 ]
}

@test "dashboard_info: emits version/endpoint/credential/ws/db/health fields" {
  export PATH="$FAKEBIN:$PATH"
  unset XIAOZHI_CONSOLE_PORT || true
  out="$(dashboard_info)"
  printf '%s\n' "$out" | grep -q '^version=0\.9\.6 / 0\.9\.6$'
  printf '%s\n' "$out" | grep -q '^endpoint=http://127\.0\.0\.1:8002$'
  printf '%s\n' "$out" | grep -q '^credential=console: first registered user becomes the super admin'
  printf '%s\n' "$out" | grep -q '^ws=ws://[0-9.]*:8000/xiaozhi/v1/'
  printf '%s\n' "$out" | grep -q '^db=bundled MySQL mysql:8\.0 + shared base redis'
  printf '%s\n' "$out" | grep -q '^health=stopped'     # fake docker ps: empty
}

@test "render_dashboard: keyline header (server/web app versions) + sunk module row" {
  run bash -c ". '$REPO_ROOT/tools/xiaozhi/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"· module"* ]] || false
  [[ "$output" == *"xiaozhi 0.9.6 / 0.9.6"* ]] || false
  [[ "$output" == *"module"*"·"*"modules/xiaozhi/"* ]] || false
}

@test "uninstall: removes compose, PRESERVES data/.config.yaml + .env + volumes by default" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/xiaozhi/install.sh" >/dev/null 2>&1
  run bash "$REPO_ROOT/tools/xiaozhi/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$AIBOX_HOME/apps/xiaozhi/docker-compose.yml" ]
  [ -f "$AIBOX_HOME/apps/xiaozhi/.env" ]                    # MySQL password preserved
  [ -f "$AIBOX_HOME/apps/xiaozhi/data/.config.yaml" ]       # user's secret preserved
}

@test "uninstall --purge (AIBOX_PURGE_DATA=1): removes the deploy root entirely" {
  export PATH="$FAKEBIN:$PATH"
  bash "$REPO_ROOT/tools/xiaozhi/install.sh" >/dev/null 2>&1
  AIBOX_PURGE_DATA=1 run bash "$REPO_ROOT/tools/xiaozhi/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -d "$AIBOX_HOME/apps/xiaozhi" ]
}

@test "compose: joins the external base network + injects base.env/secret vars (compose file contract)" {
  y="$REPO_ROOT/tools/xiaozhi/docker-compose.yml"
  # web: shared-base redis from base.env
  grep -q 'SPRING_DATA_REDIS_HOST=\${AIBOX_REDIS_HOST}' "$y" || { echo "$output"; false; }
  grep -q 'SPRING_DATA_REDIS_PORT=\${AIBOX_REDIS_PORT}' "$y" || false
  # redis auth + this module's logical DB (2026-09 review: auth on, one slot each)
  grep -q 'SPRING_DATA_REDIS_PASSWORD=\${AIBOX_REDIS_PASSWORD}' "$y" || false
  grep -q 'SPRING_DATA_REDIS_DATABASE=\${AIBOX_REDIS_DB:-0}' "$y" || false
  grep -q 'name: \${AIBOX_BASE_NETWORK:-aibox-base}' "$y"
  grep -q 'external: true' "$y"
  # web: mysql password from the deploy .env
  grep -q 'SPRING_DATASOURCE_DRUID_PASSWORD=\${XIAOZHI_MYSQL_PASSWORD}' "$y"
  grep -q 'MYSQL_ROOT_PASSWORD=\${XIAOZHI_MYSQL_PASSWORD}' "$y"
  # three services, upstream container names, upstream ports
  grep -q 'container_name: aibox-xiaozhi-server' "$y"
  grep -q 'container_name: aibox-xiaozhi-web' "$y"
  grep -q 'container_name: aibox-xiaozhi-mysql' "$y"
  grep -q '"\${XIAOZHI_WS_PORT:-8000}:8000"' "$y"
  grep -q '"\${XIAOZHI_CONSOLE_PORT:-8002}:8002"' "$y"
  grep -q '"\${XIAOZHI_HTTP_PORT:-8003}:8003"' "$y"
  # volumes with deterministic names
  grep -q 'name: \${XIAOZHI_MODELS_VOLUME:-aibox_xiaozhi_models}' "$y"
  grep -q 'name: \${XIAOZHI_UPLOAD_VOLUME:-aibox_xiaozhi_uploadfile}' "$y"
  grep -q 'name: \${XIAOZHI_MYSQL_VOLUME:-aibox_xiaozhi_mysql}' "$y"
  # upstream-faithful bits: seccomp, data bind mount, utf8mb4, healthcheck
  grep -q 'seccomp:unconfined' "$y"
  grep -q '\./data:/opt/xiaozhi-esp32-server/data' "$y"
  grep -q 'character-set-server=utf8mb4' "$y"
  grep -q 'mysqladmin' "$y"
  # no hardcoded credentials (validator also scans; assert here)
  ! grep -qE '(PASSWORD|SECRET)=[^$]' "$y"
}

@test "render_dashboard: no docker → degrades, exit 0 under set -euo pipefail" {
  run bash -c "set -euo pipefail; PATH=/usr/bin:/bin; . '$REPO_ROOT/tools/xiaozhi/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"not running (aibox xiaozhi start)"* ]] || false
}

# ---------- GHCR family: sticky-winner cache (dockerpool.cache, GHCR family) ----------

@test "GHCR cache: mirror win persists the sticky order (winner first)" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_GHCR_POOL="ghcr.nju.edu.cn ghcr.dockerproxy.net"
  export AIBOX_GHCR_DIRECT_TIMEOUT=2 AIBOX_GHCR_PULL_TIMEOUT=5
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  [ -f "$AIBOX_HOME/dockerpool.cache" ] || false
  [ "$(_dkcache_read GHCR)" = "ghcr.nju.edu.cn ghcr.dockerproxy.net" ] || false
}

@test "GHCR cache: sticky entry skips the dead direct route on the next run" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_GHCR_POOL="ghcr.nju.edu.cn ghcr.dockerproxy.net"
  export AIBOX_GHCR_DIRECT_TIMEOUT=2 AIBOX_GHCR_PULL_TIMEOUT=5
  ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6" >/dev/null 2>&1
  docker rmi "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6" >/dev/null 2>&1 || true
  : >"$FAKE_DOCKER_PULLLOG"
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  # the direct attempt (bare ghcr.io/… ref) must be SKIPPED — known dead within TTL
  if grep -q '^PULL ghcr\.io/' "$FAKE_DOCKER_PULLLOG"; then
    echo "unexpected direct attempt: $(cat "$FAKE_DOCKER_PULLLOG")"
    false
  fi
  grep -q '^PULL ghcr\.nju\.edu\.cn/' "$FAKE_DOCKER_PULLLOG" || false
}

@test "GHCR cache: direct healthy → recorded as direct, mirrors not engaged" {
  export FAKE_DOCKER_DIRECT_MODE=ok
  export AIBOX_GHCR_DIRECT_TIMEOUT=2 AIBOX_GHCR_PULL_TIMEOUT=5
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  [ "$(_dkcache_read GHCR)" = "direct" ] || false
  grep -q '^PULL ghcr\.io/xinnan-tech/xiaozhi-esp32-server:web_0\.9\.6$' "$FAKE_DOCKER_PULLLOG" || false
}

@test "GHCR cache: all mirrors dead → entry invalidated (self-heal → direct retried next run)" {
  export FAKE_DOCKER_DIRECT_MODE=dead FAKE_DOCKER_GHCRNJU_MODE=dead FAKE_DOCKER_GHDPROXY_MODE=dead
  export AIBOX_GHCR_POOL="ghcr.nju.edu.cn ghcr.dockerproxy.net"
  export AIBOX_GHCR_DIRECT_TIMEOUT=1 AIBOX_GHCR_PULL_TIMEOUT=2
  run ghcr_pool_prepull "ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6"
  [ "$status" -eq 0 ]
  if grep -q $'^GHCR\t' "$AIBOX_HOME/dockerpool.cache" 2>/dev/null; then
    echo "cache not invalidated: $(cat "$AIBOX_HOME/dockerpool.cache")"
    false
  fi
}

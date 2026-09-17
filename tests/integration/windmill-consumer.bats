#!/usr/bin/env bats
# Integration: windmill consumer-chain E2E under a named profile.
# FLAG-GATED (AIBOX_IT_WINDMILL=1): pulls ~6GB of ghcr.io images and runs a full
# Windmill deploy — run manually on a throwaway host with time/bandwidth.
# Distilled from the live 2026-09 test on root@192.168.50.88:
#   --profile prod windmill init → DATABASE_URL@aibox-base-prod-postgres, containers on
#   the aibox-base-prod network, server healthy, UI 200 — alongside the default deploy.
# Also the regression test for the shared-PG health-gate bug (init used to die with
# "Deploy did not pass the health check" because it required the replicas:0 db service).
#
# Uses a unique test profile (itwm) so it coexists with real deployments.

setup_file() {
  [ -n "${AIBOX_IT_WINDMILL:-}" ] || skip "set AIBOX_IT_WINDMILL=1 to run (pulls ~6GB images)"
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  SANDBOX="$(mktemp -d 2>/dev/null || echo /tmp/aibox-it-wm.$$)"
  export SANDBOX
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT"
  export WM_DIR="$AIBOX_HOME/apps/windmill-itwm"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR"
  docker volume ls --format '{{.Name}}' | sort > "$SANDBOX/volumes.before"

  # Pick a free UI port (8081+).
  UI_PORT=""
  for p in 8081 8082 8083 8084 8085; do
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then continue; fi
    UI_PORT="$p"; break
  done
  [ -n "$UI_PORT" ] || skip "no free UI port in 8081-8085"
  export UI_PORT

  # Derived base ports for itwm must be free.
  AIBOX_PROFILE=itwm bash -c "source '$REPO_ROOT/tools/base/lib.sh'; echo \$PG_PORT \$REDIS_PORT" | tail -1 > "$SANDBOX/ports.itwm"
  read -r PG_PORT RD_PORT < "$SANDBOX/ports.itwm"
  for p in "$PG_PORT" "$RD_PORT"; do
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      skip "derived test port $p occupied"
    fi
  done

  # Shared base under the test profile + the windmill DB (ensure_services would do this
  # on install; do it explicitly so the chain is visible).
  bash "$REPO_ROOT/bin/aibox" --profile itwm install base > "$SANDBOX/base-i.log" 2>&1 || { cat "$SANDBOX/base-i.log"; return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile itwm base start   > "$SANDBOX/base-s.log" 2>&1 || { cat "$SANDBOX/base-s.log";   return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile itwm install windmill > "$SANDBOX/wm-i.log" 2>&1 || { cat "$SANDBOX/wm-i.log"; return 1; }
  # THE init under test (health gate must pass in shared-PG mode — bug #5 regression).
  bash "$REPO_ROOT/bin/aibox" --profile itwm windmill -d "$WM_DIR" --port "$UI_PORT" init --yes > "$SANDBOX/wm-init.log" 2>&1
  echo "$?" > "$SANDBOX/wm-init.exit"
}

teardown_file() {
  [ -n "${SANDBOX:-}" ] || return 0
  bash "$REPO_ROOT/bin/aibox" --profile itwm windmill -d "$AIBOX_HOME/apps/windmill-itwm" destroy --yes >/dev/null 2>&1 || true
  bash "$REPO_ROOT/bin/aibox" --profile itwm base stop >/dev/null 2>&1 || true
  docker ps -a --format '{{.Names}}' | grep -E '^(windmill-itwm-|aibox-base-itwm-)' | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm aibox-base-itwm windmill-itwm_default >/dev/null 2>&1 || true
  if [ -f "$SANDBOX/volumes.before" ]; then
    docker volume ls --format '{{.Name}}' | sort > "$SANDBOX/volumes.after"
    comm -13 "$SANDBOX/volumes.before" "$SANDBOX/volumes.after" | while IFS= read -r v; do
      case "$v" in aibox_*_itwm|windmill-itwm_*) docker volume rm "$v" >/dev/null 2>&1 || true ;; esac
    done
  fi
  rm -rf "$SANDBOX"
}

@test "init under a named profile passes the health gate (shared-PG bug #5 regression)" {
  [ -f "$SANDBOX/wm-init.exit" ] || skip "setup did not reach init"
  [ "$(cat "$SANDBOX/wm-init.exit")" = "0" ] || { tail -30 "$SANDBOX/wm-init.log"; false; }
}

@test "generated .env points at the PROFILE's base PG (consumer chain)" {
  grep -q "^DATABASE_URL=.*@aibox-base-itwm-postgres:5432/windmill$" "$WM_DIR/.env"
}

@test "windmill containers joined the profile network alongside the base containers" {
  members="$(docker network inspect aibox-base-itwm --format '{{range .Containers}}{{.Name}} {{end}}')"
  [[ "$members" == *aibox-base-itwm-postgres* ]]
  [[ "$members" == *windmill_server* ]]
}

@test "UI answers on the chosen port and status passes" {
  code="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$UI_PORT/" || echo 000)"
  [ "$code" != "000" ]
  run bash "$REPO_ROOT/bin/aibox" --profile itwm windmill -d "$WM_DIR" status
  [ "$status" -eq 0 ]
  [[ "$output" != *"not ready"* ]]
}

#!/usr/bin/env bats
# Integration: base multi-profile E2E (requires docker; runs on any docker host).
#
# Distills the live-machine scenarios from the 2026-09 functional test on
# root@192.168.50.88: two base stacks coexisting with hash-derived ports/names,
# env-file per profile, DB + network isolation, idempotent create, deprecated alias.
#
# SAFETY: uses unique test profiles (itta/ittb) — never the "base"/"prod" names — so
# it coexists with real deployments on the same host. Teardown removes only the
# docker objects it created (volume snapshot diff).

setup_file() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  SANDBOX="$(mktemp -d 2>/dev/null || echo /tmp/aibox-it-base.$$)"
  export SANDBOX
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR"

  # Snapshot pre-existing docker volumes so teardown never deletes real data.
  docker volume ls --format '{{.Name}}' | sort > "$SANDBOX/volumes.before"

  # Derive the expected ports for itta/ittb via the real lib (also creates the confs).
  # tail -1: _profile_create logs "Created profile..." to stdout on first use — take only
  # the final "PG_PORT REDIS_PORT" line.
  AIBOX_PROFILE=itta bash -c "source '$REPO_ROOT/tools/base/lib.sh'; echo \$PG_PORT \$REDIS_PORT" | tail -1 > "$SANDBOX/ports.itta"
  AIBOX_PROFILE=ittb bash -c "source '$REPO_ROOT/tools/base/lib.sh'; echo \$PG_PORT \$REDIS_PORT" | tail -1 > "$SANDBOX/ports.ittb"
  read -r PG_A RD_A < "$SANDBOX/ports.itta"
  read -r PG_B RD_B < "$SANDBOX/ports.ittb"
  [ "$PG_A" != "$PG_B" ] || skip "test profile port collision (itta/ittb)"
  for p in "$PG_A" "$RD_A" "$PG_B" "$RD_B"; do
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      skip "port $p occupied — run on a host with the derived test ports free"
    fi
  done

  # Bring up both stacks.
  bash "$REPO_ROOT/bin/aibox" --profile itta install base > "$SANDBOX/install.itta.log" 2>&1 || { cat "$SANDBOX/install.itta.log"; return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile itta base start   > "$SANDBOX/start.itta.log"   2>&1 || { cat "$SANDBOX/start.itta.log";   return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile ittb install base > "$SANDBOX/install.ittb.log" 2>&1 || { cat "$SANDBOX/install.ittb.log"; return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile ittb base start   > "$SANDBOX/start.ittb.log"   2>&1 || { cat "$SANDBOX/start.ittb.log";   return 1; }
}

teardown_file() {
  [ -n "${SANDBOX:-}" ] || return 0
  # Stop the test stacks (best effort), then remove only what we created.
  bash "$REPO_ROOT/bin/aibox" --profile itta base stop >/dev/null 2>&1 || true
  bash "$REPO_ROOT/bin/aibox" --profile ittb base stop >/dev/null 2>&1 || true
  docker rm -f aibox-base-itta-postgres aibox-base-itta-redis aibox-base-ittb-postgres aibox-base-ittb-redis >/dev/null 2>&1 || true
  docker network rm aibox-base-itta aibox-base-ittb >/dev/null 2>&1 || true
  if [ -f "$SANDBOX/volumes.before" ]; then
    docker volume ls --format '{{.Name}}' | sort > "$SANDBOX/volumes.after"
    comm -13 "$SANDBOX/volumes.before" "$SANDBOX/volumes.after" | while IFS= read -r v; do
      case "$v" in aibox_pg_data_itt*|aibox_redis_data_itt*) docker volume rm "$v" >/dev/null 2>&1 || true ;; esac
    done
  fi
  rm -rf "$SANDBOX"
}

@test "both stacks coexist: containers running with profile-derived names" {
  docker ps --format '{{.Names}}' | grep -qx aibox-base-itta-postgres
  docker ps --format '{{.Names}}' | grep -qx aibox-base-itta-redis
  docker ps --format '{{.Names}}' | grep -qx aibox-base-ittb-postgres
  docker ps --format '{{.Names}}' | grep -qx aibox-base-ittb-redis
}

@test "host ports match the deterministic derivation (itta/ittb)" {
  read -r PG_A RD_A < "$SANDBOX/ports.itta"
  read -r PG_B RD_B < "$SANDBOX/ports.ittb"
  docker port aibox-base-itta-postgres 5432/tcp | grep -q ":$PG_A"
  docker port aibox-base-itta-redis    6379/tcp | grep -q ":$RD_A"
  docker port aibox-base-ittb-postgres 5432/tcp | grep -q ":$PG_B"
  docker port aibox-base-ittb-redis    6379/tcp | grep -q ":$RD_B"
}

@test "per-profile env files: correct host + network, default base.env untouched" {
  grep -q '^AIBOX_POSTGRES_HOST=aibox-base-itta-postgres$' "$AIBOX_HOME/base-itta.env"
  grep -q '^AIBOX_BASE_NETWORK=aibox-base-itta$'           "$AIBOX_HOME/base-itta.env"
  grep -q '^AIBOX_POSTGRES_HOST=aibox-base-ittb-postgres$' "$AIBOX_HOME/base-ittb.env"
  grep -q '^AIBOX_BASE_NETWORK=aibox-base-ittb$'           "$AIBOX_HOME/base-ittb.env"
  # the default profile was never started → no default env file
  [ ! -f "$AIBOX_HOME/base.env" ]
}

@test "volumes are distinct per profile" {
  docker volume ls --format '{{.Name}}' | grep -qx aibox_pg_data_itta
  docker volume ls --format '{{.Name}}' | grep -qx aibox_pg_data_ittb
  docker volume ls --format '{{.Name}}' | grep -qx aibox_redis_data_itta
  docker volume ls --format '{{.Name}}' | grep -qx aibox_redis_data_ittb
}

@test "DB isolation: a fresh db in itta exists ONLY in itta's PG" {
  FRESH="itdb$$"
  run bash "$REPO_ROOT/bin/aibox" --profile itta base create postgres "$FRESH"
  [ "$status" -eq 0 ]
  # createdb waits for PG readiness now (pg_isready loop) — no manual sleep needed
  run docker exec aibox-base-itta-postgres psql -U aibox -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$FRESH'"
  [ "$output" = "1" ]
  run docker exec aibox-base-ittb-postgres psql -U aibox -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$FRESH'"
  [ "$output" = "0" ]
  # idempotent re-run
  run bash "$REPO_ROOT/bin/aibox" --profile itta base create postgres "$FRESH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  # deprecated createdb alias still works (warns)
  run bash "$REPO_ROOT/bin/aibox" --profile itta base createdb "${FRESH}2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deprecated"* ]]
  docker exec aibox-base-itta-postgres psql -U aibox -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='${FRESH}2'" | grep -qx 1
}

@test "networks isolated: itta network contains only itta containers" {
  members="$(docker network inspect aibox-base-itta --format '{{range .Containers}}{{.Name}} {{end}}')"
  [[ "$members" == *aibox-base-itta-postgres* ]]
  [[ "$members" != *ittb* ]]
}

@test "profile list shows both test profiles with derived ports" {
  read -r PG_A RD_A < "$SANDBOX/ports.itta"
  # run under an installed profile (the action gate requires base installed for the
  # ACTIVE profile; the list itself reads $AIBOX_HOME/profiles/ — all profiles)
  run bash "$REPO_ROOT/bin/aibox" --profile itta base profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"itta"* ]]
  [[ "$output" == *"$PG_A"* ]]
  [[ "$output" == *"ittb"* ]]
}

@test "per-profile status reports its own endpoints" {
  read -r PG_A RD_A < "$SANDBOX/ports.itta"
  run bash "$REPO_ROOT/bin/aibox" --profile itta base status
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:$PG_A"* ]]
  [[ "$output" != *aibox-base-ittb* ]]
}

@test "shared-base contract: both profiles publish the contract keys + Redis auth + slots" {
  local p env pw
  for p in itta ittb; do
    env="$AIBOX_HOME/base-$p.env"
    [ -f "$env" ] || { echo "no contract file for $p"; false; }
    grep -q '^AIBOX_BASE_ENV_VERSION=1$' "$env" || { cat "$env"; false; }
    grep -q "^AIBOX_BASE_PROFILE=$p$" "$env" || { cat "$env"; false; }
    grep -q '^AIBOX_BASE_MODULE_VERSION=1\.' "$env" || false
    grep -q '^AIBOX_BASE_READY=1$' "$env" || false
    grep -q '^AIBOX_REDIS_PASSWORD=..*' "$env" || { echo "no redis password in $env"; false; }
  done
  pw="$(grep -m1 '^AIBOX_REDIS_PASSWORD=' "$AIBOX_HOME/base-itta.env" | cut -d= -f2-)"
  # authenticated PING works …
  run docker exec aibox-base-itta-redis redis-cli --no-auth-warning -a "$pw" PING
  [[ "$output" == *PONG* ]] || { echo "authenticated PING failed: $output"; false; }
  # … and an unauthenticated client is rejected (auth is really ON)
  run docker exec aibox-base-itta-redis redis-cli PING
  [[ "$output" == *NOAUTH* || "$status" -ne 0 ]] || { echo "unauthenticated command accepted: $output"; false; }

  # per-profile Redis slots are independent + written where the consumer reads them
  run bash "$REPO_ROOT/bin/aibox" --profile itta base create redis xiaozhi
  [[ "$output" == *"Redis logical DB for xiaozhi: 1"* ]] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/redis-itta-xiaozhi.env" ] || { echo "no per-profile redis env"; false; }
  run bash "$REPO_ROOT/bin/aibox" --profile ittb base create redis dify 3
  [[ "$output" == *"Redis logical DB for dify: 1"* ]] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/redis-ittb-dify.env" ] || false
  # the two profiles' registries are separate files (no cross-profile bleed)
  [ -f "$AIBOX_HOME/apps/base-itta/redis-dbs.conf" ] || { echo "itta registry missing"; false; }
  [ -f "$AIBOX_HOME/apps/base-ittb/redis-dbs.conf" ] || false
}

@test "host ports bind to 127.0.0.1 by default (admin DB not exposed on the LAN)" {
  local binding
  binding="$(docker port aibox-base-itta-postgres 2>/dev/null | head -1)"
  [ -n "$binding" ] || { echo "no port binding reported"; false; }
  [[ "$binding" == *"-> 127.0.0.1:"* ]] || { echo "postgres published as '${binding}' (expected 127.0.0.1)"; false; }
}

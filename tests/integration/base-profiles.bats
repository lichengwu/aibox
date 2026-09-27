#!/usr/bin/env bats
# Integration: base multi-profile E2E (requires docker; runs on any docker host).
#
# Distills the live-machine scenarios from the 2026-09 functional test on
# root@192.168.50.88: two base stacks coexisting with hash-derived ports/names,
# env-file per profile, DB + network isolation, idempotent create, deprecated alias.
#
# SAFETY: unique test profiles (ittaN, chosen so their derived ports are FREE here) —
# never the "base"/"prod" names — so
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

  # Pick test profile names whose DERIVED slots are FREE on this host. A real
  # deployment may already hold the slot a candidate hashes to — the
  # profile-conflict gate then refuses to start (that IS the feature), so the test
  # asks first instead of tripping over it. Never the "base"/"prod" names.
  _ports_of() { # $1=profile → "PG REDIS" (tail -1: the lib logs on first create)
    AIBOX_PROFILE="$1" bash -c "source '$REPO_ROOT/tools/base/lib.sh'; echo \$PG_PORT \$REDIS_PORT" | tail -1
  }
  _slot_free() { # $1=profile → 0 when both derived ports are free
    local pg rd prt
    read -r pg rd <<< "$(_ports_of "$1")"
    for prt in "$pg" "$rd"; do
      # lsof-free probe: a minimal container has no lsof, and the old check then
      # silently passed — docker died with "Bind for 127.0.0.1:35177 failed"
      if (exec 4<>"/dev/tcp/127.0.0.1/${prt}") 2>/dev/null; then
        exec 4>&- 2>/dev/null || true
        return 1
      fi
    done
    return 0
  }
  PROF_A=""
  PROF_B=""
  i=0
  while [ "$i" -lt 60 ]; do
    if [ -z "$PROF_B" ] && _slot_free "itta$i"; then
      if [ -z "$PROF_A" ]; then
        PROF_A="itta$i"
      else
        PROF_B="itta$i"
      fi
    fi
    i=$(( i + 1 ))
  done
  [ -n "$PROF_A" ] && [ -n "$PROF_B" ] || skip "no free profile slots on this host (60 candidates tried)"
  export PROF_A PROF_B
  read -r PG_A RD_A <<< "$(_ports_of "$PROF_A")"
  read -r PG_B RD_B <<< "$(_ports_of "$PROF_B")"
  [ "$PG_A" != "$PG_B" ] || skip "test profile port collision (${PROF_A}/${PROF_B})"

  # Bring up both stacks.
  bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" install base > "$SANDBOX/install.${PROF_A}.log" 2>&1 || { cat "$SANDBOX/install.${PROF_A}.log"; return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base start   > "$SANDBOX/start.${PROF_A}.log"   2>&1 || { cat "$SANDBOX/start.${PROF_A}.log";   return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile "$PROF_B" install base > "$SANDBOX/install.${PROF_B}.log" 2>&1 || { cat "$SANDBOX/install.${PROF_B}.log"; return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile "$PROF_B" base start   > "$SANDBOX/start.${PROF_B}.log"   2>&1 || { cat "$SANDBOX/start.${PROF_B}.log";   return 1; }
}

teardown_file() {
  [ -n "${SANDBOX:-}" ] || return 0
  # Stop the test stacks (best effort), then remove only what we created.
  bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base stop >/dev/null 2>&1 || true
  bash "$REPO_ROOT/bin/aibox" --profile "$PROF_B" base stop >/dev/null 2>&1 || true
  docker rm -f aibox-base-${PROF_A}-postgres aibox-base-${PROF_A}-redis aibox-base-${PROF_B}-postgres aibox-base-${PROF_B}-redis >/dev/null 2>&1 || true
  docker network rm aibox-base-${PROF_A} aibox-base-${PROF_B} >/dev/null 2>&1 || true
  if [ -f "$SANDBOX/volumes.before" ]; then
    docker volume ls --format '{{.Name}}' | sort > "$SANDBOX/volumes.after"
    comm -13 "$SANDBOX/volumes.before" "$SANDBOX/volumes.after" | while IFS= read -r v; do
      case "$v" in aibox_pg_data_itt*|aibox_redis_data_itt*) docker volume rm "$v" >/dev/null 2>&1 || true ;; esac
    done
  fi
  rm -rf "$SANDBOX"
}

@test "both stacks coexist: containers running with profile-derived names" {
  docker ps --format '{{.Names}}' | grep -qx aibox-base-${PROF_A}-postgres
  docker ps --format '{{.Names}}' | grep -qx aibox-base-${PROF_A}-redis
  docker ps --format '{{.Names}}' | grep -qx aibox-base-${PROF_B}-postgres
  docker ps --format '{{.Names}}' | grep -qx aibox-base-${PROF_B}-redis
}

@test "host ports match the deterministic derivation (${PROF_A}/${PROF_B})" {
  read -r PG_A RD_A <<< "$(_ports_of "${PROF_A}")"
  read -r PG_B RD_B <<< "$(_ports_of "${PROF_B}")"
  docker port aibox-base-${PROF_A}-postgres 5432/tcp | grep -q ":$PG_A"
  docker port aibox-base-${PROF_A}-redis    6379/tcp | grep -q ":$RD_A"
  docker port aibox-base-${PROF_B}-postgres 5432/tcp | grep -q ":$PG_B"
  docker port aibox-base-${PROF_B}-redis    6379/tcp | grep -q ":$RD_B"
}

@test "per-profile env files: correct host + network, default base.env untouched" {
  grep -q "^AIBOX_POSTGRES_HOST=aibox-base-${PROF_A}-postgres$" "$AIBOX_HOME/base-${PROF_A}.env"
  grep -q "^AIBOX_BASE_NETWORK=aibox-base-${PROF_A}$"           "$AIBOX_HOME/base-${PROF_A}.env"
  grep -q "^AIBOX_POSTGRES_HOST=aibox-base-${PROF_B}-postgres$" "$AIBOX_HOME/base-${PROF_B}.env"
  grep -q "^AIBOX_BASE_NETWORK=aibox-base-${PROF_B}$"           "$AIBOX_HOME/base-${PROF_B}.env"
  # the default profile was never started → no default env file
  [ ! -f "$AIBOX_HOME/base.env" ]
}

@test "volumes are distinct per profile" {
  docker volume ls --format '{{.Name}}' | grep -qx aibox_pg_data_${PROF_A}
  docker volume ls --format '{{.Name}}' | grep -qx aibox_pg_data_${PROF_B}
  docker volume ls --format '{{.Name}}' | grep -qx aibox_redis_data_${PROF_A}
  docker volume ls --format '{{.Name}}' | grep -qx aibox_redis_data_${PROF_B}
}

@test "DB isolation: a fresh db in ${PROF_A} exists ONLY in ${PROF_A}'s PG" {
  FRESH="itdb$$"
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base create postgres "$FRESH"
  [ "$status" -eq 0 ]
  # createdb waits for PG readiness now (pg_isready loop) — no manual sleep needed
  run docker exec aibox-base-${PROF_A}-postgres psql -U aibox -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$FRESH'"
  [ "$output" = "1" ]
  run docker exec aibox-base-${PROF_B}-postgres psql -U aibox -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$FRESH'"
  [ "$output" = "0" ]
  # idempotent re-run
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base create postgres "$FRESH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  # deprecated createdb alias still works (warns)
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base createdb "${FRESH}2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deprecated"* ]]
  docker exec aibox-base-${PROF_A}-postgres psql -U aibox -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='${FRESH}2'" | grep -qx 1
}

@test "networks isolated: ${PROF_A} network contains only ${PROF_A} containers" {
  members="$(docker network inspect aibox-base-${PROF_A} --format '{{range .Containers}}{{.Name}} {{end}}')"
  [[ "$members" == *aibox-base-${PROF_A}-postgres* ]]
  [[ "$members" != *${PROF_B}* ]]
}

@test "profile list shows both test profiles with derived ports" {
  read -r PG_A RD_A <<< "$(_ports_of "${PROF_A}")"
  # run under an installed profile (the action gate requires base installed for the
  # ACTIVE profile; the list itself reads $AIBOX_HOME/profiles/ — all profiles)
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"${PROF_A}"* ]]
  [[ "$output" == *"$PG_A"* ]]
  [[ "$output" == *"${PROF_B}"* ]]
}

@test "per-profile status reports its own endpoints" {
  read -r PG_A RD_A <<< "$(_ports_of "${PROF_A}")"
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base status
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:$PG_A"* ]]
  [[ "$output" != *aibox-base-${PROF_B}* ]]
}

@test "shared-base contract: both profiles publish the contract keys + Redis auth + slots" {
  local p env pw
  for p in ${PROF_A} ${PROF_B}; do
    env="$AIBOX_HOME/base-$p.env"
    [ -f "$env" ] || { echo "no contract file for $p"; false; }
    grep -q '^AIBOX_BASE_ENV_VERSION=1$' "$env" || { cat "$env"; false; }
    grep -q "^AIBOX_BASE_PROFILE=$p$" "$env" || { cat "$env"; false; }
    grep -q '^AIBOX_BASE_MODULE_VERSION=1\.' "$env" || false
    grep -q '^AIBOX_BASE_READY=1$' "$env" || false
    grep -q '^AIBOX_REDIS_PASSWORD=..*' "$env" || { echo "no redis password in $env"; false; }
  done
  pw="$(grep -m1 '^AIBOX_REDIS_PASSWORD=' "$AIBOX_HOME/base-${PROF_A}.env" | cut -d= -f2-)"
  # authenticated PING works …
  run docker exec aibox-base-${PROF_A}-redis redis-cli --no-auth-warning -a "$pw" PING
  [[ "$output" == *PONG* ]] || { echo "authenticated PING failed: $output"; false; }
  # … and an unauthenticated client is rejected (auth is really ON)
  run docker exec aibox-base-${PROF_A}-redis redis-cli PING
  [[ "$output" == *NOAUTH* || "$status" -ne 0 ]] || { echo "unauthenticated command accepted: $output"; false; }

  # per-profile Redis slots are independent + written where the consumer reads them
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_A" base create redis xiaozhi
  [[ "$output" == *"Redis logical DB for xiaozhi: 1"* ]] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/redis-${PROF_A}-xiaozhi.env" ] || { echo "no per-profile redis env"; false; }
  run bash "$REPO_ROOT/bin/aibox" --profile "$PROF_B" base create redis dify 3
  [[ "$output" == *"Redis logical DB for dify: 1"* ]] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/redis-${PROF_B}-dify.env" ] || false
  # the two profiles' registries are separate files (no cross-profile bleed)
  [ -f "$AIBOX_HOME/apps/base-${PROF_A}/redis-dbs.conf" ] || { echo "${PROF_A} registry missing"; false; }
  [ -f "$AIBOX_HOME/apps/base-${PROF_B}/redis-dbs.conf" ] || false
}

@test "host ports bind to 127.0.0.1 by default (admin DB not exposed on the LAN)" {
  local binding
  binding="$(docker port aibox-base-${PROF_A}-postgres 2>/dev/null | head -1)"
  [ -n "$binding" ] || { echo "no port binding reported"; false; }
  [[ "$binding" == *"-> 127.0.0.1:"* ]] || { echo "postgres published as '${binding}' (expected 127.0.0.1)"; false; }
}

#!/usr/bin/env bats
# Shared-base dependency contract (0.19.0) — locks the 2026-09 dependency review.
# Fixed here:
#   P0 profile-aware linking (consumers hardcoded `base.env` → they attached to the
#      DEFAULT profile's instance under a named profile)
#   P1 base.env contract (version/profile/readiness) + readiness wait
#   P1 Redis auth + per-module logical DB allocation (three modules shared index 0)
#   P1 base dump/restore + a real upgrade path (pins in the deploy-root .env,
#      dump-first, health gate, pin rollback, state shared with `aibox upgrade base`)
#   P1 reverse-dependency protection (base stop/purge named no dependents)
#   P2 windmill's spurious base:redis, dify's optional-mode DB creation
# Offline: stubbed docker, sandbox AIBOX_HOME, file:// metadata.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AIBOX_BIN="$REPO_ROOT/bin/aibox"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-bc.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  mkdir -p "$AIBOX_HOME" "$AIBOX_MOD_DIR" "$AIBOX_BIN_DIR"
  export AIBOX_RAW="file://$REPO_ROOT"
  unset AIBOX_PROFILE
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true; }

# ---------- P0: profile-aware linking ----------------------------------------

@test "profile linking: the shared helpers resolve the SAME paths base writes" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod
    source '$REPO_ROOT/tools/_shared/common.sh'
    printf '%s|%s|%s|%s' \"\$(base_env_file)\" \"\$(base_pg_container)\" \"\$(base_redis_container)\" \"\$(base_profile_suffix)\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$AIBOX_HOME/base-prod.env|aibox-base-prod-postgres|aibox-base-prod-redis|-prod" ] || { echo "got: $output"; false; }
}

@test "profile linking: the default profile keeps the unsuffixed names" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    source '$REPO_ROOT/tools/_shared/common.sh'
    printf '%s|%s' \"\$(base_env_file)\" \"\$(base_pg_container)\"
  "
  [ "$output" = "$AIBOX_HOME/base.env|aibox-base-postgres" ] || { echo "got: $output"; false; }
}

@test "profile linking: base itself derives through the same helpers (no drift)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod
    . '$REPO_ROOT/tools/base/lib.sh' >/dev/null 2>&1
    printf 'DERIVED=%s|%s|%s' \"\$ENV_FILE\" \"\$POSTGRES_CONTAINER\" \"\$AIBOX_BASE_NETWORK\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"DERIVED=$AIBOX_HOME/base-prod.env|aibox-base-prod-postgres|aibox-base-prod"* ]] || { echo "got: $output"; false; }
}

@test "profile linking: the manager resolves the same profile paths" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod
    source '$AIBOX_BIN'
    printf '%s|%s' \"\$(_base_env_file)\" \"\$(_base_network_name)\"
  "
  [ "$output" = "$AIBOX_HOME/base-prod.env|aibox-base-prod" ] || { echo "got: $output"; false; }
}

@test "profile linking: no consumer hardcodes base.env any more" {
  local f bad=""
  for f in "$REPO_ROOT"/tools/*/lib.sh "$REPO_ROOT"/tools/*/svc.sh; do
    case "$f" in */base/lib.sh|*/base/svc.sh) continue ;; esac
    grep -qE '(AIBOX_HOME[^)]*)/base\.env|"/base\.env"' "$f" 2>/dev/null && bad="${bad} $(basename "$(dirname "$f")")/$(basename "$f")"
  done
  [ -z "${bad}" ] || { echo "still hardcoding base.env:${bad}"; false; }
  # and the consumers that link to base DO use the shared helper
  for f in dify new-api xiaozhi; do
    grep -q 'base_env_file' "$REPO_ROOT/tools/$f/lib.sh" || { echo "$f does not use base_env_file"; false; }
  done
}

# ---------- P1: the base.env contract -----------------------------------------

@test "contract: write_base_env emits version/profile/module-version/ready + both secrets (mode 600)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod
    . '$REPO_ROOT/tools/base/lib.sh'
    resolve_secrets
    write_base_env
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local env="$AIBOX_HOME/base-prod.env"
  [ -f "$env" ] || { echo "no contract file"; false; }
  grep -q '^AIBOX_BASE_ENV_VERSION=1$' "$env" || { cat "$env"; false; }
  grep -q '^AIBOX_BASE_PROFILE=prod$' "$env" || false
  grep -q '^AIBOX_BASE_MODULE_VERSION=1\.' "$env" || false
  grep -q '^AIBOX_BASE_READY=1$' "$env" || false
  grep -q '^AIBOX_POSTGRES_PASSWORD=..*' "$env" || false
  grep -q '^AIBOX_REDIS_PASSWORD=..*' "$env" || false
  [ "$(stat -c '%a' "$env" 2>/dev/null || stat -f '%Lp' "$env")" = "600" ] || { ls -l "$env"; false; }
}

@test "contract: base_env_check accepts v1 + a pre-contract file, rejects a mismatch with a hint" {
  # v1
  printf 'AIBOX_BASE_ENV_VERSION=1\n' >"$AIBOX_HOME/base.env"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$REPO_ROOT/tools/_shared/common.sh'; base_env_check"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # pre-contract (0.18-and-older file): compatible, but says how to refresh
  printf 'AIBOX_POSTGRES_HOST=aibox-base-postgres\n' >"$AIBOX_HOME/base.env"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$REPO_ROOT/tools/_shared/common.sh'; base_env_check"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pre-contract"* ]] || { echo "$output"; false; }
  # mismatch → actionable failure
  printf 'AIBOX_BASE_ENV_VERSION=99\n' >"$AIBOX_HOME/base.env"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$REPO_ROOT/tools/_shared/common.sh'; base_env_check"
  [ "$status" -ne 0 ] || { echo "mismatch accepted"; false; }
  [[ "$output" == *"aibox update base"* ]] || { echo "$output"; false; }
}

@test "contract: the manager twin agrees with the shared lib (version + paths)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod
    source '$AIBOX_BIN'
    printf '%s|%s' \"\$BASE_ENV_VERSION_SUPPORTED\" \"\$(_base_env_file)\"
    . '$REPO_ROOT/tools/_shared/common.sh'
    printf '|%s|%s' \"\$BASE_ENV_VERSION_SUPPORTED\" \"\$(base_env_file)\"
  "
  [ "$output" = "1|$AIBOX_HOME/base-prod.env|1|$AIBOX_HOME/base-prod.env" ] || { echo "got: $output"; false; }
}

@test "readiness: cmd_start waits for pg_isready + redis PING before writing the contract" {
  # stub docker/compose so the wait loop is observable without a daemon
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    require_docker() { :; }
    ensure_compose() { :; }
    stack_running() { return 1; }
    docker_pool_prepull() { :; }
    compose() {
      case \"\$1\" in
      up) : ;;
      ps) : ;;
      config) : ;;
      esac
      return 0
    }
    docker() {
      # first pg_isready call fails (still initializing), everything after passes
      if [ \"\$1\" = exec ] && [ \"\$3\" = pg_isready ]; then
        n=\$(cat '$SANDBOX/pgcount' 2>/dev/null || echo 0)
        n=\$((n + 1)); printf '%s' \"\$n\" >'$SANDBOX/pgcount'
        [ \"\$n\" -ge 2 ] || return 1
      fi
      return 0
    }
    sleep() { :; }   # no real waiting
    cmd_start
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/base.env" ] || { echo "contract file not written"; false; }
  [ "$(cat "$SANDBOX/pgcount")" -ge 2 ] || { echo "did not retry pg_isready"; false; }
  [[ "$output" == *"Shared PG/Redis started"* ]] || { echo "$output"; false; }
}

# ---------- P1: secrets (auth) ------------------------------------------------

@test "secrets: resolution order env > contract file > persisted > generated (no silent rotation)" {
  # 1) explicit env wins
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_BASE_POSTGRES_PASSWORD=explicit; . '$REPO_ROOT/tools/base/lib.sh'; resolve_secrets; printf 'V=%s' \"\$PG_PASSWORD\""
  [[ "$output" == *"V=explicit"* ]] || { echo "env not honored: $output"; false; }
  # 2) an existing contract value is reused (existing deployments keep working)
  printf 'AIBOX_BASE_ENV_VERSION=1\nAIBOX_BASE_POSTGRES_PASSWORD=fromcontract\n' >"$AIBOX_HOME/base.env"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; . '$REPO_ROOT/tools/base/lib.sh'; resolve_secrets; printf 'V=%s' \"\$PG_PASSWORD\""
  [[ "$output" == *"V=fromcontract"* ]] || { echo "contract value not reused: $output"; false; }
  rm -f "$AIBOX_HOME/base.env"
  # 3) generated once → persisted → stable across calls
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; . '$REPO_ROOT/tools/base/lib.sh'; resolve_secrets; printf 'V=%s' \"\$PG_PASSWORD\""
  local first="${output##*V=}"
  [ -n "$first" ] && [ "$first" != "aibox" ] || { echo "no random password generated: $first"; false; }
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; . '$REPO_ROOT/tools/base/lib.sh'; resolve_secrets; printf 'V=%s' \"\$PG_PASSWORD\""
  [ "${output##*V=}" = "$first" ] || { echo "password rotated between calls"; false; }
  [ "$(stat -c '%a' "$AIBOX_HOME/.base-secret" 2>/dev/null || stat -f '%Lp' "$AIBOX_HOME/.base-secret")" = "600" ] || { ls -l "$AIBOX_HOME/.base-secret"; false; }
}

# ---------- P1: redis allocation ----------------------------------------------

@test "redis allocation: deterministic, idempotent, range-reserving, per profile" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    printf 'a=%s ' \"\$(base_redis_db_for alpha 1)\"
    printf 'b=%s ' \"\$(base_redis_db_for beta 3)\"   # reserves 2,3,4
    printf 'c=%s ' \"\$(base_redis_db_for gamma 1)\"  # → 5 (skips the range)
    printf 'again=%s' \"\$(base_redis_db_for alpha 1)\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "a=1 b=2 c=5 again=1" ] || { echo "got: $output"; false; }
  grep -q '^beta=2:3$' "$AIBOX_HOME/apps/base/redis-dbs.conf" || { cat "$AIBOX_HOME/apps/base/redis-dbs.conf"; false; }
}

@test "redis allocation: create writes the consumer env file; windmill no longer claims redis" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    _create redis xiaozhi 1
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^AIBOX_REDIS_DB=1$' "$AIBOX_HOME/redis-xiaozhi.env" || { cat "$AIBOX_HOME/redis-xiaozhi.env"; false; }
  # the spurious dependency is gone; the real ones carry their resource
  ! grep -q 'base:redis$' "$REPO_ROOT/tools/windmill/module.yaml" || { echo "windmill still declares bare base:redis"; false; }
  grep -q 'base:redis#new_api' "$REPO_ROOT/tools/new-api/module.yaml" || false
  grep -q 'base:redis#xiaozhi' "$REPO_ROOT/tools/xiaozhi/module.yaml" || false
  grep -q 'base:redis#dify' "$REPO_ROOT/tools/dify/module.yaml" || false
}

# ---------- P1: dump / restore / upgrade --------------------------------------

@test "dump/restore: arguments are validated and the newest dump is the default" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    require_docker() { :; }
    cmd_restore
  "
  [ "$status" -ne 0 ] || { echo "restore without a dump should fail"; false; }
  [[ "$output" == *"aibox base dump"* ]] || { echo "$output"; false; }

  # a fake dump exists → the default resolves to it and the gunzip/psql path runs
  mkdir -p "$AIBOX_HOME/backups/base"
  printf 'select 1;\n' | gzip -c >"$AIBOX_HOME/backups/base/cluster-20260101-000000-manual.sql.gz"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    require_docker() { :; }
    ensure_stack_running() { :; }
    docker() { cat >/dev/null; return 0; }
    cmd_restore
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"restored"* ]] || { echo "$output"; false; }
  [[ "$output" == *"REPLACES the current shared data"* ]] || { echo "no warning"; false; }
}

@test "upgrade --check: reports both pins + the rollback point, no docker needed" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    cmd_upgrade --check --pg postgres:19
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"postgres : postgres:18 → postgres:19"* ]] || { echo "$output"; false; }
  [[ "$output" == *"redis    : redis:7"* ]] || false
  [[ "$output" == *"one-way"* ]] || { echo "no PG-major warning"; false; }
  [[ "$output" == *"deploy"*".env"* || "$output" == *".env"* ]] || false
}

@test "upgrade: dumps first, rewrites the pin file, and records the state" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    stack_running() { return 0; }
    _dump_to_file() { printf '%s/backups/base/fake.sql.gz' \"\$AIBOX_HOME\"; mkdir -p \"\$AIBOX_HOME/backups/base\"; : >\"\$AIBOX_HOME/backups/base/fake.sql.gz\"; }
    cmd_start() { return 0; }   # health gate passes
    cmd_upgrade --pg postgres:19
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local pin="$AIBOX_HOME/apps/base/.env"
  grep -q '^AIBOX_BASE_PG_IMAGE=postgres:19$' "$pin" || { cat "$pin"; false; }
  local st="$AIBOX_HOME/upgrades/base.state"
  grep -q '^status=ok$' "$st" || { cat "$st"; false; }
  grep -q '^from=pg=postgres:18' "$st" || false
  grep -q '^to=pg=postgres:19' "$st" || false
  grep -q '^databak=.*fake.sql.gz$' "$st" || false
  grep -q '^envbak=.*\.bak\.' "$st" || false
}

@test "upgrade: a failing health gate rolls the pins back and exits 10 (20 when the rollback also fails)" {
  # first cmd_start (the new image) fails, the rollback start succeeds → 10
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    stack_running() { return 0; }
    _dump_to_file() { printf ''; }
    cmd_start() { n=\$(cat '$SANDBOX/gate' 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s' \"\$n\" >'$SANDBOX/gate'; [ \"\$n\" -ge 2 ]; }
    cmd_upgrade --pg postgres:19
  "
  [ "$status" -eq 10 ] || { echo "expected 10, got $status"; echo "$output"; false; }
  # the pin file is back to its pre-upgrade content (in this fixture: the comment
  # only — the effective floor is then read from the compose again)
  ! grep -q '^AIBOX_BASE_PG_IMAGE=postgres:19$' "$AIBOX_HOME/apps/base/.env" || { cat "$AIBOX_HOME/apps/base/.env"; false; }
  grep -q '^status=rolled-back$' "$AIBOX_HOME/upgrades/base.state" || { cat "$AIBOX_HOME/upgrades/base.state"; false; }
  [[ "$output" == *"rolled back to"* ]] || { echo "$output"; false; }

  rm -rf "$AIBOX_HOME/apps/base" "$AIBOX_HOME/upgrades" "$SANDBOX/gate2"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    stack_running() { return 0; }
    _dump_to_file() { printf ''; }
    cmd_start() { return 1; }   # never healthy, not even after the rollback
    cmd_upgrade --pg postgres:19
  "
  [ "$status" -eq 20 ] || { echo "expected 20, got $status"; echo "$output"; false; }
  grep -q '^status=manual$' "$AIBOX_HOME/upgrades/base.state" || false
  [[ "$output" == *"manual intervention needed"* ]] || { echo "$output"; false; }
}

@test "upgrade --rollback: restores the recorded pin and starts (module side)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    . '$REPO_ROOT/tools/base/lib.sh'
    ensure_compose() { :; }
    resolve_secrets() { :; }
    mkdir -p \"\$(dirname \"\$(pin_file)\")\"
    printf 'AIBOX_BASE_PG_IMAGE=postgres:19\n' >\"\$(pin_file)\"
    printf 'AIBOX_BASE_PG_IMAGE=postgres:18\n' >\"\$(pin_file).bak.1\"
    _state_set from 'pg=postgres:18 redis=redis:7'
    _state_set envbak \"\$(pin_file).bak.1\"
    cmd_start() { grep -q '^AIBOX_BASE_PG_IMAGE=postgres:18$' \"\$(pin_file)\"; }
    cmd_upgrade --rollback
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^AIBOX_BASE_PG_IMAGE=postgres:18$' "$AIBOX_HOME/apps/base/.env" || { cat "$AIBOX_HOME/apps/base/.env"; false; }
  [[ "$output" == *"rolled back to pg=postgres:18"* ]] || { echo "$output"; false; }
}

# ---------- P1: reverse-dependency protection ---------------------------------

_dep_fixture() { # base installed + a consumer that declares base:postgres#app
  mkdir -p "$AIBOX_MOD_DIR/base" "$AIBOX_MOD_DIR/consumer"
  printf 'name: base\nversion: 1.0.0\ndescription: "d"\ndir: tools/base\n' >"$AIBOX_MOD_DIR/base/module.yaml"
  printf 'name: consumer\nversion: 1.0.0\ndescription: "d"\ndir: tools/consumer\nservices:\n  - base:postgres#app\n' >"$AIBOX_MOD_DIR/consumer/module.yaml"
  printf 'AIBOX_INSTALLED_base="1.0.0"\nAIBOX_INSTALLED_consumer="1.0.0"\n' >"$AIBOX_INSTALLED"
}

@test "reverse deps: the manager lists the dependents of base" {
  _dep_fixture
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$AIBOX_MOD_DIR' AIBOX_INSTALLED='$AIBOX_INSTALLED'; source '$AIBOX_BIN'; _base_dependents"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "consumer" ] || { echo "got: [$output]"; false; }
}

@test "reverse deps: 'base stop' with a dependent installed warns and gates (non-interactive → exit 2)" {
  _dep_fixture
  run bash "$AIBOX_BIN" base stop
  [ "$status" -eq 2 ] || { echo "expected the gate to decline, got $status"; echo "$output"; false; }
  [[ "$output" == *"installed modules depend on the shared base: consumer"* ]] || { echo "$output"; false; }
  [[ "$output" == *"restart them afterwards"* ]] || false
}
# ---------- validator rules for the base contract -----------------------------

@test "validator: a consumer hardcoding base.env is an ERROR; base_env_file is accepted" {
  local out="$SANDBOX/tools"
  mkdir -p "$out"
  bash "$REPO_ROOT/scripts/new-module.sh" consumer --out "$out" >/dev/null 2>&1
  # the provider module must exist for the cross-ref check (provides: postgres)
  mkdir -p "$out/base"
  printf 'name: base\nversion: 1.0.0\ndescription: "provider"\ndir: tools/base\nprovides:\n  - postgres\n  - redis\n' >"$out/base/module.yaml"
  local dir="$out/consumer"
  printf 'services:\n  - base:postgres#consumer\n' >>"$dir/module.yaml"
  # the hook now hardcodes the DEFAULT profile's env file (the P0 regression)
  printf 'compose() { local e="${AIBOX_HOME}/base.env"; printf "%%s" "$e"; }\n' >>"$dir/lib.sh"
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" consumer
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"hardcodes base.env"* ]] || { echo "$output"; false; }
  # the profile-aware helper is accepted
  printf '%s\n' 'compose() { local e; e="$(base_env_file)"; printf "%s" "$e"; }' >"$dir/lib.sh"
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" consumer
  [[ "$output" != *"hardcodes base.env"* ]] || { echo "$output"; false; }
}

@test "validator: a base consumer without includes: [common] is an ERROR" {
  local out="$SANDBOX/tools2"
  mkdir -p "$out"
  bash "$REPO_ROOT/scripts/new-module.sh" consumer2 --out "$out" >/dev/null 2>&1
  local dir="$out/consumer2"
  printf 'services:\n  - base:postgres#consumer2\n' >>"$dir/module.yaml"
  # drop the include the contract helpers live in
  sed -i.bak '/^includes:/,+1d' "$dir/module.yaml" 2>/dev/null || true
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" consumer2
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"includes: [common]"* ]] || { echo "$output"; false; }
}

@test "validator: bare base:redis is flagged (no logical DB allocation)" {
  local out="$SANDBOX/tools3"
  mkdir -p "$out"
  bash "$REPO_ROOT/scripts/new-module.sh" consumer3 --out "$out" >/dev/null 2>&1
  local dir="$out/consumer3"
  printf 'services:\n  - base:redis\n' >>"$dir/module.yaml"
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" consumer3
  [[ "$output" == *"bare 'base:redis' allocates no logical DB"* ]] || { echo "$output"; false; }
}

# ---------- consumer wiring ---------------------------------------------------

@test "consumer compose: injects the PROFILE's base env + its own redis slot file" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod AIBOX_MODULE=new-api
    mkdir -p '$AIBOX_HOME/apps/new-api-prod'
    printf 'services: {}\n' >'$AIBOX_HOME/apps/new-api-prod/docker-compose.yml'
    printf 'AIBOX_BASE_ENV_VERSION=1\nAIBOX_POSTGRES_HOST=aibox-base-prod-postgres\nAIBOX_BASE_NETWORK=aibox-base-prod\n' >'$AIBOX_HOME/base-prod.env'
    printf 'AIBOX_REDIS_DB=7\n' >'$AIBOX_HOME/redis-prod-new-api.env'
    . '$REPO_ROOT/tools/new-api/lib.sh'
    require_docker() { :; }
    docker() { printf 'ARGS %s\n' \"\$*\"; }
    compose config
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ARGS"*"--env-file $AIBOX_HOME/base-prod.env"* ]] || { echo "profile base env not injected"; echo "$output"; false; }
  [[ "$output" == *"--env-file $AIBOX_HOME/redis-prod-new-api.env"* ]] || { echo "redis slot file not injected"; echo "$output"; false; }
}

@test "consumer start: ensures its shared DB + redis slot before the stack comes up" {
  for m in new-api dify xiaozhi; do
    grep -q 'ensure_shared_db\|ensure_shared_redis_db' "$REPO_ROOT/tools/$m/svc.sh" || { echo "$m/svc.sh has no self-heal ensure"; false; }
  done
  # dify (optional mode) ensures BOTH of its databases and reserves 3 redis slots
  grep -q 'ensure_shared_db dify$' "$REPO_ROOT/tools/dify/svc.sh" || false
  grep -q 'ensure_shared_db dify_plugin' "$REPO_ROOT/tools/dify/svc.sh" || false
  grep -q 'ensure_shared_redis_db "${MODULE_NAME}" 3' "$REPO_ROOT/tools/dify/svc.sh" || false
}

@test "deploy roots: consumers are profile-scoped (two profiles never share a deploy dir)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_PROFILE=prod
    source '$REPO_ROOT/tools/_shared/common.sh'
    . '$REPO_ROOT/tools/new-api/lib.sh' >/dev/null 2>&1
    printf 'D=%s' \"\$(deploy_root)\"
  "
  [[ "$output" == *"D=$AIBOX_HOME/apps/new-api-prod"* ]] || { echo "prod root: $output"; false; }
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    source '$REPO_ROOT/tools/_shared/common.sh'
    . '$REPO_ROOT/tools/new-api/lib.sh' >/dev/null 2>&1
    printf 'D=%s' \"\$(deploy_root)\"
  "
  [[ "$output" == *"D=$AIBOX_HOME/apps/new-api"* ]] || { echo "default root changed: $output"; false; }
}

@test "purge: named-profile deploy roots are listed as residue" {
  mkdir -p "$AIBOX_HOME/apps/new-api" "$AIBOX_HOME/apps/new-api-prod"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    source '$AIBOX_BIN'
    residue_paths new-api
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"apps/new-api"* ]] || { echo "$output"; false; }
  [[ "$output" == *"apps/new-api-prod"* ]] || { echo "profile root not listed: $output"; false; }
}

@test "validator: a deploy_root without the profile suffix is flagged" {
  local out="$SANDBOX/tools4"
  mkdir -p "$out"
  bash "$REPO_ROOT/scripts/new-module.sh" consumer4 --out "$out" >/dev/null 2>&1
  local lib="$out/consumer4/lib.sh"
  # the scaffold is compliant; strip the suffix to reproduce the regression
  awk '{ gsub(/\$\(profile_suffix\)/, ""); print }' "$lib" >"$lib.tmp" && mv "$lib.tmp" "$lib"
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" consumer4
  [[ "$output" == *"deploy_root() is not profile-scoped"* ]] || { echo "$output"; false; }
  # …and a fresh scaffold (which emits the suffix) is clean — its own dir, so the
  # deliberately-broken consumer4 above cannot influence the run
  local out2="$SANDBOX/tools5"
  mkdir -p "$out2"
  bash "$REPO_ROOT/scripts/new-module.sh" consumer4ok --out "$out2" >/dev/null 2>&1 || true
  run env VALIDATE_TOOLS_DIR="$out2" bash "$REPO_ROOT/scripts/validate-module.sh" consumer4ok
  [[ "$output" != *"not profile-scoped"* ]] || { echo "$output"; false; }
}

@test "manager <-> base: 'aibox upgrade base --rollback' resolves base's deploy root and restores the pin" {
  # base exposes the contract name deploy_root() (its own is base_deploy_root) —
  # without it the manager died with "cannot locate base deploy root"
  grep -qE '^deploy_root\(\)' "$REPO_ROOT/tools/base/lib.sh" || { echo "no deploy_root contract name"; false; }
  # full manager path against a fixture cache (stub svc hook, no docker)
  mkdir -p "$AIBOX_MOD_DIR/base" "$AIBOX_HOME/apps/base" "$AIBOX_HOME/upgrades"
  cp "$REPO_ROOT/tools/base/lib.sh" "$REPO_ROOT/tools/base/module.yaml" "$AIBOX_MOD_DIR/base/"
  cp "$REPO_ROOT/tools/_shared/common.sh" "$AIBOX_MOD_DIR/base/_common.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$AIBOX_MOD_DIR/base/svc.sh"
  printf 'AIBOX_INSTALLED_base="1.5.0"\n' >"$AIBOX_INSTALLED"
  printf 'AIBOX_BASE_PG_IMAGE=postgres:19\n' >"$AIBOX_HOME/apps/base/.env"
  printf 'AIBOX_BASE_PG_IMAGE=postgres:18\n' >"$AIBOX_HOME/apps/base/.env.bak.1"
  printf 'from=pg=postgres:18\nenvbak=%s/apps/base/.env.bak.1\nstatus=ok\n' "$AIBOX_HOME" >"$AIBOX_HOME/upgrades/base.state"
  run bash "$AIBOX_BIN" upgrade base --rollback --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^AIBOX_BASE_PG_IMAGE=postgres:18$' "$AIBOX_HOME/apps/base/.env" || { cat "$AIBOX_HOME/apps/base/.env"; false; }
  [[ "$output" == *"rolled back to pg=postgres:18"* ]] || { echo "$output"; false; }
}

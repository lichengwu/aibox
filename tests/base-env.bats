#!/usr/bin/env bats
# Regression tests for the base module's write_base_env.
# Guards the command-substitution-in-heredoc bug class: the env-file heredoc comment
# once contained $(aibox base start) — a LIVE substitution in an unquoted heredoc that
# recursively executed `aibox base start` on every write and left base.env empty/corrupt.
# bash -n / shellcheck cannot catch this (syntactically valid); these tests can.

setup() {
  AIBOX_HOME="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-base-test.$$")"
  mkdir -p "$AIBOX_HOME"
  export AIBOX_HOME
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../tools/base/lib.sh"
}

teardown() {
  [ -n "${AIBOX_HOME:-}" ] && rm -rf "$AIBOX_HOME" 2>/dev/null || true
}

@test "write_base_env: writes a parseable env file with all connection keys" {
  write_base_env
  [ -f "$ENV_FILE" ]
  # Must source cleanly under set -u — no embedded command output, no garbage lines.
  bash -c "set -u; . '$ENV_FILE'"
  bash -c ". '$ENV_FILE'; [ \"\$AIBOX_POSTGRES_HOST\" = 'aibox-base-postgres' ]"
  bash -c ". '$ENV_FILE'; [ \"\$AIBOX_POSTGRES_PORT\" = '5432' ]"
  bash -c ". '$ENV_FILE'; [ \"\$AIBOX_REDIS_HOST\" = 'aibox-base-redis' ]"
  bash -c ". '$ENV_FILE'; [ \"\$AIBOX_REDIS_PORT\" = '6379' ]"
}

@test "write_base_env: file contains ONLY comments + KEY=VALUE (no command output leaked)" {
  write_base_env
  # The historical bug embedded `aibox base start` output (compose "Container ... Running" lines).
  while IFS= read -r line; do
    case "$line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) echo "garbage line in env file: $line"; false ;;
    esac
  done <"$ENV_FILE"
}

@test "write_base_env: prod profile → base-prod.env with prod container host + deterministic hash" {
  export AIBOX_PROFILE=prod
  # Re-source so _profile_load runs with the profile set.
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../tools/base/lib.sh"
  [ "$ENV_FILE" = "$AIBOX_HOME/base-prod.env" ]
  write_base_env
  [ -f "$AIBOX_HOME/base-prod.env" ]
  bash -c "set -u; . '$AIBOX_HOME/base-prod.env'; [ \"\$AIBOX_POSTGRES_HOST\" = 'aibox-base-prod-postgres' ]"
  # Profile config auto-created; hash("prod")=1073 is deterministic (same on every machine).
  [ -f "$AIBOX_HOME/profiles/prod.conf" ]
  grep -q 'PROFILE_HASH=1073' "$AIBOX_HOME/profiles/prod.conf"
}

@test "profile derivation: prod → PG 35177 / Redis 36336 / prod containers" {
  export AIBOX_PROFILE=prod
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../tools/base/lib.sh"
  [ "$PG_PORT" = "35177" ]
  [ "$REDIS_PORT" = "36336" ]
  [ "$POSTGRES_CONTAINER" = "aibox-base-prod-postgres" ]
  [ "$REDIS_CONTAINER" = "aibox-base-prod-redis" ]
  [ "$(base_deploy_root)" = "$AIBOX_HOME/apps/base-prod" ]
}

@test "default profile: base → repo defaults unchanged" {
  # setup() sourced with AIBOX_PROFILE unset → base defaults
  [ "$PG_PORT" = "35432" ]
  [ "$REDIS_PORT" = "36379" ]
  [ "$POSTGRES_CONTAINER" = "aibox-base-postgres" ]
  [ "$ENV_FILE" = "$AIBOX_HOME/base.env" ]
  [ "$(base_deploy_root)" = "$AIBOX_HOME/apps/base" ]
  # No profile config created for the default profile
  [ ! -d "$AIBOX_HOME/profiles" ]
}

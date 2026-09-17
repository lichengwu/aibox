#!/usr/bin/env bats
# Profile-system regression tests (no docker, no network).
# Locks the DETERMINISTIC derivation contract: same profile name → same hash → same
# ports/containers/paths on every machine. The pinned constants (hash 1073, PG 35177,
# Redis 36336, pi-web 37173 for "prod") are the cross-machine promise — changing the
# hash algorithm or port ranges is a BREAKING change to every deployed profile.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-prof.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export HOME="$SANDBOX/home"
  mkdir -p "$AIBOX_HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  unset AIBOX_PROFILE PI_WEB_PORT AIBOX_BASE_POSTGRES_PORT AIBOX_BASE_REDIS_PORT
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "profile hash is deterministic: prod=1073 (pinned cross-machine contract)" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/base/lib.sh"
  [ "$(_profile_hash prod)" = "1073" ]
  [ "$(_profile_hash prod)" = "1073" ]
  [ "$(_profile_hash dev)" = "656" ]
}

@test "base profile derivation: prod → PG 35177, Redis 36336, prod names (pinned)" {
  export AIBOX_PROFILE=prod
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/base/lib.sh"
  [ "$PG_PORT" = "35177" ]
  [ "$REDIS_PORT" = "36336" ]
  [ "$POSTGRES_CONTAINER" = "aibox-base-prod-postgres" ]
  [ "$REDIS_CONTAINER" = "aibox-base-prod-redis" ]
  [ "$ENV_FILE" = "$AIBOX_HOME/base-prod.env" ]
  [ "$(base_deploy_root)" = "$AIBOX_HOME/apps/base-prod" ]
  # compose env exports (the compose file interpolates these)
  [ "$AIBOX_BASE_PG_VOLUME" = "aibox_pg_data_prod" ]
  [ "$AIBOX_BASE_REDIS_VOLUME" = "aibox_redis_data_prod" ]
  [ "$AIBOX_BASE_NETWORK" = "aibox-base-prod" ]
  # profile config auto-created with the pinned hash
  grep -q 'PROFILE_HASH=1073' "$AIBOX_HOME/profiles/prod.conf"
}

@test "pi-web profile derivation: prod → port 37173, label/unit suffixed (pinned)" {
  export AIBOX_PROFILE=prod
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/pi-web/lib.sh"
  [ "$PORT" = "37173" ]
  [ "$LABEL" = "pi-web-prod" ]
  if [ "$(uname -s)" = "Darwin" ]; then
    [ "$PLIST" = "$HOME/Library/LaunchAgents/pi-web-prod.plist" ]
  else
    [ "$UNIT_FILE" = "$HOME/.config/systemd/user/pi-web-prod.service" ]
    [ "$LOG_DIR" = "$HOME/.local/share/pi-web-prod/logs" ]
  fi
}

@test "cross-module consistency: base and pi-web share ONE profile config" {
  export AIBOX_PROFILE=prod
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/base/lib.sh"        # creates profiles/prod.conf
  [ "$PG_PORT" = "35177" ]
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/pi-web/lib.sh"      # reads the SAME conf
  [ "$PORT" = "37173" ]
  # exactly one config file, created once
  [ "$(ls "$AIBOX_HOME/profiles" | wc -l | tr -d ' ')" = "1" ]
}

@test "default profile 'base' → repo defaults, no config file, no suffix" {
  export AIBOX_PROFILE=base
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/base/lib.sh"
  [ "$PG_PORT" = "35432" ]
  [ "$REDIS_PORT" = "36379" ]
  [ "$POSTGRES_CONTAINER" = "aibox-base-postgres" ]
  [ "$ENV_FILE" = "$AIBOX_HOME/base.env" ]
  [ ! -d "$AIBOX_HOME/profiles" ]
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/pi-web/lib.sh"
  [ "$PORT" = "30141" ]
  [ "$LABEL" = "pi-web" ]
}

@test "port-range invariants: derived ports exclude defaults + well-known, unique across 12 names" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/base/lib.sh"
  local names="prod dev staging test qa ci alice bob carol dave eve frank"
  local n h pg rd seen_pg=" " seen_rd=" "
  for n in $names; do
    h=$(_profile_hash "$n")
    pg=$((35100 + h % 332))
    rd=$((36100 + h % 279))
    # ranges: above every well-known/aibox-module port (all < 35000), below the defaults
    [ "$pg" -ge 35100 ] && [ "$pg" -le 35431 ] || { echo "pg $pg out of range for $n"; false; }
    [ "$rd" -ge 36100 ] && [ "$rd" -le 36378 ] || { echo "rd $rd out of range for $n"; false; }
    # never equals the default-profile ports
    [ "$pg" != "35432" ] && [ "$rd" != "36379" ]
    # uniqueness within the sample set
    case "$seen_pg" in *" $pg "*) echo "pg collision $pg ($n)"; false ;; esac
    case "$seen_rd" in *" $rd "*) echo "rd collision $rd ($n)"; false ;; esac
    seen_pg="$seen_pg$pg "; seen_rd="$seen_rd$rd "
  done
}

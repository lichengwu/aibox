#!/usr/bin/env bats
# base svc.sh dispatch tests (no docker needed: only exercises create-dispatch,
# profile listing, and usage errors — never the compose/psql paths).

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-svc.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  mkdir -p "$AIBOX_HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SVC="$REPO_ROOT/tools/base/svc.sh"
  unset AIBOX_PROFILE
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "create redis <x>: allocates the module's logical DB + writes its env file" {
  # Redis auth + per-module slots (2026-09 review): redis is no longer a no-op —
  # it reserves an index range and publishes AIBOX_REDIS_DB for the consumer.
  run env AIBOX_MODULE=base AIBOX_HOME="$AIBOX_HOME" bash "$SVC" create redis anything
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Redis logical DB for anything:"* ]] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/redis-anything.env" ] || { echo "no redis env file written"; false; }
  grep -q '^AIBOX_REDIS_DB=1$' "$AIBOX_HOME/redis-anything.env" || { cat "$AIBOX_HOME/redis-anything.env"; false; }
  # idempotent: a second call returns the same slot
  run env AIBOX_MODULE=base AIBOX_HOME="$AIBOX_HOME" bash "$SVC" create redis anything
  [[ "$output" == *"anything: 1"* ]] || { echo "$output"; false; }
}

@test "create without args: usage error" {
  run env AIBOX_MODULE=base bash "$SVC" create
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "create <unknown component>: clear error" {
  run env AIBOX_MODULE=base bash "$SVC" create etcd foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"no 'create' handler"* ]]
}

@test "createdb (deprecated alias): warns, then routes to create postgres" {
  run env AIBOX_MODULE=base bash "$SVC" createdb somedb
  [ "$status" -ne 0 ]   # dies at ensure_compose (no compose in sandbox) — expected
  [[ "$output" == *"deprecated"* ]]
  [[ "$output" == *"No compose file"* ]]
}

@test "profile: lists the default base profile with repo-default ports" {
  run env AIBOX_MODULE=base bash "$SVC" profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"base"* ]]
  [[ "$output" == *"35432"* ]]
  [[ "$output" == *"36379"* ]]
}

@test "profile: named profile appears with derived ports after first use" {
  # first use under prod auto-creates the profile config (via _profile_load in lib.sh)
  run env AIBOX_MODULE=base AIBOX_PROFILE=prod bash "$SVC" create redis x
  [ "$status" -eq 0 ]
  [ -f "$AIBOX_HOME/profiles/prod.conf" ]
  run env AIBOX_MODULE=base bash "$SVC" profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"prod"* ]]
  [[ "$output" == *"35177"* ]]
  [[ "$output" == *"36336"* ]]
}

@test "unknown action: unified fallback points to --help (drift-free)" {
  run env AIBOX_MODULE=base bash "$SVC" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown action: bogus"* ]]
  [[ "$output" == *"aibox base --help"* ]]
}

@test "status|dashboard merge: module-level dashboard is an alias of status (same output)" {
  # merged 2026-09: one "show state" verb — operational facts + the rich view;
  # the manager-level aibox dashboard stays separate. Both action names must
  # produce IDENTICAL output (fall-through case, not two implementations).
  run env AIBOX_MODULE=base bash "$SVC" status
  local st_out="$output" st_rc=$status
  run env AIBOX_MODULE=base bash "$SVC" dashboard
  [ "$status" -eq "$st_rc" ]
  [ "$output" = "$st_out" ]
}

@test "render_dashboard: keyline header + module row with no docker" {
  run bash -c ". '$REPO_ROOT/tools/base/lib.sh'; PATH=/usr/bin:/bin; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"· module"* ]] || false
  [[ "$output" == *"base"* ]] || false
  [[ "$output" == *"module"*"·"*"modules/base/"* ]] || false
}

@test "dashboard_info: no docker → degrades, exit 0 under set -euo pipefail" {
  run bash -c "set -euo pipefail; PATH=/usr/bin:/bin; . '$REPO_ROOT/tools/base/lib.sh'; dashboard_info"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q '^state=stopped$' || false
}

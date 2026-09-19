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

@test "create redis <x>: generic dispatcher no-ops redis (no docker touched)" {
  run env AIBOX_MODULE=base bash "$SVC" create redis anything
  [ "$status" -eq 0 ]
  [[ "$output" == *"no resource creation needed"* ]]
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

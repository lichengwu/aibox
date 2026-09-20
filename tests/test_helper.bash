#!/usr/bin/env bash
# Shared test helpers for aibox bats tests.
# Sources bin/aibox with a throwaway AIBOX_HOME so tests are hermetic.

# Locate the repo root from the test file's location.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

AIBOX_BIN="$REPO_ROOT/bin/aibox"

# Set up an isolated AIBOX_HOME before sourcing, so config/installed/registry.cache
# don't touch the user's real state.
setup() {
  local _home
  _home="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-test.$$")"
  export AIBOX_HOME="$_home"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_CONFIG="$AIBOX_HOME/config"
  export AIBOX_REGISTRY_CACHE="$AIBOX_HOME/registry.cache"
  mkdir -p "$AIBOX_HOME" "$AIBOX_MOD_DIR"
  # Source the main CLI. It's guarded so sourcing doesn't dispatch.
  # shellcheck disable=SC1090
  source "$AIBOX_BIN"
}

# Deterministic test-server shutdown: TERM, then KILL, then wait. A plain
# `kill; wait` once missed on a macOS CI runner — the orphaned http.server held
# the step's pipes and the job hung ~50 min AFTER the suite had already passed
# (runner cleanup log: "Terminate orphan process: (Python)").
_kill_srv() { # $1 = pid
  kill "$1" 2>/dev/null || true
  sleep 1
  kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

teardown() {
  [ -n "${AIBOX_HOME:-}" ] && rm -rf "$AIBOX_HOME" 2>/dev/null || true
  # orphan sweep (belt & braces — see _kill_srv): the test http.server ports
  pkill -f "http.server 180" 2>/dev/null || true
  pkill -f "http.server 183" 2>/dev/null || true
}

#!/usr/bin/env bats
# CLI v2.1 surface: migration guidance for merged commands, dashboard modes,
# proxy check single-target routing, reserved module name 'self'.
# Hermetic: sandbox AIBOX_HOME/BIN_DIR + file:// registry (no network, no docker needed).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-surface.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT"
  mkdir -p "$AIBOX_HOME" "$SANDBOX/bin"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "merged commands leave migration guidance (list / ports / self family / proxy test)" {
  run bash "$REPO_ROOT/bin/aibox" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"'list' merged into dashboard"* ]]

  run bash "$REPO_ROOT/bin/aibox" ports
  [ "$status" -ne 0 ]
  [[ "$output" == *"'ports' merged into dashboard"* ]]

  run bash "$REPO_ROOT/bin/aibox" self update
  [ "$status" -ne 0 ]
  [[ "$output" == *"merged into the standard verbs"* ]]
  [[ "$output" == *"aibox uninstall self"* ]]

  run bash "$REPO_ROOT/bin/aibox" proxy test
  [ "$status" -ne 0 ]
  [[ "$output" == *"'proxy test' merged into"* ]]
}

@test "check without args dies pointing at check <module>|self" {
  run bash "$REPO_ROOT/bin/aibox" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"aibox check <module>|self"* ]]
}

@test "dashboard --available lists the registry catalog (file:// source)" {
  run bash "$REPO_ROOT/bin/aibox" dashboard --available
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Available modules"* ]]
  [[ "$output" == *"base"* ]]
  [[ "$output" == *"gitlab"* ]]
}

@test "dashboard overview carries VERSION column and the port table" {
  run bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"VERSION"* ]]
  [[ "$output" == *"Port assignments:"* ]]
}

@test "proxy check <url> = single-target mode; no proxy configured → clear die" {
  # sandbox has no proxy config and no clash state → deterministic offline refusal
  run bash "$REPO_ROOT/bin/aibox" proxy check http://127.0.0.1:9
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proxy configured"* ]]
}

@test "scaffolder rejects the reserved name 'self'" {
  run bash "$REPO_ROOT/scripts/new-module.sh" self --out "$SANDBOX/tools"
  [ "$status" -eq 2 ]
  [[ "$output" == *"reserved"* ]]
}

@test "validator rejects a module named 'self'" {
  mkdir -p "$SANDBOX/tools/self"
  cat > "$SANDBOX/tools/self/module.yaml" <<'YAML'
name: self
version: 1.0.0
description: "illegal reserved name"
dir: tools/self
hooks:
  install: install.sh
checks:
  disk_gb: 1
YAML
  printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$SANDBOX/tools/self/install.sh"
  run env VALIDATE_TOOLS_DIR="$SANDBOX/tools" bash "$REPO_ROOT/scripts/validate-module.sh" self
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved"* ]]
}

@test "update self passes AIBOX_RAW through to install.sh (live-caught regression pin)" {
  # Without the passthrough, a SHA-pinned/mirrored AIBOX_RAW only affects the
  # install.sh fetch; the payload silently comes from the default branch CDN.
  grep -q 'AIBOX_RAW="$AIBOX_RAW" AIBOX_VERIFY=' "$REPO_ROOT/bin/aibox"
}

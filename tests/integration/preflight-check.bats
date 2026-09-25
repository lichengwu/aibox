#!/usr/bin/env bats
# Integration: end-to-end preflight via the real CLI (local file:// registry).
# Needs: docker daemon + network (core-domain probes, daemon pull probe).
# READ-ONLY: runs `aibox check` paths only — never installs or mutates deployments.

setup_file() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  SANDBOX="$(mktemp -d 2>/dev/null || echo /tmp/aibox-it-check.$$)"
  export SANDBOX
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT"
  export AIBOX_CHECK_TIMEOUT=10
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR"
}

teardown_file() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "aibox check self — environment check passes (core domains, docker, disk)" {
  run bash "$REPO_ROOT/bin/aibox" check self
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"environment check"* ]] || false
  [[ "$output" == *"raw.githubusercontent.com"* ]] || false
  [[ "$output" == *"docker daemon reachable"* || "$output" == *"docker not available"* ]] || false
  # the disk line reads "disk free:    <N>G at AIBOX_HOME" — assert the label, not a
  # literal value (this assertion said "disk free at AIBOX_HOME", which could never match)
  [[ "$output" == *"disk free:"* ]] || false
}

@test "aibox check base — full preflight (deps, disk, daemon pull probe or cache short-circuit)" {
  run bash "$REPO_ROOT/bin/aibox" check base
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"Preflight passed: base"* ]] || false
  [[ "$output" == *"docker"* ]] || false
  [[ "$output" == *"disk:"* ]] || false
  # NOTE: deliberately NO docker-pull assertion — base declares no checks.docker_pull
  # (its images go through the docker.io pool at `base start`, probed by the daemon);
  # the old assertion ("cached" || "daemon can pull") could never match either.
}

@test "aibox check windmill — strict services gate: fails while base is not installed, hint shows the fix" {
  run bash "$REPO_ROOT/bin/aibox" check windmill
  [ "$status" -ne 0 ]
  [[ "$output" == *"base not installed"* ]]
  [[ "$output" == *"install base"* ]]
  [[ "$output" == *"Preflight FAILED"* ]]
}

@test "aibox check <unknown> — dies with Unknown module" {
  run bash "$REPO_ROOT/bin/aibox" check nosuchmodule
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown module"* ]]
}

@test "install without args — usage shows --skip-checks" {
  run bash "$REPO_ROOT/bin/aibox" install
  [ "$status" -ne 0 ]
  [[ "$output" == *"--skip-checks"* ]]
}

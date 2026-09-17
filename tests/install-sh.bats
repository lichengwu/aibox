#!/usr/bin/env bats
# install.sh bootstrap regression tests (no network: file:// source; sandboxed HOME).
# Locks the atomic temp+mv install (a live self-update once overwrote the RUNNING
# bin/aibox in place → the old bash process executed garbage: "line 1442: ugh:
# command not found") and the checksum pin/verify flow.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-inst.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  export SHELL="/bin/bash"   # deterministic rc-file choice
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export AIBOX_RAW="file://$REPO_ROOT"
  unset AIBOX_SHA256 AIBOX_VERIFY
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

@test "clean install: binary lands executable, no temp leftovers, rc updated in sandbox HOME" {
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -x "$AIBOX_BIN_DIR/aibox" ]
  run "$AIBOX_BIN_DIR/aibox" version
  [[ "$output" == aibox* ]]
  # atomic install leaves no .aibox.download.* temp behind
  [ "$(ls -a "$AIBOX_BIN_DIR" | grep -c '^\.aibox\.download\.' || true)" = "0" ]
  # PATH hint written into the SANDBOX home only
  grep -q "$AIBOX_BIN_DIR" "$HOME/.bashrc"
}

@test "wrong AIBOX_SHA256 pin: install dies, previous binary untouched, temp cleaned" {
  # pre-existing "old" install
  mkdir -p "$AIBOX_BIN_DIR"
  printf 'old-binary\n' > "$AIBOX_BIN_DIR/aibox"
  chmod 0755 "$AIBOX_BIN_DIR/aibox"
  run env AIBOX_SHA256="deadbeef" bash "$REPO_ROOT/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checksum mismatch"* ]]
  # the tampered download never replaced the existing binary
  [ "$(cat "$AIBOX_BIN_DIR/aibox")" = "old-binary" ]
  [ "$(ls -a "$AIBOX_BIN_DIR" | grep -c '^\.aibox\.download\.' || true)" = "0" ]
}

@test "correct AIBOX_SHA256 pin: install succeeds with Checksum OK" {
  local real; real="$(_sha256 "$REPO_ROOT/bin/aibox")"
  run env AIBOX_SHA256="$real" bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checksum OK"* ]]
  [ -x "$AIBOX_BIN_DIR/aibox" ]
}

@test "re-install is idempotent (self-update path)" {
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -x "$AIBOX_BIN_DIR/aibox" ]
  [ "$(ls -a "$AIBOX_BIN_DIR" | grep -c '^\.aibox\.download\.' || true)" = "0" ]
}

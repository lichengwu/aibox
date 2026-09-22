#!/usr/bin/env bats
# Module install/dispatch regression tests (file:// source, sandboxed; no network).
# Locks: nested `files:` entries (cli/openmaic) download correctly — download_module
# must mkdir -p the parent dir — and `aibox <module> <action>` passes through to svc.sh.
# Installs use --skip-checks on purpose: this file tests install MECHANICS, and the
# real openmaic preflight probes the network (github.com + daemon pull) — preflight
# behavior is tested offline in tests/preflight.bats and live in
# tests/integration/preflight-check.bats. The sandbox has no base install, so the
# services readiness gate would (correctly) block these installs otherwise.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-mod.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export AIBOX_RAW="file://$REPO_ROOT"
  unset AIBOX_PROFILE
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "install openmaic: nested cli/ file lands in modules dir + BIN_DIR, marker written" {
  run bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks
  [ "$status" -eq 0 ]
  # the nested files: entry (cli/openmaic) — regression for the cli/ restructure:
  # download_module must create modules/openmaic/cli/ before curl -o
  [ -f "$AIBOX_HOME/modules/openmaic/cli/openmaic" ]
  [ -x "$AIBOX_HOME/modules/openmaic/cli/openmaic" ]
  # install hook copied the CLI to BIN_DIR (from the nested cli/ source path)
  [ -x "$AIBOX_BIN_DIR/openmaic" ]
  # installed marker
  grep -q '^AIBOX_INSTALLED_openmaic=' "$AIBOX_HOME/installed.sh"
}

@test "aibox openmaic version: svc pass-through reaches the dispatched CLI" {
  bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  run bash "$REPO_ROOT/bin/aibox" openmaic version
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.0.1"* ]]
}

@test "uninstall openmaic: marker + cache removed (no other profile holds it)" {
  bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  run bash "$REPO_ROOT/bin/aibox" uninstall openmaic --yes
  [ "$status" -eq 0 ]
  ! grep -q '^AIBOX_INSTALLED_openmaic=' "$AIBOX_HOME/installed.sh"
  [ ! -d "$AIBOX_HOME/modules/openmaic" ]
}

@test "profile-scoped install: prod marker coexists with base, uninstall keeps shared cache" {
  # install under base, then under prod
  bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  bash "$REPO_ROOT/bin/aibox" --profile prod install openmaic --skip-checks >/dev/null 2>&1
  grep -q '^AIBOX_INSTALLED_openmaic=' "$AIBOX_HOME/installed.sh"
  grep -q '^AIBOX_INSTALLED_openmaic__prod=' "$AIBOX_HOME/installed.sh"
  # uninstall prod → base marker + shared script cache survive (live-machine bug #3)
  run bash "$REPO_ROOT/bin/aibox" --profile prod uninstall openmaic --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"script cache retained"* ]]
  grep -q '^AIBOX_INSTALLED_openmaic=' "$AIBOX_HOME/installed.sh"
  [ -f "$AIBOX_HOME/modules/openmaic/cli/openmaic" ]
  # uninstall base → now the cache goes
  run bash "$REPO_ROOT/bin/aibox" uninstall openmaic --yes
  [ "$status" -eq 0 ]
  [ ! -d "$AIBOX_HOME/modules/openmaic" ]
}

@test "shared include: declares includes → _common.sh lands in the cache, single-source identical" {
  # The include mechanism: repo tools/_shared/common.sh → cache _common.sh.
  # Locks: (1) the file is downloaded for a module declaring includes: [common],
  # (2) byte-identical to the repo single source, (3) lib.sh resolves it in the
  # cache layout and the repo layout.
  run bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks
  [ "$status" -eq 0 ]
  [ -f "$AIBOX_HOME/modules/openmaic/_common.sh" ]
  cmp -s "$AIBOX_HOME/modules/openmaic/_common.sh" "$REPO_ROOT/tools/_shared/common.sh"
  # cache-layout resolution: sourcing the cached lib.sh exposes the shared functions
  run env bash -c ". '$AIBOX_HOME/modules/openmaic/lib.sh' && type docker_pool_prepull >/dev/null && type log >/dev/null && type die >/dev/null && echo functions-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == "functions-ok" ]]
  # repo-layout resolution: direct execution finds ../_shared/common.sh
  run bash -c "cd '$REPO_ROOT' && env AIBOX_MODULE=openmaic bash tools/openmaic/svc.sh status 2>&1 | head -1"
  [ "$status" -eq 0 ]
}

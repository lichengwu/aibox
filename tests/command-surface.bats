#!/usr/bin/env bats
# Command-surface regression tests for the user-facing commands the fast suite
# previously never executed (revealed by scripts/coverage.sh — the proxy command
# family, merged-command guidance, dev-guide, and the module update flow).
# All offline: probes point at dead ports, registry via file://.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-cs.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  unset AIBOX_PROXY_URL AIBOX_PROXY_ENABLED
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "proxy show: no config → 'none (direct connection)', exit 0" {
  run bash "$REPO_ROOT/bin/aibox" proxy show
  [ "$status" -eq 0 ]
  [[ "$output" == *"config      none (direct connection)"* ]]
}

@test "proxy env: no config → clear die (nonzero)" {
  run bash "$REPO_ROOT/bin/aibox" proxy env
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proxy configured"* ]]
}

@test "proxy set <dead proxy> non-interactive: declines, writes NOTHING" {
  # non-tty stdin → ask_confirm takes the conservative default (spec §Interactive
  # confirmation); a dead port makes the pre-save probe fail deterministically.
  run bash "$REPO_ROOT/bin/aibox" proxy set http://127.0.0.1:1 </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Non-interactive environment, declining"* ]]
  [[ "$output" == *"Cancelled, config unchanged"* ]]
  [ ! -f "$AIBOX_HOME/config" ]
}

@test "proxy toggle on/off: flips AIBOX_PROXY_ENABLED, config retained" {
  printf 'AIBOX_PROXY_URL="http://127.0.0.1:7897"\n' >"$AIBOX_HOME/config"
  run bash "$REPO_ROOT/bin/aibox" proxy off
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disabled (config retained"* ]]
  grep -q '^AIBOX_PROXY_ENABLED="0"$' "$AIBOX_HOME/config"
  run bash "$REPO_ROOT/bin/aibox" proxy on
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enabled http://127.0.0.1:7897"* ]]
  grep -q '^AIBOX_PROXY_ENABLED="1"$' "$AIBOX_HOME/config"
}

@test "proxy toggle without a configured proxy: clear die" {
  run bash "$REPO_ROOT/bin/aibox" proxy off
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proxy configured yet"* ]]
}

@test "proxy unset: clears the URL, config file survives as a template" {
  printf 'AIBOX_PROXY_URL="http://127.0.0.1:7897"\n' >"$AIBOX_HOME/config"
  run bash "$REPO_ROOT/bin/aibox" proxy unset
  [ "$status" -eq 0 ]
  [[ "$output" == *"Proxy config cleared"* ]]
  grep -q '^AIBOX_PROXY_URL=""$' "$AIBOX_HOME/config"
}

@test "ports: merged-command guidance, points at dashboard" {
  run bash "$REPO_ROOT/bin/aibox" ports
  [ "$status" -ne 0 ]
  [[ "$output" == *"'ports' merged into dashboard"* ]]
  [[ "$output" == *"aibox dashboard"* ]]
}

@test "dev-guide: <module> dev-guide renders homepage/docs links (file:// registry)" {
  export AIBOX_RAW="file://$REPO_ROOT"
  run bash "$REPO_ROOT/bin/aibox" clash dev-guide
  [ "$status" -eq 0 ]
  [[ "$output" == *"clash v"* ]]
  [[ "$output" == *"homepage:"*"github.com/MetaCubeX/mihomo"* ]]
  [[ "$output" == *"dev guide:  tools/clash/docs/DEVELOPMENT.md"* ]]
}

_fake_repo() { # $1=dest — a self-contained fake registry (openmaic + its include)
  mkdir -p "$1/tools/_shared" "$1/tools/openmaic"
  cp "$REPO_ROOT/tools/openmaic/module.yaml" "$REPO_ROOT/tools/openmaic/lib.sh" \
    "$REPO_ROOT/tools/openmaic/install.sh" "$REPO_ROOT/tools/openmaic/uninstall.sh" \
    "$REPO_ROOT/tools/openmaic/update.sh" "$REPO_ROOT/tools/openmaic/svc.sh" "$1/tools/openmaic/"
  mkdir -p "$1/tools/openmaic/cli"
  cp "$REPO_ROOT/tools/openmaic/cli/openmaic" "$1/tools/openmaic/cli/openmaic"
  cp "$REPO_ROOT/tools/_shared/common.sh" "$1/tools/_shared/common.sh"
}

@test "update <module>: version bump → the transition is reported (old → new), hook runs" {
  local repo="$SANDBOX/repo"
  _fake_repo "$repo"
  export AIBOX_RAW="file://$repo"
  AIBOX_NO_AUTO_DEPS=1 bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  # bump the fake registry's module version (the "remote" moved); cur is read
  # from the fake yaml so the test survives real-version drift
  local cur
  cur="$(sed -n 's/^version: *//p' "$repo/tools/openmaic/module.yaml" | head -1)"
  sed -i.bak "s/^version: .*/version: 9.9.9/" "$repo/tools/openmaic/module.yaml" && rm -f "$repo/tools/openmaic/module.yaml.bak"
  # openmaic declares a hard services: dep on base — the sandbox has no base,
  # so this update exercises the documented --skip-checks bypass (the download +
  # marker + include-ship path is what's under test, not the preflight gate)
  run bash "$REPO_ROOT/bin/aibox" update openmaic --skip-checks
  [ "$status" -eq 0 ]
  [[ "$output" == *"openmaic module scripts updated: ${cur} → 9.9.9"* ]] || false
  # the shared include rides along on update too
  [ -f "$AIBOX_HOME/modules/openmaic/_common.sh" ] || false
  # the installed marker carries the NEW version
  grep -q 'AIBOX_INSTALLED_openmaic="9.9.9"' "$AIBOX_HOME/installed.sh" || false
}

@test "update <module>: same version → scripts NOT re-fetched, update hook STILL runs" {
  local repo="$SANDBOX/repo"
  _fake_repo "$repo"
  export AIBOX_RAW="file://$repo"
  AIBOX_NO_AUTO_DEPS=1 bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  local cur
  cur="$(sed -n 's/^version: *//p' "$repo/tools/openmaic/module.yaml" | head -1)"
  run bash "$REPO_ROOT/bin/aibox" update openmaic --skip-checks
  [ "$status" -eq 0 ]
  # the script half is skipped (no per-file fetches, no "re-fetching" banner)
  [[ "$output" == *"openmaic scripts already at ${cur} (no re-fetch) — running the update hook"* ]] || false
  [[ "$output" != *"re-fetching"* ]] || false
  [[ "$output" != *"fetch tools/openmaic"* ]] || false
  # the HOOK still ran — its own verdict (the app half) is reported by it:
  # openmaic's hook self-reports "up to date (…), no update needed"
  [[ "$output" == *"openmaic is up to date"* ]] || false
  [[ "$output" == *"openmaic module scripts unchanged at ${cur} · update hook ran above"* ]] || false
}

@test "update <module>: same version but BROKEN cache → self-heal re-fetch at the same version" {
  local repo="$SANDBOX/repo"
  _fake_repo "$repo"
  export AIBOX_RAW="file://$repo"
  AIBOX_NO_AUTO_DEPS=1 bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  rm -f "$AIBOX_HOME/modules/openmaic/svc.sh"   # a broken cache must re-fetch even at the same version
  local cur
  cur="$(sed -n 's/^version: *//p' "$repo/tools/openmaic/module.yaml" | head -1)"
  run bash "$REPO_ROOT/bin/aibox" update openmaic --skip-checks
  [ "$status" -eq 0 ]
  [[ "$output" == *"openmaic module scripts refreshed at ${cur} (no version change)"* ]] || false
  [ -f "$AIBOX_HOME/modules/openmaic/svc.sh" ] || false
}

@test "update <module>: missing DECLARED extra file (cli/) forces a re-fetch too" {
  local repo="$SANDBOX/repo"
  _fake_repo "$repo"
  export AIBOX_RAW="file://$repo"
  AIBOX_NO_AUTO_DEPS=1 bash "$REPO_ROOT/bin/aibox" install openmaic --skip-checks >/dev/null 2>&1
  local cur
  cur="$(sed -n 's/^version: *//p' "$repo/tools/openmaic/module.yaml" | head -1)"
  rm -f "$AIBOX_HOME/modules/openmaic/cli/openmaic"   # a declared files: entry
  run bash "$REPO_ROOT/bin/aibox" update openmaic --skip-checks
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"openmaic module scripts refreshed at ${cur} (no version change)"* ]] || false
  [ -s "$AIBOX_HOME/modules/openmaic/cli/openmaic" ] || false
}

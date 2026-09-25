#!/usr/bin/env bats
# Upgrade / rollback framework (0.17.0).
# The engine already had a systematic design (upgrade: stanza, multi-hop stops,
# health-gated recreate, .env backup). This suite locks the pieces that were
# missing after the review:
#   - the rollback is VERIFIED, and the exit codes match the documented contract
#     (10 = failed but rolled back, 20 = not ready after rollback)
#   - every transition is RECORDED (rollback point + history + live version)
#   - `--rollback` restores the recorded pin, and swaps the point (undo-the-undo)
#   - a pre-upgrade DATA snapshot is taken for shared-base consumers (--no-backup
#     skips it); modules without a declared DB say so explicitly
#   - the installed marker keeps the MODULE version (the app version lives in the
#     state file) — overwriting it made `aibox update` report bogus transitions
#   - the dashboard detail shows config/upgrade/rollback rows (the docs point there)
# Offline: a file:// fixture module, stubbed docker + svc hooks.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-upg.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_CONFIG="$AIBOX_HOME/config"
  export AIBOX_REGISTRY_CACHE="$AIBOX_HOME/registry.cache"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR" "$AIBOX_MOD_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AIBOX_BIN="$REPO_ROOT/bin/aibox"
  export AIBOX_RAW="file://$REPO_ROOT"
  unset AIBOX_PROFILE
  unset WM_SVC_FAIL_FIRST WM_SVC_COUNT WM_SVC_LOG
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

# One module with an upgrade: stanza. Its svc.sh counts starts (so a test can make
# the first start fail = failed upgrade, the second succeed = healthy rollback)
# and records the live version on success.
_fixture_repo() { # $1=repo
  local r="$1"
  mkdir -p "$r/tools/fixture"
  cat >"$r/tools/fixture/module.yaml" <<'YAML'
name: fixture
version: 1.0.0
description: "upgrade-engine fixture"
dir: tools/fixture
actions:
  - start
  - stop
  - status
hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh
upgrade:
  source: dockerhub-tags
  repo: example/fixture
  tag_pattern: ^v[0-9]+\.[0-9]+\.[0-9]+$
  images:
    - FX_IMAGE=ghcr.io/example/fixture:
YAML
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'root="${AIBOX_HOME}/apps/fixture"' 'mkdir -p "$root"' \
    'printf "FX_IMAGE=ghcr.io/example/fixture:1.0.0\n" >"$root/.env"' \
    'printf "1.0.0" >"$root/live"' >"$r/tools/fixture/install.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'deploy_root() { printf "%s/apps/fixture" "${AIBOX_HOME}"; }' \
    'dashboard_info() { printf "version=%s\n" "$(cat "${AIBOX_HOME}/apps/fixture/live" 2>/dev/null || echo 1.0.0)"; printf "state=ok\n"; }' \
    >"$r/tools/fixture/lib.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'n=$(( $(cat "${WM_SVC_COUNT:-/tmp/fx.count}" 2>/dev/null || echo 0) + 1 ))' \
    'printf "%s" "$n" >"${WM_SVC_COUNT:-/tmp/fx.count}"' \
    'printf "svc %s\n" "$1" >>"${WM_SVC_LOG:-/tmp/fx.log}"' \
    '[ "$1" = start ] || exit 0' \
    '[ "$n" -le "${WM_SVC_FAIL_FIRST:-0}" ] && exit 1' \
    'pin="$(sed -n "s/^FX_IMAGE=.*://p" "${AIBOX_HOME}/apps/fixture/.env" | head -1)"' \
    'printf "%s" "${pin:-1.0.0}" >"${AIBOX_HOME}/apps/fixture/live"' \
    'exit 0' >"$r/tools/fixture/svc.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$r/tools/fixture/uninstall.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$r/tools/fixture/update.sh"
  chmod +x "$r"/tools/fixture/*.sh
}

_install_fixture() { # $1=repo
  export AIBOX_RAW="file://$1"
  bash "$AIBOX_BIN" install fixture --skip-checks >/dev/null 2>&1
  grep -q '^AIBOX_INSTALLED_fixture=' "$AIBOX_INSTALLED" || { echo "fixture install failed"; return 1; }
}

# Run cmd_upgrade with the resolver + docker stubbed (no network, no daemon).
_run_upgrade() { # $1 = snippet with the cmd_upgrade invocation
  run bash -c "
    export HOME='$SANDBOX/home'
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$AIBOX_MOD_DIR' AIBOX_INSTALLED='$AIBOX_INSTALLED'
    export WM_SVC_COUNT='$SANDBOX/svc.count' WM_SVC_LOG='$SANDBOX/svc.log'
    export WM_SVC_FAIL_FIRST='${WM_SVC_FAIL_FIRST:-0}'
    source '$AIBOX_BIN'
    dockerhub_tags_fetch() { printf 'v1.0.0\nv1.1.0\n'; }
    docker() {
      case \"\${1:-}\" in
        exec) printf 'SQL\n' ;;
      esac
      return 0
    }
    $1
  "
}

_state() { # $1=module $2=key
  sed -n "s/^$2=//p" "$AIBOX_HOME/upgrades/$1.state" 2>/dev/null | head -1
}

# ---------- success path: state recorded, marker untouched -------------------

@test "upgrade: success records from/to/status/live and keeps the module marker" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(_state fixture from)" = "1.0.0" ] || { cat "$AIBOX_HOME/upgrades/fixture.state" 2>/dev/null; false; }
  [ "$(_state fixture to)" = "1.1.0" ] || false
  [ "$(_state fixture status)" = "ok" ] || false
  [ "$(_state fixture live)" = "1.1.0" ] || { cat "$AIBOX_HOME/upgrades/fixture.state"; false; }
  grep -q '^FX_IMAGE=ghcr.io/example/fixture:1.1.0$' "$AIBOX_HOME/apps/fixture/.env" || false
  grep -q '1.0.0 → 1.1.0 ok' "$AIBOX_HOME/upgrades/fixture.log" || { cat "$AIBOX_HOME/upgrades/fixture.log" 2>/dev/null; false; }
  # the module marker stays the MODULE version (app version lives in the state)
  grep -q '^AIBOX_INSTALLED_fixture="1.0.0"$' "$AIBOX_INSTALLED" || { cat "$AIBOX_INSTALLED"; false; }
  [[ "$output" == *"rollback point"* ]] || { echo "$output"; false; }
}

@test "upgrade: no shared-base DB declared → says the rollback is pin-only" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  [[ "$output" == *"no shared-base database declared"* ]] || { echo "$output"; false; }
  [ -z "$(_state fixture databak)" ] || false
}

# ---------- pre-upgrade data snapshot (shared-base consumers) ----------------

@test "upgrade: a shared-base DB is snapshotted before the version moves" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  # the DB link comes from the module metadata (cache module.yaml), the container
  # from base.env — declared AFTER install so the install path needs no base
  printf 'services:\n  - base:postgres#fxdb\n' >>"$AIBOX_MOD_DIR/fixture/module.yaml"
  printf 'AIBOX_POSTGRES_HOST=aibox-base-pg\nAIBOX_POSTGRES_USER=aibox\n' >"$AIBOX_HOME/base.env"
  _run_upgrade 'cmd_upgrade fixture --yes'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local snap; snap="$(_state fixture databak)"
  [ -n "${snap}" ] || { cat "$AIBOX_HOME/upgrades/fixture.state"; false; }
  [ -s "${snap}" ] || { echo "snapshot missing: ${snap}"; false; }
  [[ "$output" == *"data snapshot:"* ]] || { echo "$output"; false; }
}

@test "upgrade --no-backup: skips the data snapshot and says so" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  printf 'services:\n  - base:postgres#fxdb\n' >>"$AIBOX_MOD_DIR/fixture/module.yaml"
  printf 'AIBOX_POSTGRES_HOST=aibox-base-pg\nAIBOX_POSTGRES_USER=aibox\n' >"$AIBOX_HOME/base.env"
  _run_upgrade 'cmd_upgrade fixture --yes --no-backup'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$(_state fixture databak)" ] || false
  [[ "$output" == *"skipped (--no-backup)"* ]] || { echo "$output"; false; }
}

# ---------- failure: verified rollback + the documented exit codes -----------

@test "upgrade failure with a healthy rollback → exit 10, state rolled-back" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  WM_SVC_FAIL_FIRST=1 _run_upgrade 'cmd_upgrade fixture --yes'
  [ "$status" -eq 10 ] || { echo "expected 10, got $status"; echo "$output"; false; }
  [ "$(_state fixture status)" = "rolled-back" ] || { cat "$AIBOX_HOME/upgrades/fixture.state"; false; }
  grep -q '^FX_IMAGE=ghcr.io/example/fixture:1.0.0$' "$AIBOX_HOME/apps/fixture/.env" || { cat "$AIBOX_HOME/apps/fixture/.env"; false; }
  [[ "$output" == *"rolled back to 1.0.0"*"healthy"* ]] || { echo "$output"; false; }
}

@test "upgrade failure AND a failing rollback → exit 20, manual state" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  WM_SVC_FAIL_FIRST=9 _run_upgrade 'cmd_upgrade fixture --yes'
  [ "$status" -eq 20 ] || { echo "expected 20, got $status"; echo "$output"; false; }
  [ "$(_state fixture status)" = "manual" ] || { cat "$AIBOX_HOME/upgrades/fixture.state"; false; }
  [[ "$output" == *"manual intervention"* ]] || { echo "$output"; false; }
  [[ "$output" == *"aibox upgrade fixture --to 1.0.0"* ]] || false
}

# ---------- manual rollback point -------------------------------------------

@test "--rollback: restores the recorded pin and swaps the rollback point" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  [ "$(_state fixture from)" = "1.0.0" ] || false
  _run_upgrade 'cmd_upgrade fixture --rollback --yes'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^FX_IMAGE=ghcr.io/example/fixture:1.0.0$' "$AIBOX_HOME/apps/fixture/.env" || { cat "$AIBOX_HOME/apps/fixture/.env"; false; }
  [ "$(_state fixture status)" = "rolled-back" ] || { cat "$AIBOX_HOME/upgrades/fixture.state"; false; }
  # undo-the-undo: the version we just left is the new rollback point
  [ "$(_state fixture from)" = "1.1.0" ] || { cat "$AIBOX_HOME/upgrades/fixture.state"; false; }
  grep -q 'rolled-back-by-user' "$AIBOX_HOME/upgrades/fixture.log" || false
}

@test "--rollback without a recorded point: clean die with the pin hint" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --rollback --yes'
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"no rollback point recorded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--to <version>"* ]] || false
}

@test "--history: shows the recorded transition and the rollback hint" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  _run_upgrade 'cmd_upgrade fixture --history'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pin     : 1.0.0 → 1.1.0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"live: 1.1.0"* ]] || false
  [[ "$output" == *"--rollback"* ]] || false
}

@test "--history with nothing recorded: friendly no-op" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --history'
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"no upgrade recorded"* ]] || { echo "$output"; false; }
}

@test "--check: prints the recorded rollback point when there is one" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  _run_upgrade 'cmd_upgrade fixture --check'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"rollback: 1.0.0"* ]] || { echo "$output"; false; }
}

# ---------- downgrade honesty ------------------------------------------------

@test "downgrade: --to an older version warns about one-way migrations" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  # move the pin forward first, then try to go back
  sed -i.bak 's/:1.0.0$/:2.0.0/' "$AIBOX_HOME/apps/fixture/.env" 2>/dev/null || true
  awk '{ if ($0 ~ /^FX_IMAGE=/) print "FX_IMAGE=ghcr.io/example/fixture:2.0.0"; else print }' "$AIBOX_HOME/apps/fixture/.env" >"$SANDBOX/env.tmp" \
    && mv "$SANDBOX/env.tmp" "$AIBOX_HOME/apps/fixture/.env"
  _run_upgrade 'cmd_upgrade fixture --to 1.1.0 --yes'
  [[ "$output" == *"downgrade 2.0.0 → 1.1.0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"one-way"* ]] || false
}

# ---------- dashboard surface (the docs point here) -------------------------

@test "dashboard <module>: shows the upgrade state, the rollback point and config keys" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  run bash "$AIBOX_BIN" dashboard fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"upgrade"*"1.0.0 → 1.1.0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"rollback"*"aibox upgrade fixture --rollback"* ]] || { echo "$output"; false; }
}

@test "dashboard <module>: without a recorded upgrade it points at --check" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  run bash "$AIBOX_BIN" dashboard fixture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no upgrade recorded"*"aibox upgrade fixture --check"* ]] || { echo "$output"; false; }
}

@test "dashboard <module>: config row counts the declared knobs" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  printf 'env:\n  FX_KNOB: "1 — a knob"\n  FX_OTHER: "(unset) — another"\n' >>"$AIBOX_MOD_DIR/fixture/module.yaml"
  run bash "$AIBOX_BIN" dashboard fixture
  [[ "$output" == *"2 key(s) · aibox fixture config list"* ]] || { echo "$output"; false; }
}

# ---------- usage surface ----------------------------------------------------

@test "local modes: --history works with an unreachable registry (offline)" {
  local repo="$SANDBOX/fx"
  _fixture_repo "$repo"
  _install_fixture "$repo"
  _run_upgrade 'cmd_upgrade fixture --yes'
  run bash -c "
    export HOME='$SANDBOX/home'
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$AIBOX_MOD_DIR' AIBOX_INSTALLED='$AIBOX_INSTALLED'
    export AIBOX_RAW='https://dead.invalid/aibox'
    source '$AIBOX_BIN'
    cmd_upgrade fixture --history
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pin     : 1.0.0 → 1.1.0"* ]] || { echo "$output"; false; }
}

@test "unknown module: reported as Unknown module, not 'not installed'" {
  run bash "$AIBOX_BIN" upgrade definitely-not-a-module
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"Unknown module"* ]] || { echo "$output"; false; }
}

@test "usage: the new verbs are advertised in the upgrade usage line" {
  run bash "$AIBOX_BIN" upgrade fixture --help 2>&1
  [[ "$output" == *"--rollback"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--history"* ]] || false
}
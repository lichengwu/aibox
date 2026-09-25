#!/usr/bin/env bats
# Historical cases — the bug log turned into regression locks.
# Sources: AGENTS.md pitfall log (#1–#11), the CHANGELOG "Fixed" entries across
# releases, and the live-caught bugs recorded during development.
# tests/CASES.md carries the full bug → suite mapping; this file holds the cases
# that had no lock before (the audit found exactly four gaps: pitfall #3/#5, #4,
# #6 and the docker-daemon wording).
# Offline: stubbed curl/docker, no network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AIBOX_BIN="$REPO_ROOT/bin/aibox"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-hist.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_CONFIG="$SANDBOX/config"
  mkdir -p "$AIBOX_HOME" "$AIBOX_MOD_DIR"
  unset AIBOX_PROFILE
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true; }

# ---------- pitfall #3 + #5: the proxy verdict follows %{proxy_used} -----------

_proxy_test_with() { # $1 = mocked "%{http_code} %{proxy_used}" output ("" = curl failure)
  # NOTE: sourcing bin/aibox does NOT run the top-level init (load_config/apply_proxy
  # live behind the source guard), so the test sets the resolved URL explicitly —
  # the subject here is the VERDICT logic, not the config plumbing.
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_CONFIG='$AIBOX_CONFIG'
    source '$AIBOX_BIN'
    AIBOX_PROXY_URL='http://127.0.0.1:7897'
    curl() { printf '%s' \"$1\"; }
    cmd_proxy_test http://example.test
  "
}

@test "pitfall #3: a 200 answered DIRECT is not reported as proxy success" {
  _proxy_test_with "200 0"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"proxy_used=0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"DIRECT connection"* ]] || { echo "$output"; false; }
  [[ "$output" != *"traffic confirmed going through the proxy"* ]] || { echo "false positive: reported as proxied"; false; }
}

@test "pitfall #3: only proxy_used=1 counts as confirmed proxying" {
  _proxy_test_with "200 1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Via proxy"* ]] || { echo "$output"; false; }
  [[ "$output" != *"DIRECT connection"* ]] || { echo "$output"; false; }
}

@test "pitfall #5: an empty -w (connection failure) is a failure, not a blank verdict" {
  _proxy_test_with ""
  [[ "$output" == *"000"* ]] || { echo "empty curl output not normalized to 000"; echo "$output"; false; }
}

@test "pitfall #5: a build without %{proxy_used} says so instead of guessing" {
  # real curl prints a trailing space for an unsupported %{var} → `used` stays empty
  _proxy_test_with "200 "
  [[ "$output" == *"can't confirm whether proxy was used"* ]] || { echo "$output"; false; }
}

# ---------- pitfall #4: proxy persists into the module's OWN config -------------

@test "pitfall #4: openmaic writes the proxy where its CLI reads (OPENMAIC_CONF_DIR)" {
  local confdir="$SANDBOX/openmaic-etc"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' OPENMAIC_CONF_DIR='$confdir'
    export AIBOX_PROXY_URL='http://10.0.0.2:7897' AIBOX_PROXY_ENABLED=1
    mkdir -p '$confdir'
    . '$REPO_ROOT/tools/openmaic/lib.sh'
    sync_proxy_to_conf
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$confdir/openmaic.conf" ] || { echo "no conf written at the CLI's path"; false; }
  grep -q 'OPENMAIC_PROXY_URL="http://10.0.0.2:7897"' "$confdir/openmaic.conf" || { cat "$confdir/openmaic.conf"; false; }
  # and the hook path defaults to /etc/openmaic when the override is absent
  grep -q 'OPENMAIC_CONF_DIR:-/etc/openmaic' "$REPO_ROOT/tools/openmaic/lib.sh" || false
}

# ---------- pitfall #6: multibyte characters are never sliced ------------------

@test "pitfall #6: the spinner uses whole-frame array elements (never slices multibyte)" {
  # SPIN is a function-local array, so the guard is the source shape + the byte math
  grep -qE "SPIN=\( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' \)" "$AIBOX_BIN" \
    || { echo "complete-frame array literal missing"; false; }
  grep -qE 'probe_render "\$\{SPIN\[\$frame_i\]\}"' "$AIBOX_BIN" || { echo "frames not taken by index"; false; }
  ! grep -qE '\$\{(SPIN|spin):' "$AIBOX_BIN" || { echo "multibyte slicing reintroduced"; false; }
  # byte-level proof: one braille frame is 3 UTF-8 bytes (slicing would show 1-2)
  run bash -c "printf '%s' '⠋' | wc -c | tr -d ' '"
  [ "$output" = "3" ] || { echo "frame byte width=${output}"; false; }
}

# ---------- live-caught: the docker daemon wording (B4) ------------------------

@test "live: a package install that yields no docker CLI does not blame the daemon" {
  [ "$(id -u)" = "0" ] || skip "root-only branch"
  # A PATH WITHOUT docker, built from symlinks (deterministic in every image —
  # the test image itself ships the docker CLI for the integration phase).
  local shim="$SANDBOX/nodocker" b
  mkdir -p "$shim"
  for b in /usr/bin/* /bin/*; do ln -sf "$b" "$shim/" 2>/dev/null || true; done
  rm -f "$shim/docker"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' PATH='$shim'
    source '$AIBOX_BIN'
    _pm_install() { return 0; }          # 'succeeds' but installs nothing
    install_dep docker
  "
  [ "$status" -ne 0 ] || { echo "should fail when no CLI appeared"; false; }
  [[ "$output" == *"no docker CLI appeared"* ]] || { echo "$output"; false; }
  [[ "$output" != *"daemon"*"didn't start"* ]] || { echo "blamed the daemon without a CLI"; echo "$output"; false; }
}

# ---------- pitfall #10 discipline (the assertion gate) ------------------------

@test "pitfall #10: the bash-3.2 assertion quirk is documented AND gated in CI" {
  # On macOS bash 3.2 a failing [[ ]] does NOT trip errexit; the only complete
  # detector is running the suite under 3.2 itself — which is exactly what the
  # macOS CI job does. Lock both the documentation and the gate's presence.
  grep -q 'macos-bash32' "$REPO_ROOT/.github/workflows/lint.yml" || { echo "no macos-bash32 job"; false; }
  grep -q 'does NOT trigger' "$REPO_ROOT/AGENTS.md" || false
  grep -q 'bash 3.2' "$REPO_ROOT/.github/workflows/lint.yml" || false
}
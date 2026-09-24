#!/usr/bin/env bats
# UX hardening regressions (0.15.0) — the behaviors added by the UX review:
#   unknown-arg suggestions · preflight hard/soft hints · bounded PM installs ·
#   dep-install dedupe · node distro skip · NO_AUTO_DEPS coverage ·
#   require_curl/require_docker · catalog footnote · check-self coverage ·
#   profile derivation output · bin-dir precedence parity.
# Offline and fast: sourced functions + file:// registry fixtures, no network.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-ux.$$")"
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
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

# ---------- unknown-argument UX (suggestions) --------------------------------

@test "unknown verb: typo suggests the real verb (instal → install)" {
  run bash "$AIBOX_BIN" instal base
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"did you mean: aibox install?"* ]] || false
}

@test "unknown verb: transposition typo suggests too (chekc → check)" {
  run bash "$AIBOX_BIN" chekc base
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"did you mean: aibox check?"* ]] || false
}

@test "unknown module: typo suggests the closest module name" {
  run bash "$AIBOX_BIN" basee --help
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"did you mean: aibox base?"* ]] || false
  [[ "$output" == *"dashboard --available"* ]] || false
}

@test "unknown module: no near match still gets the catalog hint, no suggestion" {
  run bash "$AIBOX_BIN" zzzznope --help
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"Unknown module: zzzznope"* ]] || false
  [[ "$output" == *"dashboard --available"* ]] || false
  [[ "$output" != *"did you mean"* ]] || false
}

@test "registered module named like a verb is not hijacked (clash passes through)" {
  # regression: the verb-suggestion must only fire on a typo, never on an exact
  # verb-shaped module name — `aibox clash dev-guide` used to die as "clash"
  run bash "$AIBOX_BIN" clash --help
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"usage:  aibox clash <action>"* ]] || false
}

# ---------- preflight: hard vs soft hints ------------------------------------

@test "preflight: hard dep failure withholds the --skip-checks hint" {
  run bash -c "
    source '$AIBOX_BIN'
    install_dep() { return 1; }
    AIBOX_MODULE_fake_deps='zz-nope'
    preflight_module fake
  "
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"can't be bypassed"* ]] || false
  [[ "$output" != *"re-run with --skip-checks to bypass"* ]] || false
}

@test "preflight: soft failure (disk) still offers the --skip-checks bypass" {
  run bash -c "
    source '$AIBOX_BIN'
    AIBOX_MODULE_fake2_checks_disk_gb=99999999
    preflight_module fake2
  "
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"--skip-checks to bypass"* ]] || false
}

# ---------- package-manager auto-install bounds + dedupe ---------------------

@test "_pm_install: a hanging package manager is bounded and killed" {
  local pm="$SANDBOX/hangpm"
  printf '#!/usr/bin/env bash\nsleep 60\n' >"$pm"
  chmod +x "$pm"
  run bash -c "source '$AIBOX_BIN'; AIBOX_PM_TIMEOUT=5 _pm_install '$pm' foo"
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"timed out after 5s"* ]] || false
  [[ "$output" == *"AIBOX_PM_TIMEOUT"* ]] || false
}

@test "_pm_install: announces the install and the bound up front" {
  local pm="$SANDBOX/okpm"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$pm"
  chmod +x "$pm"
  run bash -c "source '$AIBOX_BIN'; _pm_install '$pm' foo bar"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"install -y foo bar"* ]] || false
  [[ "$output" == *"bounded 600s"* ]] || false
}

@test "preflight deps: docker + docker-compose share ONE install attempt (dedupe)" {
  run bash -c "
    source '$AIBOX_BIN'
    install_dep() { printf 'DEP-INSTALL %s\n' \"\$1\"; return 1; }
    dep_satisfied() { return 1; }
    AIBOX_MODULE_fake_deps='docker docker-compose'
    _preflight_deps fake || true
  "
  [ "$(printf '%s\n' "$output" | grep -c '^DEP-INSTALL ')" = "1" ] || false
  [[ "$output" == *"already attempted this run"* ]] || false
}

@test "install_dep node: too-old distro candidate → skip + nvm guidance" {
  [ "$(id -u)" = "0" ] || skip "root-only branch"
  command -v apt-get >/dev/null 2>&1 || skip "apt-only branch"
  run bash -c "
    source '$AIBOX_BIN'
    _pm_install() { printf 'PM-RAN\n'; return 0; }
    apt-cache() { printf '  Candidate: 18.19.1+dfsg-6ubuntu5\n'; }
    install_dep node 22
  "
  [[ "$output" == *"would not satisfy the check"* ]] || false
  [[ "$output" == *"nvm install 22"* ]] || false
  [[ "$output" != *"PM-RAN"* ]] || false
}

@test "preflight deps: AIBOX_NO_AUTO_DEPS=1 blocks PM auto-install too" {
  run bash -c "
    source '$AIBOX_BIN'
    install_dep() { printf 'PM-RAN\n'; return 0; }
    dep_satisfied() { return 1; }
    AIBOX_NO_AUTO_DEPS=1 AIBOX_MODULE_fake_deps='docker' _preflight_deps fake
  "
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"auto-install disabled: AIBOX_NO_AUTO_DEPS=1"* ]] || false
  [[ "$output" != *"PM-RAN"* ]] || false
}

# ---------- missing-primitive messages ---------------------------------------

@test "require_curl: missing curl → actionable message, not a misleading download error" {
  run bash -c "source '$AIBOX_BIN'; PATH=/nonexistent; require_curl"
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"curl is required"* ]] || false
}

@test "require_docker: missing docker → actionable message, not a raw lib line" {
  run bash -c "C_RED=; C_RST=; . '$REPO_ROOT/tools/_shared/common.sh'; PATH=/nonexistent; require_docker"
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"docker CLI not found"* ]] || false
  [[ "$output" == *"aibox check"* ]] || false
}

@test "base compose wrapper dies through require_docker (the live-caught crash path)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    source '$REPO_ROOT/tools/_shared/common.sh'
    source '$REPO_ROOT/tools/base/lib.sh'
    PATH=/nonexistent
    compose ps
  "
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"docker CLI not found"* ]] || false
}

# ---------- catalog + environment check --------------------------------------

@test "catalog: the VERSION column is explained (module vs app version)" {
  run bash "$AIBOX_BIN" dashboard --available
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"VERSION = the aibox module version"* ]] || false
  [[ "$output" == *"base"* ]] || false
}

@test "check self: node/npm are reported and the stale docker list is gone" {
  run bash "$AIBOX_BIN" check self
  [[ "$output" == *"node"* ]] || false
  [[ "$output" == *"npm"* ]] || false
  [[ "$output" != *"needed by base/openmaic/windmill"* ]] || false
}

# ---------- profile derivation output ----------------------------------------

@test "profile: creating one reports the derived ports/containers (base)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    export AIBOX_PROFILE=uxprof
    source '$REPO_ROOT/tools/_shared/common.sh'
    source '$REPO_ROOT/tools/base/lib.sh'
    printf 'PG=%s\n' \"\$PG_PORT\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Profile 'uxprof' derived: postgres="* ]] || false
  [[ "$output" == *"containers aibox-base-uxprof-postgres"* ]] || false
  [[ "$output" =~ PG=[0-9]+ ]] || false
}

@test "profile: creating one reports the derived port (pi-web)" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME'
    export AIBOX_PROFILE=uxprof
    source '$REPO_ROOT/tools/_shared/common.sh'
    source '$REPO_ROOT/tools/pi-web/lib.sh'
    printf 'PORT=%s\n' \"\$PORT\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Profile 'uxprof' derived: port="* ]] || false
  [[ "$output" == *"service=pi-web-uxprof"* ]] || false
}

# ---------- bin-dir precedence parity with the bootstrap ---------------------

@test "bin dir: explicit AIBOX_BIN_DIR always wins" {
  local w="$SANDBOX/explicit" h="$SANDBOX/fh1"
  mkdir -p "$h"
  run env AIBOX_BIN_DIR="$w" HOME="$h" bash -c "source '$AIBOX_BIN'; printf '%s\n' \"\$AIBOX_BIN_DIR\""
  [[ "$output" == "$w" ]] || false
}

@test "bin dir: ~/.local/bin in PATH keeps the classic layout (no churn)" {
  local h="$SANDBOX/fh2" w="$SANDBOX/wbin2"
  mkdir -p "$h/.local/bin" "$w"
  run env -u AIBOX_BIN_DIR HOME="$h" PATH="$w:$h/.local/bin:$PATH" bash -c "source '$AIBOX_BIN'; printf '%s\n' \"\$AIBOX_BIN_DIR\""
  [[ "$output" == "$h/.local/bin" ]] || false
}

@test "bin dir: in-PATH writable system dir preferred when ~/.local/bin is absent" {
  local h="$SANDBOX/fh3" w="$SANDBOX/wbin3"
  mkdir -p "$h" "$w"
  run env -u AIBOX_BIN_DIR HOME="$h" PATH="$w:$PATH" AIBOX_SYSTEM_BIN_DIRS="$w" bash -c "source '$AIBOX_BIN'; printf '%s\n' \"\$AIBOX_BIN_DIR\""
  [[ "$output" == "$w" ]] || false
}

@test "bin dir: manager and bootstrap resolve the SAME dir (precedence parity)" {
  local h="$SANDBOX/fh4" w="$SANDBOX/wbin4"
  mkdir -p "$h" "$w"
  run env -u AIBOX_BIN_DIR HOME="$h" PATH="$w:$PATH" AIBOX_SYSTEM_BIN_DIRS="$w" bash -c "source '$AIBOX_BIN'; printf '%s\n' \"\$AIBOX_BIN_DIR\""
  [ "$status" -eq 0 ] || false
  [ "$output" = "$w" ] || false
  run env -u AIBOX_BIN_DIR HOME="$h" PATH="$w:$PATH" AIBOX_SYSTEM_BIN_DIRS="$w" AIBOX_RAW="file://$REPO_ROOT" bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -x "$w/aibox" ] || false
}

@test "install.sh: a re-install reports the update flavor, not 'first module'" {
  local h="$SANDBOX/fh5" w="$SANDBOX/wbin5"
  mkdir -p "$h" "$w"
  run env HOME="$h" AIBOX_BIN_DIR="$w" AIBOX_RAW="file://$REPO_ROOT" bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Install your first module"* ]] || false
  run env HOME="$h" AIBOX_BIN_DIR="$w" AIBOX_RAW="file://$REPO_ROOT" bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"re-installed"*"already up to date"* ]] || false
  [[ "$output" != *"Install your first module"* ]] || false
}
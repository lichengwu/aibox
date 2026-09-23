#!/usr/bin/env bats
# Configuration system (spec §Configuration): shared helpers + the generic
# config action + the env: declaration contract + validator rules.

load test_helper

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-cfg.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  mkdir -p "$AIBOX_HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/_shared/common.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

# ---------- KEY=value store helpers ----------

@test "cfg_kv_get: bare and quoted values; empty when unset/missing file" {
  printf '# comment\nA=1\nB="two words"\n' >"$SANDBOX/s.env"
  [ "$(cfg_kv_get "$SANDBOX/s.env" A)" = "1" ]
  [ "$(cfg_kv_get "$SANDBOX/s.env" B)" = "two words" ]
  [ -z "$(cfg_kv_get "$SANDBOX/s.env" MISSING)" ]
  [ -z "$(cfg_kv_get "$SANDBOX/nope.env" A)" ]
}

@test "cfg_kv_set: replaces in place, preserves comments/order/mode; appends new keys" {
  printf '# deploy env\nPORT=30300\nSECRET="abc"\n' >"$SANDBOX/s.env"
  chmod 600 "$SANDBOX/s.env"
  cfg_kv_set "$SANDBOX/s.env" PORT 30400
  cfg_kv_set "$SANDBOX/s.env" NEWKEY v1
  head -1 "$SANDBOX/s.env" | grep -q '^# deploy env$'
  grep -q '^PORT="30400"$' "$SANDBOX/s.env"
  grep -q '^SECRET="abc"$' "$SANDBOX/s.env"
  grep -q '^NEWKEY="v1"$' "$SANDBOX/s.env"
  # portable mode check (BSD/GNU stat shapes differ; find -perm works everywhere)
  find "$SANDBOX/s.env" -perm 600 | grep -q .
  # idempotent
  cfg_kv_set "$SANDBOX/s.env" PORT 30400
  [ "$(grep -c '^PORT=' "$SANDBOX/s.env")" = "1" ]
}

@test "cfg_kv_unset: removes the key line, keeps the rest" {
  printf '# c\nA=1\nB=2\n' >"$SANDBOX/s.env"
  cfg_kv_unset "$SANDBOX/s.env" A
  ! grep -q '^A=' "$SANDBOX/s.env"
  grep -q '^B=2$' "$SANDBOX/s.env"
}

# ---------- declaration parsing + masking ----------

@test "cfg_env_declare: KEY/default/desc/flags; block ends at the next top-level key" {
  printf 'name: x\nversion: 1.0.0\nenv:\n  K1: "dv — desc one [secret]"\n  K2: "dv2 — desc two"\nchecks:\n  disk_gb: 5\n' \
    >"$SANDBOX/module.yaml"
  run cfg_env_declare "$SANDBOX/module.yaml"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
  printf '%s\n' "$output" | head -1 | grep -q $'^K1\tdv\tdesc one\tsecret'
  printf '%s\n' "$output" | tail -1 | grep -q $'^K2\tdv2\tdesc two\t$'
}

@test "cfg_secret_p: PASSWORD/SECRET/TOKEN/*KEY match; ports/users don't" {
  cfg_secret_p A_PASSWORD && cfg_secret_p MY_SECRET && cfg_secret_p AUTH_TOKEN && cfg_secret_p API_KEY
  ! cfg_secret_p NEW_API_PORT && ! cfg_secret_p PG_USER
}

# ---------- the generic config action ----------

_setup_fake_module() {
  printf 'name: fake\nversion: 1.0.0\nenv:\n  FAKE_PORT: "3000 — the port"\n  FAKE_SECRET: "auto — the secret [secret]"\nusage:\n  config: "Show/set config keys"\n' \
    >"$SANDBOX/module.yaml"
  printf '# store\nFAKE_PORT=3000\nFAKE_SECRET=hunter2\n' >"$SANDBOX/.env"
  chmod 600 "$SANDBOX/.env"
}

@test "cfg_action list: values, masked secrets, unset keys show defaults + apply hint" {
  _setup_fake_module
  export CFG_YAML="$SANDBOX/module.yaml" CFG_STORE="$SANDBOX/.env" CFG_APPLY="aibox fake restart"
  run cfg_action list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE 'FAKE_PORT +3000 +the port'
  printf '%s\n' "$output" | grep -q '••••••••'        # masked secret (grep: byte-safe)
  ! printf '%s\n' "$output" | grep -q 'hunter2'       # the plaintext never leaks
  printf '%s\n' "$output" | grep -q "apply changes: aibox fake restart"
}

@test "cfg_action get/set/unset roundtrip (non-interactive: apply hint, not auto-run)" {
  _setup_fake_module
  export CFG_YAML="$SANDBOX/module.yaml" CFG_STORE="$SANDBOX/.env" CFG_APPLY="aibox fake restart"
  run cfg_action get FAKE_PORT
  [ "$status" -eq 0 ]
  [ "$output" = "3000" ]
  run cfg_action set FAKE_PORT 9999 </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"set FAKE_PORT"* ]]
  [[ "$output" == *"apply when ready: aibox fake restart"* ]]
  [ "$(cfg_kv_get "$SANDBOX/.env" FAKE_PORT)" = "9999" ]
  run cfg_action unset FAKE_PORT </dev/null
  [ "$status" -eq 0 ]
  ! grep -q '^FAKE_PORT=' "$SANDBOX/.env"
  [[ "$output" == *"back to default: 3000"* ]]
}

# ---------- manager: --help renders the config section ----------

@test "module --help: config keys section renders from the env: declaration (offline)" {
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_fake="1.0.0"
EOF2
  mkdir -p "$AIBOX_HOME/modules/fake"
  printf 'name: fake\nversion: 1.0.0\ndescription: "x"\nenv:\n  FAKE_PORT: "3000 — the port"\n  FAKE_SECRET: "auto — the secret [secret]"\n  FAKE_KNOB: "0 — infra knob [knob]"\n' \
    >"$AIBOX_HOME/modules/fake/module.yaml"
  run bash "$REPO_ROOT/bin/aibox" fake --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "config:  aibox fake config"
  printf '%s\n' "$output" | grep -qE 'FAKE_PORT +3000 +the port'
  printf '%s\n' "$output" | grep -qE 'FAKE_SECRET +auto +the secret \[secret\]'
  printf '%s\n' "$output" | grep -vq "FAKE_KNOB" || true
  ! printf '%s\n' "$output" | grep -q "FAKE_KNOB"   # knobs excluded from the view
}

# ---------- validator: env: rules ----------

@test "validator: malformed env entry → ERROR; README drift → WARN; clean declaration → PASS" {
  # a fully-conformant module (the other mandatory rules must not mask the env
  # rules under test): checks + upstream + docs + lib + hooks
  local mod="$SANDBOX/tools/badcfg"
  mkdir -p "$mod/docs"
  local base_yaml='name: badcfg
version: 1.0.0
description: "x"
dir: tools/badcfg
hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh
actions:
  - status
usage:
  status: "x"
checks:
  disk_gb: 1
upstream:
  homepage: https://example.com
  docs: https://example.com/docs
'
  for h in install.sh uninstall.sh update.sh svc.sh; do
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >"$mod/$h"
  done
  printf '# dev notes\n' >"$mod/docs/DEVELOPMENT.md"
  printf '# shared lib\n' >"$mod/lib.sh"
  printf '# badcfg\n' >"$mod/README.md"

  # ① malformed (parses, but the value lacks the quoted shape) → ERROR
  printf '%senv:\n  BADKEY: no quotes here\n' "$base_yaml" >"$mod/module.yaml"
  run env VALIDATE_TOOLS_DIR="$SANDBOX/tools" bash "$REPO_ROOT/scripts/validate-module.sh" badcfg
  [ "$status" -eq 1 ]
  [[ "$output" == *"env entry malformed"* ]]

  # ② drift: README documents an undeclared key → WARN only (exit 0)
  printf '%senv:\n  GOOD_KEY: "dv — ok"\n' "$base_yaml" >"$mod/module.yaml"
  printf '# badcfg\n\n| Variable | Default |\n| --- | --- |\n| `UNDECLARED_KEY` | x |\n| `GOOD_KEY` | dv |\n' >"$mod/README.md"
  run env VALIDATE_TOOLS_DIR="$SANDBOX/tools" bash "$REPO_ROOT/scripts/validate-module.sh" badcfg
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q "UNDECLARED_KEY"
  printf '%s\n' "$output" | grep -q "does not declare it"

  # ③ clean: aligned + the key referenced in code → no env warnings at all
  printf '#!/usr/bin/env bash\nset -euo pipefail\nGOOD_KEY=1\n' >"$mod/svc.sh"
  printf '# badcfg\n\n| Variable | Default |\n| --- | --- |\n| `GOOD_KEY` | dv |\n' >"$mod/README.md"
  run env VALIDATE_TOOLS_DIR="$SANDBOX/tools" bash "$REPO_ROOT/scripts/validate-module.sh" badcfg
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! printf '%s\n' "$output" | grep -qE "env entry|README documents"
}

# ---------- pi-web: plist store + key mapping + restart re-reads the file ----------

@test "pi-web config: set writes the plist (runtime key mapping), get reads it back" {
  # write_service → resolve_node requires node >= 22 (CI runners ship 20)
  command -v node >/dev/null 2>&1 || skip "node unavailable"
  node -e 'process.versions.node.split(".")[0] >= 22' 2>/dev/null || skip "node < 22 (write_service floor)"
  # PLIST lives under the sandbox HOME; write_service regenerates it with
  # resolve_node + npm prefix (both work locally). The aibox-facing key
  # PI_WEB_BIND is stored as the app's runtime name PI_WEB_HOSTNAME.
  local sb
  sb="$(mktemp -d)"
  run bash -c "HOME='$sb' '$REPO_ROOT/tools/pi-web/svc.sh' config set PI_WEB_BIND 127.0.0.1 </dev/null"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"service definition regenerated"* ]]
  [ -f "$sb/Library/LaunchAgents/pi-web.plist" ]
  # the runtime key name carries the value
  run /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_WEB_HOSTNAME' "$sb/Library/LaunchAgents/pi-web.plist"
  [ "$output" = "127.0.0.1" ]
  # the aibox-facing name reads it back (mapping)
  run bash -c "HOME='$sb' '$REPO_ROOT/tools/pi-web/svc.sh' config get PI_WEB_BIND"
  [ "$output" = "127.0.0.1" ]
  rm -rf "$sb"
}

@test "pi-web restart: bootout + bootstrap (re-reads the definition — the kickstart fix)" {
  # the plist/launchctl path is Darwin-specific (Linux uses systemctl restart,
  # standard behavior); skip on Linux runners
  [ "$(uname -s)" = "Darwin" ] || skip "launchd path is macOS-only"
  local sb fb
  sb="$(mktemp -d)"
  # fake launchctl records bootout/bootstrap; bootstrap succeeds
  fb="$sb/bin"
  mkdir -p "$fb"
  cat >"$fb/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >>"$LAUNCHCTL_LOG"
case "$1" in
print) exit 0 ;;
bootout) exit 0 ;;
bootstrap) exit 0 ;;
*) exit 1 ;;
esac
SH
  chmod +x "$fb/launchctl"
  # a plist must exist for restart to pass its guard
  mkdir -p "$sb/Library/LaunchAgents"
  printf '<?xml version="1.0"?><plist version="1.0"><dict></dict></plist>' \
    >"$sb/Library/LaunchAgents/pi-web.plist"
  export LAUNCHCTL_LOG="$sb/launchctl.log"
  run env HOME="$sb" PATH="$fb:$PATH" bash "$REPO_ROOT/tools/pi-web/svc.sh" restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"restarted (service definition re-read"* ]]
  # the call sequence: bootout BEFORE bootstrap (the re-read pair)
  grep -q "bootout" "$LAUNCHCTL_LOG"
  grep -q "bootstrap" "$LAUNCHCTL_LOG"
  local b_out b_in
  b_out="$(grep -n 'bootout' "$LAUNCHCTL_LOG" | head -1 | cut -d: -f1)"
  b_in="$(grep -n 'bootstrap' "$LAUNCHCTL_LOG" | head -1 | cut -d: -f1)"
  [ -n "$b_out" ] && [ -n "$b_in" ] && [ "$b_out" -lt "$b_in" ]
  rm -rf "$sb"
}

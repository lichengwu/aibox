#!/usr/bin/env bats
# self uninstall (v2: --purge / --yes only) + uninstall <module> --purge.
# Sandbox with fake modules; hooks append "<module> <profile> <purge>" markers.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-selfun.$$")"
  export HOME="$SANDBOX"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export MARKER_FILE="$SANDBOX/markers"
  # minimal file:// registry so cmd_uninstall's load_registry finds fakemod
  export AIBOX_RAW="file://$SANDBOX/reg"
  mkdir -p "$AIBOX_HOME/modules/fakemod" "$AIBOX_HOME/modules/othermod" \
           "$AIBOX_HOME/apps/fakemod" "$AIBOX_BIN_DIR" \
           "$SANDBOX/reg/tools/fakemod" "$SANDBOX/reg/tools/othermod"
  for m in fakemod othermod; do
    cat > "$AIBOX_HOME/modules/$m/uninstall.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "${AIBOX_MODULE:-?}" "${AIBOX_PROFILE:-?}" "${AIBOX_PURGE_DATA:-?}" >> "$MARKER_FILE"
HOOK
    cat > "$SANDBOX/reg/tools/$m/module.yaml" <<YAML
name: $m
version: 1.0.0
description: "fake module for uninstall tests"
dir: tools/$m
hooks:
  install: install.sh
  uninstall: uninstall.sh
YAML
  done
  cat > "$AIBOX_HOME/installed.sh" <<'INST'
AIBOX_INSTALLED_fakemod=1.0.0
AIBOX_INSTALLED_fakemod__devx=1.0.0
AIBOX_INSTALLED_othermod=0.1.0
INST
  echo "precious" > "$AIBOX_HOME/apps/fakemod/docker-compose.yml"
  echo "fake-manager" > "$AIBOX_BIN_DIR/aibox"
  printf 'alias ll="ls -l"\n# aibox\nexport PATH="%s:$PATH"\nalias gg="git grep"\n' "$AIBOX_BIN_DIR" > "$HOME/.zshrc"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "uninstall self --yes (default): manager only; hooks NOT run; apps + rc handled" {
  run bash "$REPO_ROOT/bin/aibox" uninstall self --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$MARKER_FILE" ]                                # no teardown
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]                        # manager binary gone
  [ -f "$AIBOX_HOME/apps/fakemod/docker-compose.yml" ]   # apps preserved (manageable)
  [ ! -f "$AIBOX_HOME/installed.sh" ]                    # manager state gone
  ! grep -q '^# aibox$' "$HOME/.zshrc"                   # rc block removed
  grep -q 'alias ll=' "$HOME/.zshrc"                     # other rc lines intact
  [[ "$output" == *"KEPT"* ]]
  [[ "$output" == *"aibox uninstall <module> --purge"* ]]  # teardown-path hints
  [[ "$output" == *"purge --apply"* ]]
}

@test "uninstall self --purge --yes: cascade — hooks per (module,profile) with PURGE=1, apps dropped" {
  run bash "$REPO_ROOT/bin/aibox" uninstall self --purge --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  sort "$MARKER_FILE" > "$SANDBOX/m.sorted"
  diff - "$SANDBOX/m.sorted" <<'EOF'
fakemod base 1
fakemod devx 1
othermod base 1
EOF
  [ ! -d "$AIBOX_HOME" ]            # purge removes everything incl. apps
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]
}

@test "uninstall self: non-interactive without --yes refuses (nothing changed)" {
  run bash "$REPO_ROOT/bin/aibox" uninstall self
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-run with --yes"* ]]
  [ -f "$AIBOX_BIN_DIR/aibox" ]
  [ -f "$AIBOX_HOME/installed.sh" ]
}

@test "uninstall self: v1 flag matrix is gone (unknown option dies)" {
  run bash "$REPO_ROOT/bin/aibox" uninstall self --services=remove --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option for uninstall"* ]]
}

@test "uninstall self: no modules installed → clean manager-only removal" {
  : > "$AIBOX_HOME/installed.sh"
  rm -rf "$AIBOX_HOME/modules" "$AIBOX_HOME/apps"
  run bash "$REPO_ROOT/bin/aibox" uninstall self --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]
  [ ! -d "$AIBOX_HOME" ]
  [[ "$output" == *"installed modules: none"* ]]
}

@test "uninstall <module> --purge: hook gets AIBOX_PURGE_DATA=1 and apps/<m> is swept" {
  run bash "$REPO_ROOT/bin/aibox" uninstall fakemod --purge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^fakemod base 1$' "$MARKER_FILE"
  [ ! -d "$AIBOX_HOME/apps/fakemod" ]
  # base-profile marker gone, devx marker kept (profile-scoped unmark)
  ! grep -q '^AIBOX_INSTALLED_fakemod=' "$AIBOX_HOME/installed.sh"
  grep -q '^AIBOX_INSTALLED_fakemod__devx=' "$AIBOX_HOME/installed.sh"
}

@test "uninstall <module> (no --purge): hook gets PURGE=0, apps preserved" {
  run bash "$REPO_ROOT/bin/aibox" uninstall othermod
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^othermod base 0$' "$MARKER_FILE"
  [ -d "$AIBOX_HOME/apps/fakemod" ]
  [ ! -d "$AIBOX_HOME/modules/othermod" ]   # cache removed (no other profile holds it)
}

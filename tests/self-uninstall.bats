#!/usr/bin/env bats
# self uninstall — selective teardown tests (sandboxed; no docker/network).
#
# Proves the three-layer semantics of `aibox self uninstall`:
#   services (per module+profile hook runs, --only/--except filters),
#   data     (AIBOX_PURGE_DATA=1 reaches hooks; apps/ dropped only on purge),
#   manager  (binary + state removed; apps/ PRESERVED when data=keep; rc block).
# Fake module hooks append "<module> <profile> <purge>" markers to $MARKER_FILE.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-selfun.$$")"
  export HOME="$SANDBOX"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export MARKER_FILE="$SANDBOX/markers"
  mkdir -p "$AIBOX_HOME/modules/fakemod" "$AIBOX_HOME/modules/othermod" \
           "$AIBOX_HOME/apps/fakemod" "$AIBOX_BIN_DIR"

  # Fake module hooks: record exactly what the manager passed in.
  for m in fakemod othermod; do
    cat > "$AIBOX_HOME/modules/$m/uninstall.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "${AIBOX_MODULE:-?}" "${AIBOX_PROFILE:-?}" "${AIBOX_PURGE_DATA:-?}" >> "$MARKER_FILE"
HOOK
  done

  # installed.sh: fakemod under base AND devx profiles; othermod under base.
  cat > "$AIBOX_HOME/installed.sh" <<'INST'
AIBOX_INSTALLED_fakemod=1.0.0
AIBOX_INSTALLED_fakemod__devx=1.0.0
AIBOX_INSTALLED_othermod=0.1.0
INST
  # deploy data + manager binary + rc block
  echo "precious" > "$AIBOX_HOME/apps/fakemod/docker-compose.yml"
  echo "fake-manager" > "$AIBOX_BIN_DIR/aibox"
  printf 'alias ll="ls -l"\n# aibox\nexport PATH="%s:$PATH"\nalias gg="git grep"\n' "$AIBOX_BIN_DIR" > "$SANDBOX/.zshrc"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

run_self_uninstall() {
  run bash "$REPO_ROOT/bin/aibox" self uninstall "$@"
}

@test "default (non-TTY): services kept, hooks NOT run, apps preserved, manager+rc removed" {
  run_self_uninstall --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$MARKER_FILE" ]                          # no teardown
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]                  # manager binary gone
  [ -f "$AIBOX_HOME/apps/fakemod/docker-compose.yml" ]  # apps preserved (services manageable)
  [ ! -f "$AIBOX_HOME/installed.sh" ]              # manager state gone
  [[ "$output" == *"services were NOT touched"* ]]
  # rc: marked block removed, other content intact
  [ -f "$SANDBOX/.zshrc" ]
  ! grep -q '^# aibox$' "$SANDBOX/.zshrc"
  grep -q 'alias ll=' "$SANDBOX/.zshrc"
  grep -q 'alias gg=' "$SANDBOX/.zshrc"
}

@test "--services=remove: hooks run per module AND profile, purge=0" {
  run_self_uninstall --services=remove --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  sort "$MARKER_FILE" > "$SANDBOX/m.sorted"
  diff - "$SANDBOX/m.sorted" <<'EOF'
fakemod base 0
fakemod devx 0
othermod base 0
EOF
  [ -f "$AIBOX_HOME/apps/fakemod/docker-compose.yml" ]  # data=keep → apps preserved
}

@test "--only filter: just the named module (all its profiles)" {
  run_self_uninstall --services=remove --only=fakemod --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  sort "$MARKER_FILE" > "$SANDBOX/m.sorted"
  diff - "$SANDBOX/m.sorted" <<'EOF'
fakemod base 0
fakemod devx 0
EOF
}

@test "--except filter: everything but the named module" {
  run_self_uninstall --services=remove --except=fakemod --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cat "$MARKER_FILE"
  [ "$(wc -l < "$MARKER_FILE" | tr -d ' ')" = "1" ]
  grep -q '^othermod base 0$' "$MARKER_FILE"
}

@test "--data=purge: hooks get AIBOX_PURGE_DATA=1 and apps/ is dropped" {
  run_self_uninstall --services=remove --data=purge --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^fakemod base 1$' "$MARKER_FILE"
  grep -q '^fakemod devx 1$' "$MARKER_FILE"
  [ ! -d "$AIBOX_HOME" ]        # purge removes the whole home incl. apps
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]
}

@test "--data=purge without --services=remove is refused" {
  run_self_uninstall --data=purge --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --services=remove"* ]]
  [ -f "$AIBOX_BIN_DIR/aibox" ]   # nothing changed
  [ -f "$AIBOX_HOME/installed.sh" ]
}

@test "--yes resolves services=ask to the SAFE side (keep)" {
  run_self_uninstall --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$MARKER_FILE" ]
  [[ "$output" == *"resolves to the safe side"* || "$output" == *"services were NOT touched"* ]]
}

@test "--no-rc keeps the shell rc block" {
  run_self_uninstall --yes --no-rc
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^# aibox$' "$SANDBOX/.zshrc"
}

@test "no modules installed: clean manager-only removal" {
  : > "$AIBOX_HOME/installed.sh"
  rm -rf "$AIBOX_HOME/modules" "$AIBOX_HOME/apps"
  run_self_uninstall --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]
  [ ! -d "$AIBOX_HOME" ]   # apps absent → home fully removed
  [[ "$output" == *"installed modules: none"* ]]
}

@test "invalid --services value dies with usage hint" {
  run_self_uninstall --services=maybe --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--services must be ask|remove|keep"* ]]
}

@test "missing hook: warns but continues (offline-safe, no registry needed)" {
  rm -f "$AIBOX_HOME/modules/othermod/uninstall.sh"
  run_self_uninstall --services=remove --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no cached uninstall hook for othermod"* ]]
  grep -q '^fakemod base 0$' "$MARKER_FILE"   # others still torn down
}

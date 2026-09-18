#!/usr/bin/env bats
# aibox-purge (standalone residue cleaner) + `aibox clean` wrapper — hermetic
# sandbox tests. PURGE_* env overrides redirect every root into the sandbox;
# host-touching scanners (docker/processes/npm) are disabled via guards so the
# tests never see — or touch — the real machine's state.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PURGE="$REPO_ROOT/scripts/purge.sh"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-purge.$$")"
  export PURGE_HOME="$SANDBOX/userhome"
  export PURGE_AIBOX_HOME="$SANDBOX/home"
  export PURGE_BIN_DIR="$SANDBOX/bin"
  export PURGE_ETC="$SANDBOX/etc"
  export PURGE_SYSTEMD_DIR="$SANDBOX/etc/systemd/system"
  export PURGE_NO_DOCKER=1
  export PURGE_NO_PROCS=1
  export PURGE_NO_NPM=1

  # plant residues: base + windmill (modules) and manager (bin/state/rc)
  mkdir -p "$PURGE_AIBOX_HOME/apps/base" "$PURGE_AIBOX_HOME/apps/windmill" "$PURGE_AIBOX_HOME/modules"
  echo x > "$PURGE_AIBOX_HOME/base.env"
  echo x > "$PURGE_AIBOX_HOME/installed.sh"
  mkdir -p "$PURGE_BIN_DIR"
  echo x > "$PURGE_BIN_DIR/aibox"
  echo x > "$PURGE_BIN_DIR/windmill"
  mkdir -p "$PURGE_ETC/windmill" "$PURGE_SYSTEMD_DIR"
  echo x > "$PURGE_SYSTEMD_DIR/windmill-backup.timer"
  mkdir -p "$PURGE_HOME/.config"
  printf 'alias ll="ls"\n# aibox\nexport PATH="%s:$PATH"\nalias gg="git"\n' "$PURGE_BIN_DIR" > "$PURGE_HOME/.zshrc"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "scan (dry-run): categorizes residue and deletes nothing" {
  run bash "$PURGE"
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"[base]"* ]]
  [[ "$output" == *"[windmill]"* ]]
  [[ "$output" == *"[manager]"* ]]
  [[ "$output" == *"base.env"* ]]
  [[ "$output" == *"windmill-backup.timer"* ]]
  [[ "$output" == *"# aibox PATH block"* ]]
  # nothing deleted
  [ -f "$PURGE_AIBOX_HOME/base.env" ]
  [ -f "$PURGE_BIN_DIR/aibox" ]
  [ -f "$PURGE_SYSTEMD_DIR/windmill-backup.timer" ]
}

@test "apply --only=windmill: scoped removal; base AND manager untouched" {
  run bash "$PURGE" --apply --only=windmill --yes
  [ "$status" -eq 0 ] || echo "$output"
  [ ! -d "$PURGE_AIBOX_HOME/apps/windmill" ]
  [ ! -f "$PURGE_BIN_DIR/windmill" ]
  [ ! -d "$PURGE_ETC/windmill" ]
  [ ! -f "$PURGE_SYSTEMD_DIR/windmill-backup.timer" ]
  # out of scope → intact (regression: manager used to be scanned unconditionally)
  [ -d "$PURGE_AIBOX_HOME/apps/base" ]
  [ -f "$PURGE_AIBOX_HOME/base.env" ]
  [ -f "$PURGE_BIN_DIR/aibox" ]
  grep -q '^# aibox$' "$PURGE_HOME/.zshrc"
}

@test "apply --keep-manager: module residue goes, manager survives" {
  run bash "$PURGE" --apply --keep-manager --yes
  [ "$status" -eq 0 ] || echo "$output"
  [ ! -d "$PURGE_AIBOX_HOME/apps/base" ]
  [ ! -d "$PURGE_AIBOX_HOME/apps/windmill" ]
  [ -f "$PURGE_BIN_DIR/aibox" ]
  [ -f "$PURGE_AIBOX_HOME/installed.sh" ]
  grep -q '^# aibox$' "$PURGE_HOME/.zshrc"
}

@test "apply full: everything gone, rc surgery keeps other lines, rescan clean" {
  run bash "$PURGE" --apply --yes
  [ "$status" -eq 0 ] || echo "$output"
  [ ! -e "$PURGE_BIN_DIR/aibox" ]
  [ ! -e "$PURGE_AIBOX_HOME" ]   # tidy finish removes the empty shell
  [ ! -d "$PURGE_ETC/windmill" ]
  [ -f "$PURGE_HOME/.zshrc" ]
  ! grep -q '^# aibox$' "$PURGE_HOME/.zshrc"
  grep -q 'alias ll=' "$PURGE_HOME/.zshrc"
  grep -q 'alias gg=' "$PURGE_HOME/.zshrc"
  run bash "$PURGE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no residue found"* ]]
}

@test "apply without --yes in a non-interactive shell refuses (nothing deleted)" {
  run bash "$PURGE" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-interactive"* ]]
  [ -f "$PURGE_BIN_DIR/aibox" ]
  [ -f "$PURGE_AIBOX_HOME/base.env" ]
}

@test "aibox clean forwards to aibox-purge with args" {
  cat > "$PURGE_BIN_DIR/aibox-purge" <<'FAKE'
#!/usr/bin/env bash
echo "PURGE-CALLED $*"
FAKE
  chmod +x "$PURGE_BIN_DIR/aibox-purge"
  run env AIBOX_HOME="$PURGE_AIBOX_HOME" AIBOX_BIN_DIR="$PURGE_BIN_DIR" \
    bash "$REPO_ROOT/bin/aibox" clean --apply --only=base
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"PURGE-CALLED --apply --only=base"* ]]
}

@test "aibox clean without aibox-purge prints the fetch hint and fails" {
  rm -f "$PURGE_BIN_DIR/aibox-purge"
  run env AIBOX_HOME="$PURGE_AIBOX_HOME" AIBOX_BIN_DIR="$PURGE_BIN_DIR" \
    bash "$REPO_ROOT/bin/aibox" clean
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/purge.sh"* ]]
}

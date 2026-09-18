#!/usr/bin/env bats
# `aibox purge` — residue scan/cleanup (v2 CLI: embedded in bin/aibox).
# Hermetic sandbox: PURGE_* env overrides redirect etc/systemd roots; HOME /
# AIBOX_HOME / AIBOX_BIN_DIR are sandboxed; host-touching scanners
# (docker/processes/npm) are disabled via guards so tests never see — or
# touch — the real machine's state.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AIBOX="$REPO_ROOT/bin/aibox"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-purge.$$")"
  export HOME="$SANDBOX/userhome"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export PURGE_ETC="$SANDBOX/etc"
  export PURGE_SYSTEMD_DIR="$SANDBOX/etc/systemd/system"
  export PURGE_NO_DOCKER=1
  export PURGE_NO_PROCS=1
  export PURGE_NO_NPM=1

  # plant residues: gitlab + windmill (modules) and self (manager bin/state/rc)
  mkdir -p "$AIBOX_HOME/apps/gitlab" "$AIBOX_HOME/apps/windmill" "$AIBOX_HOME/modules"
  echo x > "$AIBOX_HOME/installed.sh"
  mkdir -p "$AIBOX_BIN_DIR"
  echo x > "$AIBOX_BIN_DIR/aibox"
  echo x > "$AIBOX_BIN_DIR/windmill"
  mkdir -p "$PURGE_ETC/windmill" "$PURGE_SYSTEMD_DIR"
  echo x > "$PURGE_SYSTEMD_DIR/windmill-backup.timer"
  mkdir -p "$HOME/.config"
  printf 'alias ll="ls"\n# aibox\nexport PATH="%s:$PATH"\nalias gg="git"\n' "$AIBOX_BIN_DIR" > "$HOME/.zshrc"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "purge scan (dry-run): categorizes residue and deletes nothing" {
  run bash "$AIBOX" purge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"[gitlab]"* ]]
  [[ "$output" == *"[windmill]"* ]]
  [[ "$output" == *"[self]"* ]]
  [[ "$output" == *"windmill-backup.timer"* ]]
  [[ "$output" == *"# aibox PATH block"* ]]
  # nothing deleted
  [ -d "$AIBOX_HOME/apps/gitlab" ]
  [ -f "$AIBOX_BIN_DIR/aibox" ]
  [ -f "$PURGE_SYSTEMD_DIR/windmill-backup.timer" ]
}

@test "purge <module> --apply: scoped removal; other modules and manager untouched" {
  run bash "$AIBOX" purge windmill --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -d "$AIBOX_HOME/apps/windmill" ]
  [ ! -f "$AIBOX_BIN_DIR/windmill" ]
  [ ! -d "$PURGE_ETC/windmill" ]
  [ ! -f "$PURGE_SYSTEMD_DIR/windmill-backup.timer" ]
  # out of scope → intact
  [ -d "$AIBOX_HOME/apps/gitlab" ]
  [ -f "$AIBOX_BIN_DIR/aibox" ]
  grep -q '^# aibox$' "$HOME/.zshrc"
}

@test "purge self --apply: only the manager residue goes" {
  run bash "$AIBOX" purge self --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]
  ! grep -q '^# aibox$' "$HOME/.zshrc"
  grep -q 'alias ll=' "$HOME/.zshrc"   # rc surgery keeps other lines
  # module residue untouched
  [ -d "$AIBOX_HOME/apps/gitlab" ]
  [ -f "$AIBOX_BIN_DIR/windmill" ]
}

@test "purge --apply (all): everything gone, rc surgery, rescan clean" {
  run bash "$AIBOX" purge --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$AIBOX_BIN_DIR/aibox" ]
  [ ! -e "$AIBOX_HOME" ]          # tidy finish removes the empty shell
  [ -f "$HOME/.zshrc" ]
  ! grep -q '^# aibox$' "$HOME/.zshrc"
  grep -q 'alias ll=' "$HOME/.zshrc"
  grep -q 'alias gg=' "$HOME/.zshrc"
  run bash "$AIBOX" purge
  [ "$status" -eq 0 ]
  [[ "$output" == *"no residue found"* ]]
}

@test "purge --apply without --yes in a non-interactive shell refuses" {
  run bash "$AIBOX" purge --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-interactive"* ]]
  [ -f "$AIBOX_BIN_DIR/aibox" ]
  [ -d "$AIBOX_HOME/apps/gitlab" ]
}

@test "purge: unknown flag dies with usage" {
  run bash "$AIBOX" purge --only=gitlab
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option for purge"* ]]
}

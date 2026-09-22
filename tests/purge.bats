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


# ---- running-container interaction (the live-caught UX: --apply on running
# containers used to warn 2x per container and force a --stop re-run) ----

_fake_docker_running() {
  # FAKEBIN docker: ps/inspect report one running container for purge windmill
  local fb="$SANDBOX/fakebin"
  mkdir -p "$fb"
  cat >"$fb/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
ps)    printf 'windmill-windmill_server-1\n' ;;
info)  exit 0 ;;
inspect) printf 'running\n' ;;
volume)
  case "$2" in
  ls) printf 'windmill_db_data\nwindmill_caddy_data\n' ;;
  rm)
    echo "volume rm $3" >>"$DOCKER_CALLS_LOG"
    case "$3" in windmill_db_data) exit 0 ;; *) exit 1 ;; esac ;;
  esac
  exit 0 ;;
stop|rm)
  eval __last=\${$#}
  echo "$1 $__last" >>"$DOCKER_CALLS_LOG"
  exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/docker"
  export PATH="$fb:$PATH"
  export DOCKER_CALLS_LOG="$SANDBOX/docker-calls.log"
  : >"$DOCKER_CALLS_LOG"
  unset PURGE_NO_DOCKER
}

@test "purge --apply non-interactive (--yes, no --stop): running container skipped + ONE hint, dirs still swept" {
  _fake_docker_running
  run bash "$AIBOX" purge windmill --apply --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # the consolidated hint (was: 2 warnings per running container)
  [[ "$output" == *"1 running container(s) will be SKIPPED"* ]]
  [[ "$output" != *"is RUNNING — rerun with --stop"* ]]
  # dirs swept, container untouched (no stop/rm call)
  [ ! -d "$AIBOX_HOME/apps/windmill" ]
  ! grep -q "^stop" "$DOCKER_CALLS_LOG"
  # closing actionable line
  [[ "$output" == *"stop + sweep in one run: aibox purge windmill --apply --stop"* ]]
}

@test "purge --apply --stop: containers stopped BEFORE the volumes (call order)" {
  _fake_docker_running
  run bash "$AIBOX" purge windmill --apply --stop --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"stopped+removed container: windmill-windmill_server-1"* ]]
  # stop must precede every volume rm in the call log
  local first_stop first_vol
  first_stop="$(grep -n '^stop' "$DOCKER_CALLS_LOG" | head -1 | cut -d: -f1)"
  first_vol="$(grep -n '^volume' "$DOCKER_CALLS_LOG" | head -1 | cut -d: -f1)"
  [ -n "$first_stop" ] && [ -n "$first_vol" ] && [ "$first_stop" -lt "$first_vol" ]
}

@test "purge --apply: interactive decline on the stop question → containers kept, hint shown" {
  command -v expect >/dev/null 2>&1 || skip "expect unavailable (CI ubuntu)"
  _fake_docker_running
  export DOCKER_CALLS_LOG
  expect -c '
    spawn bash "'"$AIBOX"'" purge windmill --apply
    expect -re {Delete all} { send "y\r" }
    expect -re {container\(s\) are RUNNING} { send "n\r" }
    expect eof
  ' >/dev/null 2>&1
  # declined: no stop call, dir swept, closing hint stands
  ! grep -q "^stop" "$DOCKER_CALLS_LOG"
  [ ! -d "$AIBOX_HOME/apps/windmill" ]
}

@test "purge --apply: interactive ACCEPT on the stop question → one-run full sweep" {
  command -v expect >/dev/null 2>&1 || skip "expect unavailable (CI ubuntu)"
  _fake_docker_running
  export DOCKER_CALLS_LOG
  expect -c '
    spawn bash "'"$AIBOX"'" purge windmill --apply
    expect -re {Delete all} { send "y\r" }
    expect -re {container\(s\) are RUNNING} { send "y\r" }
    expect eof
  ' >/dev/null 2>&1
  # accepted: stop happened in the SAME run (no --stop flag, no re-run)
  grep -q "^stop windmill-windmill_server-1" "$DOCKER_CALLS_LOG"
}

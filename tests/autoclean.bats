#!/usr/bin/env bats
# `aibox autoclean` — residue scan/cleanup (v2 CLI: embedded in bin/aibox).
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

  # Residue knowledge is DECLARED by the module and captured into
  # $AIBOX_HOME/residue.conf at install time (download_module) — this is what a
  # real host has after `aibox install` + `aibox uninstall` (the rescue case).
  cat > "$AIBOX_HOME/residue.conf" <<'RESIDUE'
windmill_residue_bin=windmill
windmill_residue_paths=$ETC_DIR/windmill
windmill_residue_units=windmill-backup.service windmill-backup.timer
windmill_residue_containers=^windmill-
windmill_residue_volumes=^windmill_
gitlab_residue_containers=^aibox-gitlab$
gitlab_residue_volumes=^gitlab_gitlab_(config|logs|data)$
RESIDUE
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "autoclean scan (dry-run): categorizes residue and deletes nothing" {
  run bash "$AIBOX" autoclean
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

@test "autoclean <module> --apply: scoped removal; other modules and manager untouched" {
  run bash "$AIBOX" autoclean windmill --apply --yes
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
  run bash "$AIBOX" autoclean self --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -f "$AIBOX_BIN_DIR/aibox" ]
  ! grep -q '^# aibox$' "$HOME/.zshrc"
  grep -q 'alias ll=' "$HOME/.zshrc"   # rc surgery keeps other lines
  # module residue untouched
  [ -d "$AIBOX_HOME/apps/gitlab" ]
  [ -f "$AIBOX_BIN_DIR/windmill" ]
}

@test "autoclean --apply (all): everything gone, rc surgery, rescan clean" {
  run bash "$AIBOX" autoclean --apply --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$AIBOX_BIN_DIR/aibox" ]
  [ ! -e "$AIBOX_HOME" ]          # tidy finish removes the empty shell
  [ -f "$HOME/.zshrc" ]
  ! grep -q '^# aibox$' "$HOME/.zshrc"
  grep -q 'alias ll=' "$HOME/.zshrc"
  grep -q 'alias gg=' "$HOME/.zshrc"
  run bash "$AIBOX" autoclean
  [ "$status" -eq 0 ]
  [[ "$output" == *"no residue found"* ]]
}

@test "autoclean --apply without --yes in a non-interactive shell refuses" {
  run bash "$AIBOX" autoclean --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-interactive"* ]]
  [ -f "$AIBOX_BIN_DIR/aibox" ]
  [ -d "$AIBOX_HOME/apps/gitlab" ]
}

@test "autoclean: unknown flag dies with usage" {
  run bash "$AIBOX" autoclean --only=gitlab
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option for autoclean"* ]]
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

@test "autoclean --apply non-interactive (--yes, no --stop): running container skipped + ONE hint, dirs still swept" {
  _fake_docker_running
  run bash "$AIBOX" autoclean windmill --apply --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # the consolidated hint (was: 2 warnings per running container)
  [[ "$output" == *"1 running container(s) will be SKIPPED"* ]]
  [[ "$output" != *"is RUNNING — rerun with --stop"* ]]
  # dirs swept, container untouched (no stop/rm call)
  [ ! -d "$AIBOX_HOME/apps/windmill" ]
  ! grep -q "^stop" "$DOCKER_CALLS_LOG"
  # closing actionable line
  [[ "$output" == *"stop + sweep in one run: aibox autoclean windmill --apply --stop"* ]]
}

@test "autoclean --apply --stop: containers stopped BEFORE the volumes (call order)" {
  _fake_docker_running
  run bash "$AIBOX" autoclean windmill --apply --stop --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"stopped+removed container: windmill-windmill_server-1"* ]]
  # stop must precede every volume rm in the call log
  local first_stop first_vol
  first_stop="$(grep -n '^stop' "$DOCKER_CALLS_LOG" | head -1 | cut -d: -f1)"
  first_vol="$(grep -n '^volume' "$DOCKER_CALLS_LOG" | head -1 | cut -d: -f1)"
  [ -n "$first_stop" ] && [ -n "$first_vol" ] && [ "$first_stop" -lt "$first_vol" ]
}

@test "autoclean --apply: interactive decline on the stop question → containers kept, hint shown" {
  command -v expect >/dev/null 2>&1 || skip "expect unavailable (CI ubuntu)"
  _fake_docker_running
  export DOCKER_CALLS_LOG
  expect -c '
    spawn bash "'"$AIBOX"'" autoclean windmill --apply
    expect -re {Delete all} { send "y\r" }
    expect -re {container\(s\) are RUNNING} { send "n\r" }
    expect eof
  ' >/dev/null 2>&1
  # declined: no stop call, dir swept, closing hint stands
  ! grep -q "^stop" "$DOCKER_CALLS_LOG"
  [ ! -d "$AIBOX_HOME/apps/windmill" ]
}

@test "autoclean --apply: interactive ACCEPT on the stop question → one-run full sweep" {
  command -v expect >/dev/null 2>&1 || skip "expect unavailable (CI ubuntu)"
  _fake_docker_running
  export DOCKER_CALLS_LOG
  expect -c '
    spawn bash "'"$AIBOX"'" autoclean windmill --apply
    expect -re {Delete all} { send "y\r" }
    expect -re {container\(s\) are RUNNING} { send "y\r" }
    expect eof
  ' >/dev/null 2>&1
  # accepted: stop happened in the SAME run (no --stop flag, no re-run)
  grep -q "^stop windmill-windmill_server-1" "$DOCKER_CALLS_LOG"
}

# ---------- declared residue (module contract, not a manager map) ---------------

@test "residue declarations are captured at install time (download_module → residue.conf)" {
  rm -f "$AIBOX_HOME/residue.conf"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT'
    source '$AIBOX'
    download_module new-api >/dev/null 2>&1 || exit 1
    grep -c '^new-api_residue_' '$AIBOX_HOME/residue.conf'
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${output##*$'\n'}" = "2" ] || { echo "expected 2 declared fields, got: $output"; false; }
  grep -q '^new-api_residue_containers=\^aibox-new-api\$' "$AIBOX_HOME/residue.conf" || { cat "$AIBOX_HOME/residue.conf"; false; }
}

@test "rescue: declared residue is found with NO module cache (store survives uninstall)" {
  [ ! -d "$AIBOX_HOME/modules/windmill" ] || false    # fixture has no cache for it
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' PURGE_ETC='$PURGE_ETC' PURGE_NO_DOCKER=1
    source '$AIBOX'
    residue_systemd_units windmill
    residue_container_patterns windmill
  "
  [[ "$output" == *"windmill-backup.timer"* ]] || { echo "$output"; false; }
  [[ "$output" == *"^windmill-"* ]] || { echo "$output"; false; }
}

@test "the module's own residue_paths() wins over the declaration (escape hatch)" {
  mkdir -p "$AIBOX_HOME/modules/base"
  cp "$REPO_ROOT/tools/base/module.yaml" "$AIBOX_HOME/modules/base/"
  cp "$REPO_ROOT/tools/base/lib.sh" "$AIBOX_HOME/modules/base/"
  cp "$REPO_ROOT/tools/_shared/common.sh" "$AIBOX_HOME/modules/base/_common.sh"
  mkdir -p "$AIBOX_HOME/apps/base"
  touch "$AIBOX_HOME/base.env" "$AIBOX_HOME/base-prod.env"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' PURGE_ETC='$PURGE_ETC' PURGE_NO_DOCKER=1
    source '$AIBOX'
    residue_paths base
  "
  [[ "$output" == *"$AIBOX_HOME/base.env"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$AIBOX_HOME/base-prod.env"* ]] || { echo "$output"; false; }
}

@test "generic: every named profile's deploy root is a residue candidate" {
  mkdir -p "$AIBOX_HOME/apps/dify-prod"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' PURGE_ETC='$PURGE_ETC' PURGE_NO_DOCKER=1
    source '$AIBOX'
    residue_paths dify
  "
  [[ "$output" == *"apps/dify-prod"* ]] || { echo "$output"; false; }
}

# ---------- the candidate list is DERIVED (no module list in the manager) ------

@test "derived: a module known ONLY from residue.conf is still scanned (rescue)" {
  # post-uninstall + offline: no cache, no marker, no registry cache entry
  rm -rf "$AIBOX_HOME/modules" "$AIBOX_HOME/installed.sh"
  mkdir -p "$AIBOX_HOME/apps/orphanmod"
  printf 'orphanmod_residue_containers=^orphan-$
orphanmod_residue_paths=$HOME/orphan-data
' >"$AIBOX_HOME/residue.conf"
  mkdir -p "$HOME/orphan-data"
  run bash "$AIBOX" autoclean
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[orphanmod]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"orphan-data"* ]] || { echo "$output"; false; }
}

@test "derived: a module known only as a cache dir is listed" {
  rm -rf "$AIBOX_HOME/modules" "$AIBOX_HOME/installed.sh" "$AIBOX_HOME/residue.conf"
  mkdir -p "$AIBOX_HOME/modules/cachedmod" "$AIBOX_HOME/apps/cachedmod"
  printf 'name: cachedmod\nversion: 1.0.0\n' >"$AIBOX_HOME/modules/cachedmod/module.yaml"
  run bash "$AIBOX" autoclean
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[cachedmod]"* ]] || { echo "$output"; false; }
}

@test "derived: registry cache module names are candidates too (offline host)" {
  rm -rf "$AIBOX_HOME/modules" "$AIBOX_HOME/installed.sh" "$AIBOX_HOME/residue.conf"
  mkdir -p "$AIBOX_HOME/apps/registrymod"
  printf 'AIBOX_MODULES="registrymod"\nAIBOX_MODULE_registrymod_version="1.0.0"\n' >"$AIBOX_HOME/registry.cache"
  run bash "$AIBOX" autoclean
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[registrymod]"* ]] || { echo "$output"; false; }
}

@test "no module-name list literal exists in the manager sources (D1)" {
  ! grep -rq 'PURGE_MODULES_KNOWN' "$REPO_ROOT/src/aibox" || { echo "PURGE_MODULES_KNOWN is back"; false; }
  # a hand-maintained list would show >= 3 module names adjacent on one line
  run bash -c "grep -rnE 'base clash|clash pi-web|pi-web openmaic|openmaic windmill|windmill gitlab|gitlab dify|dify new-api|new-api xiaozhi' '$REPO_ROOT/src/aibox/*.sh' '$REPO_ROOT/src/aibox'"
  [ "$status" -ne 0 ] || { echo "a module list literal is back: $output"; false; }
  # the derivation itself must exist and be used on both paths
  grep -q '^_purge_candidate_modules()' "$AIBOX" || false
  [ "$(grep -c '_purge_candidate_modules' "$AIBOX")" -ge 3 ] || { echo "helper defined but not used on both paths"; false; }
}

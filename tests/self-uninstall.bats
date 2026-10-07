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
  if [ -n "${SANDBOX:-}" ]; then
    case ":${PATH}:" in *":$SANDBOX/fakebin:"*) PATH="$(printf '%s' "$PATH" | sed "s#$SANDBOX/fakebin:##")"; export PATH ;; esac
    rm -rf "$SANDBOX" 2>/dev/null || true
  fi
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
  [[ "$output" == *"autoclean --apply"* ]]
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
  run bash "$REPO_ROOT/bin/aibox" uninstall fakemod --purge --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^fakemod base 1$' "$MARKER_FILE"
  [ ! -d "$AIBOX_HOME/apps/fakemod" ]
  # base-profile marker gone, devx marker kept (profile-scoped unmark)
  ! grep -q '^AIBOX_INSTALLED_fakemod=' "$AIBOX_HOME/installed.sh"
  grep -q '^AIBOX_INSTALLED_fakemod__devx=' "$AIBOX_HOME/installed.sh"
}

@test "uninstall <module> (no --purge): hook gets PURGE=0, apps preserved" {
  run bash "$REPO_ROOT/bin/aibox" uninstall othermod --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^othermod base 0$' "$MARKER_FILE"
  [ -d "$AIBOX_HOME/apps/fakemod" ]
  [ ! -d "$AIBOX_HOME/modules/othermod" ]   # cache removed (no other profile holds it)
}


@test "uninstall <module> without --yes in a non-interactive shell: declines, NOTHING runs (exit 2)" {
  # the interaction contract: destructive verbs decline by default (spec
  # §Interactive confirmation). Before this gate, plain `aibox uninstall <m>`
  # executed immediately with zero confirmation (live-caught on the deploy host).
  run bash "$REPO_ROOT/bin/aibox" uninstall othermod </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"Non-interactive environment, declining"* ]]
  [[ "$output" == *"Cancelled, nothing changed"* ]]
  # nothing ran: marker file untouched, module still marked installed
  [ ! -f "$MARKER_FILE" ] || ! grep -q '^othermod ' "$MARKER_FILE"
  grep -q '^AIBOX_INSTALLED_othermod=' "$AIBOX_HOME/installed.sh"
}

@test "uninstall <module> --yes (non-interactive): proceeds, data RETAINED + purge hint" {
  run bash "$REPO_ROOT/bin/aibox" uninstall othermod --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # hook ran with PURGE=0 (the safe default without an explicit --purge)
  grep -q '^othermod base 0$' "$MARKER_FILE"
  [[ "$output" == *"data RETAINED (cleanup: aibox autoclean othermod)"* ]]
}

@test "uninstall <module> --purge --yes: data contract = 1 + 'data deleted' verdict" {
  run bash "$REPO_ROOT/bin/aibox" uninstall fakemod --purge --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^fakemod base 1$' "$MARKER_FILE"
  [[ "$output" == *"Uninstalled fakemod — data deleted (volumes + deploy .env)"* ]]
}

@test "uninstall <module>: interactive accept on gate 1, decline on gate 2 → data kept" {
  # gate 1 (uninstall?) answered y; gate 2 (delete data?) answered n (default)
  command -v expect >/dev/null 2>&1 || skip "expect unavailable (CI ubuntu)"
  export MARKER_FILE
  expect -c '
    spawn bash "'"$REPO_ROOT"'/bin/aibox" uninstall othermod
    expect -re {Uninstall othermod\?} { send "y\r" }
    expect -re {Also DELETE the data\?} { send "n\r" }
    expect eof
  ' >/dev/null 2>&1
  grep -q '^othermod base 0$' "$MARKER_FILE"
  ! grep -q '^AIBOX_INSTALLED_othermod=' "$AIBOX_HOME/installed.sh"
}

@test "uninstall <module>: interactive accept both gates → data purged in the same run" {
  command -v expect >/dev/null 2>&1 || skip "expect unavailable (CI ubuntu)"
  export MARKER_FILE
  expect -c '
    spawn bash "'"$REPO_ROOT"'/bin/aibox" uninstall fakemod --purge
    expect -re {Uninstall fakemod\?} { send "y\r" }
    expect eof
  ' >/dev/null 2>&1
  # --purge skips gate 2; the hook got the data contract
  grep -q '^fakemod base 1$' "$MARKER_FILE"
  [ ! -d "$AIBOX_HOME/apps/fakemod" ]
}

# ---- the purge-time sweeps (networks/images) + verification + self --purge reclaim ----

@test "uninstall <module> --purge: sweeps declared networks/images (unattached/unreferenced only)" {
  export SANDBOX                      # the stub is a child process
  mkdir -p "$SANDBOX/fakebin"
  cat > "$SANDBOX/fakebin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "info ") exit 0 ;;
  "network ls") printf 'app_default\napp_render\nother_net\n' ;;
  "network inspect") case "$5" in app_default) printf '0\n' ;; app_render) printf '2\n' ;; *) exit 1 ;; esac ;;
  "image ls") printf 'app-openmaic:latest\napp-render-service:latest\nkeepme:1\n' ;;
  "image inspect") printf '12345\n' ;;
  "ps -aq") case "$*" in *"ancestor=app-render-service:latest"*) printf 'beef99\n' ;; *) exit 0 ;; esac ;;
  "ps -a") exit 0 ;;
  "volume ls") exit 0 ;;
  "builder du") exit 0 ;;
  "network rm"|"image rm") echo "$2 $3" >> "$SANDBOX/docker.log"; exit 0 ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$SANDBOX/fakebin/docker"
  export PATH="$SANDBOX/fakebin:$PATH"
  cat >> "$AIBOX_HOME/modules/fakemod/module.yaml" <<'YAML'
residue:
  networks: "^app_(default|render)$"
  images: "^app-(openmaic|render-service):"
YAML
  run bash "$REPO_ROOT/bin/aibox" uninstall fakemod --purge --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^rm app_default$' "$SANDBOX/docker.log" || { echo "$output"; false; }
  grep -q '^rm app-openmaic:latest$' "$SANDBOX/docker.log" || { echo "$output"; cat "$SANDBOX/docker.log"; false; }
  ! grep -q 'app_render' "$SANDBOX/docker.log" || { echo "attached network removed"; false; }
  ! grep -q 'app-render-service:latest' "$SANDBOX/docker.log" || { echo "in-use image removed"; false; }
  printf '%s\n' "$output" | grep -q 'removed network: app_default' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q 'removed image: app-openmaic:latest' || { echo "$output"; false; }
}

@test "uninstall <module> --purge: verification reports leftovers the hook missed" {
  sed -i '/AIBOX_INSTALLED_fakemod__devx/d' "$AIBOX_HOME/installed.sh"   # fully uninstalled → verification runs
  cat > "$AIBOX_HOME/modules/fakemod/uninstall.sh" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
  printf 'fakemod_residue_paths=%s/leftover-fakemod\n' "$HOME" > "$AIBOX_HOME/residue.conf"
  mkdir -p "$HOME/leftover-fakemod"
  run bash "$REPO_ROOT/bin/aibox" uninstall fakemod --purge --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q 'leftover item(s) remain' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q 'aibox autoclean fakemod --apply' || { echo "$output"; false; }
}

@test "uninstall self --purge: reclaims docker-level debris before the manager goes" {
  export SANDBOX                      # the stub is a child process
  mkdir -p "$SANDBOX/fakebin"
  cat > "$SANDBOX/fakebin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "info ") exit 0 ;;
  "builder du") printf 'Total: 9.9G\n' ;;
  "builder prune") echo "$*" >> "$SANDBOX/docker.log"; exit 0 ;;
  "image ls"|"volume ls") exit 0 ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$SANDBOX/fakebin/docker"
  export PATH="$SANDBOX/fakebin:$PATH"
  run bash "$REPO_ROOT/bin/aibox" uninstall self --purge --yes </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q 'build cache' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -q 'docker-level debris reclaimed' || { echo "$output"; false; }
  grep -q 'builder prune' "$SANDBOX/docker.log" || { echo "reclaim was not applied: $output"; false; }
  # the conservative 24h filter keeps recently-used entries — the closing line must
  # name what remains and the full-clean command (full teardown hosts want that)
  printf '%s\n' "$output" | grep -q 'full clean: docker builder prune -f' || { echo "$output"; false; }
}

#!/usr/bin/env bats
# Dependency readiness at ACTION time (0.15.1).
# Live-caught: `aibox xiaozhi start` died with
#   ✗ shared base not running (compose needs the external network aibox-base) — first: aibox base start
# — two commands for one intent. Bringing a module UP now ensures its declared
# `services:` deps first (manager side), and the module hooks carry the same
# guard for direct invocation (shared-library helper).
# Covered here:
#   manager: start/restart ensure the declared base services; stop/logs never start anything
#   manager: the redis-only entry form (base:redis, no #resource) also ensures base
#   manager: cheap declared-deps guard warns when a dep binary is missing
#   shared helper: ensure_shared_base (already-up fast path / start+wait / not installed)
#   module hook: a down shared base is auto-started, not a fatal instruction
#   base: create/createdb auto-start a stopped stack instead of "PG not running?"
# Offline: file:// fixtures + stub hooks; no docker daemon required.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-deps.$$")"
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

# base + app fixture. app declares BOTH entry forms:
#   base:redis          → ensure base is up (no resource to create)
#   base:postgres#appdb → ensure base is up + create the database
# svc hooks only log their invocations (no docker involved).
_deps_repo() { # $1=repo
  local r="$1" f
  mkdir -p "$r/tools/base" "$r/tools/app" "$r/tools/app2"
  cat >"$r/tools/base/module.yaml" <<'YAML'
name: base
version: 1.0.0
description: "stub base"
dir: tools/base
actions:
  - start
  - stop
  - restart
  - status
  - logs
  - create
hooks:
  install: install.sh
  svc: svc.sh
YAML
  cat >"$r/tools/app/module.yaml" <<'YAML'
name: app
version: 1.0.0
description: "stub consumer"
dir: tools/app
actions:
  - start
  - stop
  - restart
  - status
  - logs
services:
  - base:redis
  - base:postgres#appdb
hooks:
  install: install.sh
  svc: svc.sh
YAML
  cat >"$r/tools/app2/module.yaml" <<'YAML'
name: app2
version: 1.0.0
description: "stub with a missing runtime dep"
dir: tools/app2
actions:
  - start
deps:
  - "zz-nope:22"
hooks:
  install: install.sh
  svc: svc.sh
YAML
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf "base-%s\n" "$*" >>"${MARKER_LOG:?}"' >"$r/tools/base/svc.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf "app-%s\n" "${1:-}" >>"${MARKER_LOG:?}"' >"$r/tools/app/svc.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'printf "app2-%s\n" "${1:-}" >>"${MARKER_LOG:?}"' >"$r/tools/app2/svc.sh"
  for f in install.sh lib.sh uninstall.sh update.sh; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$r/tools/base/$f"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$r/tools/app/$f"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$r/tools/app2/$f"
  done
  chmod +x "$r"/tools/*/*.sh
}

_install_fixture() { # $1=repo — install base + app (markers reset afterwards)
  local repo="$1"
  export AIBOX_RAW="file://$repo"
  export MARKER_LOG="$SANDBOX/markers"
  : >"$MARKER_LOG"
  bash "$AIBOX_BIN" install base --skip-checks >/dev/null 2>&1
  bash "$AIBOX_BIN" install app --skip-checks >/dev/null 2>&1
  : >"$MARKER_LOG"
}

# ---------- manager: services ensured for the actions that bring a module UP ----

@test "app start: declared base services are ensured BEFORE the module (both entry forms)" {
  local repo="$SANDBOX/repo"
  _deps_repo "$repo"
  _install_fixture "$repo"
  run bash "$AIBOX_BIN" app start
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -1 "$MARKER_LOG")" = "base-start" ] || { cat "$MARKER_LOG"; false; }
  grep -q '^base-create postgres appdb$' "$MARKER_LOG" || { cat "$MARKER_LOG"; false; }
  grep -q '^app-start$' "$MARKER_LOG" || false
  # the redis-only entry must NOT trigger a create (no resource to create)
  ! grep -q '^base-create redis' "$MARKER_LOG" || false
}

@test "app restart: same ensure as start (base comes up first)" {
  local repo="$SANDBOX/repo"
  _deps_repo "$repo"
  _install_fixture "$repo"
  run bash "$AIBOX_BIN" app restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -1 "$MARKER_LOG")" = "base-start" ] || { cat "$MARKER_LOG"; false; }
  grep -q '^app-restart$' "$MARKER_LOG" || false
}

@test "app stop: never starts the declared services" {
  local repo="$SANDBOX/repo"
  _deps_repo "$repo"
  _install_fixture "$repo"
  run bash "$AIBOX_BIN" app stop
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '^base-start' "$MARKER_LOG" || { cat "$MARKER_LOG"; false; }
  grep -q '^app-stop$' "$MARKER_LOG" || false
}

@test "app logs: never starts the declared services" {
  local repo="$SANDBOX/repo"
  _deps_repo "$repo"
  _install_fixture "$repo"
  run bash "$AIBOX_BIN" app logs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! grep -q '^base-start' "$MARKER_LOG" || { cat "$MARKER_LOG"; false; }
  grep -q '^app-logs$' "$MARKER_LOG" || false
}

@test "start guard: a missing declared dep binary warns with the check hint" {
  local repo="$SANDBOX/repo"
  _deps_repo "$repo"
  export AIBOX_RAW="file://$repo"
  export MARKER_LOG="$SANDBOX/markers"
  : >"$MARKER_LOG"
  bash "$AIBOX_BIN" install app2 --skip-checks >/dev/null 2>&1
  : >"$MARKER_LOG"
  run bash "$AIBOX_BIN" app2 start
  # quoted list entry ("zz-nope:22") — the version + the quotes are stripped, so
  # the message names the BINARY (live-caught: it printed `missing "zz-nope`)
  [[ "$output" == *"missing zz-nope —"* ]] || { echo "$output"; false; }
  [[ "$output" == *"aibox check app2"* ]] || false
  [[ "$output" != *'missing "'* ]] || { echo "$output"; false; }
  grep -q '^app2-start$' "$MARKER_LOG" || false
}

@test "start guard: no noise when every declared dep exists" {
  local repo="$SANDBOX/repo"
  _deps_repo "$repo"
  _install_fixture "$repo"
  run bash "$AIBOX_BIN" app start
  [[ "$output" != *"missing zz-nope"* ]] || { echo "$output"; false; }
}

# ---------- shared helper (module side) --------------------------------------

@test "ensure_shared_base: base installed but down → starts it and waits for the network" {
  local mods="$SANDBOX/mods"
  mkdir -p "$mods/base"
  cat >"$mods/base/svc.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'base-%s\n' "${1:-}" >>"${MARKER_LOG:?}"
if [ "${1:-}" = start ]; then
  printf 'AIBOX_BASE_NETWORK=aibox-base\n' >>"${AIBOX_HOME:?}/base.env"
  : >"${NET_FLAG:?}"
fi
EOF
  chmod +x "$mods/base/svc.sh"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$mods'
    export MARKER_LOG='$SANDBOX/markers' NET_FLAG='$SANDBOX/net.flag'
    : >\"\$MARKER_LOG\"
    source '$REPO_ROOT/tools/_shared/common.sh'
    docker() { [ \"\$1\" = network ] && [ -f \"\$NET_FLAG\" ]; }
    ensure_shared_base
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"starting it"* ]] || { echo "$output"; false; }
  grep -q '^base-start$' "$SANDBOX/markers" || { cat "$SANDBOX/markers"; false; }
}

@test "ensure_shared_base: an already-up base is a silent no-op (no start call)" {
  local mods2="$SANDBOX/mods2"
  mkdir -p "$mods2/base"
  cat >"$mods2/base/svc.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'base-%s\n' "${1:-}" >>"${MARKER_LOG:?}"
EOF
  chmod +x "$mods2/base/svc.sh"
  printf 'AIBOX_BASE_NETWORK=aibox-base\n' >"$AIBOX_HOME/base.env"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$mods2'
    export MARKER_LOG='$SANDBOX/markers2'
    : >\"\$MARKER_LOG\"
    source '$REPO_ROOT/tools/_shared/common.sh'
    docker() { return 0; }
    ensure_shared_base
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"starting it"* ]] || { echo "$output"; false; }
  [ ! -s "$SANDBOX/markers2" ] || { cat "$SANDBOX/markers2"; false; }
}

@test "ensure_shared_base: base not installed → clear die naming the fix" {
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$SANDBOX/empty-mods'
    mkdir -p \"\$AIBOX_MOD_DIR\"
    source '$REPO_ROOT/tools/_shared/common.sh'
    docker() { return 0; }
    ensure_shared_base
  "
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"not installed — first: aibox install base"* ]] || { echo "$output"; false; }
}

@test "ensure_shared_base: a base that cannot start dies with the logs hint" {
  local mods4="$SANDBOX/mods4"
  mkdir -p "$mods4/base"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'exit 1' >"$mods4/base/svc.sh"
  chmod +x "$mods4/base/svc.sh"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$mods4'
    source '$REPO_ROOT/tools/_shared/common.sh'
    docker() { return 1; }
    ensure_shared_base
  "
  [ "$status" -ne 0 ] || false
  [[ "$output" == *"shared base failed to start"* ]] || { echo "$output"; false; }
  [[ "$output" == *"aibox base logs"* ]] || false
}

# ---------- module hook wiring (the live-caught case) ------------------------

@test "xiaozhi svc.sh start: a down shared base is auto-started, never a fatal instruction" {
  local mods="$SANDBOX/mods5" shim="$SANDBOX/shim"
  mkdir -p "$mods/xiaozhi" "$mods/base" "$shim"
  cp -R "$REPO_ROOT/tools/xiaozhi/." "$mods/xiaozhi/"
  cp "$REPO_ROOT/tools/_shared/common.sh" "$mods/xiaozhi/_common.sh"
  cat >"$mods/base/svc.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'base-%s\n' "${1:-}" >>"${MARKER_LOG:?}"
printf 'AIBOX_BASE_NETWORK=aibox-base\n' >>"${AIBOX_HOME:?}/base.env"
: >"${NET_FLAG:?}"
EOF
  chmod +x "$mods/base/svc.sh"
  # docker shim: the network probe works, anything else fails fast (no daemon here)
  cat >"$shim/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = network ] && [ "${2:-}" = inspect ]; then exit 0; fi
exit 1
EOF
  chmod +x "$shim/docker"
  run env PATH="$shim:$PATH" AIBOX_HOME="$AIBOX_HOME" AIBOX_MOD_DIR="$mods" \
    AIBOX_MODULE=xiaozhi MARKER_LOG="$SANDBOX/markers5" NET_FLAG="$SANDBOX/net5.flag" \
    bash "$mods/xiaozhi/svc.sh" start
  [[ "$output" == *"is not running — starting it"* ]] || { echo "$output"; false; }
  [[ "$output" != *"first: aibox base start"* ]] || { echo "$output"; false; }
  grep -q '^base-start$' "$SANDBOX/markers5" || { cat "$SANDBOX/markers5"; false; }
}

# ---------- base create: the stack auto-starts --------------------------------

@test "base create: a stopped stack is started instead of dying with 'PG not running?'" {
  mkdir -p "$SANDBOX/apps/base"
  printf 'services: {}\n' >"$SANDBOX/apps/base/docker-compose.yml"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_APPS_ROOT='$SANDBOX/apps'
    source '$REPO_ROOT/tools/_shared/common.sh'
    source '$REPO_ROOT/tools/base/lib.sh'
    stack_running() { return 1; }
    cmd_start() { printf 'START-CALLED\n'; }
    docker() { return 0; }
    cmd_createdb appdb
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"starting it"* ]] || { echo "$output"; false; }
  [[ "$output" == *"START-CALLED"* ]] || false
  [[ "$output" == *"Database appdb ready"* ]] || false
}

@test "base create: an already-running stack is not restarted" {
  mkdir -p "$SANDBOX/apps/base"
  printf 'services: {}\n' >"$SANDBOX/apps/base/docker-compose.yml"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME' AIBOX_APPS_ROOT='$SANDBOX/apps'
    source '$REPO_ROOT/tools/_shared/common.sh'
    source '$REPO_ROOT/tools/base/lib.sh'
    stack_running() { return 0; }
    cmd_start() { printf 'START-CALLED\n'; }
    docker() { return 0; }
    cmd_createdb appdb
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"START-CALLED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Database appdb ready"* ]] || false
}
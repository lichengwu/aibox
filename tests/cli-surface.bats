#!/usr/bin/env bats
# CLI v2.1 surface: migration guidance for merged commands, dashboard modes,
# proxy check single-target routing, reserved module name 'self'.
# Hermetic: sandbox AIBOX_HOME/BIN_DIR + file:// registry (no network, no docker needed).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-surface.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT"
  mkdir -p "$AIBOX_HOME" "$SANDBOX/bin"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "merged commands leave migration guidance (list / ports / self family / proxy test)" {
  run bash "$REPO_ROOT/bin/aibox" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"'list' merged into dashboard"* ]]

  run bash "$REPO_ROOT/bin/aibox" ports
  [ "$status" -ne 0 ]
  [[ "$output" == *"'ports' merged into dashboard"* ]]

  run bash "$REPO_ROOT/bin/aibox" self update
  [ "$status" -ne 0 ]
  [[ "$output" == *"merged into the standard verbs"* ]]
  [[ "$output" == *"aibox uninstall self"* ]]

  run bash "$REPO_ROOT/bin/aibox" proxy test
  [ "$status" -ne 0 ]
  [[ "$output" == *"'proxy test' merged into"* ]]
}

@test "check without args dies pointing at check <module>|self" {
  run bash "$REPO_ROOT/bin/aibox" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"aibox check <module>|self"* ]]
}

@test "dashboard --available lists the registry catalog (file:// source)" {
  run bash "$REPO_ROOT/bin/aibox" dashboard --available
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # header since the TUI redesign (66d6175): "aibox module catalog" + registry line
  [[ "$output" == *"aibox module catalog"* ]]
  [[ "$output" == *"registry @ "* ]]
  [[ "$output" == *"base"* ]]
  [[ "$output" == *"gitlab"* ]]
}

@test "dashboard overview: local-first (dead network OK), per-profile sections, module blocks" {
  # installed state from installed.sh + module caches — NO registry/network.
  # Point AIBOX_RAW at a dead host: the overview must still render.
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF'
AIBOX_INSTALLED_base="1.2.1"
AIBOX_INSTALLED_new_api__work="1.0.1"
EOF
  # module cache (lib.sh with dashboard_info) for base
  mkdir -p "$AIBOX_HOME/modules/base"
  # state=ok pins the header icon (without it the fallback port-probe is
  # environment-dependent: file:// registry provides base's ports → on a
  # docker-less CI host 35432 never listens → ○ stopped, and the ✓ asserts fail)
  printf 'dashboard_info() { echo "state=ok"; echo "endpoint=pg://127.0.0.1:35432"; echo "health=ok"; }\n' \
    >"$AIBOX_HOME/modules/base/lib.sh"
  mkdir -p "$AIBOX_HOME/modules/new-api"
  printf 'dashboard_info() { echo "endpoint=http://127.0.0.1:30300"; echo "credential=first login"; echo "version=v0.13.2"; }\n' \
    >"$AIBOX_HOME/modules/new-api/lib.sh"
  run bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # two profile sections (base + named profile), grouped separately
  [[ "$output" == *"profile base"* ]] || false
  [[ "$output" == *"profile work"* ]] || false
  # per-module keyline blocks: icon + bold name + app version (new-api mock has
  # version=v0.13.2 → header carries it, v-stripped; base has none → dim
  # module-version fallback 1.2.1)
  [[ "$output" == *"── profile base"* ]] || false
  [[ "$output" == *"✓ base 1.2.1"* ]] || false
  [[ "$output" == *"✓ new-api 0.13.2"* ]] || false
  # rows: colon-free grid, health merged into the endpoint row
  [[ "$output" == *"pg://127.0.0.1:35432 · ok"* ]] || false
  [[ "$output" == *"endpoint"*"http://127.0.0.1:30300"* ]] || false
  [[ "$output" == *"auth"*"first login"* ]] || false
  # version= is header-only now (upstream: label retired); sunk module row
  [[ "$output" != *"upstream:"* ]] || false
  [[ "$output" == *"module"*"1.0.1 · "*"modules/new-api/"* ]] || false
  # health= is consumed by the endpoint merge — never a standalone row
  [[ "$output" != *"health "* ]] || false
}

@test "dashboard overview: empty state + residue section for not-installed leftovers" {
  # the residue scan is gated on the docker CLI (manager-side docker probes);
  # skip where docker is absent (minimal containers) — CI runners carry it
  command -v docker >/dev/null 2>&1 || skip "no docker CLI (residue scan needs it)"
  export AIBOX_RAW="https://dead.invalid/aibox"
  export AIBOX_DASH_UPDATE_TIMEOUT=1
  # base installed; gitlab NOT installed but with a residue dir → residue section
  cat >"$AIBOX_HOME/installed.sh" <<'EOF'
AIBOX_INSTALLED_base="1.2.1"
EOF
  mkdir -p "$AIBOX_HOME/modules/base" "$AIBOX_HOME/apps/gitlab"
  printf 'dashboard_info() { echo "endpoint=pg://x"; }\n' >"$AIBOX_HOME/modules/base/lib.sh"
  run bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"✓ base"* ]] || false
  [[ "$output" == *"── residue"* ]] || false
  [[ "$output" == *"gitlab"* ]] || false
  # gitlab is NOT in a profile section (not installed)
  [[ "$output" != *"✓ gitlab"* ]] || false
}

@test "dashboard detail: local-first — installed module renders with a dead registry" {
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF'
AIBOX_INSTALLED_base="1.2.1"
EOF
  mkdir -p "$AIBOX_HOME/modules/base"
  printf 'dashboard_info() { echo "endpoint=pg://127.0.0.1:35432"; echo "health=ok"; }\n' \
    >"$AIBOX_HOME/modules/base/lib.sh"
  run bash "$REPO_ROOT/bin/aibox" dashboard base
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # keyline: dim module-version fallback (no version= in this mock), rule,
  # health merged into the endpoint row, sunk module row
  [[ "$output" == *"base 1.2.1"* ]] || false
  [[ "$output" == *"pg://127.0.0.1:35432 · ok"* ]] || false
  [[ "$output" == *"module"*"1.2.1 · "*"modules/base/"* ]] || false
  [[ "$output" != *"Failed to fetch module list"* ]] || false
}

@test "proxy check <url> = single-target mode; no proxy configured → clear die" {
  # sandbox has no proxy config and no clash state → deterministic offline refusal
  run bash "$REPO_ROOT/bin/aibox" proxy check http://127.0.0.1:9
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proxy configured"* ]]
}

@test "scaffolder rejects the reserved name 'self'" {
  run bash "$REPO_ROOT/scripts/new-module.sh" self --out "$SANDBOX/tools"
  [ "$status" -eq 2 ]
  [[ "$output" == *"reserved"* ]]
}

@test "validator rejects a module named 'self'" {
  mkdir -p "$SANDBOX/tools/self"
  cat > "$SANDBOX/tools/self/module.yaml" <<'YAML'
name: self
version: 1.0.0
description: "illegal reserved name"
dir: tools/self
hooks:
  install: install.sh
checks:
  disk_gb: 1
YAML
  printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$SANDBOX/tools/self/install.sh"
  run env VALIDATE_TOOLS_DIR="$SANDBOX/tools" bash "$REPO_ROOT/scripts/validate-module.sh" self
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved"* ]]
}

@test "update self passes AIBOX_RAW through to install.sh (live-caught regression pin)" {
  # Without the passthrough, a SHA-pinned/mirrored AIBOX_RAW only affects the
  # install.sh fetch; the payload silently comes from the default branch CDN.
  grep -q 'AIBOX_RAW="$AIBOX_RAW" AIBOX_VERIFY=' "$REPO_ROOT/bin/aibox"
}

@test "module help: bare / help / -h / --help all route to it, offline (local-first)" {
  # installed module + module.yaml in the per-module cache (standard 6) →
  # the help renders with a DEAD registry (local-first, zero network)
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_base="1.2.1"
EOF2
  mkdir -p "$AIBOX_HOME/modules/base"
  printf 'name: base\nversion: 1.2.1\ndescription: "Shared base (PG + Redis)"\nactions:\n  - start\n  - stop\nports:\n  - 35432/tcp:postgres\n' \
    >"$AIBOX_HOME/modules/base/module.yaml"
  for form in "" "help" "-h" "--help"; do
    run bash "$REPO_ROOT/bin/aibox" base ${form}
    [ "$status" -eq 0 ] || { echo "form=[${form}] failed"; echo "$output"; false; }
    [[ "$output" == *"base · module 1.2.1"* ]]
    [[ "$output" == *"Shared base (PG + Redis)"* ]]
    [[ "$output" == *"usage:  aibox base <action>"* ]]
    [[ "$output" == *"ports:    35432/tcp:postgres"* ]]
    [[ "$output" == *"module:   "*"/modules/base/"* ]]
    [[ "$output" != *"Failed to fetch module list"* ]]
  done
  # unknown module (typo): needs the registry → clean die, not a stack of noise
  run bash "$REPO_ROOT/bin/aibox" bas --help
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown module: bas"* ]]
}

@test "module help: usage table renders action + description per line" {
  # the usage: stanza drives a fixed-column action table
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_base="1.2.1"
EOF2
  mkdir -p "$AIBOX_HOME/modules/base"
  printf 'name: base\nversion: 1.2.1\ndescription: "Shared base"\nactions:\n  - start\n  - stop\n  - create\nusage:\n  start: "Start shared PG + Redis"\n  stop: "Stop containers (data preserved)"\n' \
    >"$AIBOX_HOME/modules/base/module.yaml"
  run bash "$REPO_ROOT/bin/aibox" base --help
  [ "$status" -eq 0 ]
  # covered actions render with their usage description
  [[ "$output" == *"  start                    Start shared PG + Redis"* ]] \
    || [[ "$output" =~ [[:space:]]start[[:space:]]+Start\ shared\ PG\ \+\ Redis ]]
  [[ "$output" == *"  stop                     Stop containers (data preserved)"* ]] \
    || [[ "$output" =~ [[:space:]]stop[[:space:]]+Stop\ containers\ \(data\ preserved\) ]]
  # uncovered action still lists the bare name (no description, no error)
  [[ "$output" =~ [[:space:]]create([[:space:]]*$|[[:space:]]+[^S]) ]]
}

@test "module help: hyphenated action names render (use-external etc.)" {
  # registry parser normalizes hyphens in variable names; help reads the
  # cached module.yaml directly — hyphenated usage keys must not break eval
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_clash="1.3.0"
EOF2
  mkdir -p "$AIBOX_HOME/modules/clash"
  printf 'name: clash\nversion: 1.3.0\ndescription: "Clash pool"\nactions:\n  - start\n  - use-external\nusage:\n  start: "Start the kernel"\n  use-external: "[port] — reuse a local clash client"\n' \
    >"$AIBOX_HOME/modules/clash/module.yaml"
  run bash "$REPO_ROOT/bin/aibox" clash --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"use-external"* ]]
  [[ "$output" == *"reuse a local clash client"* ]]
}

@test "module unknown action: unified fallback points to --help" {
  # svc.sh dies with a pointer to the authoritative help, not a
  # hand-maintained action list (drift-free)
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_clash="1.3.0"
EOF2
  mkdir -p "$AIBOX_HOME/modules/clash"
  cp "$REPO_ROOT/tools/clash/module.yaml" "$AIBOX_HOME/modules/clash/module.yaml"
  cp "$REPO_ROOT/tools/clash/svc.sh" "$AIBOX_HOME/modules/clash/svc.sh"
  cp "$REPO_ROOT/tools/clash/lib.sh" "$AIBOX_HOME/modules/clash/lib.sh"
  cp "$REPO_ROOT/tools/_shared/common.sh" "$AIBOX_HOME/modules/clash/_common.sh"
  run bash "$REPO_ROOT/bin/aibox" clash badaction
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown action: badaction"* ]]
  [[ "$output" == *"aibox clash --help"* ]]
}

@test "action-level help: <module> <action> --help renders args hint + description" {
  # the usage: line's "<args> — description" shape becomes the usage tail
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_clash="1.3.0"
EOF2
  mkdir -p "$AIBOX_HOME/modules/clash"
  printf 'name: clash\nversion: 1.3.0\ndescription: "Clash pool"\nactions:\n  - start\n  - set\nusage:\n  start: "Start the kernel"\n  set: "<subscription-url> — store the subscription + generate config"\n' \
    >"$AIBOX_HOME/modules/clash/module.yaml"
  run bash "$REPO_ROOT/bin/aibox" clash set --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"clash set · module 1.3.0"* ]]
  [[ "$output" == *"usage:  aibox clash set <subscription-url>"* ]]
  [[ "$output" == *"store the subscription + generate config"* ]]
  [[ "$output" == *"aibox clash --help"* ]]
  # no-args action: usage line has no args tail
  run bash "$REPO_ROOT/bin/aibox" clash start --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:  aibox clash start"* ]]
  [[ "$output" != *"usage:  aibox clash start "* ]]
}

@test "action-level help: unknown action falls back to the module table" {
  export AIBOX_RAW="https://dead.invalid/aibox"
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_clash="1.3.0"
EOF2
  mkdir -p "$AIBOX_HOME/modules/clash"
  printf 'name: clash\nversion: 1.3.0\ndescription: "Clash pool"\nactions:\n  - start\nusage:\n  start: "Start the kernel"\n' \
    >"$AIBOX_HOME/modules/clash/module.yaml"
  run bash "$REPO_ROOT/bin/aibox" clash bogus --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"no usage entry for 'bogus'"* ]]
  # the module table follows → typo recovery
  [[ "$output" == *"usage:  aibox clash <action>"* ]]
}


@test "dashboard overview: state= contract renders the composite icon + word" {
  export AIBOX_DASH_UPDATE_TIMEOUT=1
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_new_api="1.1.1"
EOF2
  # one module, all four contract states via a state-file-driven mock
  mkdir -p "$AIBOX_HOME/modules/new-api"
  printf 'dashboard_info() { echo "state=$(cat \"$MOCK_STATE\" 2>/dev/null)"; echo "endpoint=http://127.0.0.1:30300"; }\n' \
    >"$AIBOX_HOME/modules/new-api/lib.sh"
  for st in ok starting stopped na; do
    printf '%s' "$st" >"$AIBOX_HOME/mock_state"
    export MOCK_STATE="$AIBOX_HOME/mock_state"
    run bash "$REPO_ROOT/bin/aibox" dashboard
    [ "$status" -eq 0 ] || { echo "state=$st"; echo "$output"; false; }
    case "$st" in
    ok)
      # keyline: icon-only header (the state word is gone — icon expresses it)
      [[ "$output" == *"✓ new-api 1.1.1"* ]] || false
      [[ "$output" != *"· ok"* ]] || false
      [[ "$output" != *"state"* ]] || false   # consumed by the header, never a row
      ;;
    starting)
      [[ "$output" == *"⚠ new-api 1.1.1"* ]] || false
      ;;
    stopped)
      [[ "$output" == *"○ new-api 1.1.1"* ]] || false
      # the endpoint row carries the actionable hint (colon-free grid)
      [[ "$output" == *"http://127.0.0.1:30300 (stopped — aibox new-api start)"* ]] || false
      ;;
    na)
      # CLI-type module: plain header, no icon, no state word
      [[ "$output" == *"  new-api 1.1.1"* ]] || false
      [[ "$output" != *"· ok"* && "$output" != *"· stopped"* ]] || false
      ;;
    esac
  done
}

@test "dashboard overview: stale cache without state= falls back to the port heuristic" {
  export AIBOX_DASH_UPDATE_TIMEOUT=1
  cat >"$AIBOX_HOME/installed.sh" <<'EOF2'
AIBOX_INSTALLED_new_api="1.1.1"
EOF2
  # no state=, no module.yaml → no ports → plain ✓ (deterministic on any host)
  mkdir -p "$AIBOX_HOME/modules/new-api"
  printf 'dashboard_info() { echo "endpoint=http://127.0.0.1:30300"; }\n' \
    >"$AIBOX_HOME/modules/new-api/lib.sh"
  run bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"✓ new-api 1.1.1"* ]] || false
  [[ "$output" != *"· ok"* && "$output" != *"· stopped"* ]] || false
}

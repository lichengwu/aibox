#!/usr/bin/env bats
# Preflight checks (mandatory install/update gate) — fast, offline:
#   yaml parsing of checks:, disk/commands/probe/routes/skip semantics.
# Domain probes use file:// (always "reachable" via curl) and a dead port (always
# unreachable) — no external network. See docs/module-spec.md §Preflight checks.

load test_helper

# --- checks: section parsing -------------------------------------------------

@test "parse: checks section (nested scalar + sub-lists) parses into module vars" {
  cat >"$BATS_TEST_TMPDIR/module.yaml" <<'EOF'
name: wm
version: 1.0.0
description: "d"
dir: tools/wm
checks:
  disk_gb: 7
  domains:
    - ghcr.io
    - example.com
  docker_pull: hello-world
  docker_images:
    - postgres:18
  commands:
    - systemctl@linux
hooks:
  install: install.sh
EOF
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    eval \"\$(parse_yaml_module_stdin wm < '$BATS_TEST_TMPDIR/module.yaml')\"
    printf 'disk=%s doms=[%s] pull=%s imgs=[%s] cmds=[%s]\n' \
      \"\$AIBOX_MODULE_wm_checks_disk_gb\" \"\$AIBOX_MODULE_wm_checks_domains\" \"\$AIBOX_MODULE_wm_checks_docker_pull\" \
      \"\$AIBOX_MODULE_wm_checks_docker_images\" \"\$AIBOX_MODULE_wm_checks_commands\"
  "
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == 'disk=7 doms=[ghcr.io example.com] pull=hello-world imgs=[postgres:18] cmds=[systemctl@linux]' ]]
}

# --- disk --------------------------------------------------------------------

@test "_disk_free_gb returns an integer for an existing path" {
  run bash -c "source '$REPO_ROOT/bin/aibox'; _disk_free_gb '$AIBOX_HOME'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "_disk_free_gb walks up from a non-existent path" {
  run bash -c "source '$REPO_ROOT/bin/aibox'; _disk_free_gb '$AIBOX_HOME/no/such/dir'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "_preflight_disk: fails when disk_gb exceeds free space, passes when tiny" {
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_MODULE_fake_checks_disk_gb=99999999
    _preflight_disk fake
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires 99999999G"* ]]

  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_MODULE_fake_checks_disk_gb=1
    _preflight_disk fake
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"✔ disk"* ]]
}

# --- probes / routes (offline-safe: a localhost HTTP server and a dead port) ----

# NOTE: file:// is NOT usable as a "reachable" fixture — curl reports http_code
# 000 for it (no HTTP), and the probe counts only non-000 as reachable.

@test "_preflight_probe_route: localhost HTTP server is reachable via current route" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  python3 -m http.server 18099 --bind 127.0.0.1 >/dev/null 2>&1 &
  local srv=$!
  sleep 1
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_CHECK_TIMEOUT=2; _preflight_probe_route current 'http://127.0.0.1:18099/'"
  kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
  [ "$status" -eq 0 ] || echo "$output"
}

@test "_preflight_probe_route: dead port is unreachable via current and direct routes" {
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_CHECK_TIMEOUT=1; _preflight_probe_route current 'http://127.0.0.1:9/x'"
  [ "$status" -ne 0 ]
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_CHECK_TIMEOUT=1; _preflight_probe_route direct 'http://127.0.0.1:9/x'"
  [ "$status" -ne 0 ]
}

@test "_preflight_probe_route: clash route without state file, proxy route without URL → unreachable (no hang)" {
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_CHECK_TIMEOUT=1; _preflight_probe_route clash 'http://127.0.0.1:9/x'"
  [ "$status" -ne 0 ]
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_CHECK_TIMEOUT=1; AIBOX_PROXY_URL=''; _preflight_probe_route proxy 'http://127.0.0.1:9/x'"
  [ "$status" -ne 0 ]
}

@test "_preflight_domains: reachable domains pass; dead domain fails after trying alternatives" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  python3 -m http.server 18098 --bind 127.0.0.1 >/dev/null 2>&1 &
  local srv=$!
  sleep 1
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_MODULE_ok_checks_domains='http://127.0.0.1:18098'
    AIBOX_CHECK_TIMEOUT=2
    _preflight_domains ok
  "
  kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"✔"* ]]
  [[ "$output" != *"unreachable"* ]]

  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_MODULE_bad_checks_domains='http://127.0.0.1:9'
    AIBOX_CHECK_TIMEOUT=1
    _preflight_domains bad
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreachable domains"* ]]
  [[ "$output" == *"trying configured alternatives"* ]]
}

@test "_preflight_domains: docker_images all cached → domain probes skipped" {
  # use an image guaranteed present if docker exists; skip when docker missing
  docker image inspect postgres:18 >/dev/null 2>&1 || skip "postgres:18 not cached locally"
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_MODULE_m_checks_docker_images='postgres:18'
    AIBOX_MODULE_m_checks_domains='http://127.0.0.1:9'
    AIBOX_CHECK_TIMEOUT=1
    _preflight_domains m
  "
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"skipping domain probes"* ]]
}

@test "_preflight_docker_pull: no field → no-op; images cached → pull probe skipped" {
  run bash -c "source '$REPO_ROOT/bin/aibox'; _preflight_docker_pull nothing_declared"
  [ "$status" -eq 0 ]

  docker image inspect postgres:18 >/dev/null 2>&1 || skip "postgres:18 not cached locally"
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_MODULE_m_checks_docker_images='postgres:18'
    AIBOX_MODULE_m_checks_docker_pull='http://127.0.0.1:9-nope'
    _preflight_docker_pull m
  "
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"skipping pull probe"* ]]
}

# --- commands ------------------------------------------------------------------

@test "_preflight_commands: present passes, missing fails, off-platform skipped" {
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_MODULE_m_checks_commands='bash'; _preflight_commands m"
  [ "$status" -eq 0 ]

  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_MODULE_m_checks_commands='definitely_missing_cmd_xyz'; _preflight_commands m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"definitely_missing_cmd_xyz not found"* ]]

  # @platform tag for the OTHER platform is skipped everywhere (linux on macOS, darwin on Linux)
  other=linux; [ "$(uname -s)" = Linux ] && other=darwin
  run bash -c "source '$REPO_ROOT/bin/aibox'; AIBOX_MODULE_m_checks_commands='definitely_missing_cmd_xyz@${other}'; _preflight_commands m"
  [ "$status" -eq 0 ]
}

# --- services (recursive base readiness) ---------------------------------------

@test "_preflight_services: base not installed → fail with install hint (profile-aware)" {
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_PROFILE=dev
    AIBOX_MODULE_m_services='base:postgres#m'
    _preflight_services m
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"base not installed"* ]]
  [[ "$output" == *"--profile dev install base"* ]]
}

@test "_preflight_services: running base container → ready (profile-scoped marker)" {
  docker ps >/dev/null 2>&1 || skip "docker unavailable"
  docker run -d --rm --name aibox-base-itx-postgres alpine sleep 60 >/dev/null 2>&1 \
    || skip "cannot start a scratch alpine container"
  # installed state lives in $AIBOX_HOME/installed.sh, keyed via _ikey:
  # profile itx → AIBOX_INSTALLED_base__itx
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    AIBOX_PROFILE=itx
    echo 'AIBOX_INSTALLED_base__itx=1.0.0' > \"\$AIBOX_HOME/installed.sh\"
    AIBOX_MODULE_m_services='base:postgres#m'
    _preflight_services m
  "
  rc="$status"
  docker rm -f aibox-base-itx-postgres >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || echo "$output"
  [[ "$output" == *"✔ base:postgres ready"* ]]
}

# --- preflight_module composition + skip ---------------------------------------

@test "preflight_module: hard-fails on a failing config, message mentions --skip-checks" {
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    PREFLIGHT_SKIP=0
    AIBOX_MODULE_fake_checks_disk_gb=99999999
    preflight_module fake
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Preflight FAILED"* ]]
  [[ "$output" == *"--skip-checks"* ]]
}

@test "preflight_module: PREFLIGHT_SKIP=1 bypasses a failing config" {
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    PREFLIGHT_SKIP=1
    AIBOX_MODULE_fake_checks_disk_gb=99999999
    preflight_module fake
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preflight skipped"* ]]
}

@test "preflight_module: empty checks config passes" {
  run bash -c "
    source '$REPO_ROOT/bin/aibox'
    PREFLIGHT_SKIP=0
    preflight_module nothing_declared
  "
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"Preflight passed"* ]]
}

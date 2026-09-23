#!/usr/bin/env bats
# pi-web npm registry pick (download-throughput probe) + stalled-registry
# failover — fully offline. fake curl/npm shims drive the logic:
# FAKE_CURL_TABLE maps a url-substring to "latest:speed_bytes_per_sec" (or
# "=dead" for an unusable candidate; speed 0 = metadata ok, tarball dead →
# last-resort); FAKE_NPM_STALL_ON makes the fake npm sleep 300s for matching
# registries so the watchdog fires.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-piweb-npm.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  unset AIBOX_PROFILE AIBOX_NPM_REGISTRY AIBOX_NPM_REGISTRIES AIBOX_NPM_TIMEOUT \
    AIBOX_NPM_PROBE_TIMEOUT npm_config_prefix FAKE_CURL_TABLE FAKE_USER_REGISTRY \
    FAKE_NPM_STALL_ON || true
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FAKEBIN="$SANDBOX/bin"
  mkdir -p "$FAKEBIN"

  # ---- fake curl: pi-web lib's exact call shapes. Two endpoints:
  # metadata (URL without .tgz, -o FILE) → JSON with latest + a tarball URL that
  # points back at this registry; tarball (URL ends .tgz, -w size+time) → prints
  # "<speed_bytes> 1" so the measured throughput = speed_bytes/s.
  cat > "$FAKEBIN/curl" <<'SHIM'
#!/usr/bin/env bash
out="" fmt="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -s | -L) shift ;;
    *) url="$1"; shift ;;
  esac
done
for entry in ${FAKE_CURL_TABLE:-}; do
  key="${entry%%=*}"; val="${entry#*=}"
  case "$url" in
  *"$key"*)
    ver="${val%%:*}"; spd="${val#*:}"
    if [ "$ver" = "dead" ] || [ "$spd" = "dead" ]; then exit 0; fi
    case "$url" in
    *.tgz)
      case "$fmt" in *size_download*) printf '%s 1' "$spd" ;; esac
      ;;
    *)
      printf '{"dist-tags":{"latest":"%s"},"versions":{"%s":{"dist":{"tarball":"https://%s/pkg-%s.tgz"}}}}' \
        "$ver" "$ver" "$key" "$ver" > "$out" 2>/dev/null || true
      ;;
    esac
    exit 0
    ;;
  esac
done
exit 1
SHIM
  chmod +x "$FAKEBIN/curl"

  # ---- fake npm: config get registry / install -g ... --registry URL
  cat > "$FAKEBIN/npm" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "config" ] && [ "${2:-}" = "get" ]; then
  printf '%s\n' "${FAKE_USER_REGISTRY:-}"
  exit 0
fi
if [ "${1:-}" = "install" ]; then
  reg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --registry) reg="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  # stall on the configured registry substring (empty never matches real ones);
  # trap TERM so a watchdog kill exits 143 like real npm (a bare sleep would let
  # bash fall through to exit 0 after its child is pkilled — unrealistic).
  trap 'exit 143' TERM
  case "$reg" in
  *"${FAKE_NPM_STALL_ON:-__never_matches__}"*) sleep 300 ;;
  esac
  exit 0
fi
exit 1
SHIM
  chmod +x "$FAKEBIN/npm"

  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  . "$REPO_ROOT/tools/pi-web/lib.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "npm_registry_pick: probes rank by measured DOWNLOAD THROUGHPUT, fastest-first" {
  # NOTE: called DIRECTLY (not via run) — bats run executes in a subshell and the
  # function's global side-effects (NPM_REGISTRY et al) would be lost.
  # npmmirror 1MB/s > huawei 500KB/s > tencent 200KB/s > npmjs 10KB/s.
  export FAKE_CURL_TABLE="npmmirror=0.9.1:1048576 tencent=0.9.1:204800 huaweicloud=0.9.1:512000 registry.npmjs.org=0.9.1:10240"
  npm_registry_pick
  [ "$NPM_REGISTRY" = "https://registry.npmmirror.com" ]
  [ "$NPM_LATEST" = "0.9.1" ]
  set -- $NPM_REGISTRY_ORDER
  [ "$1" = "https://registry.npmmirror.com" ]
  [ "$2" = "https://mirrors.huaweicloud.com/repository/npm" ]
  [ "$3" = "https://mirrors.cloud.tencent.com/npm" ]
  [ "$4" = "https://registry.npmjs.org" ]
}

@test "npm_registry_pick: a mirror without the package (or dead) is dropped from the ranking" {
  export FAKE_CURL_TABLE="npmmirror=0.9.1:1048576 registry.npmjs.org=dead tencent=0.9.1:204800 huaweicloud=0.9.1:512000"
  npm_registry_pick
  [ "$NPM_REGISTRY" = "https://registry.npmmirror.com" ]
  case " $NPM_REGISTRY_ORDER " in
  *" registry.npmjs.org "*) false ;; # dropped
  *) : ;;
  esac
}

@test "npm_registry_pick: metadata ok but tarball speed 0 → kept as a last-resort candidate" {
  export FAKE_CURL_TABLE="npmmirror=0.9.1:1048576 tencent=0.9.1:0 huaweicloud=0.9.1:512000"
  npm_registry_pick
  [ "$NPM_REGISTRY" = "https://registry.npmmirror.com" ]
  # tencent is reachable (metadata ok) → stays in the order, ranked last (speed 0)
  [ "$(printf '%s\n' $NPM_REGISTRY_ORDER | tail -1)" = "https://mirrors.cloud.tencent.com/npm" ]
}

@test "npm_registry_pick: all candidates unusable → die with the pin hint" {
  export FAKE_CURL_TABLE="npmmirror=dead registry.npmjs.org=dead tencent=dead huaweicloud=dead"
  run npm_registry_pick
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usable npm registry"* ]]
  [[ "$output" == *"AIBOX_NPM_REGISTRY=<url>"* ]]
}

@test "npm_registry_pick: AIBOX_NPM_REGISTRY hard-pins without ranking" {
  export AIBOX_NPM_REGISTRY="https://registry.corp.internal"
  export FAKE_CURL_TABLE="registry.corp.internal=9.9.9:1048576"
  npm_registry_pick
  [ "$NPM_REGISTRY" = "https://registry.corp.internal" ]
  [ "$NPM_LATEST" = "9.9.9" ]
  [ "$NPM_REGISTRY_ORDER" = "https://registry.corp.internal" ]
}

@test "npm_registry_pick: the user's non-default .npmrc registry joins the probe and can win" {
  export FAKE_USER_REGISTRY="https://registry.corp.internal"
  export FAKE_CURL_TABLE="registry.corp.internal=0.9.1:2097152 npmmirror=0.9.1:1048576 tencent=0.9.1:204800 huaweicloud=0.9.1:512000 registry.npmjs.org=0.9.1:10240"
  npm_registry_pick
  # the configured registry is NOT in the shipped list, yet it wins → it joined the probe
  [ "$NPM_REGISTRY" = "https://registry.corp.internal" ]
  set -- $NPM_REGISTRY_ORDER
  [ "$1" = "https://registry.corp.internal" ]
}

@test "npm_install_global: watchdog kills a stalled registry and fails over to the runner-up" {
  export FAKE_CURL_TABLE="npmmirror=0.9.1:1048576 huaweicloud=0.9.1:512000 tencent=0.9.1:204800 registry.npmjs.org=0.9.1:10240"
  npm_registry_pick
  [ "$NPM_REGISTRY" = "https://registry.npmmirror.com" ]
  export FAKE_NPM_STALL_ON="registry.npmmirror.com"
  export AIBOX_NPM_TIMEOUT=2
  run npm_install_global
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm stalled on https://registry.npmmirror.com"* ]]
  [[ "$output" == *"installed via https://mirrors.huaweicloud.com/repository/npm"* ]]
}

@test "npm_install_global: every registry stalls → die listing all tried" {
  export FAKE_CURL_TABLE="npmmirror=0.9.1:1048576 registry.npmjs.org=0.9.1:10240"
  npm_registry_pick
  export FAKE_NPM_STALL_ON="registry" # matches both candidates
  export AIBOX_NPM_TIMEOUT=2
  run npm_install_global
  [ "$status" -ne 0 ]
  [[ "$output" == *"npm install failed on every registry tried"* ]]
}

@test "npm_install_global: fast success on the winner (no watchdog interference, ok path)" {
  export FAKE_CURL_TABLE="npmmirror=0.9.1:1048576 huaweicloud=0.9.1:512000"
  npm_registry_pick
  export AIBOX_NPM_TIMEOUT=2
  run npm_install_global
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed via https://registry.npmmirror.com"* ]]
}

@test "update.sh: the version check comes from the probe (no network-hanging 'npm view')" {
  # npm view hits the registry with NO timeout — replaced by the curl-bounded probe.
  ! grep -q "npm view" "$REPO_ROOT/tools/pi-web/update.sh"
  grep -q "npm_registry_pick" "$REPO_ROOT/tools/pi-web/update.sh"
}

@test "module.yaml: no static npmjs domains gate (the runtime probe supersedes it)" {
  # The domains BLOCK must not gate on registry.npmjs.org (the install hook probes
  # npmjs + CN mirrors at runtime; a static gate false-fails mirror-saved networks).
  # The explanatory comment legitimately mentions npmjs — parse the block, not the file.
  ! awk '/^  domains:/{f=1;next} /^  [a-z_]+:/{f=0} f' "$REPO_ROOT/tools/pi-web/module.yaml" | grep -q "registry.npmjs.org"
}

@test "render_dashboard: no unbound variables under set -u (the SERVICE_ID crash)" {
  # live-caught: after update to module 1.3.2, `aibox pi-web dashboard` died at
  # lib.sh line 590 — SERVICE_ID was never assigned anywhere in the module.
  # render_dashboard must degrade gracefully with NO deployment at all
  # (fresh sandbox HOME: no plist, no unit, no listener → HTTP 000 path).
  local sb
  sb="$(mktemp -d)"
  run bash -c "set -euo pipefail; HOME='$sb'; . '$REPO_ROOT/tools/pi-web/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pi-web · module"* ]]                       # header renders
  # degraded, not crashed — Darwin says "not running", Linux says "inactive"
  [[ "$output" == *"service:"*"not running"* || "$output" == *"service:"*"inactive"* ]]
  [[ "$output" == *"app:"*"http://127.0.0.1:"* ]]              # endpoint line
  rm -rf "$sb"
}

@test "render_dashboard: service state via the label (running service detected)" {
  # only meaningful where a pi-web launchd service actually runs (the dev
  # machine); CI skips — the unbound-variable guard is the portable part above
  launchctl print "gui/$(id -u)/pi-web" >/dev/null 2>&1 || skip "no local pi-web service"
  run bash -c ". '$REPO_ROOT/tools/pi-web/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ]
  [[ "$output" == *"service:  running (pid "* ]]
}

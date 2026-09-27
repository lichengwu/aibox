#!/usr/bin/env bats
# Tests for the registry: module.yaml parsing (parse_yaml_module_stdin) and the
# TTL cache path in load_registry (no network on a cache hit).

load test_helper

@test "parse_yaml_module_stdin: parses scalar + list + nested fields" {
  yaml='name: pi-web
version: 1.0.0
description: "a test module"
dir: tools/pi-web

deps:
  - "node:22"
  - npm

hooks:
  install: install.sh
  svc: svc.sh

ports:
  - 30141/tcp:http
'
  eval "$(printf '%s\n' "$yaml" | parse_yaml_module_stdin pi_web)"
  [ "$AIBOX_MODULE_pi_web_name" = "pi-web" ]
  [ "$AIBOX_MODULE_pi_web_version" = "1.0.0" ]
  [ "$AIBOX_MODULE_pi_web_description" = "a test module" ]
  [ "$AIBOX_MODULE_pi_web_dir" = "tools/pi-web" ]
  # list -> space-joined
  [[ "$AIBOX_MODULE_pi_web_deps" == *"node:22"* ]]
  [[ "$AIBOX_MODULE_pi_web_deps" == *"npm"* ]]
  # nested -> <parent>_<subkey>
  [ "$AIBOX_MODULE_pi_web_install" = "install.sh" ]
  [ "$AIBOX_MODULE_pi_web_svc" = "svc.sh" ]
  [[ "$AIBOX_MODULE_pi_web_ports" == "30141/tcp:http" ]]
}

@test "parse_yaml_module_stdin: strips surrounding double-quotes from values" {
  yaml='description: "keep the quotes out"'
  eval "$(printf '%s\n' "$yaml" | parse_yaml_module_stdin x)"
  [ "$AIBOX_MODULE_x_description" = "keep the quotes out" ]
}

@test "parse_yaml_module_stdin: escapes shell metacharacters (no command injection via value)" {
  # A value containing $ and backticks must not be executed when eval'd.
  yaml='description: "price is $5 and `whoami` is bad"'
  eval "$(printf '%s\n' "$yaml" | parse_yaml_module_stdin x)"
  [[ "$AIBOX_MODULE_x_description" == *'$5'* ]]
  [[ "$AIBOX_MODULE_x_description" == *'`whoami`'* ]]
}

@test "load_registry: local file:// source discovers tools/*/module.yaml" {
  AIBOX_RAW="file://$REPO_ROOT"
  load_registry
  # All five shipped modules are discoverable.
  for m in base clash openmaic pi-web windmill; do
    module_exists "$m" || { echo "missing module: $m" >&2; false; }
  done
  # pi-web's version field is populated from module.yaml.
  [ -n "$(module_field pi-web version)" ]
}

@test "load_registry: remote cache hit serves from cache without network" {
  # Pre-seed a cache with a fake module, fresh mtime.
  cat > "$AIBOX_REGISTRY_CACHE" <<'EOF'
AIBOX_MODULES="fake-mod"
AIBOX_MODULE_fake_mod_version="9.9.9"
AIBOX_MODULE_fake_mod_description="from cache"
AIBOX_MODULE_fake_mod_dir="tools/fake-mod"
EOF
  # Point RAW at the real remote URL, but the cache should short-circuit before any curl.
  AIBOX_RAW="https://raw.githubusercontent.com/lichengwu/aibox/main"
  load_registry
  [ "$AIBOX_MODULES" = "fake-mod" ]
  [ "$(module_field fake-mod version)" = "9.9.9" ]
}

@test "_cache_fresh: fresh cache returns 0; stale/missing returns non-zero" {
  # The staleness logic is extracted into _cache_fresh() so it can be tested directly
  # (the remote-branch fallback itself can't be tested hermetically without mocking the network).
  AIBOX_REGISTRY_TTL=60
  # missing file -> stale (non-zero)
  ! _cache_fresh "$AIBOX_REGISTRY_CACHE" || fail "missing cache should be stale"
  # fresh file -> fresh (zero)
  echo 'AIBOX_MODULES="x"' > "$AIBOX_REGISTRY_CACHE"
  _cache_fresh "$AIBOX_REGISTRY_CACHE" || fail "fresh cache should be fresh"
  # backdated beyond TTL -> stale (non-zero)
  touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$AIBOX_REGISTRY_CACHE" 2>/dev/null || true
  ! _cache_fresh "$AIBOX_REGISTRY_CACHE" || fail "backdated cache should be stale"
}

@test "load_registry remote: _-prefixed dirs (tools/_shared) are skipped — no wasted module.yaml fetch" {
  # GitHub contents API lists tools/ including _shared (the include home — no
  # module.yaml there). Previously each refresh tried to fetch it: a 4-candidate
  # pool miss + a noisy warn (live-caught in the user's update output).
  AIBOX_RAW="https://raw.githubusercontent.com/lichengwu/aibox/main"
  # fake curl: the tools/ listing + exactly ONE module.yaml fetch (gitlab)
  FAKEBIN="$AIBOX_HOME/bin"
  mkdir -p "$FAKEBIN"
  cat >"$FAKEBIN/curl" <<'SHIM'
#!/usr/bin/env bash
out="" fmt="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -[fsSL]*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"${FAKE_CURL_LOG:-/dev/null}"
emit() { # $1 = body
  if [ -n "$out" ]; then printf '%s' "$1" >"$out"; else printf '%s' "$1"; fi
  case "$fmt" in *time_total*) printf '%s' "0.1" ;; esac
  exit 0
}
case "$url" in
*"/contents/tools")
  emit '{"name":"_shared"}
{"name":"gitlab"}'
  ;;
*/tools/gitlab/module.yaml)
  emit 'name: gitlab
version: 1.5.2
dir: tools/gitlab
'
  ;;
*/tools/_shared/module.yaml)
  echo "BUG: _shared module.yaml fetched" >&2
  exit 1
  ;;
*)
  exit 6
  ;;
esac
SHIM
  chmod +x "$FAKEBIN/curl"
  export FAKE_CURL_LOG="$AIBOX_HOME/curl.log"
  : >"$FAKE_CURL_LOG"
  export PATH="$FAKEBIN:$PATH"
  load_registry
  [ "$AIBOX_MODULES" = "gitlab" ] || false
  if grep -q "_shared/module.yaml" "$FAKE_CURL_LOG"; then
    echo "wasted fetch: $(cat "$FAKE_CURL_LOG")"
    false
  fi
}

# ---------- the shared readers (one implementation of the dialect) ------------

@test "meta_field: scalar, flat list, and empty for a missing field" {
  local f="$BATS_TEST_TMPDIR/module.yaml"
  printf 'name: demo\nversion: 1.2.3\nactions:\n  - start\n  - stop\n' >"$f"
  [ "$(meta_field "$f" version)" = "1.2.3" ] || false
  [ "$(meta_field "$f" actions)" = "start stop" ] || false
  [ "$(meta_field "$f" missing)" = "" ] || false
  [ "$(meta_field "$BATS_TEST_TMPDIR/nope.yaml" version)" = "" ] || false
}

@test "meta_map_value: two-space map member (usage.<action>)" {
  local f="$BATS_TEST_TMPDIR/module.yaml"
  printf 'name: demo\nusage:\n  start: "Start the thing"\n  stop: "Stop it"\n' >"$f"
  [ "$(meta_map_value "$f" usage start)" = "Start the thing" ] || false
  [ "$(meta_map_value "$f" usage stop)" = "Stop it" ] || false
  [ "$(meta_map_value "$f" usage nope)" = "" ] || false
}

@test "meta_version: the module libs' single reader (and the manager's injection wins)" {
  [ "$(meta_version "$REPO_ROOT/tools/new-api/module.yaml")" = "$(grep '^version:' "$REPO_ROOT/tools/new-api/module.yaml" | sed 's/^version: *//')" ] || false
  # injected value wins over the file (the contract the manager uses on dispatch)
  run bash -c "
    export AIBOX_MODULE_VERSION=9.9.9
    . '$REPO_ROOT/tools/new-api/lib.sh'
    printf '%s' \"\$MODULE_VERSION\"
  "
  [ "$output" = "9.9.9" ] || { echo "got: $output"; false; }
  # direct execution falls back to module.yaml next to lib.sh
  run bash -c "
    . '$REPO_ROOT/tools/new-api/lib.sh'
    printf '%s' \"\$MODULE_VERSION\"
  "
  [ "$output" = "$(meta_version "$REPO_ROOT/tools/new-api/module.yaml")" ] || { echo "got: $output"; false; }
}

@test "every module lib resolves its version through the shared reader" {
  local m f
  for f in "$REPO_ROOT"/tools/*/lib.sh; do
    m="$(basename "$(dirname "$f")")"
    [ "$m" = "_shared" ] && continue
    # modules without MODULE_VERSION at all (pure dispatch CLIs) are out of scope
    grep -qE "^(export )?MODULE_VERSION=" "$f" || continue
    grep -q 'meta_version "\${LIB_SELF}/module.yaml"' "$f" || { echo "$m: lib.sh does not use meta_version"; false; }
    # and no module re-implements the dialect
    ! grep -qE '(awk|sed|grep)[^|]*module\.yaml' "$f" || { echo "$m: hand-parses module.yaml"; false; }
  done
}

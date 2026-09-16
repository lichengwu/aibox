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

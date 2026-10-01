#!/usr/bin/env bats
# State layers and "data is not code". aibox keeps state in a few plain files;
# NONE of them may be sourced — sourcing executes whatever the file contains, so
# a corrupted or hostile config/cache/state/deploy-env would run as the user.
# Everything is parsed (cfg_kv_load / cfg_kv_get) with values taken literally.

load test_helper

@test "config: hostile content is parsed literally, never executed" {
  {
    printf 'AIBOX_PROXY_URL=http://127.0.0.1:7890\n'
    printf 'AIBOX_PROXY_ENABLED=1\n'
    printf 'EVIL=$(touch "%s/PWNED")\n' "$AIBOX_HOME"
    printf 'ALSO_EVIL=`touch "%s/PWNED2"`\n' "$AIBOX_HOME"
    printf 'not a kv line\n9BAD_KEY=x\n'
  } >"$AIBOX_CONFIG"
  run bash -c "source '$AIBOX_BIN'; load_config; printf '%s|%s|%s' \"\$AIBOX_PROXY_URL\" \"\$AIBOX_PROXY_ENABLED\" \"\${EVIL:-<unset>}\""
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "http://127.0.0.1:7890|1|\$(touch \"$AIBOX_HOME/PWNED\")" ] || { echo "got: $output"; false; }
  [ ! -e "$AIBOX_HOME/PWNED" ] || { echo "config content EXECUTED"; false; }
  [ ! -e "$AIBOX_HOME/PWNED2" ] || { echo "config content EXECUTED"; false; }
}

@test "registry cache: hostile module metadata is parsed, not executed" {
  mkdir -p "$AIBOX_MOD_DIR/demo"
  {
    printf 'AIBOX_MODULES="demo"\nAIBOX_MODULE_COUNT="1"\n'
    printf 'AIBOX_MODULE_demo_version="1.2.3"\nAIBOX_MODULE_demo_ports="30300/tcp:http"\n'
    printf 'AIBOX_MODULE_demo_evil="$(touch "%s/PWNED")"\n' "$AIBOX_HOME"
  } >"$AIBOX_REGISTRY_CACHE"
  run bash -c "source '$AIBOX_BIN'; load_registry >/dev/null 2>&1; printf '%s|%s' \"\$(module_field demo version)\" \"\$(module_field demo ports)\""
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "1.2.3|30300/tcp:http" ] || { echo "got: $output"; false; }
  [ ! -e "$AIBOX_HOME/PWNED" ] || { echo "registry cache content EXECUTED"; false; }
}

@test "clash state: a hostile state file cannot execute (read via cfg_kv_load)" {
  mkdir -p "$AIBOX_HOME/apps/clash"
  {
    printf 'CLASH_ENABLED=1\nCLASH_PORT=7890\nCLASH_MODE=internal\n'
    printf 'EVIL="$(touch "%s/PWNED")"\n' "$AIBOX_HOME"
  } >"$AIBOX_HOME/apps/clash/state"
  run bash -c "source '$AIBOX_BIN'; clash_active >/dev/null 2>&1; echo rc=\$?"
  [ ! -e "$AIBOX_HOME/PWNED" ] || { echo "clash state EXECUTED"; false; }
}

@test "cfg_kv_get: single key, literal value, missing file/key is empty" {
  local f="$AIBOX_HOME/kv"
  {
    printf 'A="quoted value"\nB=plain\n# comment\n'
    printf 'C=$(echo boom)\n'
  } >"$f"
  run bash -c "source '$AIBOX_BIN'; printf '%s|%s|%s|%s' \"\$(cfg_kv_get '$f' A)\" \"\$(cfg_kv_get '$f' B)\" \"\$(cfg_kv_get '$f' C)\" \"\$(cfg_kv_get '$f' MISSING)\""
  [ "$output" = "quoted value|plain|\$(echo boom)|" ] || { echo "got: $output"; false; }
}

@test "cfg_kv_load_export: exports parsed keys (deploy .env for compose)" {
  local f="$AIBOX_HOME/env"
  printf 'GITLAB_HTTP_PORT=8929\nGITLAB_IMAGE=gitlab/gitlab-ce:x\n' >"$f"
  run bash -c "source '$AIBOX_BIN'; cfg_kv_load_export '$f' GITLAB_; env | grep -c '^GITLAB_'"
  [ "$output" = "2" ] || { echo "got: $output"; false; }
}

@test "gitlab load_env parses the deploy .env instead of sourcing it" {
  grep -q 'cfg_kv_load_export "\$envf"' "$REPO_ROOT/tools/gitlab/lib.sh" || { grep -n 'load_env' -A 8 "$REPO_ROOT/tools/gitlab/lib.sh" | head; false; }
}

@test "guard: no source file sources a data store (and the gate has teeth)" {
  run bash "$REPO_ROOT/scripts/check-sources.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"parsed, never sourced"* ]] || false
  local fx="$AIBOX_HOME/srctest"
  mkdir -p "$fx/src/aibox" "$fx/tools/_shared/lib" "$fx/scripts"
  cp "$REPO_ROOT/scripts/check-sources.sh" "$fx/scripts/"
  printf 'ok() { :; }\n' >"$fx/tools/_shared/lib/00-out.sh"
  printf 'load() {\n  . "$AIBOX_CONFIG"\n}\n' >"$fx/src/aibox/30-state.sh"
  run bash "$fx/scripts/check-sources.sh"
  [ "$status" -eq 1 ] || { echo "expected rc=1, got $status: $output"; false; }
  [[ "$output" == *"SOURCES A DATA FILE"* ]] || { echo "$output"; false; }
}

@test "the state model is documented: layers + parsed-not-sourced" {
  grep -q 'State model' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'cfg_kv_load' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'State model' "$REPO_ROOT/AGENTS.md" || false
}

@test "cfg_kv_set: simple values are written BARE, complex ones quoted" {
  # Regression: a quoted port/image made compose fail with "invalid hostPort" /
  # "invalid reference format" (live-caught migrating a new-api deployment) — the
  # writer must emit bare values whenever they can survive a plain KEY=VALUE line.
  frag="$(mktemp)"
  sed -n '/^cfg_kv_set() {/,/^}/p' "$REPO_ROOT/tools/_shared/lib/40-cfg.sh" >"$frag"
  [ -s "$frag" ] || false
  run bash -c ". '$frag'; f=\$(mktemp); cfg_kv_set \"\$f\" NEW_API_PORT 3000; cfg_kv_set \"\$f\" NEW_API_IMAGE calciumion/new-api:v1.0.0-rc.30; cfg_kv_set \"\$f\" MSG 'hello world'; cat \"\$f\""
  [ "$status" -eq 0 ] || false
  case "$output" in *"NEW_API_PORT=3000"*) ;; *) false ;; esac
  case "$output" in *"NEW_API_IMAGE=calciumion/new-api:v1.0.0-rc.30"*) ;; *) false ;; esac
  case "$output" in *'MSG="hello world"'*) ;; *) false ;; esac
  # and an existing quoted value is REPAIRED in place by the next write
  run bash -c ". '$frag'; f=\$(mktemp); printf 'NEW_API_PORT=\"3000\"\n' >\"\$f\"; cfg_kv_set \"\$f\" NEW_API_PORT 3000; cat \"\$f\""
  [ "$output" = "NEW_API_PORT=3000" ] || false
  rm -f "$frag"
}


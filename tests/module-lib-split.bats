#!/usr/bin/env bats
# Module libraries may be split by domain: lib.sh + lib-<domain>.sh. The extra file
# must reach the CACHE layout (that is what hooks source), be declared in
# module.yaml files:, and be a sourced library (no shebang / strict line).

load test_helper

@test "the split libraries are declared in files: and sourced by lib.sh" {
  local m lib part
  for m in base clash pi-web; do
    lib="$REPO_ROOT/tools/$m/lib.sh"
    part="$(awk '/^files:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - lib-/{sub(/^  - /,""); print; exit}' "$REPO_ROOT/tools/$m/module.yaml")"
    [ -n "$part" ] || { echo "$m: no lib-* entry in files:"; false; }
    [ -f "$REPO_ROOT/tools/$m/$part" ] || { echo "$m: declared $part does not exist"; false; }
    grep -q "LIB_PART=\"\${LIB_SELF}/$part\"" "$lib" || { echo "$m: lib.sh does not source $part"; false; }
    # a sourced library: no shebang, no strict-mode line
    if head -1 "$REPO_ROOT/tools/$m/$part" | grep -q '^#!'; then
      echo "$m/$part: has a shebang"; false
    fi
    if grep -qE '^set -euo pipefail' "$REPO_ROOT/tools/$m/$part"; then
      echo "$m/$part: has a strict-mode line"; false
    fi
  done
}

@test "cache layout: the extra file lands next to lib.sh for every split module" {
  local m part
  for m in base clash pi-web; do
    rm -rf "$AIBOX_HOME/modules/$m"
    part="$(awk '/^files:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - lib-/{sub(/^  - /,""); print; exit}' "$REPO_ROOT/tools/$m/module.yaml")"
    run bash -c "
      export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT'
      source '$AIBOX_BIN'
      download_module '$m' >/dev/null 2>&1 || exit 1
      [ -f \"\$AIBOX_MOD_DIR/$m/lib.sh\" ] || exit 2
      [ -f \"\$AIBOX_MOD_DIR/$m/$part\" ] || exit 3
      echo ok
    "
    [ "$output" = "ok" ] || { echo "$m: rc=$status $output"; false; }
  done
}

@test "the moved functions exist in BOTH layouts (repo and cache)" {
  local m fn
  for m in base clash pi-web; do
    case "$m" in
    base) fn="cmd_upgrade" ;;
    clash) fn="download_mihomo" ;;
    pi-web) fn="resolve_node" ;;
    esac
    run bash -c "
      export AIBOX_HOME='$AIBOX_HOME'
      . '$REPO_ROOT/tools/$m/lib.sh' >/dev/null 2>&1 || exit 1
      type -t '$fn' >/dev/null 2>&1 || exit 2
      echo ok
    "
    [ "$output" = "ok" ] || { echo "$m/$fn: repo layout rc=$status $output"; false; }
    bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT'; source '$AIBOX_BIN'; download_module '$m' >/dev/null 2>&1" || true
    run bash -c "
      export AIBOX_HOME='$AIBOX_HOME'
      . '$AIBOX_HOME/modules/$m/lib.sh' >/dev/null 2>&1 || exit 1
      type -t '$fn' >/dev/null 2>&1 || exit 2
      echo ok
    "
    [ "$output" = "ok" ] || { echo "$m/$fn: cache layout rc=$status $output"; false; }
  done
}

@test "no function is defined twice across the split files (anti-twin)" {
  run bash "$REPO_ROOT/scripts/check-sources.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local m
  for m in base clash pi-web; do
    local dup
    dup="$(cat "$REPO_ROOT/tools/$m/lib.sh" "$REPO_ROOT/tools/$m"/lib-*.sh 2>/dev/null |
      grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' | sort | uniq -d)"
    [ -z "$dup" ] || { echo "$m: duplicated definitions: $dup"; false; }
  done
}

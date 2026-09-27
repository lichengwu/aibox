#!/usr/bin/env bats
# File ownership in a deploy root:
#   MANAGED (shipped templates/code) — refreshed on update, but a USER-EDITED copy
#     is kept (the new version lands as <name>.new)
#   STATE (`state_files:` in module.yaml — .env, data) — never overwritten
# Before this, install hooks did a plain `cp`: an edited compose file was silently
# replaced by the next `aibox update`.

load test_helper

@test "install_managed_file: fresh install places the file and records its hash" {
  printf 'v1\n' >"$AIBOX_HOME/src.yml"
  run bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/compose.yml'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$AIBOX_HOME/root/compose.yml")" = "v1" ] || false
  [ -f "$AIBOX_HOME/root/.managed.sha256" ] || { ls -la "$AIBOX_HOME/root"; false; }
  grep -q 'compose.yml$' "$AIBOX_HOME/root/.managed.sha256" || { cat "$AIBOX_HOME/root/.managed.sha256"; false; }
}

@test "install_managed_file: an UNTOUCHED file is refreshed on update" {
  printf 'v1\n' >"$AIBOX_HOME/src.yml"
  bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/compose.yml'" >/dev/null
  printf 'v2\n' >"$AIBOX_HOME/src.yml"
  run bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/compose.yml'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$AIBOX_HOME/root/compose.yml")" = "v2" ] || { cat "$AIBOX_HOME/root/compose.yml"; false; }
}

@test "install_managed_file: a USER-EDITED file is kept, the new version lands as .new" {
  printf 'v1\n' >"$AIBOX_HOME/src.yml"
  bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/compose.yml'" >/dev/null
  printf 'my local edit\n' >"$AIBOX_HOME/root/compose.yml"
  printf 'v2\n' >"$AIBOX_HOME/src.yml"
  run bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/compose.yml'"
  [ "$status" -eq 0 ] || { echo "keeping the user's file must not fail the hook, got $status"; false; }
  [[ "$output" == *"modified by you"* ]] || { echo "$output"; false; }
  [ "$(cat "$AIBOX_HOME/root/compose.yml")" = "my local edit" ] || { cat "$AIBOX_HOME/root/compose.yml"; false; }
  [ "$(cat "$AIBOX_HOME/root/compose.yml.new")" = "v2" ] || { cat "$AIBOX_HOME/root/compose.yml.new"; false; }
}

@test "install_managed_file: a second update after the user reverted refreshes cleanly" {
  printf 'v1\n' >"$AIBOX_HOME/src.yml"
  bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/c.yml'" >/dev/null
  printf 'edit\n' >"$AIBOX_HOME/root/c.yml"
  printf 'v2\n' >"$AIBOX_HOME/src.yml"
  bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/c.yml'" >/dev/null 2>&1 || true
  # user accepts the shipped version by copying it back, then update again
  cp "$AIBOX_HOME/root/c.yml.new" "$AIBOX_HOME/root/c.yml"
  printf 'v3\n' >"$AIBOX_HOME/src.yml"
  run bash -c "source '$AIBOX_BIN'; install_managed_file '$AIBOX_HOME/src.yml' '$AIBOX_HOME/root/c.yml'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$AIBOX_HOME/root/c.yml")" = "v3" ] || { cat "$AIBOX_HOME/root/c.yml"; false; }
}

@test "every compose module ships its compose through install_managed_file" {
  local m f
  for f in "$REPO_ROOT"/tools/*/install.sh; do
    m="$(basename "$(dirname "$f")")"
    case "$m" in base | dify | gitlab | new-api | xiaozhi) ;; *) continue ;; esac
    grep -q 'install_managed_file' "$f" || { echo "$m: install.sh still plain-copies"; false; }
    ! grep -qE '^[[:space:]]*cp .*docker-compose' "$f" || { echo "$m: raw cp of compose remains"; false; }
  done
}

@test "state_files: declared where the deploy .env is written, and never in files:" {
  local m f state
  for f in "$REPO_ROOT"/tools/*/module.yaml; do
    m="$(basename "$(dirname "$f")")"
    state="$(awk '/^state_files:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); print}' "$f")"
    grep -q '\.env' "$REPO_ROOT/tools/$m/install.sh" 2>/dev/null || continue
    printf '%s\n' "${state}" | grep -qx '.env' || { echo "$m: install.sh writes .env but state_files: misses it"; false; }
  done
}

@test "validator: a file listed as both managed and state is an ERROR" {
  local out="$AIBOX_HOME/vtools"
  mkdir -p "$out"
  bash "$REPO_ROOT/scripts/new-module.sh" both --out "$out" >/dev/null 2>&1
  local y="$out/both/module.yaml"
  # both: .env managed AND state (the same file cannot be both)
  printf 'files:\n  - .env\nstate_files:\n  - .env\n' >>"$y"
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" both
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"either managed or state"* ]] || { echo "$output"; false; }
}

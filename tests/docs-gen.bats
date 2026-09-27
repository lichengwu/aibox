#!/usr/bin/env bats
# Generated README blocks: the action table and the config-key table are the same
# facts as module.yaml (actions/usage/env), so they are OUTPUT — CI checks freshness.

load test_helper

@test "gen-docs --check: the repo's README blocks are fresh" {
  run bash "$REPO_ROOT/scripts/gen-docs.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"fresh"* ]] || false
}

@test "every module README carries both generated blocks" {
  local m r
  for r in "$REPO_ROOT"/tools/*/README.md; do
    m="$(basename "$(dirname "$r")")"
    [ "$m" = "_shared" ] && continue
    grep -q 'BEGIN GENERATED: actions' "$r" || { echo "$m: no actions block"; false; }
    grep -q 'BEGIN GENERATED: config' "$r" || { echo "$m: no config block"; false; }
    grep -q 'END GENERATED: actions' "$r" || false
    grep -q 'END GENERATED: config' "$r" || false
  done
}

@test "the actions table lists exactly the module.yaml actions, with usage text" {
  local r="$REPO_ROOT/tools/new-api/README.md" y="$REPO_ROOT/tools/new-api/module.yaml" a usage
  for a in $(source "$REPO_ROOT/bin/aibox" && meta_field "$y" actions); do
    grep -q "| \`${a}\` |" "$r" || { echo "action $a missing from the README table"; false; }
  done
  usage="$(source "$REPO_ROOT/bin/aibox" && meta_map_value "$y" usage start)"
  [ -n "$usage" ] || false
  grep -qF "$usage" "$r" || { echo "usage text for start not in the table"; false; }
}

@test "stale blocks are detected (usage change → --check fails)" {
  local tmp="$AIBOX_HOME/gen"
  mkdir -p "$tmp/scripts" "$tmp/tools/demo"
  cp "$REPO_ROOT/scripts/gen-docs.sh" "$tmp/scripts/"
  cp -r "$REPO_ROOT/tools/_shared" "$tmp/tools/"
  cat >"$tmp/tools/demo/module.yaml" <<'YAML'
name: demo
version: 1.0.0
actions:
  - start
usage:
  start: "Start it"
env:
  DEMO_PORT: "30300 — the port"
YAML
  printf '# demo\n\n<!-- BEGIN GENERATED: actions (scripts/gen-docs.sh) -->\nstale\n<!-- END GENERATED: actions -->\n<!-- BEGIN GENERATED: config (scripts/gen-docs.sh) -->\nstale\n<!-- END GENERATED: config -->\n' >"$tmp/tools/demo/README.md"
  run bash "$tmp/scripts/gen-docs.sh" --check
  [ "$status" -eq 1 ] || { echo "expected stale rc=1: $output"; false; }
  [[ "$output" == *"STALE"* ]] || { echo "$output"; false; }
  # regenerate → fresh, and the table now carries the yaml facts
  bash "$tmp/scripts/gen-docs.sh" >/dev/null
  run bash "$tmp/scripts/gen-docs.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '| `start` | Start it |' "$tmp/tools/demo/README.md" || { cat "$tmp/tools/demo/README.md"; false; }
  grep -q 'DEMO_PORT' "$tmp/tools/demo/README.md" || false
}

@test "CI enforces the generated-docs gate" {
  grep -q 'scripts/gen-docs.sh --check' "$REPO_ROOT/.github/workflows/lint.yml" || false
}

@test "no module hand-maintains an action table outside the generated block" {
  # a second "| `start` |" line outside the markers means someone re-added a table
  local m r
  for r in "$REPO_ROOT"/tools/*/README.md; do
    m="$(basename "$(dirname "$r")")"
    [ "$m" = "_shared" ] && continue
    [ "$(grep -c '| `start` |' "$r")" = "1" ] || { echo "$m: multiple action tables"; false; }
  done
}

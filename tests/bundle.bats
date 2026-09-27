#!/usr/bin/env bats
# bundle: the single-file CLI is a GENERATED artifact (src/aibox/*.sh → bin/aibox).
# Guards the source/artifact contract: the shipped file must always be the exact
# concatenation of the sources, and only the head fragment may carry a shebang or
# top-level shell settings (anything else would silently change execution order).

load test_helper

@test "artifact is up to date with src/aibox/*.sh" {
  run bash "$REPO_ROOT/scripts/bundle.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"up to date"* ]] || false
}

@test "artifact equals the concatenation byte-for-byte" {
  bash "$REPO_ROOT/scripts/bundle.sh" --print >"$AIBOX_HOME/printed"
  cmp -s "$AIBOX_HOME/printed" "$REPO_ROOT/bin/aibox" || { diff <(head -50 "$REPO_ROOT/bin/aibox") <(head -50 "$AIBOX_HOME/printed"); false; }
}

@test "stale artifact is detected (and reported as STALE)" {
  cp "$REPO_ROOT/bin/aibox" "$AIBOX_HOME/fake-aibox"
  printf '# hand edit\n' >>"$AIBOX_HOME/fake-aibox"
  run bash "$REPO_ROOT/scripts/bundle.sh" --check --out "$AIBOX_HOME/fake-aibox"
  [ "$status" -eq 1 ] || { echo "expected stale rc=1, got $status"; false; }
  [[ "$output" == *"STALE"* ]] || { echo "$output"; false; }
}

@test "artifact carries the GENERATED marker on an early line" {
  head -6 "$REPO_ROOT/bin/aibox" | grep -q 'GENERATED FILE' || { head -6 "$REPO_ROOT/bin/aibox"; false; }
}

@test "only the head fragment has a shebang (fragments are concatenated verbatim)" {
  local f n=0
  for f in "$REPO_ROOT"/src/aibox/*.sh; do
    if head -1 "$f" | grep -q '^#!'; then n=$((n + 1)); fi
  done
  [ "$n" -eq 1 ] || { grep -l '^#!' "$REPO_ROOT"/src/aibox/*.sh; false; }
  head -1 "$REPO_ROOT/src/aibox/00-head.sh" | grep -q '^#!/usr/bin/env bash' || false
}

@test "head fragment sets strict mode before any other statement" {
  # the first non-comment, non-blank line of the head fragment must be the strict-mode line
  local first
  first="$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/src/aibox/00-head.sh" | head -1)"
  [ "$first" = "set -euo pipefail" ] || { echo "first statement: $first"; false; }
}

@test "every fragment parses standalone and is non-trivial" {
  local f
  for f in "$REPO_ROOT"/src/aibox/*.sh; do
    bash -n "$f" || { echo "parse fail: $f"; false; }
    [ "$(wc -l <"$f")" -gt 5 ] || { echo "suspiciously small: $f"; false; }
  done
}

@test "bundler refuses an unknown option with exit 2 (usage)" {
  run bash "$REPO_ROOT/scripts/bundle.sh" --nope
  [ "$status" -eq 2 ] || { echo "$output"; false; }
}

@test "CI enforces the bundle check" {
  grep -q 'bundle.sh --check' "$REPO_ROOT/.github/workflows/lint.yml" || { grep -n 'bundle' "$REPO_ROOT/.github/workflows/lint.yml"; false; }
}

@test "the contributor contract is documented (edit src, never bin/aibox)" {
  grep -q 'src/aibox' "$REPO_ROOT/AGENTS.md" || false
  grep -q 'scripts/bundle.sh' "$REPO_ROOT/AGENTS.md" || false
  grep -q 'src/aibox' "$REPO_ROOT/docs/module-spec.md" || false
}
#!/usr/bin/env bats
# bundle: the single-file CLI is a GENERATED artifact (src/aibox/*.sh → bin/aibox).
# Guards the source/artifact contract: the shipped file must always be the exact
# concatenation of the sources, and only the head fragment may carry a shebang or
# top-level shell settings (anything else would silently change execution order).

load test_helper

@test "artifact is up to date with src/aibox/*.sh" {
  run bash "$REPO_ROOT/scripts/bundle.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"fresh:"* ]] || false
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

@test "the module-side include is the same concatenation as the manager's shared part" {
  bash "$REPO_ROOT/scripts/bundle.sh" --check >/dev/null || false
  cmp -s <(cat "$REPO_ROOT"/tools/_shared/lib/*.sh) "$REPO_ROOT/tools/_shared/common.sh" || { echo "common.sh drifted from lib/*.sh"; false; }
  # one injection, in the right place: after 05-env.sh (colours), before the UI file
  local sh_pos ui_pos
  sh_pos="$(grep -n 'shared base linking (profile-aware)' "$REPO_ROOT/bin/aibox" | head -1 | cut -d: -f1)"
  ui_pos="$(grep -n 'unknown-argument UX' "$REPO_ROOT/bin/aibox" | head -1 | cut -d: -f1)"
  [ -n "$sh_pos" ] && [ -n "$ui_pos" ] && [ "$sh_pos" -lt "$ui_pos" ] || { echo "sh=$sh_pos ui=$ui_pos"; false; }
}

@test "no helper is defined twice (anti-twin gate)" {
  run bash "$REPO_ROOT/scripts/check-sources.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"anti-twin"* ]] || false
}

@test "anti-twin gate has teeth: a planted duplicate is caught" {
  # hermetic twin fixture: same function in the shared lib and in the manager
  local fx="$AIBOX_HOME/twinfix"
  mkdir -p "$fx/src/aibox" "$fx/tools/_shared/lib" "$fx/scripts"
  cp "$REPO_ROOT/scripts/check-sources.sh" "$fx/scripts/"
  printf 'log() { printf "%%s\n" "$*"; }\n' >"$fx/tools/_shared/lib/00-out.sh"
  printf 'log() { printf "%%s\n" "$*"; }\n' >"$fx/src/aibox/10-ui.sh"
  run bash "$fx/scripts/check-sources.sh"
  [ "$status" -eq 1 ] || { echo "expected rc=1, got $status: $output"; false; }
  [[ "$output" == *"ANTI-TWIN"* ]] || { echo "$output"; false; }
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
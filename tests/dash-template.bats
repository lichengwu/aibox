#!/usr/bin/env bats
# dash_* keyline template helpers (tools/_shared/common.sh).
# Spec: docs/superpowers/specs/2026-09-23-dashboard-app-version-keyline-design.md §4-5.
# Assertions carry `|| false` — pitfall #10 (macOS bash 3.2 swallows failing
# [[ ]] mid-test under set -e).
# Sourcing standalone: no C_* exported → plain output; non-TTY → rule width 64.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091
  . "$REPO_ROOT/tools/_shared/common.sh"
}

@test "dash_header: name + app version + state word, then the rule" {
  run dash_header "pi-web" "0.9.3" "ok"
  [ "$status" -eq 0 ] || false
  [ "${lines[0]}" = "pi-web 0.9.3 · ✓ ok" ] || false
  [ "${lines[1]}" = "$(printf '─%.0s' $(seq 1 64))" ] || false
}

@test "dash_header: empty app version / na state omit their segments" {
  run dash_header "base" "" ""
  [ "${lines[0]}" = "base" ] || false
  run dash_header "openmaic" "" "na"
  [ "${lines[0]}" = "openmaic" ] || false
}

@test "dash_header: state words map icons (running ✓ / starting ⚠ / stopped ○)" {
  run dash_header "m" "1" "running"
  [[ "${lines[0]}" == *"✓ running" ]] || false
  run dash_header "m" "1" "starting"
  [[ "${lines[0]}" == *"⚠ starting" ]] || false
  run dash_header "m" "1" "stopped"
  [[ "${lines[0]}" == *"○ stopped" ]] || false
}

@test "dash_row: %-10s label grid, no colon; value verbatim (CJK never truncated)" {
  run dash_row "endpoint" "http://127.0.0.1:30141 · HTTP 307"
  [ "$output" = "  endpoint   http://127.0.0.1:30141 · HTTP 307" ] || false
  run dash_row "kernel" "日本-TY-4-HY2-流量倍率:0.6 16ms"
  [[ "$output" == *"日本-TY-4-HY2-流量倍率:0.6 16ms" ]] || false
}

@test "dash_module_row: sunk row — version + path, grid-consistent" {
  run dash_module_row "1.3.5" "/home/u/.aibox/modules/pi-web/"
  [ "$output" = "  module     1.3.5 · /home/u/.aibox/modules/pi-web/" ] || false
}

@test "dash_secheader: ── title ──… reaches the rule width" {
  run dash_secheader "profile base (active)"
  [[ "$output" == "── profile base (active) ─"* ]] || false
  [[ "$output" == *$(printf '─%.0s' $(seq 1 3)) ]] || false
}

@test "dash_rule: non-TTY = exactly 64 complete ─ literals, zero ANSI escapes" {
  run dash_rule
  [ "$output" = "$(printf '─%.0s' $(seq 1 64))" ] || false
  case "$output" in *$'\033'*) false ;; *) : ;; esac
}

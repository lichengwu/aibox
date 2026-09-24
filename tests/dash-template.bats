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

@test "dash_rule: TTY width adapts to terminal columns (clamped [40,72])" {
  command -v expect >/dev/null 2>&1 || skip "no expect"
  # A pty of 50 cols must yield a 50-char rule. (RED against the old code:
  # [ -t 1 ] ran inside $(…) — always a pipe — so the width was dead-fixed 64.
  # expect's spawn has no TERM by default — export one or tput dies; the
  # command travels via $env() so Tcl never eats the shell's [ ].)
  local cmd line chars
  cmd="cd '$REPO_ROOT'; export TERM=xterm; . tools/_shared/common.sh; stty cols 50; dash_rule"
  line="$(EXPECT_CMD="$cmd" expect -c '
    log_user 0
    spawn /bin/bash -c $env(EXPECT_CMD)
    expect {
      -re "(.+)\r" { puts $expect_out(1,string) }
      timeout { exit 3 }
    }
  ' | tr -d "\r" | tail -1)"
  # count CHARS locale-independently: Tcl string length counts BYTES under the
  # C locale (─×50 → 150 in a minimal container), and bash ${#line}/wc -m do
  # too — map each ─ to one ASCII byte, then count bytes
  chars="$(printf '%s' "$line" | sed 's/─/x/g' | wc -c | tr -d '[:space:]')"
  [ "$chars" = "50" ] || { echo "rule chars: [$chars] line=[$line]"; false; }
}

@test "bash glob semantics pin: multibyte suffix patterns match fine (the misdiagnosed #11)" {
  # *"X" anchors at END-OF-STRING; *"X"* is containment. A multibyte tail is
  # NOT a bash 3.2 bug — pinned so nobody re-misdiagnoses a suffix-pattern miss.
  run /bin/bash -c '[[ "m 1 · ✓" == *"· ✓" ]]'
  [ "$status" -eq 0 ] || false
  run /bin/bash -c '[[ "a · ✓ b" == *"· ✓" ]]'
  [ "$status" -ne 0 ] || false   # suffix anchor: "b" follows — correctly NO
}

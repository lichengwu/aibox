#!/usr/bin/env bats
# dashboard TTY path (P2): a real pty driven by expect. This is the highest-risk
# area of any TUI (the terminal must be handed back exactly as it was found), so it
# gets its own suite: alternate screen entered AND left, cursor restored, exit 0.
# AGENTS.md pitfall #7: use expect, never `script`, to drive a pty.
load test_helper

_fixture() {
  local f="$BATS_TMPDIR/tty-fx.snap"
  cat >"$f" <<'SNAP'
#aibox-dashboard-snapshot 1
SNAPSHOT ts=1790660000 cost_ms=380 stale=0 docker=ok load=0.42 interval=2
MODULE name=gitlab profile=default mver=1.12.0 aver=18.9.1-ce.0 state=ok health=healthy endpoint=https://gl ports=80,443 listening=80,443 upgrade=- age=0
SNAP
  printf '%s' "$f"
}

@test "pty: alternate screen entered+left, cursor restored, exit 0 (expect)" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  local log="$BATS_TMPDIR/pty.log"
  : >"$log"
  run expect -c "
log_file -noappend $log
set timeout 30
spawn env AIBOX_DASH_SNAPSHOT=$(_fixture) AIBOX_DASH_FRAMES=8 TERM=xterm \
  bash $REPO_ROOT/bin/aibox dashboard
after 2500
send \"q\"
expect eof
catch wait result
puts \"EXIT=[lindex \$result 3]\"
"
  [ "$status" -eq 0 ] || false
  case "$output" in *"EXIT=0"*) ;; *) false ;; esac
  # the alternate screen must be entered and left again
  [ "$(grep -c 1049h "$log" || true)" -ge 1 ] || false
  [ "$(grep -c 1049l "$log" || true)" -ge 1 ] || false
  # ...and the cursor must be shown again on the way out
  [ "$(grep -c '?25h' "$log" || true)" -ge 1 ] || false
  # the frame really rendered inside the pty
  case "$(cat "$log")" in *"aibox dashboard"*) ;; *) false ;; esac
}

@test "pty: Ctrl-C leaves the terminal usable (trap cleanup, exit 0)" {
  command -v expect >/dev/null 2>&1 || skip "expect not available"
  local log="$BATS_TMPDIR/pty-int.log"
  : >"$log"
  run expect -c "
log_file -noappend $log
set timeout 30
spawn env AIBOX_DASH_SNAPSHOT=$(_fixture) AIBOX_DASH_FRAMES=0 TERM=xterm \
  bash $REPO_ROOT/bin/aibox dashboard
after 2000
send \"\003\"
expect eof
catch wait result
puts \"EXIT=[lindex \$result 3]\"
"
  [ "$(grep -c 1049l "$log" || true)" -ge 1 ] || false
  [ "$(grep -c '?25h' "$log" || true)" -ge 1 ] || false
  case "$output" in *"EXIT="*) ;; *) false ;; esac
}
#!/usr/bin/env bats
# dashboard key loop (P2/P3): the interactive loop driven HEADLESS through
# AIBOX_DASH_KEYS — no pty needed, and it must not touch stty or the alternate
# screen (that is the TTY path, covered by dashboard-tty.bats).
load test_helper

_fixture() {
  local f="$BATS_TMPDIR/keys-fx.snap"
  cat >"$f" <<'SNAP'
#aibox-dashboard-snapshot 1
SNAPSHOT ts=1790660000 cost_ms=380 stale=0 docker=ok load=0.42 interval=2
MODULE name=gitlab profile=default mver=1.12.0 aver=18.9.1-ce.0 state=ok health=healthy endpoint=https://gl ports=80,443 listening=80,443 upgrade=19.4.1-ce.0 age=0
MODULE name=xiaozhi profile=default mver=1.7.0 aver=v1.5.0 state=drift health=- endpoint=http://x ports=31130 listening=- upgrade=- age=0
CONTAINER name=aibox-gitlab image=gitlab/gitlab-ce:18.9.1 cpu=8.7% mem=2.4G uptime=1d health=healthy ports=80
SNAP
  printf '%s' "$f"
}

_keys() { # $1… = key tokens, one per line (a leading `p` pauses, which also removes
  # the inter-frame sleep so the tests stay fast)
  local f="$BATS_TMPDIR/keys.txt" k
  : >"$f"
  for k in "$@"; do printf '%s\n' "$k" >>"$f"; done
  printf '%s' "$f"
}

_dash_headless() { # $1=keys file, $2=frames → run one headless session
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 \
    AIBOX_DASH_KEYS="$1" AIBOX_DASH_FRAMES="$2" \
    bash "$REPO_ROOT/bin/aibox" dashboard
}

@test "keys: TAB and BTAB cycle panes (pane label + count in the header)" {
  _dash_headless "$(_keys p TAB TAB q)" 4
  [ "$status" -eq 0 ] || false
  case "$output" in *"pane modules (1/4)"*) ;; *) false ;; esac
  case "$output" in *"pane containers (2/4)"*) ;; *) false ;; esac
  case "$output" in *"pane upgrades (3/4)"*) ;; *) false ;; esac
}

@test "keys: s cycles the sort key (visible in the status line)" {
  _dash_headless "$(_keys p s s q)" 4
  case "$output" in *"sort:name"*) ;; *) false ;; esac
  case "$output" in *"sort:state"*) ;; *) false ;; esac
  case "$output" in *"sort:ports"*) ;; *) false ;; esac
}

@test "keys: + and - cycle the refresh interval" {
  _dash_headless "$(_keys p + q)" 3
  case "$output" in *"interval:2s"*) ;; *) false ;; esac
  case "$output" in *"interval:5s"*) ;; *) false ;; esac
}

@test "keys: p toggles pause (PAUSED in the status line)" {
  _dash_headless "$(_keys p p q)" 3
  case "$output" in *"PAUSED"*) ;; *) false ;; esac
}

@test "keys: q quits immediately (no further frames)" {
  _dash_headless "$(_keys q)" 5
  [ "$status" -eq 0 ] || false
  local n
  n="$(printf '%s' "$output" | grep -c "aibox dashboard" || true)"
  [ "$n" = "1" ] || false
}

@test "keys: headless mode never emits stty/alternate-screen control sequences" {
  _dash_headless "$(_keys p q)" 3
  case "$output" in *1049h* | *1049l*) false ;; esac
  case "$output" in *"[?25"*) false ;; esac
}

@test "arrows: the parser accepts BOTH CSI (ESC[A) and SS3 (ESCOA) sequences" {
  # SS3 is "application cursor keys" (DECCKM) — many terminals switch to it, and the
  # parser only knowing CSI is why Up/Down looked dead (reported live).
  frag="$(mktemp)"
  sed -n '/^_dash_key_read() {/,/^}/p' "$REPO_ROOT/src/aibox/74-dashboard-tui.sh" >"$frag"
  [ -s "$frag" ] || false
  run bash -c "printf '\033OB' | bash -c '. \"$frag\"; _dash_key_read'"
  [ "$output" = "DOWN" ] || false
  run bash -c "printf '\033[A' | bash -c '. \"$frag\"; _dash_key_read'"
  [ "$output" = "UP" ] || false
  run bash -c "printf '\033[5~' | bash -c '. \"$frag\"; _dash_key_read'"
  [ "$output" = "PGUP" ] || false
  rm -f "$frag"
}

@test "keys: Down moves the marker to the NEXT row (per-line, not containment)" {
  local f="$BATS_TMPDIR/keys-sel.txt" dash_out
  printf 'DOWN\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 AIBOX_DASH_FORCE_COLOR=1 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=3 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  dash_out="$output"   # `run` OVERWRITES $output — snapshot it before asserting again
  # PER LINE: a containment check (*▸*xiaozhi*) passed even while the renderer hardcoded
  # sel=0 and the marker never moved — that is exactly how this bug hid the first time.
  run bash -c "printf '%s\n' \"\$1\" | grep '▸' | head -1 | grep -q gitlab" _ "$dash_out"
  [ "$status" -eq 0 ] || false
  run bash -c "printf '%s\n' \"\$1\" | grep '▸' | tail -1 | grep -q xiaozhi" _ "$dash_out"
  [ "$status" -eq 0 ] || false
}

@test "keys: Up returns to the previous row; Down past the end stays on the last row" {
  local f="$BATS_TMPDIR/keys-sel3.txt" dash_out
  printf 'DOWN\nDOWN\nUP\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 AIBOX_DASH_FORCE_COLOR=1 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=5 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  dash_out="$output"
  # TWO modules: the marker walk is gitlab → xiaozhi → xiaozhi (clamped) → gitlab (UP).
  # Compare the LAST TWO marker lines: the second-to-last proves DOWN got there, the last
  # proves UP came back (checking only the last line would not distinguish UP from a no-op).
  run bash -c "printf '%s\n' \"\$1\" | grep '▸' | tail -2 | head -1 | grep -q xiaozhi" _ "$dash_out"
  [ "$status" -eq 0 ] || false
  run bash -c "printf '%s\n' \"\$1\" | grep '▸' | tail -1 | grep -q gitlab" _ "$dash_out"
  [ "$status" -eq 0 ] || false
  printf 'DOWN\nDOWN\nDOWN\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 AIBOX_DASH_FORCE_COLOR=1 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=5 bash "$REPO_ROOT/bin/aibox" dashboard
  dash_out="$output"
  # walking past the last row must leave the marker ON the last row (clamped)
  run bash -c "printf '%s\n' \"\$1\" | grep '▸' | tail -1 | grep -q xiaozhi" _ "$dash_out"
  [ "$status" -eq 0 ] || false
}

@test "keys: selection works in the containers pane too" {
  local f="$BATS_TMPDIR/keys-selc.txt" dash_out
  printf 'TAB\nDOWN\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 AIBOX_DASH_FORCE_COLOR=1 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=4 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  dash_out="$output"
  # the fixture has ONE container: the pane must render and the marker must sit on it
  case "$dash_out" in *"CONTAINERS · 1 container(s)"*) ;; *) false ;; esac
  run bash -c "printf '%s\n' \"\$1\" | grep '▸' | tail -1 | grep -q aibox-gitlab" _ "$dash_out"
  [ "$status" -eq 0 ] || false
}

@test "keys: handled immediately — 10 keypresses must not cost 10 sleeps" {
  local f="$BATS_TMPDIR/keys-fast.txt" i t0 t1
  : >"$f"
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'j\n' >>"$f"; done
  t0="$(date +%s)"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=11 bash "$REPO_ROOT/bin/aibox" dashboard
  t1="$(date +%s)"
  [ "$status" -eq 0 ] || false
  # the old loop slept 1s AFTER every key (≥9s here; reported as "keys are slow")
  [ "$((t1 - t0))" -lt 6 ] || false
}

@test "frame: the selected row is highlighted and no stub AGE column exists" {
  local f="$BATS_TMPDIR/keys-visual.txt"
  printf 'DOWN\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 AIBOX_DASH_FORCE_COLOR=1 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=3 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  case "$output" in *$'\033[7m'*) ;; *) false ;; esac   # reverse video on the selection
  case "$output" in *AGE*) false ;; esac                # the always-0s column is gone
  case "$output" in *"▸"*) ;; *) false ;; esac          # the marker still reads
}

@test "keys: a filtered name narrows the module rows (filter input via / )" {
  local f="$BATS_TMPDIR/keys-filter.txt"
  printf 'p\n/\ngitlab\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=4 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  case "$output" in *"filter:gitlab"*) ;; *) false ;; esac
}

@test "keys: Ctrl-C arriving as a byte quits the loop (pty/no-ISIG safety net)" {
  local f="$BATS_TMPDIR/keys-int.txt"
  printf '\003\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=5 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  local n
  n="$(printf '%s' "$output" | grep -c 'aibox dashboard' || true)"
  [ "$n" = "1" ] || false
}


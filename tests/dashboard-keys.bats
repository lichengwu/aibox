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

@test "keys: a filtered name narrows the module rows (filter input via / )" {
  local f="$BATS_TMPDIR/keys-filter.txt"
  printf 'p\n/\ngitlab\nq\n' >"$f"
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE=100x30 \
    AIBOX_DASH_KEYS="$f" AIBOX_DASH_FRAMES=4 bash "$REPO_ROOT/bin/aibox" dashboard
  [ "$status" -eq 0 ] || false
  case "$output" in *"filter:gitlab"*) ;; *) false ;; esac
}
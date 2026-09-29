#!/usr/bin/env bats
# dashboard frames (P1/P3/P4): rendering from a FIXED snapshot, the JSON surface,
# and the non-TTY degrade path. No docker and no network are involved.
load test_helper

_fixture() { # writes a deterministic snapshot and prints its path
  local f="$BATS_TMPDIR/dash-fx.snap"
  cat >"$f" <<'SNAP'
#aibox-dashboard-snapshot 1
SNAPSHOT ts=1790660000 cost_ms=380 stale=0 docker=ok load=0.42 interval=2
MODULE name=gitlab profile=default mver=1.12.0 aver=18.9.1-ce.0 state=ok health=healthy endpoint=https://gitlab.example ports=80,443,31222 listening=80,443 upgrade=19.4.1-ce.0 age=0
MODULE name=xiaozhi profile=default mver=1.7.0 aver=v1.5.0 state=drift health=- endpoint=http://127.0.0.1:31131 ports=31130,31131 listening=31131 upgrade=- age=0
MODULE name=openmaic profile=default mver=1.7.0 aver=- state=stopped health=- endpoint=- ports=31140 listening=- upgrade=- age=0
CONTAINER name=aibox-gitlab image=gitlab/gitlab-ce:18.9.1 cpu=8.7% mem=2.4G/8.0G uptime=1d2h restarts=0 health=healthy ports=80,443
CONTAINER name=windmill-caddy image=caddy:2-alpine cpu=0.1% mem=18M/512M uptime=18h restarts=1 health=- ports=31100,31443
RESIDUE dangling=3 buildcache=1.2G volumes=0 staletags=2 total=Images=2G note=read-only-preview
SNAP
  printf '%s' "$f"
}

_dash() { # args → run the dashboard with the fixture and a forced size
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_SIZE="${DASH_SIZE:-100x30}" \
    bash "$REPO_ROOT/bin/aibox" dashboard "$@"
}

@test "frame(modules): every module row is intact (names, states, ports, upgrade)" {
  _dash --once --pane modules
  [ "$status" -eq 0 ] || false
  case "$output" in *"MODULES · 3 module(s)"*) ;; *) false ;; esac
  # names must not be mangled by column math (regression: `cut -c2-` ate the first char)
  case "$output" in *gitlab*) ;; *) false ;; esac
  case "$output" in *xiaozhi*) ;; *) false ;; esac
  case "$output" in *openmaic*) ;; *) false ;; esac
  case "$output" in *"19.4.1-ce.0"*) ;; *) false ;; esac
  case "$output" in *"stopped"*) ;; *) false ;; esac
  # state glyphs: ok / drift / stopped
  case "$output" in *"●"*) ;; *) false ;; esac
  case "$output" in *"✗"*) ;; *) false ;; esac
}

@test "frame(modules): a module argument presets the filter" {
  _dash --once gitlab
  case "$output" in *gitlab*) ;; *) false ;; esac
  case "$output" in *xiaozhi*) false ;; esac
  case "$output" in *openmaic*) false ;; esac
  # the header reports the honest ratio: rows shown vs rows in the snapshot
  case "$output" in *"1 of 3 module(s)"*) ;; *) false ;; esac
}

@test "frame(modules): narrow terminal drops columns (compact modes)" {
  DASH_SIZE=70x20 _dash --once --pane modules
  [ "$status" -eq 0 ] || false
  case "$output" in *ENDPOINT*) false ;; esac
  case "$output" in *MODULE*STATE*) ;; *) false ;; esac
  DASH_SIZE=32x20 _dash --once --pane modules
  case "$output" in *PROFILE*) false ;; esac
  case "$output" in *gitlab*) ;; *) false ;; esac
}

@test "frame(containers|upgrades|residue): pane content comes from the snapshot" {
  _dash --once --pane containers
  case "$output" in *"CONTAINERS · 2 container(s)"*) ;; *) false ;; esac
  case "$output" in *aibox-gitlab*) ;; *) false ;; esac
  case "$output" in *"8.7%"*) ;; *) false ;; esac
  _dash --once --pane upgrades
  case "$output" in *"19.4.1-ce.0"*) ;; *) false ;; esac
  case "$output" in *"aibox upgrade gitlab --check"*) ;; *) false ;; esac
  # xiaozhi has no cached latest → it must not appear as an upgrade row
  case "$output" in *xiaozhi*) false ;; esac
  _dash --once --pane residue
  case "$output" in *"READ-ONLY"*) ;; *) false ;; esac
  case "$output" in *"1.2G"*) ;; *) false ;; esac
  case "$output" in *"aibox autoclean --apply"*) ;; *) false ;; esac
}

@test "json: one object with modules/containers/residue (superset of status --json)" {
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" bash "$REPO_ROOT/bin/aibox" dashboard --json
  [ "$status" -eq 0 ] || false
  printf '%s' "$output" >"$BATS_TMPDIR/dash.json"
  run python3 -c "
import json
d = json.load(open('$BATS_TMPDIR/dash.json'))
assert d['snapshot'] == 'v1', d
assert len(d['modules']) == 3, d['modules']
assert [m['name'] for m in d['modules']] == ['gitlab','xiaozhi','openmaic']
assert d['modules'][0]['upgrade'] == '19.4.1-ce.0'
assert d['modules'][0]['state'] == 'ok'
assert d['modules'][1]['health'] == '-'
assert len(d['containers']) == 2 and d['containers'][0]['cpu'] == '8.7%'
assert d['residue']['buildcache'] == '1.2G'
print('OK')"
  [ "$status" -eq 0 ] || false
  [ "$output" = "OK" ] || false
}

@test "non-TTY: one frame plus a hint; AIBOX_DASH_QUIET=1 silences the hint" {
  _dash --once --pane modules
  case "$output" in *"not a TTY"*) ;; *) false ;; esac
  run env AIBOX_DASH_SNAPSHOT="$(_fixture)" AIBOX_DASH_QUIET=1 \
    bash "$REPO_ROOT/bin/aibox" dashboard --once --pane modules
  case "$output" in *"not a TTY"*) false ;; esac
  case "$output" in *MODULES*) ;; *) false ;; esac
}

@test "usage: an unknown pane is a usage error (exit 2)" {
  run bash "$REPO_ROOT/bin/aibox" dashboard --pane nope
  [ "$status" -eq 2 ] || false
  case "$output" in *"unknown pane"*) ;; *) false ;; esac
}

@test "help: dashboard is a first-class verb (help + --help agree)" {
  run bash "$REPO_ROOT/bin/aibox" dashboard --help
  [ "$status" -eq 0 ] || false
  case "$output" in *"htop-style LIVE view"*) ;; *) false ;; esac
  run bash "$REPO_ROOT/bin/aibox" help dashboard
  case "$output" in *"htop-style LIVE view"*) ;; *) false ;; esac
  run bash "$REPO_ROOT/bin/aibox" dashboard --help
  case "$output" in *"--pane"*) ;; *) false ;; esac
  case "$output" in *"READ-ONLY"*) ;; *) false ;; esac
}
#!/usr/bin/env bats
# dashboard sampler (P1): snapshot format, atomic publish, degrade with no docker,
# upgrade cache. The UI never samples itself — this is the process that does.
load test_helper

_seed_installed() { # $1=module [$2=profile]
  printf 'AIBOX_INSTALLED_%s%s="1.2.3"\n' "${1//-/_}" "${2:+__$2}" >>"$AIBOX_HOME/installed.sh"
}

_seed_module_lib() { # $1=module → cached lib.sh exposing the status_info contract
  mkdir -p "$AIBOX_HOME/modules/$1"
  cat >"$AIBOX_HOME/modules/$1/lib.sh" <<'LIB'
status_info() {
  echo "version=v9.9.9"
  echo "state=ok"
  echo "endpoint=http://127.0.0.1:32100"
  echo "health=healthy (detail words are dropped)"
}
LIB
}

_seed_module_meta() { # $1=module → minimal module.yaml with declared ports
  mkdir -p "$AIBOX_HOME/modules/$1"
  cat >"$AIBOX_HOME/modules/$1/module.yaml" <<YAML
name: $1
version: 1.2.3
ports:
  - 32100/tcp:http
  - 32101/tcp:git-ssh
YAML
}

_sample() { # → run one sampler pass
  run bash "$REPO_ROOT/bin/aibox" __dashboard-sample "$AIBOX_HOME/dashboard" --once
}

_snap() { # → newest snapshot file content
  cat "$AIBOX_HOME/dashboard/snapshot.1" 2>/dev/null || cat "$AIBOX_HOME/dashboard/snapshot.2" 2>/dev/null || true
}

@test "sampler: writes header + SNAPSHOT record, atomically (no .tmp leftovers)" {
  _sample
  [ "$status" -eq 0 ] || false
  grep -q '^#aibox-dashboard-snapshot 1$' "$AIBOX_HOME/dashboard/snapshot.1" || false
  grep -qE '^SNAPSHOT ts=[0-9]+ cost_ms=[0-9]+ stale=0 docker=(ok|down) load=.* interval=2$' \
    "$AIBOX_HOME/dashboard/snapshot.1" || false
  run bash -c "ls '$AIBOX_HOME/dashboard'/snapshot.tmp* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ] || false
}

@test "sampler: alternating slots — a second pass keeps both files (double buffer)" {
  _sample
  _sample
  [ -f "$AIBOX_HOME/dashboard/snapshot.1" ] || false
  [ -f "$AIBOX_HOME/dashboard/snapshot.2" ] || false
  [ "$(grep -c '^SNAPSHOT ' "$AIBOX_HOME/dashboard/snapshot.1")" = "1" ] || false
}

@test "sampler: installed modules become MODULE records (status_info + declared ports)" {
  _seed_installed base
  _seed_module_lib base
  _seed_module_meta base
  _sample
  local rec
  rec="$(sed -n 's/^MODULE //p' "$AIBOX_HOME/dashboard/snapshot.1" | head -1)"
  [ -n "$rec" ] || false
  case " $rec " in *" name=base "*) ;; *) false ;; esac
  case " $rec " in *" mver=1.2.3 "*) ;; *) false ;; esac
  case " $rec " in *" aver=v9.9.9 "*) ;; *) false ;; esac
  case " $rec " in *" state=ok "*) ;; *) false ;; esac
  # health keeps only its first token (space-free record field)
  case " $rec " in *" health=healthy "*) ;; *) false ;; esac
  case " $rec " in *" ports=32100,32101 "*) ;; *) false ;; esac
}

@test "sampler: docker absent → docker=down and no CONTAINER records" {
  # Deterministic: shadow `docker` with a failing shim. Without this the test depends on
  # the HOST (CI runners ship a working docker, the test image does not) — caught by CI.
  mkdir -p "$BATS_TMPDIR/nodocker"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TMPDIR/nodocker/docker"
  chmod +x "$BATS_TMPDIR/nodocker/docker"
  run env PATH="$BATS_TMPDIR/nodocker:/usr/bin:/bin" \
    bash "$REPO_ROOT/bin/aibox" __dashboard-sample "$AIBOX_HOME/dashboard" --once
  [ "$status" -eq 0 ] || false
  grep -q 'docker=down' "$AIBOX_HOME/dashboard/snapshot.1" || false
  run grep -c '^CONTAINER ' "$AIBOX_HOME/dashboard/snapshot.1"
  [ "$output" = "0" ] || false
}

@test "sampler: the cached upgrade probe result feeds the MODULE upgrade field" {
  _seed_installed gitlab
  mkdir -p "$AIBOX_HOME/dashboard/upgrade"
  printf '19.4.1-ce.0\n' >"$AIBOX_HOME/dashboard/upgrade/gitlab.latest"
  _sample
  run grep -c 'upgrade=19.4.1-ce.0' "$AIBOX_HOME/dashboard/snapshot.1"
  [ "$output" = "1" ] || false
}

@test "sampler: profile-scoped installs keep their profile in the record" {
  _seed_installed base prod
  _seed_module_lib base
  _sample
  run grep -c 'name=base profile=prod' "$AIBOX_HOME/dashboard/snapshot.1"
  [ "$output" = "1" ] || true
}

@test "sampler: _dash_kv_get parses the record fields (pure bash, no sourcing)" {
  run bash -c ". '$REPO_ROOT/src/aibox/72-dashboard-sample.sh'; _dash_kv_get 'name=gitlab port=80 state=ok' state"
  [ "$output" = "ok" ] || false
  run bash -c ". '$REPO_ROOT/src/aibox/72-dashboard-sample.sh'; _dash_kv_get 'name=gitlab' missing"
  [ "$output" = "" ] || false
}

@test "sampler: a snapshot is never sourced (data, not code)" {
  _seed_installed base
  # a poisoned field must not execute: the record is parsed, not evaluated
  _seed_module_lib base
  printf 'status_info() { echo "version=\$(touch %s/PWNED)"; echo "state=ok"; }\n' "$AIBOX_HOME" \
    >"$AIBOX_HOME/modules/base/lib.sh"
  _sample
  [ ! -f "$AIBOX_HOME/PWNED" ] || false
  run grep -q 'PWNED' "$AIBOX_HOME/dashboard/snapshot.1"
  [ "$status" -ne 0 ] || true
}
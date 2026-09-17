#!/usr/bin/env bats
# Integration: pi-web multi-profile E2E. FLAG-GATED (AIBOX_IT_PIWEB=1) because it
# registers real services in the user's service manager (launchd/systemd --user) and
# npm-installs @agegr/pi-web globally. Run on a throwaway host (distilled from the
# live 2026-09 test on root@192.168.50.88: prod port 37173 + pi-web-prod.service,
# both profiles simultaneously, per-profile uninstall leaving the other running).
#
# Uses unique test profiles (itp1/itp2) so it never collides with a real pi-web.

setup_file() {
  [ -n "${AIBOX_IT_PIWEB:-}" ] || skip "set AIBOX_IT_PIWEB=1 to run (real service-manager side effects)"
  command -v node >/dev/null 2>&1 || skip "node not installed"
  node -e 'process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)' || skip "node >= 22 required"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  SANDBOX="$(mktemp -d 2>/dev/null || echo /tmp/aibox-it-piweb.$$)"
  export SANDBOX
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR"

  # Derive expected ports/labels via the real lib (tail -1: skip the "Created profile" log line).
  AIBOX_PROFILE=itp1 bash -c "source '$REPO_ROOT/tools/pi-web/lib.sh'; echo \$PORT \$LABEL" | tail -1 > "$SANDBOX/p1"
  AIBOX_PROFILE=itp2 bash -c "source '$REPO_ROOT/tools/pi-web/lib.sh'; echo \$PORT \$LABEL" | tail -1 > "$SANDBOX/p2"
  read -r PORT1 LABEL1 < "$SANDBOX/p1"
  read -r PORT2 LABEL2 < "$SANDBOX/p2"
  [ "$PORT1" != "$PORT2" ] || skip "test profile port collision (itp1/itp2)"
  for p in "$PORT1" "$PORT2"; do
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      skip "port $p occupied"
    fi
  done

  bash "$REPO_ROOT/bin/aibox" --profile itp1 install pi-web > "$SANDBOX/i1.log" 2>&1 || { cat "$SANDBOX/i1.log"; return 1; }
  bash "$REPO_ROOT/bin/aibox" --profile itp2 install pi-web > "$SANDBOX/i2.log" 2>&1 || { cat "$SANDBOX/i2.log"; return 1; }
}

teardown_file() {
  [ -n "${SANDBOX:-}" ] || return 0
  bash "$REPO_ROOT/bin/aibox" --profile itp1 uninstall pi-web >/dev/null 2>&1 || true
  bash "$REPO_ROOT/bin/aibox" --profile itp2 uninstall pi-web >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}

@test "both profiles serve simultaneously on their derived ports" {
  read -r PORT1 LABEL1 < "$SANDBOX/p1"
  read -r PORT2 LABEL2 < "$SANDBOX/p2"
  code1="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT1/" || echo 000)"
  code2="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/" || echo 000)"
  [ "$code1" != "000" ]
  [ "$code2" != "000" ]
  # distinct service identities
  [ "$LABEL1" = "pi-web-itp1" ]
  [ "$LABEL2" = "pi-web-itp2" ]
}

@test "status shows the password actually written to the service unit (reuse regression)" {
  read -r PORT1 LABEL1 < "$SANDBOX/p1"
  run bash "$REPO_ROOT/bin/aibox" --profile itp1 pi-web status
  [ "$status" -eq 0 ]
  shown="$(printf '%s\n' "$output" | grep -oE 'pi/[0-9a-f]+' | head -1 | cut -d/ -f2)"
  [ -n "$shown" ]
  if [ "$(uname -s)" = "Darwin" ]; then
    unit_pw="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PI_WEB_PASSWORD' "$HOME/Library/LaunchAgents/${LABEL1}.plist" 2>/dev/null)"
  else
    unit_pw="$(grep -E '^Environment="PI_WEB_PASSWORD=' "$HOME/.config/systemd/user/${LABEL1}.service" | sed -E 's/.*PI_WEB_PASSWORD=([^"]*)".*/\1/')"
  fi
  [ "$shown" = "$unit_pw" ]
  # calling status twice must NOT rotate the password (the live-machine regression)
  run bash "$REPO_ROOT/bin/aibox" --profile itp1 pi-web status
  shown2="$(printf '%s\n' "$output" | grep -oE 'pi/[0-9a-f]+' | head -1 | cut -d/ -f2)"
  [ "$shown" = "$shown2" ]
}

@test "per-profile uninstall: itp1 goes, itp2 keeps running (live bug #3 scenario)" {
  read -r PORT2 LABEL2 < "$SANDBOX/p2"
  run bash "$REPO_ROOT/bin/aibox" --profile itp1 uninstall pi-web
  [ "$status" -eq 0 ]
  # itp2 still serves
  sleep 1
  code2="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT2/" || echo 000)"
  [ "$code2" != "000" ]
  # itp2 still known to aibox; shared script cache retained
  run bash "$REPO_ROOT/bin/aibox" --profile itp2 list
  [[ "$output" == *"pi-web"* ]]
  [ -f "$AIBOX_HOME/modules/pi-web/lib.sh" ]
  # re-install itp1 for a clean teardown pass
  bash "$REPO_ROOT/bin/aibox" --profile itp1 install pi-web >/dev/null 2>&1 || true
}

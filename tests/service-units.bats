#!/usr/bin/env bats
# Platform service units: the SHAPES (launchd plist keys, systemd section order,
# Environment= quoting) live in ONE place (tools/_shared/lib/70-service.sh); the
# modules supply their content. Two modules generating units used to mean two
# copies of that knowledge.

load test_helper

@test "launchd plist: keys, program args, env, logging — from the shared renderer" {
  run bash -c "
    source '$AIBOX_BIN'
    ENV_PAIRS='PATH=/n:/usr/bin HOME=/h PORT=5050 PI_WEB_NO_OPEN=1' \
      svc_render_launchd_plist pi-web-1 /h /h/logs pi-web 10 1 1 /n/node /n/pi-web --hostname 127.0.0.1 --port 5050
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'<key>Label</key><string>pi-web-1</string>'* ]] || false
  [[ "$output" == *'<string>/n/node</string>'* ]] || false
  [[ "$output" == *'<string>--hostname</string>'* ]] || false
  [[ "$output" == *'<key>KeepAlive</key><true/>'* ]] || false
  [[ "$output" == *'<key>ThrottleInterval</key><integer>10</integer>'* ]] || false
  [[ "$output" == *'<key>StandardOutPath</key><string>/h/logs/pi-web.log</string>'* ]] || false
  [[ "$output" == *'<key>PI_WEB_NO_OPEN</key><string>1</string>'* ]] || false
  [[ "$output" == *'</plist>'* ]] || false
}

@test "systemd user unit: sections, env quoting, restart, default.target" {
  run bash -c "
    source '$AIBOX_BIN'
    ENV_PAIRS='PATH=/n:/usr/bin HOME=/h PORT=5050' \
      svc_render_systemd_unit user 'demo unit' /n/node /h /h/logs demo simple 10 '' 'After=network-online.target' '' /n/app --port 5050
  "
  [[ "$output" == *$'[Unit]\nDescription=demo unit\nAfter=network-online.target'* ]] || { echo "$output"; false; }
  [[ "$output" == *'Type=simple'* ]] || false
  [[ "$output" == *'Environment="PORT=5050"'* ]] || false
  [[ "$output" == *'ExecStart=/n/node /n/app --port 5050'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'Restart=always\nRestartSec=10'* ]] || false
  [[ "$output" == *'WantedBy=default.target'* ]] || false
  [[ "$output" != *'User=root'* ]] || false
}

@test "systemd system unit: User=root + multi-user.target + extra service lines" {
  run bash -c "
    source '$AIBOX_BIN'
    ENV_PAIRS='WM_DIR=/opt/wm' \
      svc_render_systemd_unit system 'stack alignment' /usr/local/bin/windmill /opt/wm '' '' oneshot '' 'RemainAfterExit=yes
TimeoutStartSec=900' 'Requires=docker.service' '' --quiet up
  "
  [[ "$output" == *'User=root'* ]] || { echo "$output"; false; }
  [[ "$output" == *'Requires=docker.service'* ]] || false
  [[ "$output" == *'RemainAfterExit=yes'* ]] || false
  [[ "$output" == *'WantedBy=multi-user.target'* ]] || false
  [[ "$output" == *'ExecStart=/usr/local/bin/windmill --quiet up'* ]] || false
  [[ "$output" != *'StandardOutput'* ]] || false   # no logging when log dir is empty
}

@test "pi-web generates both units through the shared renderer (no inline templates)" {
  local lib="$REPO_ROOT/tools/pi-web/lib.sh"
  grep -q 'svc_render_launchd_plist' "$lib" || { echo "plist renderer not used"; false; }
  grep -q 'svc_render_systemd_unit' "$lib" || { echo "unit renderer not used"; false; }
  ! grep -q '<?xml version' "$lib" || { echo "inline plist template is back"; false; }
  ! grep -q '^\[Unit\]' "$lib" || { echo "inline unit template is back"; false; }
}

@test "the renderers exist once (shared library, injected into the manager)" {
  [ "$(grep -c '^svc_render_launchd_plist()' "$AIBOX_BIN")" = "1" ] || false
  [ "$(grep -c '^svc_render_systemd_unit()' "$AIBOX_BIN")" = "1" ] || false
  [ "$(grep -rc '^svc_render_launchd_plist()' "$REPO_ROOT"/src/aibox/*.sh | awk -F: '{s+=$2} END{print s+0}')" = "0" ] || false
}

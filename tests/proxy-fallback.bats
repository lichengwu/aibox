#!/usr/bin/env bats
# proxy check/test clash-fallback regression (offline: probes point at dead local
# ports, which fail instantly with ECONNREFUSED).
# Locks bb1b981: with no static proxy but an active clash pool, `proxy check`/`proxy
# test` must probe THROUGH the clash mixed port instead of dying "No proxy configured".

load test_helper

_clash_state_on() {
  mkdir -p "$AIBOX_HOME/apps/clash"
  cat > "$AIBOX_HOME/apps/clash/state" <<'EOF'
SUB_URL="https://example.invalid/sub"
CLASH_SECRET="testsecret"
CLASH_ENABLED="1"
CLASH_PORT="7890"
CLASH_API_PORT="9090"
LAST_REFRESH="0"
KERNEL_TAG=""
EOF
}

@test "proxy check: falls back to the clash pool when no static proxy" {
  _clash_state_on
  AIBOX_PROXY_URL=""
  AIBOX_PROBE_SITES='dead|http://127.0.0.1:9/x|g'
  PROBE_TIMEOUT=1
  TUI_TTY=0
  run cmd_proxy_check
  # probes fail (nothing on :7890) but the URL resolution must have picked clash
  [[ "$output" == *"socks5://127.0.0.1:7890"* ]]
  [[ "$output" != *"No proxy configured"* ]]
}

@test "proxy test: falls back to the clash pool when no static proxy" {
  _clash_state_on
  AIBOX_PROXY_URL=""
  PROBE_TARGET="http://127.0.0.1:9/x"   # dead local target: offline-safe, fails fast
  run cmd_proxy_test
  [[ "$output" == *"socks5://127.0.0.1:7890"* ]]
  [[ "$output" != *"No proxy configured"* ]]
}

@test "proxy check: explicit static proxy takes precedence over clash" {
  _clash_state_on
  AIBOX_PROXY_URL="http://127.0.0.1:2"
  AIBOX_PROBE_SITES='dead|http://127.0.0.1:9/x|g'
  PROBE_TIMEOUT=1
  TUI_TTY=0
  run cmd_proxy_check
  [[ "$output" == *"127.0.0.1:2"* ]]
  [[ "$output" != *"socks5://127.0.0.1:7890"* ]]
}

@test "proxy check: no static proxy + no clash → clear usage error (no silent pass)" {
  AIBOX_PROXY_URL=""
  rm -f "$AIBOX_HOME/apps/clash/state" 2>/dev/null || true
  run cmd_proxy_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proxy configured"* ]]
}

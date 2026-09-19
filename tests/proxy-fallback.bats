#!/usr/bin/env bats
# proxy check/test clash-fallback regression (offline: probes point at dead local
# ports, which fail instantly with ECONNREFUSED).
# Locks bb1b981: with no static proxy but an active clash pool, `proxy check`/`proxy
# test` must probe THROUGH the clash mixed port instead of dying "No proxy configured".
# NOTE: clash_active PROBES the port (the stale-clash fix) — the simulation starts
# a REAL TCP listener on 7890 (a configured-but-dead port is NOT "active").

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
  # live mixed-port listener (self-exits after 120s; killed in teardown)
  if [ ! -f "$AIBOX_HOME/apps/clash/.tcp.pid" ]; then
    python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 7890)); s.listen(4); time.sleep(120)" 2>/dev/null &
    echo $! >"$AIBOX_HOME/apps/clash/.tcp.pid"
    # wait for the bind (python startup race — the port probe must see it live)
    local i=0
    while [ "${i}" -lt 50 ]; do
      if (exec 3<>"/dev/tcp/127.0.0.1/7890") 2>/dev/null; then break; fi
      sleep 0.1
      i=$((i + 1))
    done
  fi
}

teardown() {
  if [ -f "${AIBOX_HOME:-}/apps/clash/.tcp.pid" ]; then
    kill "$(cat "${AIBOX_HOME}/apps/clash/.tcp.pid")" 2>/dev/null || true
    rm -f "${AIBOX_HOME}/apps/clash/.tcp.pid"
  fi
  [ -n "${SANDBOX:-}" ] && rm -rf "${SANDBOX}" 2>/dev/null || true
}

@test "proxy check: falls back to the clash pool when no static proxy" {
  _clash_state_on
  AIBOX_PROXY_URL=""
  AIBOX_PROBE_SITES='dead|http://127.0.0.1:9/x|g'
  PROBE_TIMEOUT=1
  TUI_TTY=0
  run cmd_proxy_check
  # probes fail (nothing answers on :7890) but the URL resolution must have picked clash
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

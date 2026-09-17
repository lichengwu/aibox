#!/usr/bin/env bats
# Regression tests for config (save_config / load_config).
# save_config once had backticks `aibox proxy` in an unquoted heredoc comment, which
# EXECUTED `aibox proxy` and embedded its show-output into the config file, corrupting
# it. These tests guard against that class of bug.

load test_helper

@test "save_config: writes a parseable config (no embedded command output)" {
  AIBOX_PROXY_URL="http://10.0.0.2:7897"
  AIBOX_PROXY_ENABLED="1"
  save_config
  [ -f "$AIBOX_CONFIG" ]
  # Sourcing must succeed cleanly under set -u (no "command not found" from leaked output).
  bash -c "set -u; . '$AIBOX_CONFIG'" 2>/tmp/sc.err
  rc=$?
  [ "$rc" -eq 0 ]
  [ ! -s /tmp/sc.err ] || { echo "unexpected stderr:"; cat /tmp/sc.err; false; }
  rm -f /tmp/sc.err
}

@test "save_config: values round-trip through load_config" {
  AIBOX_PROXY_URL="socks5://127.0.0.1:1080"
  AIBOX_PROXY_ENABLED="1"
  save_config
  # Reset and reload.
  AIBOX_PROXY_URL=""
  AIBOX_PROXY_ENABLED=""
  load_config
  [ "$AIBOX_PROXY_URL" = "socks5://127.0.0.1:1080" ]
  [ "$AIBOX_PROXY_ENABLED" = "1" ]
}

@test "save_config: no proxy-show output leaked into the file" {
  AIBOX_PROXY_URL="http://127.0.0.1:7897"
  AIBOX_PROXY_ENABLED="1"
  save_config
  # The old bug embedded `aibox proxy show` lines (e.g. a line starting with "Proxy ").
  ! grep -Eq '^ +(Proxy|State|No-proxy|Effective) ' "$AIBOX_CONFIG"
  # And the config must be mode 600.
  [ "$(stat -c %a "$AIBOX_CONFIG" 2>/dev/null || stat -f %Lp "$AIBOX_CONFIG")" = "600" ]
}

@test "load_config: missing config is a no-op (no error)" {
  rm -f "$AIBOX_CONFIG"
  load_config
  [ -z "$AIBOX_PROXY_URL" ]
}

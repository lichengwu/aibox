#!/usr/bin/env bats
# Tests for the proxy helpers in bin/aibox: normalize_proxy_url, mask_url, probe_grade_of.

load test_helper

@test "normalize_proxy_url: empty stays empty" {
  [ "$(normalize_proxy_url "")" = "" ]
}

@test "normalize_proxy_url: bare host:port gets http:// prefix" {
  [ "$(normalize_proxy_url "10.0.0.2:7897")" = "http://10.0.0.2:7897" ]
}

@test "normalize_proxy_url: explicit scheme is preserved" {
  [ "$(normalize_proxy_url "http://10.0.0.2:7897")" = "http://10.0.0.2:7897" ]
  [ "$(normalize_proxy_url "socks5://127.0.0.1:7890")" = "socks5://127.0.0.1:7890" ]
  [ "$(normalize_proxy_url "https://proxy.example:3128")" = "https://proxy.example:3128" ]
}

@test "mask_url: redacts credentials from a user:pass@ URL" {
  result="$(mask_url "http://user:secret@10.0.0.2:7897")"
  echo "got: $result" >&2
  [[ "$result" == "http://user:***@10.0.0.2:7897" ]]
}

@test "mask_url: leaves a credential-free URL untouched" {
  result="$(mask_url "http://10.0.0.2:7897")"
  [[ "$result" == "http://10.0.0.2:7897" ]]
}

@test "mask_url: handles socks5 with credentials" {
  result="$(mask_url "socks5://u:p@127.0.0.1:1080")"
  [[ "$result" == "socks5://u:***@127.0.0.1:1080" ]]
}

@test "probe_grade_of: 200 -> ok" {
  [ "$(probe_grade_of 200)" = "ok" ]
}

@test "probe_grade_of: 000/empty -> fail" {
  [ "$(probe_grade_of 000)" = "fail" ]
  [ "$(probe_grade_of "")" = "fail" ]
}

@test "probe_grade_of: 5xx -> warn" {
  [ "$(probe_grade_of 500)" = "warn" ]
  [ "$(probe_grade_of 503)" = "warn" ]
}

@test "probe_grade_of: 401/404/405 -> ok (peer answered)" {
  [ "$(probe_grade_of 401)" = "ok" ]
  [ "$(probe_grade_of 404)" = "ok" ]
  [ "$(probe_grade_of 405)" = "ok" ]
}

@test "probe_fmt_time: falls back to 0.00 on garbage" {
  [ "$(probe_fmt_time "")" = "0.00" ]
  [ "$(probe_fmt_time "abc")" = "0.00" ]
}

@test "probe_fmt_time: formats a number to 2 decimals" {
  [ "$(probe_fmt_time "0.6543")" = "0.65" ]
}

# proxy_probe touches the network, so we only test its failure/edge contract:
# a bogus proxy must return non-zero and set PROBE_CONFIRMED=0 (no false positive).
# Called directly (not via `run`) so PROBE_CONFIRMED propagates to the test shell.
@test "proxy_probe: unreachable proxy returns non-zero, PROBE_CONFIRMED=0" {
  if proxy_probe "http://127.0.0.1:1" "https://example.com"; then
    fail "expected proxy_probe to fail for an unreachable proxy"
  fi
  [ "$PROBE_CONFIRMED" = "0" ]
}

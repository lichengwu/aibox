#!/usr/bin/env bats
# Machine-readable output (`--json`): a manager whose consumers are scripts,
# timers and CI must answer with JSON, not with prose to be scraped.
# Shape contract: status = {aibox_version, profile, modules[]}; check =
# {module, ok, exit, details[]}. stdout carries JSON ONLY; exit codes unchanged.

load test_helper

# Bytes-first decoding: CI macOS runs bats with a non-UTF-8 locale and the
# preflight details carry ·/… — `json.load(sys.stdin)` would decode as ASCII and
# fail on valid UTF-8 JSON (measured on the macOS lint job).
_json_valid() { # stdin → "ok" when it parses, "" otherwise (stderr is NOT the verdict)
  # 2>/dev/null matters: with 2>&1 a python warning on stderr would replace the
  # "ok" answer (measured on the macOS runner) and turn a valid payload into a
  # failure. Diagnostics live in _json_error.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.loads(sys.stdin.buffer.read().decode("utf-8")); print("ok")' 2>/dev/null | tail -1
  else
    printf 'ok'
  fi
}

_json_error() { # stdin → why it did not parse
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import json,sys
raw = sys.stdin.buffer.read()
try:
    json.loads(raw.decode("utf-8")); print("valid")
except Exception as e:
    print("ERR:", e)
    i = getattr(e, "pos", 0)
    print("near:", raw[max(0, i - 60):i + 60])' 2>&1 | tail -3
}
_json_field() { # $1=json $2=python expression over d
  command -v python3 >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$1" | python3 -c "import json,sys; d=json.loads(sys.stdin.buffer.read().decode('utf-8')); print($2)" 2>/dev/null || true
}

@test "status --json: valid JSON, documented keys, no ANSI escapes" {
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$AIBOX_BIN'; cmd_status_json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(_json_valid <<<"$output")" = "ok" ] || { printf '%s\n' "$output" | _json_error; false; }
  [ "$(_json_field "$output" 'sorted(d.keys())')" = "['aibox_version', 'modules', 'profile']" ] || { echo "$output" | head -3; false; }
  [ "$(_json_field "$output" 'd["profile"]')" = "base" ] || false
  ! printf '%s' "$output" | grep -q $'\033' || false
}

@test "status --json: one object per installed module with the full field set" {
  mkdir -p "$AIBOX_MOD_DIR/new-api"
  cp "$REPO_ROOT/tools/new-api/module.yaml" "$AIBOX_MOD_DIR/new-api/"
  printf 'AIBOX_INSTALLED_new_api="1.3.0"\n' >"$AIBOX_INSTALLED"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$AIBOX_BIN'; cmd_status_json"
  [ "$(_json_valid <<<"$output")" = "ok" ] || { printf '%s\n' "$output" | _json_error; false; }
  [ "$(_json_field "$output" 'len(d["modules"])')" = "1" ] || false
  [ "$(_json_field "$output" 'd["modules"][0]["name"]')" = "new-api" ] || false
  [ "$(_json_field "$output" 'd["modules"][0]["module_version"]')" = "1.3.0" ] || false
  [ "$(_json_field "$output" 'd["modules"][0]["ports"]')" = "['30300/tcp:http']" ] || false
  [ "$(_json_field "$output" 'sorted(d["modules"][0].keys())')" = "['app_version', 'endpoint', 'module_version', 'name', 'ports', 'profile', 'state']" ] || { echo "$output"; false; }
}

@test "status --json: a profile-scoped install reports its profile" {
  printf 'AIBOX_INSTALLED_new_api__prod="1.3.0"\n' >"$AIBOX_INSTALLED"
  mkdir -p "$AIBOX_MOD_DIR/new-api"
  cp "$REPO_ROOT/tools/new-api/module.yaml" "$AIBOX_MOD_DIR/new-api/"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$AIBOX_BIN'; cmd_status_json"
  [ "$(_json_field "$output" 'd["modules"][0]["profile"]')" = "prod" ] || { echo "$output"; false; }
}

@test "status --json: upgrade state is embedded when a state file exists" {
  printf 'AIBOX_INSTALLED_new_api="1.3.0"\n' >"$AIBOX_INSTALLED"
  mkdir -p "$AIBOX_MOD_DIR/new-api" "$AIBOX_HOME/upgrades"
  cp "$REPO_ROOT/tools/new-api/module.yaml" "$AIBOX_MOD_DIR/new-api/"
  printf 'status=ok\nfrom=v0.13.1\nto=v0.13.2\n' >"$AIBOX_HOME/upgrades/new-api.state"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME'; source '$AIBOX_BIN'; cmd_status_json"
  [ "$(_json_field "$output" 'd["modules"][0]["upgrade"]["status"]')" = "ok" ] || { echo "$output"; false; }
  [ "$(_json_field "$output" 'd["modules"][0]["upgrade"]["to"]')" = "v0.13.2" ] || false
}

@test "check --json: envelope with module/ok/exit/details, exit code preserved" {
  mkdir -p "$AIBOX_MOD_DIR/new-api"
  cp "$REPO_ROOT/tools/new-api/module.yaml" "$AIBOX_MOD_DIR/new-api/"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT'; source '$AIBOX_BIN'; cmd_check new-api --json 2>/dev/null"
  [ "$status" -eq 3 ] || [ "$status" -eq 4 ] || { echo "unexpected rc=$status: $output"; false; }
  [ "$(_json_valid <<<"$output")" = "ok" ] || { printf '%s\n' "$output" | _json_error; false; }
  [ "$(_json_field "$output" 'd["module"]')" = "new-api" ] || false
  [ "$(_json_field "$output" 'd["ok"]')" = "False" ] || false
  [ "$(_json_field "$output" 'd["exit"]')" = "$status" ] || { echo "$output"; false; }
  [ "$(_json_field "$output" 'len(d["details"]) > 0')" = "True" ] || false
}

@test "check --json: stdout is JSON only (log lines never leak into it)" {
  mkdir -p "$AIBOX_MOD_DIR/new-api"
  cp "$REPO_ROOT/tools/new-api/module.yaml" "$AIBOX_MOD_DIR/new-api/"
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT'; source '$AIBOX_BIN'; cmd_check new-api --json"
  # the whole capture (stderr merged) must still be parseable — details carry the prose
  [ "$(_json_valid <<<"$output")" = "ok" ] || { echo "$output" | head -8; false; }
}

@test "the JSON helpers escape quotes, backslashes and control characters" {
  run bash -c "source '$AIBOX_BIN'; json_str 'he said \"hi\" \\\\ end
tab	here'"
  [ "$status" -eq 0 ] || false
  [ "$(_json_valid <<<"{\"v\": $output}")" = "ok" ] || { echo "$output"; false; }
  [[ "$output" == *'\"hi\"'* ]] || { echo "$output"; false; }
}

@test "json_arr: comma-separated items, empty list for no items" {
  run bash -c "source '$AIBOX_BIN'; json_arr ports a b"
  [ "$output" = '"ports": ["a", "b"]' ] || { echo "$output"; false; }
  run bash -c "source '$AIBOX_BIN'; json_arr ports"
  [ "$output" = '"ports": []' ] || { echo "$output"; false; }
}

@test "help documents --json for status and check" {
  run bash -c "source '$AIBOX_BIN'; _verb_help status"
  [[ "$output" == *"--json"* ]] || false
  run bash -c "source '$AIBOX_BIN'; _verb_help check"
  [[ "$output" == *"--json"* ]] || false
}

@test "the JSON emitter is the shared library's, not a manager twin" {
  [ "$(grep -c '^json_escape()' "$AIBOX_BIN")" = "1" ] || false
  grep -q '^json_escape()' "$REPO_ROOT/tools/_shared/lib/50-json.sh" || false
  [ "$(grep -rc '^json_escape()' "$REPO_ROOT"/src/aibox/*.sh | awk -F: '{s+=$2} END{print s+0}')" = "0" ] || false
}

@test "json_escape: EVERY control byte is escaped (ESC from brew/apt output)" {
  # live-caught: the macOS preflight auto-install of docker put brew's ANSI colour
  # (ESC) into a detail line → "Invalid control character" → the whole --json
  # envelope stopped parsing. Raw control bytes are illegal inside JSON strings.
  run bash -c "source '$AIBOX_BIN'; printf 'esc:%b bell:%b tab:\\t' '\033[34m' '\007'"
  local payload="$output"
  run bash -c "source '$AIBOX_BIN'; json_str \"\$1\"" _ "$payload"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # no RAW control byte survives
  if printf '%s' "$output" | grep -qP '[\x00-\x1f]' 2>/dev/null; then
    echo "raw control byte left in: $output"; false
  fi
  [[ "$output" == *'\u001b'* ]] || { echo "ESC not escaped: $output"; false; }
  [[ "$output" == *'\u0007'* ]] || { echo "BEL not escaped: $output"; false; }
  [ "$(_json_valid <<<"{\"v\": $output}")" = "ok" ] || { printf '%s' "{\"v\": $output}" | _json_error; false; }
}

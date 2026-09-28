#!/usr/bin/env bats
# Windmill stack knobs (0.16.0) — the config surface beyond the original four keys.
# Live audit found the gaps: domain/HTTPS was unreachable, worker replicas +
# memory limits were hardcoded in the generated compose, and LOG_MAX_*/backup
# retention had no persisted knob. Locks:
#   - conf whitelist accepts the new keys (aibox windmill config set)
#   - rendered compose interpolates the worker/indexer/log knobs
#   - BASE_URL drives the Caddyfile site + the 443 publish (https) + harden
#   - the default entry port is 31100 everywhere (was 80 in code, 31100 in docs)
#   - backup retention reaches the systemd unit (Environment=KEEP)
# Pure render tests: the CLI is sourced with the source guard, no docker.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-wmcfg.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export WM_DIR="$AIBOX_HOME/apps/windmill"
  export WM_CONF_FILE="$SANDBOX/windmill.conf"
  export WM_TEST_HOME="$SANDBOX/home2"
  mkdir -p "$WM_DIR" "$WM_TEST_HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WM_CLI="$REPO_ROOT/tools/windmill/cli/windmill"
  : >"$WM_CONF_FILE"
  # keep any ambient knob out of the tests
  unset BASE_URL LOG_MAX_SIZE LOG_MAX_FILE KEEP HTTP_PORT PROXY_URL 2>/dev/null || true
  unset WM_WORKER_REPLICAS WM_WORKER_MEMORY WM_NATIVE_REPLICAS WM_NATIVE_MEMORY WM_INDEXER_REPLICAS 2>/dev/null || true
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

# Run a snippet with the windmill CLI sourced (source guard keeps it from dispatching).
_wm() { # $1 = shell snippet
  run bash -c "export HOME='$WM_TEST_HOME' AIBOX_HOME='$AIBOX_HOME' WM_DIR='$WM_DIR' WM_CONF_FILE='$WM_CONF_FILE'; source '$WM_CLI'; $1"
}

_conf() { # $1=KEY $2=value
  printf '%s=%s\n' "$1" "$2" >>"$WM_CONF_FILE"
}

# ---------- default entry port: 31100 everywhere ------------------------------

@test "default: entry port is 31100 (code default, no conf, no .env)" {
  _wm 'printf "%s" "$HTTP_PORT"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "31100" ] || { echo "got: $output"; false; }
}

@test "default: the rendered caddy publish uses the 31100 default" {
  _wm 'wm_paths; render_compose'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '"\${HTTP_PORT:-31100}:80"' "$WM_DIR/docker-compose.yml" || { false; }
}

@test "module.yaml: the declared port matches the 31100 default" {
  grep -q '31100/tcp:http' "$REPO_ROOT/tools/windmill/module.yaml" || false
  grep -q 'HTTP_PORT: "31100' "$REPO_ROOT/tools/windmill/module.yaml" || false
}

@test "conf: HTTP_PORT still overrides the default" {
  _conf HTTP_PORT 9080
  _wm 'printf "%s" "$HTTP_PORT"'
  [ "$output" = "9080" ] || { echo "got: $output"; false; }
}

# ---------- new conf keys are accepted + resolved ----------------------------

@test "conf: the new stack knobs are read from windmill.conf" {
  _conf BASE_URL "https://wm.example.com"
  _conf LOG_MAX_SIZE "50m"
  _conf LOG_MAX_FILE "3"
  _conf KEEP "14"
  _conf WM_WORKER_REPLICAS "6"
  _conf WM_WORKER_MEMORY "2048M"
  _conf WM_NATIVE_REPLICAS "2"
  _conf WM_NATIVE_MEMORY "512M"
  _conf WM_INDEXER_REPLICAS "1"
  _wm 'printf "%s|%s|%s|%s|%s|%s|%s|%s|%s" "$BASE_URL" "$LOG_MAX_SIZE" "$LOG_MAX_FILE" "$KEEP" "$WM_WORKER_REPLICAS" "$WM_WORKER_MEMORY" "$WM_NATIVE_REPLICAS" "$WM_NATIVE_MEMORY" "$WM_INDEXER_REPLICAS"'
  [ "$output" = "https://wm.example.com|50m|3|14|6|2048M|2|512M|1" ] || { echo "got: $output"; false; }
}

@test "conf: unknown keys are still ignored (whitelist only)" {
  _conf WM_IMAGE "ghcr.io/evil/x"
  _wm 'printf "%s" "${WM_IMAGE:-unset}"'
  [ "$output" = "unset" ] || { echo "got: $output"; false; }
}

@test "module.yaml declares every new knob (aibox windmill config list)" {
  for k in BASE_URL LOG_MAX_SIZE LOG_MAX_FILE KEEP WM_WORKER_REPLICAS WM_WORKER_MEMORY \
           WM_NATIVE_REPLICAS WM_NATIVE_MEMORY WM_INDEXER_REPLICAS; do
    grep -q "^  ${k}:" "$REPO_ROOT/tools/windmill/module.yaml" || { echo "missing ${k}"; false; }
  done
}

@test "config list renders the new keys with their defaults" {
  run bash -c "CFG_YAML='$REPO_ROOT/tools/windmill/module.yaml' CFG_STORE='$WM_CONF_FILE' bash -c 'source $REPO_ROOT/tools/_shared/common.sh; cfg_action list'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"BASE_URL"* ]] || false
  [[ "$output" == *"(default: 31100)"* ]] || false
  [[ "$output" == *"WM_WORKER_REPLICAS"* ]] || false
}

# ---------- rendered compose interpolates the knobs -------------------------

@test "compose: worker/indexer replicas + memory are interpolation-driven" {
  _wm 'wm_paths; render_compose'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local c="$WM_DIR/docker-compose.yml"
  grep -q 'replicas: \${WM_WORKER_REPLICAS:-3}' "$c" || { grep -n 'replicas' "$c"; false; }
  grep -q 'memory: \${WM_WORKER_MEMORY:-1536M}' "$c" || { grep -n 'memory' "$c"; false; }
  grep -q 'replicas: \${WM_NATIVE_REPLICAS:-1}' "$c" || false
  grep -q 'memory: \${WM_NATIVE_MEMORY:-1024M}' "$c" || false
  grep -q 'replicas: \${WM_INDEXER_REPLICAS:-0}' "$c" || false
  grep -q 'max-size: "\${LOG_MAX_SIZE:-20m}"' "$c" || false
  grep -q 'max-file: "\${LOG_MAX_FILE:-10}"' "$c" || false
}

@test "compose: no 443 publish for a plain HTTP deployment" {
  _wm 'wm_paths; render_compose'
  ! grep -q '31443:443' "$WM_DIR/docker-compose.yml" || { false; }
}

@test "compose: https BASE_URL publishes 443 and points caddy at the URL" {
  _conf BASE_URL "https://wm.example.com"
  _wm 'wm_paths; render_compose'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q -- '- "31443:443"' "$WM_DIR/docker-compose.yml" || { false; }
  grep -q 'BASE_URL="\${BASE_URL:-:80}"' "$WM_DIR/docker-compose.yml" || { grep -n BASE_URL "$WM_DIR/docker-compose.yml"; false; }
}

# ---------- Caddyfile: site address + tls internal for IP -------------------

@test "caddy: the site address comes from BASE_URL (templated, no re-render needed)" {
  _wm 'wm_paths; render_caddy'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^{\$BASE_URL} {' "$WM_DIR/Caddyfile" || { false; }
  ! grep -q 'tls internal' "$WM_DIR/Caddyfile" || { false; }
}

@test "caddy: https + a bare IP gets tls internal (self-signed; no ACME possible)" {
  _conf BASE_URL "https://10.0.0.5"
  _wm 'wm_paths; render_caddy'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'tls internal' "$WM_DIR/Caddyfile" || { echo "$output"; cat "$WM_DIR/Caddyfile"; false; }
}

@test "caddy: https + a domain stays automatic (Let's Encrypt, no tls internal)" {
  _conf BASE_URL "https://wm.example.com"
  _wm 'wm_paths; render_caddy'
  ! grep -q 'tls internal' "$WM_DIR/Caddyfile" || { false; }
}

# ---------- .env carries the resolved knobs ---------------------------------

@test "env: render_env writes every knob with its resolved value" {
  _conf LOG_MAX_SIZE "50m"
  _conf WM_WORKER_REPLICAS "6"
  _conf BASE_URL "https://wm.example.com"
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local e="$WM_DIR/.env"
  grep -q '^BASE_URL=https://wm.example.com$' "$e" || { false; }
  grep -q '^HTTP_PORT=31100$' "$e" || false
  grep -q '^LOG_MAX_SIZE=50m$' "$e" || false
  grep -q '^LOG_MAX_FILE=10$' "$e" || false
  grep -q '^WM_WORKER_REPLICAS=6$' "$e" || false
  grep -q '^WM_WORKER_MEMORY=1536M$' "$e" || false
  grep -q '^WM_NATIVE_REPLICAS=1$' "$e" || false
  grep -q '^WM_NATIVE_MEMORY=1024M$' "$e" || false
  grep -q '^WM_INDEXER_REPLICAS=0$' "$e" || false
  grep -q '^WM_TLS=1$' "$e" || false
  [ "$(stat -c '%a' "$e" 2>/dev/null || stat -f '%Lp' "$e")" = "600" ] || false
}

@test "env: sync_env_knobs applies a conf change without touching credentials" {
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  local before; before="$(grep '^POSTGRES_PASSWORD=' "$WM_DIR/.env")"
  _conf WM_WORKER_REPLICAS "8"
  _conf BASE_URL "https://wm.example.com"
  _wm 'wm_paths; sync_env_knobs'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^WM_WORKER_REPLICAS=8$' "$WM_DIR/.env" || { false; }
  grep -q '^BASE_URL=https://wm.example.com$' "$WM_DIR/.env" || false
  [ "$(grep '^POSTGRES_PASSWORD=' "$WM_DIR/.env")" = "$before" ] || { echo "password churned"; false; }
}

@test "env: sync_env_knobs warns when the TLS publish needs a re-render" {
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  _conf BASE_URL "https://wm.example.com"
  _wm 'wm_paths; sync_env_knobs'
  [[ "$output" == *"deploy --recreate"* ]] || { echo "$output"; false; }
}

@test "env: a hand-set knob in .env survives when the conf has no explicit value" {
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  # a deploy host editing its own instance copy (the documented precedence)
  _wm 'wm_paths; set_env WM_WORKER_REPLICAS 9'
  _wm 'wm_paths; sync_env_knobs'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^WM_WORKER_REPLICAS=9$' "$WM_DIR/.env" || { grep WM_WORKER "$WM_DIR/.env"; false; }
  # …but an explicit conf value does win over it
  _conf WM_WORKER_REPLICAS "6"
  _wm 'wm_paths; sync_env_knobs'
  grep -q '^WM_WORKER_REPLICAS=6$' "$WM_DIR/.env" || false
}

@test "env: BASE_URL living only in .env still drives TLS" {
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  _wm 'wm_paths; set_env BASE_URL https://wm.example.com'
  _wm 'wm_paths; sync_env_knobs >/dev/null; base_url_tls && echo TLS-ON'
  [[ "$output" == *"TLS-ON"* ]] || { echo "$output"; false; }
}

@test "env: comments render literally (no command substitution in the unquoted heredoc)" {
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # backticks inside an UNQUOTED heredoc would EXECUTE (this once ran `tls internal`
  # and `windmill systemd install` while rendering the .env comments)
  [[ "$output" != *"command not found"* ]] || { echo "$output"; false; }
  grep -q 'tls internal' "$WM_DIR/.env" || { false; }
  grep -q 'windmill systemd' "$WM_DIR/.env" || false
}

@test "conf: windmill_extra feature switches are settable and interpolated" {
  _conf ENABLE_MULTIPLAYER "true"
  _wm 'printf "%s|%s|%s" "$ENABLE_LSP" "$ENABLE_MULTIPLAYER" "$ENABLE_DEBUGGER"'
  [ "$output" = "true|true|true" ] || { echo "got: $output"; false; }
  _wm 'wm_paths; render_compose'
  grep -q 'ENABLE_MULTIPLAYER=\${ENABLE_MULTIPLAYER:-false}' "$WM_DIR/docker-compose.yml" || { grep -n ENABLE_ "$WM_DIR/docker-compose.yml"; false; }
  _wm 'wm_paths; render_env 1.811.1 secret 31100'
  grep -q '^ENABLE_MULTIPLAYER=true$' "$WM_DIR/.env" || false
}

@test "conf: a non-boolean ENABLE_* value is ignored (whitelist guard)" {
  _conf ENABLE_LSP "yes"
  _wm 'printf "%s" "$ENABLE_LSP"'
  [ "$output" = "true" ] || { echo "got: $output"; false; }
}

@test "deploy --recreate re-renders the compose + Caddyfile (so a scheme change lands)" {
  # the recreate branch is the only path that can pick up the 443 publish and the
  # tls-internal decision; assert the render calls sit inside it
  awk '/^cmd_deploy\(\)/{f=1} f&&/recreate\)/{r=1} r&&/render_compose|render_caddy/{print} r&&/crun stack_up_staged/{exit}' "$WM_CLI" | grep -c 'render_' | grep -q '^2$' || { false; }
}

# ---------- BASE_URL reaches the instance address + hardening ---------------

@test "instance_url: BASE_URL wins over the auto-detected IP" {
  _conf BASE_URL "https://wm.example.com"
  _wm 'wm_paths; printf "%s" "$(instance_url)"'
  [ "$output" = "https://wm.example.com" ] || { echo "got: $output"; false; }
}

@test "instance_url: without BASE_URL the IP + port form is kept" {
  _wm 'wm_paths; printf "%s" "$(instance_url)"'
  [[ "$output" == http://*:31100 ]] || { echo "got: $output"; false; }
}

@test "base_url validation: a port in BASE_URL is rejected with guidance" {
  _conf BASE_URL "https://wm.example.com:8443"
  _wm 'wm_paths; base_url_check'
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"HTTP_PORT"* ]] || { echo "$output"; false; }
}

# ---------- systemd: retention reaches the unit -----------------------------

@test "systemd: the backup unit bakes in KEEP from the conf" {
  _conf KEEP "14"
  _wm 'wm_paths; systemd_unit windmill-backup.service'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'Environment="KEEP=14"'* ]] || { echo "$output"; false; }
  [[ "$output" == *'backup --daily'* ]] || false
}

@test "systemd: KEEP defaults to 7 when nothing is configured" {
  _wm 'wm_paths; systemd_unit windmill-backup.service'
  [[ "$output" == *'Environment="KEEP=7"'* ]] || { echo "$output"; false; }
}

# ---------- regression: the original four keys still work -------------------

@test "conf: the original keys (proxy + mirrors) still resolve" {
  _conf PROXY_URL "http://127.0.0.1:7890"
  _conf WM_GHCR_MIRROR "https://ghcr.nju.edu.cn"
  _conf WM_HUB_MIRROR "https://docker.1ms.run"
  _wm 'printf "%s|%s|%s" "$PROXY_URL" "$WM_GHCR_MIRROR" "$WM_HUB_MIRROR"'
  [ "$output" = "http://127.0.0.1:7890|https://ghcr.nju.edu.cn|https://docker.1ms.run" ] || { echo "got: $output"; false; }
}

@test "deploy --recreate recovers a MISSING docker-compose.yml (re-render, then up)" {
  # live-caught: a deploy root whose compose was gone could neither start nor
  # redeploy — cmd_up needs the file and cmd_deploy validated it before the
  # --recreate branch re-renders it. The render artifact must be recoverable.
  # The CLI's commands exit() by design, so the assertion looks at the stubbed
  # renderer's side effect from the OUTER shell.
  rm -f "$WM_DIR/docker-compose.yml"
  run bash -c "
    export HOME='$WM_TEST_HOME' AIBOX_HOME='$AIBOX_HOME' WM_DIR='$WM_DIR' WM_CONF_FILE='$WM_CONF_FILE'
    source '$WM_CLI'
    require_root() { :; } ; require_docker() { :; } ; acquire_lock() { :; } ; release_lock() { :; }
    step() { :; } ; info() { :; } ; hr() { :; } ; sync_env_knobs() { :; }
    crun() { return 0; }
    config_missing() { :; }        # model 'config intact, compose artifact gone'
    render_compose() { printf 'services: {}\n' >\"\$COMPOSE_FILE\"; }
    render_caddy()   { printf '# caddy\n' >\"\$CADDY_FILE\"; }
    all_running() { return 0; } ; wm_port_listening() { return 0; } ; probe_version() { printf 'test'; }
    cmd_deploy --recreate --yes
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$WM_DIR/docker-compose.yml" ] || { echo "the compose was NOT re-rendered: $output"; false; }
  grep -q 'services' "$WM_DIR/docker-compose.yml" || false
}

@test "svc.sh start self-heals: init when never deployed, deploy --recreate when only artifacts are gone" {
  # svc.sh resolves the CLI from its install destination (AIBOX_BIN_DIR/windmill)
  # first, else PATH — put the recording stub there so the routed verb is observable
  export WM_VERB_LOG="$SANDBOX/verbs"
  mkdir -p "$AIBOX_HOME/bin"
  cat >"$AIBOX_HOME/bin/windmill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WM_VERB_LOG"
STUB
  chmod +x "$AIBOX_HOME/bin/windmill"
  mkdir -p "$WM_DIR"
  _run_start() {
    : >"$WM_VERB_LOG"
    run env HOME="$WM_TEST_HOME" AIBOX_HOME="$AIBOX_HOME" AIBOX_BIN_DIR="$AIBOX_HOME/bin" \
      WM_DIR="$WM_DIR" WM_CONF_FILE="$WM_CONF_FILE" WM_VERB_LOG="$WM_VERB_LOG" \
      bash "$REPO_ROOT/tools/windmill/svc.sh" start
  }
  # never deployed (no compose, no .env) → the CLI's init
  rm -f "$WM_DIR/docker-compose.yml" "$WM_DIR/.env"
  _run_start
  [ "$(cat "$WM_VERB_LOG")" = "init" ] || { echo "verbs: $(cat "$WM_VERB_LOG")"; false; }
  [[ "$output" == *"not deployed yet"* ]] || { echo "$output"; false; }
  # deployed (has .env) but the render artifacts are gone → deploy --recreate
  printf 'HTTP_PORT=31100\n' >"$WM_DIR/.env"
  _run_start
  [ "$(cat "$WM_VERB_LOG")" = "deploy --recreate" ] || { echo "verbs: $(cat "$WM_VERB_LOG")"; false; }
  [[ "$output" == *"re-rendering it first"* ]] || { echo "$output"; false; }
  # healthy artifacts present → plain up
  printf 'services: {}\n' >"$WM_DIR/docker-compose.yml"
  _run_start
  [ "$(cat "$WM_VERB_LOG")" = "up" ] || { echo "verbs: $(cat "$WM_VERB_LOG")"; false; }
}

@test "connection facts: .env carries the RESOLVED contract value, compose interpolates at runtime" {
  # .env is a snapshot (for the CLI's own psql/backup tooling); the compose line must
  # stay ${DATABASE_URL} so `docker compose` resolves it from the environment the CLI
  # exports from base.env — that is what makes a rotated provider password take effect
  # on the next up instead of crash-looping on a stale copy.
  grep -q '^DATABASE_URL=\${_DB_URL}$' "$WM_CLI" || { echo ".env line is not the resolved value"; false; }
  [ "$(grep -c '^      - DATABASE_URL=\${DATABASE_URL}$' "$WM_CLI")" -ge 4 ] || { echo "compose lines lost runtime interpolation"; false; }
  grep -q 'load_base_contract' "$WM_CLI" || false
  grep -q 'cfg_kv_load_export' "$WM_CLI" || { echo "the contract reader is not used"; false; }
  grep -q 'sync_connection_facts' "$WM_CLI" || false
  # no silent legacy default anywhere in the render path
  ! grep -q 'AIBOX_BASE_POSTGRES_PASSWORD:-aibox' "$WM_CLI" || { echo "the silent 'aibox' fallback is back"; false; }
}

@test "connection facts: a stale .env copy is realigned from the contract (only that field)" {
  # the live failure: base rotated its password, the rendered copy in .env stayed
  mkdir -p "$AIBOX_HOME"
  printf 'AIBOX_POSTGRES_USER=aibox\nAIBOX_POSTGRES_PASSWORD=contract-secret-32chars-xx\nAIBOX_POSTGRES_HOST=aibox-base-postgres\n' >"$AIBOX_HOME/base.env"
  printf 'HTTP_PORT=31100\nDATABASE_URL=postgres://aibox:aibox@aibox-base-postgres:5432/windmill\nWM_TLS=0\n' >"$WM_DIR/.env"
  run bash -c "export HOME='$WM_TEST_HOME' AIBOX_HOME='$AIBOX_HOME' WM_DIR='$WM_DIR' WM_CONF_FILE='$WM_CONF_FILE'
    source '$WM_CLI'
    wm_paths
    sync_connection_facts
    grep -E '^DATABASE_URL=' \"\$WM_DIR/.env\"
    echo \"---\"
    grep -E '^(HTTP_PORT|WM_TLS)=' \"\$WM_DIR/.env\""
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"contract-secret-32chars-xx"* ]] || { echo "not realigned: $output"; false; }
  [[ "$output" == *"HTTP_PORT=31100"* ]] || { echo "unrelated keys touched"; false; }
  [[ "$output" == *"WM_TLS=0"* ]] || { echo "unrelated keys touched"; false; }
  # and the drift is reported (non-mutating) for the check/doctor path
  run bash -c "export HOME='$WM_TEST_HOME' AIBOX_HOME='$AIBOX_HOME' WM_DIR='$WM_DIR' WM_CONF_FILE='$WM_CONF_FILE'
    source '$WM_CLI'; wm_paths
    printf 'HTTP_PORT=31100\nDATABASE_URL=postgres://aibox:stale@aibox-base-postgres:5432/windmill\n' >\"\$WM_DIR/.env\"
    connection_facts_drift"
  [[ "$output" == *"does not match"* ]] || { echo "drift not reported: $output"; false; }
}

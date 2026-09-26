#!/usr/bin/env bats
# Component-upgrade engine tests (offline: pure helpers + a mocked upgrade_fetch
# for the resolver path — no docker, no network).
# The APPLY path (docker pull → .env rewrite → svc start → rollback) is not
# covered here: it needs a docker host; live-smoke it on a real deployment.

load test_helper

# ---------------------------------------------------------------------------
# pure helpers
# ---------------------------------------------------------------------------

@test "upgrade_ver_cmp: ordering, equality, suffixes, numeric (not lexicographic)" {
  [ "$(upgrade_ver_cmp 1.17.2 1.17.1)" = "1" ]
  [ "$(upgrade_ver_cmp 1.17.1 1.17.2)" = "-1" ]
  [ "$(upgrade_ver_cmp 1.17.1 1.17.1)" = "0" ]
  # suffix after '-' ignored (gitlab tags: 19.2.6-ce.0)
  [ "$(upgrade_ver_cmp 19.2.6-ce.0 19.2.5-ce.0)" = "1" ]
  # numeric, not lexicographic: 1.10 > 1.9, 2.0 > 1.99
  [ "$(upgrade_ver_cmp 1.10.0 1.9.9)" = "1" ]
  [ "$(upgrade_ver_cmp 2.0 1.99)" = "1" ]
  # padding: 1.17 == 1.17.0
  [ "$(upgrade_ver_cmp 1.17 1.17.0)" = "0" ]
}

@test "upgrade_pick_tag: max among matching, pattern-filtered, blank-safe" {
  r="$(printf '19.2.4-ce.0\n19.2.6-ce.0\n19.2.5-ce.0\n' | upgrade_pick_tag '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$')"
  [ "$r" = "19.2.6-ce.0" ]
  # pattern rejects junk (latest / ee / v-prefixed)
  r="$(printf 'latest\n19.2.6-ee.0\nv19.2.7-ce.0\n19.2.6-ce.0\n' | upgrade_pick_tag '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$')"
  [ "$r" = "19.2.6-ce.0" ]
  # empty / blank-only input returns 1
  run bash -c ". '$AIBOX_BIN' >/dev/null 2>&1; printf '' | upgrade_pick_tag ''"
  [ "$status" -ne 0 ]
  run bash -c ". '$AIBOX_BIN' >/dev/null 2>&1; printf '\n\n' | upgrade_pick_tag ''"
  [ "$status" -ne 0 ]
}

@test "upgrade_extract_tag: pulls the tag after an upstream image prefix" {
  body='  api:
    image: langgenius/dify-api:1.17.2
    restart: always
  worker:
    image: langgenius/dify-api:1.17.2
'
  r="$(printf '%s' "$body" | upgrade_extract_tag 'langgenius/dify-api:')"
  [ "$r" = "1.17.2" ]
  # hyphen-suffixed tags survive intact
  r="$(printf '    image: langgenius/dify-plugin-daemon:0.6.10-local\n' | upgrade_extract_tag 'langgenius/dify-plugin-daemon:')"
  [ "$r" = "0.6.10-local" ]
  # missing prefix → non-zero
  run bash -c ". '$AIBOX_BIN' >/dev/null 2>&1; printf 'image: nginx:latest\n' | upgrade_extract_tag 'langgenius/dify-api:'"
  [ "$status" -ne 0 ]
}

@test "upgrade_env_rewrite: rewrites in place, appends missing, preserves the rest + mode" {
  d="$(mktemp -d)"; f="$d/.env"
  printf 'A=1\nB=old\n# a comment stays\n' > "$f"
  chmod 600 "$f"
  upgrade_env_rewrite "$f" "B=new" "C=3"
  grep -q '^B=new$' "$f"
  grep -q '^A=1$' "$f"
  grep -q '^C=3$' "$f"
  grep -q '^# a comment stays$' "$f"
  # GNU syntax first, BSD fallback — same order as tests/config.bats (the reverse
  # concatenates GNU stat -f's stdout garbage with the fallback value).
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = "600" ]
  rm -rf "$d"
}

@test "upgrade_floor_image: reads the \${KEY:-image} default out of a compose file" {
  d="$(mktemp -d)"; c="$d/docker-compose.yml"
  printf 'services:\n  api:\n    image: ${DIFY_API_IMAGE:-langgenius/dify-api:1.17.1}\n' > "$c"
  r="$(upgrade_floor_image "$c" DIFY_API_IMAGE)"
  [ "$r" = "langgenius/dify-api:1.17.1" ]
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# stanza round-trip via the real parser
# ---------------------------------------------------------------------------

@test "upgrade stanza: dify + gitlab module.yaml round-trip through module_field" {
  AIBOX_RAW="file://$REPO_ROOT"
  load_registry
  [ "$(module_field dify upgrade_source)" = "github-release" ]
  [ "$(module_field dify upgrade_repo)" = "langgenius/dify" ]
  [ -n "$(module_field dify upgrade_mapping_url)" ]
  case "$(module_field dify upgrade_mapping_url)" in
  *'<VER>'*) ;;
  *) false ;;
  esac
  # 5 image keys declared, each ENV_KEY=prefix:
  [ "$(printf '%s' "$(module_field dify upgrade_images)" | wc -w | tr -d ' ')" = "5" ]
  case "$(module_field dify upgrade_images)" in
  *DIFY_API_IMAGE=langgenius/dify-api:*) ;;
  *) false ;;
  esac
  [ "$(module_field gitlab upgrade_source)" = "dockerhub-tags" ]
  [ "$(module_field gitlab upgrade_repo)" = "gitlab/gitlab-ce" ]
  # backslash regex survives the parser round-trip and matches stable CE tags only
  pat="$(module_field gitlab upgrade_tag_pattern)"
  printf '%s\n' '19.2.6-ce.0' | grep -qE "$pat"
  ! printf '%s\n' 'latest' | grep -qE "$pat"
  ! printf '%s\n' '19.2.6-ee.0' | grep -qE "$pat"
}

@test "dockerhub resolver pipeline: grep|cut|pick_tag over a tags-API fixture" {
  fixture='{"count":123,"results":[{"name":"19.2.4-ce.0"},{"name":"19.2.8-ce.0"},{"name":"latest"},{"name":"19.2.8-ee.0"},{"name":"19.2.6-ce.0"}]}'
  r="$(printf '%s' "$fixture" | grep -oE '"name": *"[^"]+"' | cut -d'"' -f4 | upgrade_pick_tag '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$')"
  [ "$r" = "19.2.8-ce.0" ]
}

# ---------------------------------------------------------------------------
# cmd_upgrade engine paths (mocked upgrade_fetch; no docker/network)
# ---------------------------------------------------------------------------

_setup_dify_deploy() {
  AIBOX_RAW="file://$REPO_ROOT"
  load_registry
  mkdir -p "$AIBOX_MOD_DIR/dify" "$AIBOX_HOME/apps/dify"
  cp "$REPO_ROOT/tools/dify/lib.sh" "$AIBOX_MOD_DIR/dify/lib.sh"
  cp "$REPO_ROOT/tools/dify/docker-compose.yml" "$AIBOX_MOD_DIR/dify/docker-compose.yml"
  printf 'AIBOX_INSTALLED_dify="1.17.1"\n' > "$AIBOX_INSTALLED"
  printf 'DIFY_API_IMAGE=langgenius/dify-api:1.17.1\nSECRET_KEY=x\n' > "$AIBOX_HOME/apps/dify/.env"
}

@test "cmd_upgrade: usage / unknown module / not installed / no stanza — clean errors" {
  AIBOX_RAW="file://$REPO_ROOT"
  load_registry
  run cmd_upgrade
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: aibox upgrade"* ]]
  run cmd_upgrade nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown module: nosuch"* ]]
  run cmd_upgrade gitlab
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
  # installed but no stanza → clean decline
  printf 'AIBOX_INSTALLED_base="1.1.0"\n' > "$AIBOX_INSTALLED"
  run cmd_upgrade base
  [ "$status" -ne 0 ]
  # base implements its own upgrade verbs → the manager points at them instead of
  # a bare "no support" (same for openmaic/windmill)
  [[ "$output" == *"owns its upgrade path"*"aibox base upgrade --help"* ]] || { echo "$output"; false; }
}

@test "cmd_upgrade --check (mocked resolver): reports current/target/status, exit 0" {
  _setup_dify_deploy
  upgrade_fetch() { printf '{"tag_name":"1.17.2"}'; } # mock: github release json
  run cmd_upgrade dify --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"current : 1.17.1"* ]]
  [[ "$output" == *"target  : 1.17.2"* ]]
  [[ "$output" == *"upgrade available"* ]]
}

@test "cmd_upgrade --check (mocked): already at latest → exit 0, no target noise" {
  _setup_dify_deploy
  upgrade_fetch() { printf '{"tag_name":"1.17.1"}'; }
  run cmd_upgrade dify --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"already at 1.17.1"* ]]
}

@test "cmd_upgrade guardrail: auto-latest refuses cross-major; --to reaches the confirm gate" {
  _setup_dify_deploy
  upgrade_fetch() { printf '{"tag_name":"2.0.0"}'; }
  # auto-latest cross-major → die with the --to hint
  run cmd_upgrade dify
  [ "$status" -ne 0 ]
  [[ "$output" == *"crosses a major version"* ]]
  [[ "$output" == *"--to 2.0.0"* ]]
  # pinned cross-major passes the guardrail but the non-interactive confirm declines → 2
  run cmd_upgrade dify --to 2.0.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"declined (non-interactive? add --yes)"* ]]
}

@test "cmd_upgrade --check with --to: works with no resolver network at all" {
  _setup_dify_deploy
  upgrade_fetch() { return 1; } # network totally down
  run cmd_upgrade dify --to 1.18.0 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"target  : 1.18.0"* ]]
}

# ---------------------------------------------------------------------------
# _gh_api_fetch: raw.githubusercontent.com → api.github.com contents fallback
# ---------------------------------------------------------------------------

@test "gh-api decode pipeline: contents-API JSON (base64 with \n escapes) → file content" {
  expected='services:
  api:
    image: langgenius/dify-api:1.17.0'
  # base64, then insert literal backslash-n escapes every 60 chars (GitHub style)
  b64="$(printf '%s' "$expected" | base64 | tr -d '\n')"
  esc="$(printf '%s' "$b64" | awk '{line=$0; out=""; while (length(line)>60) {out=out substr(line,1,60) "\\n"; line=substr(line,61)}; print out line}')"
  json="{\"name\":\"x\",\"content\":\"${esc}\",\"encoding\":\"base64\"}"
  decoded="$(printf '%s' "$json" | grep -oE '"content": *"[^"]*"' | cut -d'"' -f4 | sed 's/\\n//g' | base64 -d 2>/dev/null)"
  [ "$decoded" = "$expected" ]
  # short content without escapes also decodes
  json2='{"content":"aGVsbG8gd29ybGQ="}'
  d2="$(printf '%s' "$json2" | grep -oE '"content": *"[^"]*"' | cut -d'"' -f4 | sed 's/\\n//g' | base64 -d 2>/dev/null)"
  [ "$d2" = "hello world" ]
}

@test "gh-api URL parsing: raw URL splits into owner/repo/ref/path" {
  u='https://raw.githubusercontent.com/langgenius/dify/1.17.0/docker/docker-compose.yaml'
  r="${u#https://raw.githubusercontent.com/}"
  [ "$(printf '%s' "$r" | cut -d/ -f1)" = "langgenius" ]
  [ "$(printf '%s' "$r" | cut -d/ -f2)" = "dify" ]
  [ "$(printf '%s' "$r" | cut -d/ -f3)" = "1.17.0" ]
  [ "$(printf '%s' "$r" | cut -d/ -f4-)" = "docker/docker-compose.yaml" ]
}

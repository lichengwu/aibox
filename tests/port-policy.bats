#!/usr/bin/env bats
# Port policy (spec §Port allocation): host ports live in the aibox reserved band —
# 30000-30999 existing services, 31000-31999 services, 32000-32999 infrastructure.
# Refused: privileged (<1024), the common conventions (3000/5000/8080/8443/8888/
# 9000/9090/7890/8000…), and Linux's ephemeral range 32768-60999 (the kernel hands
# those to outbound connections first — the old defaults sat inside it).

load test_helper

@test "every declared host port is in the reserved band (or explicitly :public)" {
  local f m p
  for f in "$REPO_ROOT"/tools/*/module.yaml; do
    m="$(basename "$(dirname "$f")")"
    for p in $(awk '/^ports:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); print}' "$f"); do
      case "${p}" in *:public*) continue ;; esac
      local n="${p%%/*}"
      case "${n}" in *[!0-9]* | "") continue ;; esac
      { [ "${n}" -ge 30000 ] && [ "${n}" -le 32999 ]; } || { echo "${m}: ${p} is outside the reserved band"; false; }
    done
  done
}

@test "each module's default port constant matches its module.yaml declaration" {
  # drift guard: the code default and the declaration cannot disagree
  _decl() { awk '/^ports:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{sub(/^  - /,""); sub(/\/.*/,""); print; exit}' "$REPO_ROOT/tools/$1/module.yaml"; }
  _has() { # $1=file $2=port → the file mentions that port as a default
    grep -qE "(:-|=\"|: )${2}\b|\b${2}\b" "$REPO_ROOT/tools/$1" 2>/dev/null
  }
  [ "$(_decl windmill)" = "31100" ] || { echo "windmill decl: $(_decl windmill)"; false; }
  _has "windmill/cli/windmill" 31100 || { echo "windmill CLI default is not 31100"; false; }
  [ "$(_decl dify)" = "31101" ] || false
  grep -q 'DEFAULT_PORT="31101"' "$REPO_ROOT/tools/dify/lib.sh" || { echo "dify default"; false; }
  [ "$(_decl gitlab)" = "31110" ] || false
  grep -q 'DEFAULT_HTTP_PORT="31110"' "$REPO_ROOT/tools/gitlab/lib.sh" || false
  grep -q 'DEFAULT_SSH_PORT="31222"' "$REPO_ROOT/tools/gitlab/lib.sh" || false
  [ "$(_decl xiaozhi)" = "31130" ] || false
  grep -q 'DEFAULT_WS_PORT="31130"' "$REPO_ROOT/tools/xiaozhi/lib.sh" || false
  [ "$(_decl clash)" = "31790" ] || false
  grep -q 'CLASH_PORT="${CLASH_PORT:-31790}"' "$REPO_ROOT/tools/clash/lib.sh" || false
  [ "$(_decl base)" = "32432" ] || false
  grep -q 'AIBOX_BASE_POSTGRES_PORT:-32432' "$REPO_ROOT/tools/base/docker-compose.yml" || false
  grep -q 'AIBOX_BASE_REDIS_PORT:-32379' "$REPO_ROOT/tools/base/docker-compose.yml" || false
}

@test "port_policy_hint: explains each refused zone, silent in-band" {
  run bash -c "source '$AIBOX_BIN'; for p in 80 443 8080 7890 35000; do printf '%s: %s\n' \"\$p\" \"\$(port_policy_hint \"\$p\")\"; done"
  [[ "$output" == *"80: privileged"* ]] || { echo "$output"; false; }
  [[ "$output" == *"443: privileged"* ]] || false
  [[ "$output" == *"8080: a common service convention"* ]] || { echo "$output"; false; }
  [[ "$output" == *"7890: a common service convention"* ]] || false
  [[ "$output" == *"35000: inside Linux's ephemeral range"* ]] || { echo "$output"; false; }
  run bash -c "source '$AIBOX_BIN'; printf '[%s]' \"\$(port_policy_hint 31100)\" \"\$(port_policy_hint 32432)\""
  [ "$output" = "[][]" ] || { echo "in-band ports must be silent: $output"; false; }
}

@test "validator: an out-of-band port is an ERROR and ':public' is the escape hatch" {
  local out="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$out"
  bash "$REPO_ROOT/scripts/new-module.sh" porty --out "$out" >/dev/null 2>&1
  local y="$out/porty/module.yaml"
  sed -i.bak 's#^  - 31100/tcp:http$#  - 8080/tcp:http#' "$y" 2>/dev/null || true
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" porty
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"outside the aibox reserved band"* ]] || { echo "$output"; false; }
  # the explicit public escape hatch is accepted
  sed -i.bak 's#^  - .*:http$#  - 443/tcp:https:public#' "$y" 2>/dev/null || true
  run env VALIDATE_TOOLS_DIR="$out" bash "$REPO_ROOT/scripts/validate-module.sh" porty
  [[ "$output" != *"outside the aibox reserved band"* ]] || { echo "$output"; false; }
}

@test "profile bands come from the shared allocator, inside the reserved band" {
  run bash -c "source '$AIBOX_BIN'; printf '%s %s %s' \"\$(profile_port pg 0)\" \"\$(profile_port redis 0)\" \"\$(profile_port web 0)\""
  [ "$output" = "32100 32600 31150" ] || { echo "bands: $output"; false; }
}

@test "the policy is written where contributors read it (spec + AGENTS)" {
  grep -q '### Port allocation (the aibox reserved band)' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '32768–60999' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'reserved band' "$REPO_ROOT/AGENTS.md" || false
  grep -q 'S13j' "$REPO_ROOT/docs/module-spec.md" || { grep -q 'port_policy_hint' "$REPO_ROOT/docs/module-spec.md" || false; }
}

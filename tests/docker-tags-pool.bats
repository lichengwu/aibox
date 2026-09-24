#!/usr/bin/env bats
# docker source selector: TAGS family (dockerhub version resolution) —
# dockerhub_tags_fetch in bin/aibox (manager-side twin of common.sh's
# PULL/GHCR families; same dockerpool.cache file + grammar).
# Fully OFFLINE via a fake curl shim + a fake docker (registry-mirrors
# discovery). Route control: FAKE_<ROUTE>_MODE (ok|dead), FAKE_<ROUTE>_TIME
# (the -w time_total), FAKE_<ROUTE>_BODY (JSON per shape: hub v2 "results"
# for the direct route, registry v2 "tags" for mirrors).
# FAKE_CURL_LOG records every URL for call-order assertions.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-dktags.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_CONFIG="$AIBOX_HOME/config"
  export AIBOX_REGISTRY_CACHE="$AIBOX_HOME/registry.cache"
  mkdir -p "$AIBOX_HOME" "$AIBOX_MOD_DIR"
  unset AIBOX_DOCKER_POOL AIBOX_DOCKER_MIRROR AIBOX_DOCKER_TAGS_TIMEOUT \
    AIBOX_DOCKER_POOL_TTL FAKE_DOCKER_INFO_MIRRORS \
    FAKE_DOCKERHUB_MODE FAKE_DOCKERHUB_TIME FAKE_DOCKERHUB_BODY \
    FAKE_M_1MS_MODE FAKE_M_1MS_TIME FAKE_M_1MS_BODY \
    FAKE_M_RAT_MODE FAKE_M_RAT_TIME FAKE_M_RAT_BODY \
    FAKE_M_DAOCLOUD_MODE FAKE_M_DAOCLOUD_TIME FAKE_M_DAOCLOUD_BODY \
    FAKE_M_LINKEASE_MODE FAKE_M_LINKEASE_TIME FAKE_M_LINKEASE_BODY || true
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  FAKEBIN="$SANDBOX/bin"
  mkdir -p "$FAKEBIN"
  export FAKE_CURL_LOG="$SANDBOX/curl.log"
  : >"$FAKE_CURL_LOG"

  # default bodies: hub v2 (direct) / registry v2 (mirrors)
  export FAKE_DOCKERHUB_BODY='{"results":[{"name":"19.4.2-ce.0"},{"name":"19.4.1-ce.0"}]}'
  export FAKE_M_1MS_BODY='{"name":"gitlab/gitlab-ce","tags":["19.4.1-ce.0","19.3.3-ce.0"]}'
  export FAKE_M_RAT_BODY='{"name":"gitlab/gitlab-ce","tags":["19.4.0-ce.0"]}'
  export FAKE_M_DAOCLOUD_BODY='{"name":"gitlab/gitlab-ce","tags":["19.2.6-ce.0"]}'
  export FAKE_M_LINKEASE_BODY='{"name":"gitlab/gitlab-ce","tags":["19.4.3-ce.0"]}'

  cat >"$FAKEBIN/curl" <<'SHIM'
#!/usr/bin/env bash
out="" fmt="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -[fsSL]*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
route() {
  local mode t body
  eval "mode=\${FAKE_${1}_MODE:-ok}"
  eval "t=\${FAKE_${1}_TIME:-0.5}"
  eval "body=\${FAKE_${1}_BODY:-}"
  if [ "$mode" = "dead" ]; then exit 28; fi
  if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
  case "$fmt" in *time_total*) printf '%s' "$t" ;; esac
  exit 0
}
case "$url" in
https://hub.docker.com/v2/*)            route DOCKERHUB ;;
https://docker.1ms.run/v2/*)            route M_1MS ;;
https://hub.rat.dev/v2/*)               route M_RAT ;;
https://docker.m.daocloud.io/v2/*)      route M_DAOCLOUD ;;
https://registry.linkease.net:5443/v2/*) route M_LINKEASE ;;
*) exit 6 ;;
esac
SHIM
  chmod +x "$FAKEBIN/curl"

  # fake docker: only `info --format ... Mirrors` matters (local discovery)
  cat >"$FAKEBIN/docker" <<'SHIM2'
#!/usr/bin/env bash
if [ "${1:-}" = "info" ]; then
  # shellcheck disable=SC2124
  printf '%s\n' "${FAKE_DOCKER_INFO_MIRRORS:-}"
  exit 0
fi
exit 0
SHIM2
  chmod +x "$FAKEBIN/docker"
  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bin/aibox"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

_direct_hits() { grep -c "hub.docker.com" "$FAKE_CURL_LOG" || true; }

@test "dockerhub_tags_fetch: direct dead → pool race, ranked cache, registry JSON parsed" {
  export FAKE_DOCKERHUB_MODE=dead
  export AIBOX_DOCKER_POOL="docker.1ms.run hub.rat.dev docker.m.daocloud.io"
  export FAKE_M_1MS_TIME=0.3 FAKE_M_RAT_TIME=0.8
  export FAKE_M_DAOCLOUD_MODE=dead
  local out
  out="$(dockerhub_tags_fetch "gitlab/gitlab-ce")" || false
  printf '%s\n' "$out" | grep -q '^19.4.1-ce.0$' || false
  [ "$(_dkcache_read TAGS)" = "docker.1ms.run hub.rat.dev" ] || false   # daocloud pruned
  [ "$(stat -c %a "$AIBOX_HOME/dockerpool.cache" 2>/dev/null || stat -f %Lp "$AIBOX_HOME/dockerpool.cache" 2>/dev/null)" = "600" ] || false
}

@test "dockerhub_tags_fetch: cached order (no direct token) → direct NOT retried within TTL" {
  export FAKE_DOCKERHUB_MODE=dead
  export AIBOX_DOCKER_POOL="docker.1ms.run"
  dockerhub_tags_fetch "gitlab/gitlab-ce" >/dev/null
  # direct comes BACK alive — the cache must still skip it (known dead within TTL)
  export FAKE_DOCKERHUB_MODE=ok
  : >"$FAKE_CURL_LOG"
  local out
  out="$(dockerhub_tags_fetch "gitlab/gitlab-ce")" || false
  printf '%s\n' "$out" | grep -q '^19.4.1-ce.0$' || false
  [ "$(_direct_hits)" -eq 0 ] || { echo "direct retried: $(cat "$FAKE_CURL_LOG")"; false; }
}

@test "dockerhub_tags_fetch: direct alive → wins, cache records direct, hub JSON parsed" {
  export FAKE_DOCKERHUB_MODE=ok
  local out
  out="$(dockerhub_tags_fetch "gitlab/gitlab-ce")" || false
  printf '%s\n' "$out" | grep -q '^19.4.2-ce.0$' || false
  [ "$(_dkcache_read TAGS)" = "direct" ] || false
  # the pool was never engaged
  [ "$(grep -c "docker.1ms.run" "$FAKE_CURL_LOG" || true)" -eq 0 ] || false
}

@test "dockerhub_tags_fetch: daemon registry-mirrors (local addresses) tried before the pool" {
  export FAKE_DOCKERHUB_MODE=dead
  export FAKE_DOCKER_INFO_MIRRORS="[https://registry.linkease.net:5443/]"
  export AIBOX_DOCKER_POOL="docker.1ms.run"
  export FAKE_M_1MS_MODE=ok FAKE_M_LINKEASE_MODE=ok
  local out
  out="$(dockerhub_tags_fetch "gitlab/gitlab-ce")" || false
  printf '%s\n' "$out" | grep -q '^19.4.3-ce.0$' || false
  [ "$(_dkcache_read TAGS)" = "registry.linkease.net:5443" ] || false
  # the pool never raced (the local mirror satisfied the resolve)
  [ "$(grep -c "docker.1ms.run/v2" "$FAKE_CURL_LOG" || true)" -eq 0 ] || false
}

@test "dockerhub_tags_fetch: dead cached order → invalidate → full re-resolve" {
  _dkcache_write TAGS "docker.1ms.run"
  export FAKE_DOCKERHUB_MODE=dead
  export AIBOX_DOCKER_POOL="docker.1ms.run"
  export FAKE_M_1MS_MODE=dead
  run dockerhub_tags_fetch "gitlab/gitlab-ce"
  [ "$status" -eq 1 ] || false
  if grep -q $'^TAGS\t' "$AIBOX_HOME/dockerpool.cache" 2>/dev/null; then
    echo "cache not invalidated: $(cat "$AIBOX_HOME/dockerpool.cache")"
    false
  fi
}

@test "dockerhub_tags_fetch: TTL expiry → the official route is re-probed" {
  export FAKE_DOCKERHUB_MODE=dead
  export AIBOX_DOCKER_POOL="docker.1ms.run"
  dockerhub_tags_fetch "gitlab/gitlab-ce" >/dev/null
  touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d "2 hours ago" +%Y%m%d%H%M.%S)" "$AIBOX_HOME/dockerpool.cache"
  : >"$FAKE_CURL_LOG"
  dockerhub_tags_fetch "gitlab/gitlab-ce" >/dev/null || false
  [ "$(_direct_hits)" -ge 1 ] || false   # expired → direct re-probed honestly
}

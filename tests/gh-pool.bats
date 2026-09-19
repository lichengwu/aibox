#!/usr/bin/env bats
# gh source-pool engine tests — fully OFFLINE via a fake curl shim.
# Route control: FAKE_<ROUTE>_MODE (ok|dead), FAKE_<ROUTE>_TIME, FAKE_<ROUTE>_BODY.
# Routes are matched by URL prefix: DIRECT(raw.githubusercontent.com), API
# (api.github.com), GH_PROXY, GHPROXY_NET, DOCKERHUB, UMIRROR (user mirror).
# FAKE_CURL_LOG records every curl URL for call-count assertions.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-ghpool.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_CONFIG="$AIBOX_HOME/config"
  export AIBOX_REGISTRY_CACHE="$AIBOX_HOME/registry.cache"
  mkdir -p "$AIBOX_HOME" "$AIBOX_MOD_DIR"
  unset AIBOX_GH_POOL CLASH_MIRROR AIBOX_GH_MIRROR AIBOX_GH_POOL_TIMEOUT \
    AIBOX_GH_POOL_TTL FAKE_GH_PROXY_MODE FAKE_GH_PROXY_TIME FAKE_GH_PROXY_BODY \
    FAKE_GHPROXY_NET_MODE FAKE_GHPROXY_NET_TIME FAKE_GHPROXY_NET_BODY \
    FAKE_DIRECT_MODE FAKE_DIRECT_TIME FAKE_DIRECT_BODY \
    FAKE_API_MODE FAKE_API_TIME FAKE_API_BODY \
    FAKE_DOCKERHUB_MODE FAKE_DOCKERHUB_BODY FAKE_UMIRROR_BODY || true
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  FAKEBIN="$SANDBOX/bin"
  mkdir -p "$FAKEBIN"
  export FAKE_CURL_LOG="$SANDBOX/curl.log"
  : >"$FAKE_CURL_LOG"

  cat > "$FAKEBIN/curl" <<'SHIM'
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

route() { # $1=ROUTE → env FAKE_<ROUTE>_{MODE,TIME,BODY}
  local mode t body
  eval "mode=\${FAKE_${1}_MODE:-ok}"
  eval "t=\${FAKE_${1}_TIME:-0.5}"
  eval "body=\${FAKE_${1}_BODY:-BODY_${1}}"
  if [ "$mode" = "dead" ]; then exit 28; fi
  if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
  case "$fmt" in *time_total*) printf '%s' "$t" ;; esac
  exit 0
}

case "$url" in
https://gh-proxy.com/*)       route GH_PROXY ;;
https://ghproxy.net/*)        route GHPROXY_NET ;;
https://raw.githubusercontent.com/*) route DIRECT ;;
https://api.github.com/*)     route API ;;
https://hub.docker.com/*)     route DOCKERHUB ;;
https://user-mirror.example/*) route UMIRROR ;;
*) exit 6 ;;
esac
SHIM
  chmod +x "$FAKEBIN/curl"
  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bin/aibox"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

_curl_calls() { wc -l <"$FAKE_CURL_LOG" | tr -d ' '; }
_curl_urls() { grep -c "$1" "$FAKE_CURL_LOG"; }

@test "_gh_pool_family: classifies raw / api / rel / other" {
  [ "$(_gh_pool_family "https://raw.githubusercontent.com/o/r/main/f")" = "RAW" ]
  [ "$(_gh_pool_family "https://api.github.com/repos/o/r")" = "API" ]
  [ "$(_gh_pool_family "https://github.com/o/r/releases/download/v1/x.tgz")" = "REL" ]
  [ "$(_gh_pool_family "https://hub.docker.com/v2/x")" = "OTHER" ]
}

@test "_gh_pool_candidates: user mirror → direct → pool → ghapi (RAW only)" {
  export CLASH_MIRROR="https://user-mirror.example"
  export AIBOX_GH_POOL="https://a.example https://b.example"
  local out
  out="$(_gh_pool_candidates RAW)"
  set -- $out
  [ "$1" = "prefix|https://user-mirror.example" ]
  [ "$2" = "direct|" ]
  [ "$3" = "prefix|https://a.example" ]
  [ "$4" = "prefix|https://b.example" ]
  [ "$5" = "ghapi|" ]
  # API family: no ghapi pseudo-candidate
  out="$(_gh_pool_candidates API)"
  case "$out" in
  *ghapi*) false ;;
  *) : ;;
  esac
}

@test "pool: races all candidates, fastest mirror wins + ranking cached to file" {
  export FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_TIME=0.3 FAKE_GHPROXY_NET_TIME=0.9 FAKE_API_TIME=1.2
  local out
  out="$(gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f")"
  [ "$out" = "BODY_GH_PROXY" ]
  # all four candidates raced
  [ "$(_curl_calls)" -ge 4 ]
  # ranking cached: gh-proxy first; direct (failed) appended last
  local first
  first="$(awk -F'\t' '$1=="RAW" {print $2; exit}' "$AIBOX_HOME/ghpool.cache")"
  [ "${first%% *}" = "prefix|https://gh-proxy.com" ]
  case "$first" in
  *" direct|"*) : ;;   # failed direct kept as last resort
  *) false ;;
  esac
}

@test "pool: warm fetch within TTL → single sequential fetch, no re-race" {
  export FAKE_GH_PROXY_TIME=0.3 FAKE_GHPROXY_NET_TIME=0.9
  gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f" >/dev/null
  local n1 n2
  n1="$(_curl_calls)"
  local out
  out="$(gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/other")"
  [ "$out" = "BODY_GH_PROXY" ]
  n2="$(_curl_calls)"
  # exactly ONE sequential winner fetch — not another 4-way race
  [ "$((n2 - n1))" -eq 1 ]
}

@test "pool: cached winner dies → failover to the runner-up" {
  export FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_TIME=0.3 FAKE_GHPROXY_NET_TIME=0.9 FAKE_API_MODE=dead
  gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f" >/dev/null
  export FAKE_GH_PROXY_MODE=dead
  local out
  out="$(gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f")"
  [ "$out" = "BODY_GHPROXY_NET" ]
}

@test "pool: every cached candidate dies → invalidate, re-race, recover" {
  export FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_TIME=0.3 FAKE_GHPROXY_NET_TIME=0.9 FAKE_API_MODE=dead
  gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f" >/dev/null
  # now everything is dead: the walk fails on all four, the entry is invalidated
  # (in THIS shell — clears the in-process global too), the re-race fails → nonzero.
  # if-condition context keeps set -e from killing the test on the expected rc=1.
  export FAKE_GH_PROXY_MODE=dead FAKE_GHPROXY_NET_MODE=dead
  if gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f" >/dev/null 2>&1; then
    false   # should have failed
  fi
  # invalidation cleared the RAW entry (empty candidates line)
  [ -z "$(awk -F'\t' '$1=="RAW" {print $2; exit}' "$AIBOX_HOME/ghpool.cache")" ]
  # direct revives → the next fetch re-races and direct wins
  export FAKE_DIRECT_MODE=ok FAKE_DIRECT_BODY=REVIVED
  local out
  out="$(gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f")"
  [ "$out" = "REVIVED" ]
  [ "$(awk -F'\t' '$1=="RAW" {print $2; exit}' "$AIBOX_HOME/ghpool.cache" | awk '{print $1}')" = "direct|" ]
}

@test "pool: everything dead → nonzero, no ranking cached" {
  export FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_MODE=dead FAKE_GHPROXY_NET_MODE=dead FAKE_API_MODE=dead
  run gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f"
  [ "$status" -ne 0 ]
  [ -z "$(awk -F'\t' '$1=="RAW" {print $2; exit}' "$AIBOX_HOME/ghpool.cache")" ]
}

@test "pool: AIBOX_GH_POOL=direct → direct only, no mirrors raced" {
  export AIBOX_GH_POOL=direct FAKE_DIRECT_MODE=dead
  run gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f"
  [ "$status" -ne 0 ]
  # only direct URLs in the log — no gh-proxy / ghproxy / api call
  [ "$(_curl_urls "gh-proxy.com")" -eq 0 ]
  [ "$(_curl_urls "ghproxy.net")" -eq 0 ]
  [ "$(_curl_urls "api.github.com")" -eq 0 ]
  [ "$(_curl_urls "raw.githubusercontent.com")" -ge 1 ]
}

@test "pool: ghapi serves when direct and every mirror is dead" {
  export FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_MODE=dead FAKE_GHPROXY_NET_MODE=dead
  local b64 body
  body="API_DECODED_FILE"
  b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
  export FAKE_API_BODY="{\"content\":\"${b64}\"}"
  local out
  out="$(gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f")"
  [ "$out" = "$body" ]
  [ "$(awk -F'\t' '$1=="RAW" {print $2; exit}' "$AIBOX_HOME/ghpool.cache" | awk '{print $1}')" = "ghapi|" ]
}

@test "pool: OTHER family (dockerhub) → direct, then the user mirror" {
  export FAKE_DOCKERHUB_MODE=dead FAKE_UMIRROR_BODY=VIA_USER_MIRROR
  export CLASH_MIRROR="https://user-mirror.example"
  local out
  out="$(gh_pool_fetch "https://hub.docker.com/v2/repositories/x/tags")"
  [ "$out" = "VIA_USER_MIRROR" ]
}

@test "pool: API family race ranks by time and caches under API" {
  export FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_TIME=0.2 FAKE_GHPROXY_NET_TIME=0.7
  local out
  out="$(gh_pool_fetch "https://api.github.com/repos/o/r/contents/tools")"
  [ "$out" = "BODY_GH_PROXY" ]
  [ "$(awk -F'\t' '$1=="API" {print $2; exit}' "$AIBOX_HOME/ghpool.cache" | awk '{print $1}')" = "prefix|https://gh-proxy.com" ]
}

@test "pool: TTL expiry → re-race" {
  export FAKE_GH_PROXY_TIME=0.3 FAKE_GHPROXY_NET_TIME=0.9
  gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f" >/dev/null
  export AIBOX_GH_POOL_TTL=0
  # TTL bounds the FILE ranking; the in-process global legitimately outlives it —
  # clear it for this call (prefix assignment) to exercise the stale-file re-race.
  export FAKE_GH_PROXY_MODE=dead FAKE_GHPROXY_NET_BODY=SECOND FAKE_DIRECT_MODE=dead
  local out
  out="$(GH_POOL_ORDER_RAW= gh_pool_fetch "https://raw.githubusercontent.com/o/r/main/f")"
  [ "$out" = "SECOND" ]
}

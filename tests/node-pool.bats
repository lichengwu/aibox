#!/usr/bin/env bats
# node-dist source-pool tests — fully OFFLINE via a fake curl shim.
# The probe call shape: curl -sL -o /dev/null -w '%{size_download} %{time_total}'
# --max-time N <base>/index.json. Routes by URL prefix: nodejs.org / npmmirror.com
# / mirrors.aliyun.com / mirror.example (user). FAKE_<R>_MODE (ok|dead),
# FAKE_<R>_SIZE (default 331021), FAKE_<R>_TIME (default 0.5). FAKE_CURL_LOG
# records each URL for no-probe assertions.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-nodepool.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  mkdir -p "$AIBOX_HOME"
  unset AIBOX_NODE_POOL AIBOX_NODE_MIRROR AIBOX_NODE_PROBE_TIMEOUT \
    FAKE_NODEJS_MODE FAKE_NODEJS_SIZE FAKE_NODEJS_TIME \
    FAKE_NPMMIRROR_MODE FAKE_NPMMIRROR_SIZE FAKE_NPMMIRROR_TIME \
    FAKE_ALIYUN_MODE FAKE_ALIYUN_SIZE FAKE_ALIYUN_TIME \
    FAKE_USERMIRROR_MODE FAKE_USERMIRROR_SIZE FAKE_USERMIRROR_TIME || true
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
    -s | -L | -f) shift ;;
    -[sLf]*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
R="OTHER"
case "$url" in
https://nodejs.org/*) R=NODEJS ;;
https://npmmirror.com/*) R=NPMMIRROR ;;
https://mirrors.aliyun.com/*) R=ALIYUN ;;
https://mirror.example/*) R=USERMIRROR ;;
esac
mode="ok" size=331021 t="0.5"
eval "mode=\${FAKE_${R}_MODE:-ok}"
eval "size=\${FAKE_${R}_SIZE:-331021}"
eval "t=\${FAKE_${R}_TIME:-0.5}"
if [ "$mode" = "dead" ]; then exit 28; fi
case "$fmt" in
*size_download*) printf '%s %s' "$size" "$t" ;;
esac
exit 0
SHIM
  chmod +x "$FAKEBIN/curl"
  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bin/aibox"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "node pool: races candidates, the fastest VALID mirror wins" {
  export FAKE_NODEJS_TIME=2.0 FAKE_NPMMIRROR_TIME=0.5 FAKE_ALIYUN_TIME=0.1
  [ "$(_node_dist_pick)" = "https://mirrors.aliyun.com/nodejs-release" ]
  # every candidate raced
  [ "$(grep -c "index.json" "$FAKE_CURL_LOG")" -ge 3 ]
}

@test "node pool: small fast response (404 page) is rejected by the size floor" {
  # a 500B "fast" response would fake a huge rate — the ≥100KB floor rejects it
  export FAKE_NODEJS_TIME=2.0 FAKE_NPMMIRROR_SIZE=500 FAKE_NPMMIRROR_TIME=0.01 FAKE_ALIYUN_TIME=0.5
  [ "$(_node_dist_pick)" = "https://mirrors.aliyun.com/nodejs-release" ]
}

@test "node pool: direct fastest → stays nodejs.org (default semantics preserved)" {
  export FAKE_NODEJS_TIME=0.1 FAKE_NPMMIRROR_TIME=0.5 FAKE_ALIYUN_TIME=2.0
  [ "$(_node_dist_pick)" = "https://nodejs.org/dist" ]
}

@test "node pool: AIBOX_NODE_POOL=direct → direct only, zero probes" {
  export AIBOX_NODE_POOL=direct
  [ "$(_node_dist_pick)" = "https://nodejs.org/dist" ]
  [ "$(grep -c "index.json" "$FAKE_CURL_LOG")" -eq 0 ]
}

@test "node pool: user mirror joins the race and can win" {
  export AIBOX_NODE_MIRROR="https://mirror.example/node-dist"
  export FAKE_NODEJS_TIME=2.0 FAKE_NPMMIRROR_TIME=0.5 FAKE_ALIYUN_TIME=0.5 FAKE_USERMIRROR_TIME=0.05
  [ "$(_node_dist_pick)" = "https://mirror.example/node-dist" ]
}

@test "node pool: every candidate dead → direct fallback" {
  export FAKE_NODEJS_MODE=dead FAKE_NPMMIRROR_MODE=dead FAKE_ALIYUN_MODE=dead
  [ "$(_node_dist_pick)" = "https://nodejs.org/dist" ]
}

@test "node pool: pool override replaces the shipped mirror list" {
  export AIBOX_NODE_POOL="https://mirror.example/node-dist"
  export FAKE_NODEJS_TIME=2.0 FAKE_USERMIRROR_TIME=0.05
  [ "$(_node_dist_pick)" = "https://mirror.example/node-dist" ]
  # the shipped npmmirror/aliyun were NOT probed
  [ "$(grep -c "mirrors.aliyun.com" "$FAKE_CURL_LOG")" -eq 0 ]
  [ "$(grep -c "npmmirror.com" "$FAKE_CURL_LOG")" -eq 0 ]
}

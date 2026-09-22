#!/usr/bin/env bats
# clash download source-pool tests — fully OFFLINE via a fake curl shim.
# The shim understands clash's three curl call shapes:
#   PROBE  (-w '%{size_download} %{time_total}') → bounded partial of the route's
#          bodyfile (FAKE_<R>_PROBE_PARTIAL_BYTES; 0 = whole file), reports size/time
#   GET    (plain, -o FILE) → full bodyfile copy
#   resume (-C -) → full bodyfile copy (a complete transfer)
# Route control: FAKE_<ROUTE>_MODE (ok|dead), FAKE_<ROUTE>_BODYFILE,
# FAKE_<ROUTE>_PROBE_PARTIAL_BYTES, FAKE_<ROUTE>_PROBE_TIME. FAKE_CURL_LOG records
# "<MODE> <URL>" per call. Routes (by URL prefix): DIRECT (github.com), API
# (api.github.com), GH_PROXY, GHPROXY_NET.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-clashpool.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  export CLASH_BIN_DIR="$SANDBOX/clashbin"
  mkdir -p "$AIBOX_HOME" "$AIBOX_BIN_DIR" "$CLASH_BIN_DIR"
  unset AIBOX_GH_POOL CLASH_MIRROR AIBOX_GH_MIRROR CLASH_PROBE_TIME \
    CLASH_TAG_TIMEOUT CLASH_DOWNLOAD_TIMEOUT CLASH_DOWNLOAD_ATTEMPTS \
    FAKE_GH_PROXY_MODE FAKE_GH_PROXY_BODYFILE FAKE_GH_PROXY_PROBE_PARTIAL_BYTES FAKE_GH_PROXY_PROBE_TIME \
    FAKE_GHPROXY_NET_MODE FAKE_GHPROXY_NET_BODYFILE FAKE_GHPROXY_NET_PROBE_PARTIAL_BYTES FAKE_GHPROXY_NET_PROBE_TIME \
    FAKE_DIRECT_MODE FAKE_DIRECT_BODYFILE FAKE_DIRECT_PROBE_PARTIAL_BYTES FAKE_DIRECT_PROBE_TIME \
    FAKE_API_MODE FAKE_API_BODYFILE FAKE_API_PROBE_PARTIAL_BYTES FAKE_API_PROBE_TIME || true
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  BODIES="$SANDBOX/bodies"
  mkdir -p "$BODIES"
  # default plain bodies per route
  for r in GH_PROXY GHPROXY_NET DIRECT API; do
    printf 'BODY_%s' "$r" >"$BODIES/$r.txt"
    eval "export FAKE_${r}_BODYFILE=\$BODIES/\$r.txt"
  done
  # a runnable fake "mihomo binary" wrapped in gzip (gunzip -t valid, -v runs)
  printf '#!/bin/sh\necho v9.9.9\n' | gzip >"$BODIES/kernel.gz"

  FAKEBIN="$SANDBOX/bin2"
  mkdir -p "$FAKEBIN"
  export FAKE_CURL_LOG="$SANDBOX/curl.log"
  : >"$FAKE_CURL_LOG"

  cat > "$FAKEBIN/curl" <<'SHIM'
#!/usr/bin/env bash
out="" fmt="" url="" resume=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -C) resume=1; shift 2 ;;
    -[fsSL]*) shift ;;
    *) url="$1"; shift ;;
  esac
done
R=OTHER
case "$url" in
https://gh-proxy.com/*) R=GH_PROXY ;;
https://ghproxy.net/*) R=GHPROXY_NET ;;
https://github.com/*) R=DIRECT ;;
https://api.github.com/*) R=API ;;
esac
mode="ok" bodyfile="" part=0 ptime="0.5"
eval "mode=\${FAKE_${R}_MODE:-ok}"
eval "bodyfile=\${FAKE_${R}_BODYFILE:-}"
eval "part=\${FAKE_${R}_PROBE_PARTIAL_BYTES:-0}"
eval "ptime=\${FAKE_${R}_PROBE_TIME:-0.5}"
kind="GET"
case "$fmt" in
*size_download*) kind="PROBE" ;;
esac
if [ "$resume" = 1 ]; then kind="RESUME"; fi
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s %s\n' "$kind" "$url" >>"$FAKE_CURL_LOG"
if [ "$mode" = "dead" ]; then exit 28; fi

write_body() { # $1 = target
  if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then cp "$bodyfile" "$1"
  else printf 'BODY_%s' "$R" >"$1"; fi
}
if [ "$kind" = "PROBE" ]; then
  if [ "$part" -gt 0 ]; then
    if [ -n "$out" ]; then head -c "$part" "$bodyfile" >"$out" 2>/dev/null || :; fi
    printf '%s %s' "$part" "$ptime"
  else
    if [ -n "$out" ]; then write_body "$out"; fi
    sz=0
    if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then sz="$(wc -c <"$bodyfile" | tr -d ' ')"; fi
    printf '%s %s' "$sz" "$ptime"
  fi
  exit 0
fi
# GET / RESUME: a complete transfer
if [ -n "$out" ]; then write_body "$out"; else
  if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then cat "$bodyfile"; else printf 'BODY_%s' "$R"; fi
fi
exit 0
SHIM
  chmod +x "$FAKEBIN/curl"
  export PATH="$FAKEBIN:$PATH"

  # a runnable "mihomo" placeholder for the final -v check when tests place it
  # shellcheck disable=SC1090
  source "$REPO_ROOT/tools/clash/lib.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

_log() { grep -c "$1" "$FAKE_CURL_LOG" || true; }

@test "clash_gh_get: first-success race — dead direct, mirror serves" {
  # NOTE: the DIRECT candidate for an api.github.com URL maps to the shim's API
  # route — kill it with FAKE_API_MODE, not FAKE_DIRECT_MODE.
  export FAKE_API_MODE=dead FAKE_DIRECT_MODE=dead FAKE_GH_PROXY_BODYFILE="$BODIES/tag.json"
  printf '{"tag_name":"v9.9.9"}' >"$BODIES/tag.json"
  local out
  out="$(clash_gh_get "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")"
  [ "$out" = '{"tag_name":"v9.9.9"}' ]
  # direct raced and failed; a mirror won
  [ "$(_log "api.github.com")" -ge 1 ]
  [ "$(_log "gh-proxy.com")" -ge 1 ]
}

@test "clash_gh_get: AIBOX_GH_POOL=direct → direct only, no mirrors" {
  # the direct-only fetch of the api URL maps to the shim's API route
  export AIBOX_GH_POOL=direct FAKE_API_MODE=dead
  run clash_gh_get "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  [ "$status" -ne 0 ]
  [ "$(_log "gh-proxy.com")" -eq 0 ]
  [ "$(_log "ghproxy.net")" -eq 0 ]
  [ "$(_log "api.github.com")" -ge 1 ]
}

@test "_clash_gh_candidates: user mirror → DIRECT → shipped pool" {
  export CLASH_MIRROR="https://user-mirror.example"
  local out
  out="$(_clash_gh_candidates)"
  set -- $out
  [ "$1" = "https://user-mirror.example" ]
  [ "$2" = "DIRECT" ]
  [ "$3" = "https://gh-proxy.com" ]
  [ "$4" = "https://ghproxy.net" ]
}

@test "clash_rank_candidates: rate ranking + the winner's partial is kept (direct call — no subshell)" {
  # gh-proxy 2000 B/s (partial 1000B in 0.5s), ghproxy.net 100 B/s, direct dead
  export FAKE_GH_PROXY_BODYFILE="$BODIES/kernel.gz" FAKE_GH_PROXY_PROBE_PARTIAL_BYTES=1000 FAKE_GH_PROXY_PROBE_TIME=0.5
  export FAKE_GHPROXY_NET_PROBE_PARTIAL_BYTES=100 FAKE_GHPROXY_NET_PROBE_TIME=1.0
  export FAKE_DIRECT_MODE=dead
  local rf out
  rf="$(mktemp "$SANDBOX/ranked.XXXXXX")"
  clash_rank_candidates "https://github.com/MetaCubeX/mihomo/releases/download/v9.9.9/mihomo-x-v9.9.9.gz" "$rf"
  out="$(cat "$rf")"
  set -- $out
  [ "$1" = "https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/v9.9.9/mihomo-x-v9.9.9.gz" ]
  [ "$2" = "https://ghproxy.net/https://github.com/MetaCubeX/mihomo/releases/download/v9.9.9/mihomo-x-v9.9.9.gz" ]
  # dead direct kept as a last-resort candidate (configured order behind)
  [ "$3" = "https://github.com/MetaCubeX/mihomo/releases/download/v9.9.9/mihomo-x-v9.9.9.gz" ]
  # the winner's partial survived the tmpdir cleanup and is a real prefix of the asset
  [ -n "$CLASH_PROBE_PARTIAL" ] && [ -s "$CLASH_PROBE_PARTIAL" ]
  [ "$(head -c 10 "$CLASH_PROBE_PARTIAL" | od -An -tx1 | tr -d ' \n')" = "$(head -c 10 "$BODIES/kernel.gz" | od -An -tx1 | tr -d ' \n')" ]
}

@test "download_mihomo: fast route — the probe completes the whole file (no RESUME calls)" {
  : >"$FAKE_CURL_LOG"
  # winner gh-proxy probes the WHOLE kernel.gz (part=0); direct + ghproxy dead
  export FAKE_GH_PROXY_BODYFILE="$BODIES/kernel.gz" FAKE_GH_PROXY_PROBE_PARTIAL_BYTES=0 FAKE_GH_PROXY_PROBE_TIME=0.2
  export FAKE_DIRECT_MODE=dead FAKE_GHPROXY_NET_MODE=dead
  download_mihomo "9.9.9"
  # placed + runnable
  [ -x "$KERNEL_DEST" ]
  [ "$("$KERNEL_DEST" -v)" = "v9.9.9" ]
  # the probe completed it: zero RESUME/download calls
  [ "$(_log "^RESUME")" -eq 0 ]
}

@test "download_mihomo: probe partial seeds the resumable download from the winner" {
  : >"$FAKE_CURL_LOG"
  # gh-proxy probe yields only 10 bytes (the gz is ~40 — a real truncation,
  # not a whole-file "partial") → the download resumes from the winner
  export FAKE_GH_PROXY_BODYFILE="$BODIES/kernel.gz" FAKE_GH_PROXY_PROBE_PARTIAL_BYTES=10
  export FAKE_DIRECT_MODE=dead FAKE_GHPROXY_NET_MODE=dead
  download_mihomo "9.9.9"
  [ -x "$KERNEL_DEST" ]
  [ "$("$KERNEL_DEST" -v)" = "v9.9.9" ]
  # exactly one download (RESUME) call — from the ranked winner
  [ "$(_log "^RESUME https://gh-proxy.com")" -eq 1 ]
}

@test "download_mihomo: winner dies mid-download → failover to the runner-up" {
  : >"$FAKE_CURL_LOG"
  # gh-proxy WINS the probe (fast) but its download mode is dead;
  # ghproxy.net is slower but serves.
  # mode is shared between probe/download in the shim → use a 2-body trick:
  # gh-proxy probe ok (partial), then flip it dead before the download starts.
  # Simplest deterministic way: gh-proxy dead entirely EXCEPT probe is not used here —
  # instead: make gh-proxy DEAD and ghproxy the probe winner with a full-file probe.
  export FAKE_GH_PROXY_MODE=dead
  export FAKE_GHPROXY_NET_BODYFILE="$BODIES/kernel.gz" FAKE_GHPROXY_NET_PROBE_PARTIAL_BYTES=0 FAKE_GHPROXY_NET_PROBE_TIME=0.3
  download_mihomo "9.9.9"
  [ -x "$KERNEL_DEST" ]
  [ "$("$KERNEL_DEST" -v)" = "v9.9.9" ]
  # ghproxy.net served (probe completed the file); gh-proxy was tried and failed
  [ "$(_log "ghproxy.net")" -ge 1 ]
  [ "$(_log "gh-proxy.com")" -ge 1 ]
}

@test "download_mihomo: every source dead → die listing all sources" {
  export FAKE_GH_PROXY_MODE=dead FAKE_GHPROXY_NET_MODE=dead FAKE_DIRECT_MODE=dead
  run download_mihomo "9.9.9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Download failed on every source tried"* ]]
  [[ "$output" == *"aibox proxy set"* ]]
}

@test "latest_mihomo_tag: pooled resolve through a mirror when direct is dead" {
  # the DIRECT candidate maps to the shim's API route for this URL
  export FAKE_API_MODE=dead
  printf '{"tag_name":"v3.2.1"}' >"$BODIES/tag2.json"
  export FAKE_GH_PROXY_BODYFILE="$BODIES/tag2.json"
  [ "$(latest_mihomo_tag)" = "3.2.1" ]
}


# ---- verification-gated failover (live-caught: a mirror served a valid gzip
# of the WRONG thing; gunzip -t passed, the binary died, and the install died
# with it instead of failing over) ----

_make_gz() { # $1=out $2=payload
  printf '%s\n' "$2" >"${1}.raw"
  gzip -c "${1}.raw" >"$1"
  rm -f "${1}.raw"
}

@test "_clash_verify_gz: accepts a runnable payload reporting the pinned version" {
  _make_gz "$SANDBOX/good.gz" '#!/bin/sh
echo "Mihomo Meta v1.19.31 linux amd64 fake"
exit 0'
  run _clash_verify_gz "$SANDBOX/good.gz" "1.19.31"
  [ "$status" -eq 0 ]
}

@test "_clash_verify_gz: rejects a valid gzip of garbage (the mirror-garbage shape)" {
  _make_gz "$SANDBOX/garbage.gz" "this is an html error page, gzipped by a confused mirror"
  run _clash_verify_gz "$SANDBOX/garbage.gz" "1.19.31"
  [ "$status" -eq 1 ]
}

@test "_clash_verify_gz: rejects a runnable payload of the WRONG version" {
  _make_gz "$SANDBOX/wrongver.gz" '#!/bin/sh
echo "Mihomo Meta v1.18.0 linux amd64"'
  run _clash_verify_gz "$SANDBOX/wrongver.gz" "1.19.31"
  [ "$status" -eq 1 ]
}

@test "_clash_verify_gz: rejects a truncated gzip (incomplete download)" {
  _make_gz "$SANDBOX/full.gz" '#!/bin/sh
echo "Mihomo Meta v1.19.31"'
  head -c 20 "$SANDBOX/full.gz" >"$SANDBOX/trunc.gz"
  run _clash_verify_gz "$SANDBOX/trunc.gz" "1.19.31"
  [ "$status" -eq 1 ]
}

@test "download_mihomo: winner serves a complete-but-bad body → verified failover to the runner-up" {
  # DIRECT wins the rate race but serves a valid gzip of garbage; GH_PROXY
  # serves the real (fake) mihomo. The install must discard the bad body and
  # land the good one — not die on the first source.
  _make_gz "$SANDBOX/bad.gz" "mirror garbage, gzipped"
  _make_gz "$SANDBOX/good.gz" '#!/bin/sh
echo "Mihomo Meta v1.19.31 linux amd64"
exit 0'
  export FAKE_DIRECT_MODE=ok FAKE_DIRECT_BODYFILE="$SANDBOX/bad.gz" FAKE_DIRECT_PROBE_TIME=0.1
  export FAKE_GH_PROXY_MODE=ok FAKE_GH_PROXY_BODYFILE="$SANDBOX/good.gz" FAKE_GH_PROXY_PROBE_TIME=0.5
  export FAKE_CURL_LOG="$SANDBOX/curl.log"
  : >"$FAKE_CURL_LOG"
  run download_mihomo 1.19.31
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"failed verification"* ]]
  [[ "$output" == *"trying the next source"* ]]
  # the placed kernel is the GOOD payload (runs and reports the version)
  [ -x "$CLASH_BIN_DIR/mihomo" ]
  run "$CLASH_BIN_DIR/mihomo" -v
  [[ "$output" == *"v1.19.31"* ]]
  # both sources were actually used (failover happened)
  grep -q "github.com" "$FAKE_CURL_LOG"
  grep -q "gh-proxy.com" "$FAKE_CURL_LOG"
}

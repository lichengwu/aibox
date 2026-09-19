#!/usr/bin/env bats
# dify docker.io source-pool tests — fully OFFLINE via a fake docker shim.
# The shim models: image inspect (cached-set file), pull (per-registry route:
# FAKE_DOCKER_<ROUTE>_MODE ok|dead, FAKE_DOCKER_<ROUTE>_DELAY seconds), rmi,
# tag (recorded to FAKE_DOCKER_TAGLOG), compose config --images
# (FAKE_COMPOSE_IMAGES). FAKE_DOCKER_PULLLOG records "PULL <ref>" per call.
# Routes by ref prefix: docker.1ms.run / docker.m.daocloud.io / dockerproxy.net /
# hub.rat.dev / (bare) DIRECT.

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-dkpool.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/aiboxhome"
  unset AIBOX_DOCKER_POOL AIBOX_DOCKER_MIRROR AIBOX_DOCKER_FORCE_POOL \
    AIBOX_DOCKER_PROBE_TIMEOUT AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT \
    AIBOX_DOCKER_PULL_TIMEOUT AIBOX_DOCKER_POLL \
    FAKE_DOCKER_1MS_MODE FAKE_DOCKER_1MS_DELAY \
    FAKE_DOCKER_DAOCLOUD_MODE FAKE_DOCKER_DAOCLOUD_DELAY \
    FAKE_DOCKER_DOCKERPROXY_MODE FAKE_DOCKER_DOCKERPROXY_DELAY \
    FAKE_DOCKER_RATDEV_MODE FAKE_DOCKER_RATDEV_DELAY \
    FAKE_DOCKER_DIRECT_MODE FAKE_DOCKER_DIRECT_DELAY || true
  export AIBOX_DOCKER_POLL=0.2   # fast watchdog polls
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # deploy root so compose() is satisfied (the fake docker does the parsing)
  mkdir -p "$AIBOX_HOME/apps/dify"
  : >"$AIBOX_HOME/apps/dify/docker-compose.yml"
  export FAKE_COMPOSE_IMAGES="langgenius/dify-api:1.17.1 postgres:15-alpine cr.weaviate.io/semitechnologies/weaviate:1.39.2 nginx:latest"

  export FAKE_DOCKER_CACHED="$SANDBOX/cached"
  export FAKE_DOCKER_TAGLOG="$SANDBOX/taglog"
  export FAKE_DOCKER_PULLLOG="$SANDBOX/pulllog"
  : >"$FAKE_DOCKER_CACHED"
  : >"$FAKE_DOCKER_TAGLOG"
  : >"$FAKE_DOCKER_PULLLOG"

  FAKEBIN="$SANDBOX/bin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/docker" <<'SHIM'
#!/usr/bin/env bash
cmd="${1:-}"; shift
case "$cmd" in
image) # docker image inspect <ref> → cached?
  ref="${2:-}"
  if [ -f "$FAKE_DOCKER_CACHED" ] && grep -qxF "$ref" "$FAKE_DOCKER_CACHED"; then exit 0; fi
  exit 1
  ;;
pull)
  ref="$1"
  r="DIRECT"
  case "$ref" in
  docker.1ms.run/*) r=1MS ;;
  docker.m.daocloud.io/*) r=DAOCLOUD ;;
  dockerproxy.net/*) r=DOCKERPROXY ;;
  hub.rat.dev/*) r=RATDEV ;;
  esac
  printf 'PULL %s\n' "$ref" >>"$FAKE_DOCKER_PULLLOG"
  mode="ok"; delay=0
  eval "mode=\${FAKE_DOCKER_${r}_MODE:-ok}"
  eval "delay=\${FAKE_DOCKER_${r}_DELAY:-0}"
  if [ "$mode" = "dead" ]; then exit 1; fi
  if [ "${delay:-0}" -gt 0 ]; then sleep "$delay"; fi
  printf '%s\n' "$ref" >>"$FAKE_DOCKER_CACHED"
  exit 0
  ;;
rmi)
  ref="${!#}"
  if [ -f "$FAKE_DOCKER_CACHED" ]; then
    grep -vxF "$ref" "$FAKE_DOCKER_CACHED" >"$FAKE_DOCKER_CACHED.tmp" 2>/dev/null || true
    mv "$FAKE_DOCKER_CACHED.tmp" "$FAKE_DOCKER_CACHED"
  fi
  exit 0
  ;;
tag)
  printf '%s %s\n' "$1" "$2" >>"$FAKE_DOCKER_TAGLOG"
  printf '%s\n' "$2" >>"$FAKE_DOCKER_CACHED"
  exit 0
  ;;
compose)
  prev=""
  for a in "$@"; do
    if [ "$prev" = "config" ] && [ "$a" = "--images" ]; then
      # shellcheck disable=SC2086
      printf '%s\n' ${FAKE_COMPOSE_IMAGES:-}
      exit 0
    fi
    prev="$a"
  done
  exit 0
  ;;
esac
exit 1
SHIM
  chmod +x "$FAKEBIN/docker"
  export PATH="$FAKEBIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/tools/dify/lib.sh"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

_pulls() { grep -c "PULL" "$FAKE_DOCKER_PULLLOG" || true; }
_mirror_pulls() { grep -cE "PULL (docker\.[0-9a-z.]+|dockerproxy|hub\.rat)" "$FAKE_DOCKER_PULLLOG" || true; }

@test "_dk_is_dockerio: docker.io vs foreign-registry refs (incl. the explicit docker.io/ form)" {
  _dk_is_dockerio "docker.io/library/mysql:8.0"
  _dk_is_dockerio "langgenius/dify-api:1.17.1" && _dk_is_dockerio "postgres:15-alpine" \
    && _dk_is_dockerio "nginx:latest" \
    && ! _dk_is_dockerio "cr.weaviate.io/semitechnologies/weaviate:1.39.2" \
    && ! _dk_is_dockerio "localhost:5000/foo"
}

@test "_dk_pool_ref: official images get the library/ prefix; docker.io/ prefix is stripped" {
  [ "$(_dk_pool_ref docker.1ms.run "docker.io/library/mysql:8.0")" = "docker.1ms.run/library/mysql:8.0" ]
  [ "$(_dk_pool_ref docker.1ms.run "postgres:15-alpine")" = "docker.1ms.run/library/postgres:15-alpine" ]
  [ "$(_dk_pool_ref docker.1ms.run "langgenius/dify-api:1.17.1")" = "docker.1ms.run/langgenius/dify-api:1.17.1" ]
}

@test "docker_pool_prepull: everything cached → no-op, zero docker calls" {
  printf 'langgenius/dify-api:1.17.1\npostgres:15-alpine\ncr.weaviate.io/semitechnologies/weaviate:1.39.2\nnginx:latest\n' >>"$FAKE_DOCKER_CACHED"
  run docker_pool_prepull langgenius/dify-api:1.17.1 postgres:15-alpine cr.weaviate.io/semitechnologies/weaviate:1.39.2 nginx:latest
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 0 ]
}

@test "docker_pool_prepull: foreign-registry uncached images are skipped (direct-only)" {
  run docker_pool_prepull cr.weaviate.io/semitechnologies/weaviate:1.39.2
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 0 ]
}

@test "docker_pool_prepull: AIBOX_DOCKER_POOL=direct → disabled, zero calls" {
  export AIBOX_DOCKER_POOL=direct
  run docker_pool_prepull langgenius/dify-api:1.17.1
  [ "$status" -eq 0 ]
  [ "$(_pulls)" -eq 0 ]
}

@test "docker_pool_prepull: direct route healthy → zero-overhead skip (probe only, no mirror pulls)" {
  export FAKE_DOCKER_DIRECT_MODE=ok
  run docker_pool_prepull langgenius/dify-api:1.17.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"direct daemon route OK"* ]]
  # the direct probe pulled hello-world (honest probe: rmi + pull)
  grep -q "^PULL hello-world$" "$FAKE_DOCKER_PULLLOG"
  [ "$(_mirror_pulls)" -eq 0 ]
}

@test "docker_pool_prepull: direct dead + one mirror alive → ranked pre-pull + tag" {
  export FAKE_DOCKER_DIRECT_MODE=dead FAKE_DOCKER_1MS_MODE=ok
  export FAKE_DOCKER_DAOCLOUD_MODE=dead FAKE_DOCKER_DOCKERPROXY_MODE=dead FAKE_DOCKER_RATDEV_MODE=dead
  run docker_pool_prepull langgenius/dify-api:1.17.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"engaging the mirror pool"* ]]
  [[ "$output" == *"pulled langgenius/dify-api:1.17.1 via docker.1ms.run"* ]]
  # pull via mirror + tag to the official name
  grep -q "^PULL docker.1ms.run/langgenius/dify-api:1.17.1$" "$FAKE_DOCKER_PULLLOG"
  grep -q "^docker.1ms.run/langgenius/dify-api:1.17.1 langgenius/dify-api:1.17.1$" "$FAKE_DOCKER_TAGLOG"
  # the official ref is now cached (compose up finds it locally)
  grep -qxF "langgenius/dify-api:1.17.1" "$FAKE_DOCKER_CACHED"
}

@test "docker_pool_prepull: probe winner dead for the image → failover to the runner-up" {
  # 1ms wins the ranking (probe: hello-world pulls fine) but its pull of the
  # REAL image is intercepted as dead by a wrapper → the pool must fail over to
  # daocloud and tag from there.
  export AIBOX_DOCKER_POOL="docker.1ms.run docker.m.daocloud.io"
  export FAKE_DOCKER_DIRECT_MODE=dead
  export FAKE_DOCKER_REAL="$FAKEBIN/docker.real"
  W="$FAKEBIN/wrap"
  mkdir -p "${W}"
  cat >"${W}/docker" <<'EOF'
#!/usr/bin/env bash
# wrapper: fail 1ms pulls of refs containing dify-api (the real image);
# everything else goes to the real shim underneath.
if [ "${1:-}" = "pull" ] \
  && [ "${2:-}" != "${2%%*dify-api*}" ] \
  && [ "${2:-}" != "${2%%docker.1ms.run/*}" ]; then
  exit 1
fi
exec "${FAKE_DOCKER_REAL}" "$@"
EOF
  chmod +x "${W}/docker"
  mv "$FAKEBIN/docker" "$FAKE_DOCKER_REAL"
  # the wrapper dir MUST lead the PATH (the real shim moved out of $FAKEBIN)
  export PATH="${W}:$PATH"
  run docker_pool_prepull langgenius/dify-api:1.17.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"mirror docker.1ms.run failed for langgenius/dify-api:1.17.1"* ]]
  [[ "$output" == *"pulled langgenius/dify-api:1.17.1 via docker.m.daocloud.io"* ]]
  grep -q "^docker.m.daocloud.io/langgenius/dify-api:1.17.1 langgenius/dify-api:1.17.1$" "$FAKE_DOCKER_TAGLOG"
}

@test "docker_pool_prepull: every mirror dead → warn, compose tries direct, rc 0" {
  export FAKE_DOCKER_DIRECT_MODE=dead FAKE_DOCKER_1MS_MODE=dead FAKE_DOCKER_DAOCLOUD_MODE=dead
  export FAKE_DOCKER_DOCKERPROXY_MODE=dead FAKE_DOCKER_RATDEV_MODE=dead
  run docker_pool_prepull langgenius/dify-api:1.17.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"every mirror probe failed"* ]]
}

@test "docker_pool_prepull: ranking picks the faster mirror (delay 0 vs 2s)" {
  export FAKE_DOCKER_DIRECT_MODE=dead
  export AIBOX_DOCKER_POOL="docker.1ms.run docker.m.daocloud.io"
  export FAKE_DOCKER_1MS_DELAY=0 FAKE_DOCKER_DAOCLOUD_DELAY=2
  run docker_pool_prepull langgenius/dify-api:1.17.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulled langgenius/dify-api:1.17.1 via docker.1ms.run"* ]]
  # the real image pull went to the ranked winner
  grep -q "^PULL docker.1ms.run/langgenius/dify-api:1.17.1$" "$FAKE_DOCKER_PULLLOG"
}

@test "compose_images: lists refs from the (mode-aware) compose definition" {
  local imgs
  imgs="$(compose_images)"
  printf '%s\n' "$imgs" | grep -q "^langgenius/dify-api:1.17.1$"
  printf '%s\n' "$imgs" | grep -q "^cr.weaviate.io/semitechnologies/weaviate:1.39.2$"
}

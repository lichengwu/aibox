#!/usr/bin/env bash
# aibox docker test harness — the full suite, reproducibly, on any machine with
# docker. Run from anywhere:
#
#   tests/docker/run.sh                    # build + the whole default matrix
#   tests/docker/run.sh --fast-only        # skip the non-root pass
#   tests/docker/run.sh --integration      # also run tests/integration/*.bats
#   tests/docker/run.sh --no-build         # reuse the existing image
#   tests/docker/run.sh --shell            # drop into the container instead
#
# The default matrix mirrors what CI enforces plus the passes CI cannot localize:
#   1. gates        bash -n · shellcheck (error) · gotcha #1/#8 · module conformance · port conflicts
#   2. fast suite   bats tests/*.bats                       (root)
#   3. root parity  bats tests/*.bats                       (non-root user `tester`)
#   4. integration  bats tests/integration/*.bats           (--integration only)
# bash 3.2 runtime is NOT reproducible in this image (it predates the distro) —
# the macOS CI job `macos-bash32` remains the authoritative 3.2 gate; this harness
# runs the static 3.2-compat checks the validator provides.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${AIBOX_TEST_IMAGE:-aibox-test:local}"
FAST_ONLY=0; INTEGRATION=0; NO_BUILD=0; SHELL_MODE=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fast-only)   FAST_ONLY=1; shift ;;
    --integration) INTEGRATION=1; shift ;;
    --no-build)    NO_BUILD=1; shift ;;
    --shell)       SHELL_MODE=1; shift ;;
    --keep)        KEEP=1; shift ;;
    --image)       IMAGE="${2:-}"; [ -n "$IMAGE" ] || { echo "--image needs a tag" >&2; exit 2; }; shift 2 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

log()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m  %s\n' "$*"; }
bad()  { printf '\033[31m✗\033[0m  %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { bad "docker is required"; exit 3; }
docker info >/dev/null 2>&1 || { bad "the docker daemon is not reachable"; exit 3; }

if [ "$NO_BUILD" != 1 ]; then
  step "build image ${IMAGE}"
  docker build -q -t "$IMAGE" "$REPO_ROOT/tests/docker" >/dev/null
  ok "image built"
fi

if [ "$SHELL_MODE" = 1 ]; then
  exec docker run --rm -it -v "$REPO_ROOT":/repo -w /repo "$IMAGE" bash
fi

FAILED=""
run_phase() { # $1=label $2=user $3=shell command
  local label="$1" user="$2" cmd="$3"
  step "$label"
  local rc=0
  if [ "$user" = "root" ]; then
    docker run --rm -v "$REPO_ROOT":/repo -w /repo "$IMAGE" bash -c "$cmd" || rc=$?
  else
    docker run --rm -u "$user" -e HOME=/home/tester -v "$REPO_ROOT":/repo -w /repo "$IMAGE" bash -c "$cmd" || rc=$?
  fi
  if [ "$rc" = "0" ]; then ok "${label}"; else bad "${label} (exit ${rc})"; FAILED="${FAILED} ${label}"; fi
  return 0
}

# ---- 1. gates (the same checks lint.yml enforces, minus the macOS-only job) ----
GATES='
set -e
files=$(git ls-files | grep -E "\.sh$|^(bin/aibox|tools/[^/]+/cli/(openmaic|windmill))$")
fail=0
for f in $files; do bash -n "$f" || { echo "bash -n FAIL: $f"; fail=1; }; done
echo "bash -n: $(echo "$files" | wc -l | tr -d " ") files OK"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck --severity=error --external-sources --shell=bash $files && echo "shellcheck(error): OK"
fi
grep -nP "\$[A-Za-z_][A-Za-z0-9_]*[，。、；：！？（）「」]" $(git ls-files "*.sh" bin/aibox) | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#" && { echo "gotcha #1 found"; fail=1; } || echo "gotcha #1: clean"
scripts/validate-module.sh --all
exit $fail
'
run_phase "gates: syntax · shellcheck · gotchas · module conformance" root "$GATES"

# ---- 2./3. the fast suite, twice: root and non-root -------------------------
run_phase "fast suite (root)" root 'bats tests/*.bats'
if [ "$FAST_ONLY" != 1 ]; then
  run_phase "fast suite (non-root — CI parity, catches root-masked bugs)" tester 'bats tests/*.bats'
fi

# ---- 4. integration (opt-in): the two SAFE suites, against the HOST daemon ----
# base-profiles (unique itta/ittb profiles, snapshot-safe teardown) and
# preflight-check (read-only `aibox check`) are what CI's integration.yml runs.
# The flag-gated suites (pi-web: real service-manager side effects; windmill: ~6GB
# pulls) are deliberately excluded — run those on a throwaway host.
if [ "$INTEGRATION" = 1 ]; then
  if [ ! -S /var/run/docker.sock ]; then
    bad "--integration needs a docker daemon on this host (/var/run/docker.sock)"
    FAILED="${FAILED} integration(no socket)"
  else
    step "integration suite (host daemon via mounted socket)"
    docker run --rm -v "$REPO_ROOT":/repo -w /repo -v /var/run/docker.sock:/var/run/docker.sock \
      "$IMAGE" bash -c 'bats tests/integration/base-profiles.bats tests/integration/preflight-check.bats' \
      || { bad "integration suite"; FAILED="${FAILED} integration"; }
  fi
  step "flag-gated integration suites"
  log "  not run: pi-web-profiles (AIBOX_IT_PIWEB=1) / windmill-consumer (AIBOX_IT_WINDMILL=1)"
  log "  — real service-manager side effects and ~6GB image pulls; throwaway host only"
else
  step "integration suite"
  log "  skipped (opt-in: --integration) — needs a docker daemon on the host"
fi

step "summary"
if [ -n "$FAILED" ]; then
  bad "FAILED phases:${FAILED}"
  exit 1
fi
ok "ALL GREEN — image ${IMAGE}"
[ "$KEEP" = 1 ] || log "  (image kept: ${IMAGE}; remove with: docker rmi ${IMAGE})"
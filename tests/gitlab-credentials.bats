#!/usr/bin/env bats
# GitLab credentials — deterministic root password (seeded GITLAB_ROOT_PASSWORD)
# + live verification, replacing the fragile 24h initial_root_password file
# mechanism (the file's password is rewritten by every reconfigure while the
# DB keeps the first-seed one — live-caught on a deploy host).
# Docker is a function override (export -f) so the svc.sh subprocess sees it.
# NOTE: AIBOX_HOME is exported by test_helper's setup() — resolve the deploy
# root INSIDE each test (file-level vars evaluate before setup runs).

load test_helper

GITLAB_LIB="$REPO_ROOT/tools/gitlab/lib.sh"
GITLAB_SVC="$REPO_ROOT/tools/gitlab/svc.sh"
GITLAB_INSTALL="$REPO_ROOT/tools/gitlab/install.sh"

_write_env() { # $1 = extra lines (may be empty)
  local root
  root="$AIBOX_HOME/apps/gitlab"
  mkdir -p "$root"
  {
    echo "# gitlab deploy env — test"
    echo "GITLAB_IMAGE=gitlab/gitlab-ce:19.2.6-ce.0"
    echo "GITLAB_HTTP_PORT=8929"
    echo "GITLAB_SSH_PORT=8922"
    printf '%s\n' "$1"
  } >"$root/.env"
}

_envf() { printf '%s' "$AIBOX_HOME/apps/gitlab/.env"; }

# fake docker: routes `exec ... gitlab-rails runner` probes to $FAKE_VERIFY
# (true/false/empty+rc1); everything else succeeds silently.
_fake_docker() {
  if [ "$1" = "exec" ] && case " $* " in *" gitlab-rails runner "*) true ;; *) false ;; esac; then
    [ -n "${FAKE_VERIFY:-}" ] || return 1
    printf '%s\n' "${FAKE_VERIFY}"
    return 0
  fi
  return 0
}

@test "ensure_root_password: appends a generated seed when missing, never rotates" {
  _write_env ""
  run bash -c ". '$GITLAB_LIB'; ensure_root_password"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^GITLAB_ROOT_PASSWORD=[0-9a-f]\{32\}$' "$(_envf)" || false
  seeded="$(sed -n 's/^GITLAB_ROOT_PASSWORD=//p' "$(_envf)")"
  run bash -c ". '$GITLAB_LIB'; ensure_root_password"
  [ "$(sed -n 's/^GITLAB_ROOT_PASSWORD=//p' "$(_envf)")" = "$seeded" ] || false
}

@test "ensure_root_password: no .env → no-op, exit 0" {
  mkdir -p "$AIBOX_HOME/apps/gitlab"
  run bash -c ". '$GITLAB_LIB'; ensure_root_password"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "install.sh: fresh .env carries the seeded GITLAB_ROOT_PASSWORD" {
  docker() { return 0; }
  export -f docker
  run bash "$GITLAB_INSTALL"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^GITLAB_ROOT_PASSWORD=' "$(_envf)" || false
}

@test "install.sh: legacy .env without the key gets it appended, existing keys kept" {
  _write_env "GITLAB_PUMA_WORKERS=3"
  docker() { return 0; }
  export -f docker
  run bash "$GITLAB_INSTALL"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q '^GITLAB_PUMA_WORKERS=3$' "$(_envf)" || false
  grep -q '^GITLAB_ROOT_PASSWORD=' "$(_envf)" || false
}

@test "compose: passes GITLAB_ROOT_PASSWORD into the container environment" {
  grep -q 'GITLAB_ROOT_PASSWORD' "$REPO_ROOT/tools/gitlab/docker-compose.yml" || false
}

@test "credentials: shows the seeded password and verifies it live (probe true)" {
  _write_env "GITLAB_ROOT_PASSWORD=abc123def456abc123def456abc123de"
  FAKE_VERIFY=true
  export FAKE_VERIFY
  docker() { _fake_docker "$@"; }
  export -f docker _fake_docker
  run bash "$GITLAB_SVC" credentials
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"password: abc123def456abc123def456abc123de"* ]] || false
  [[ "$output" == *"verified"* ]] || false
  [[ "$output" != *"reset"* ]] || false
}

@test "credentials: invalid password → the modern reset recipe (bracket syntax)" {
  _write_env "GITLAB_ROOT_PASSWORD=stalepassword0000000000000000000"
  FAKE_VERIFY=false
  export FAKE_VERIFY
  docker() { _fake_docker "$@"; }
  export -f docker _fake_docker
  run bash "$GITLAB_SVC" credentials
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"INVALID"* ]] || false
  [[ "$output" == *"gitlab:password:reset[root]"* ]] || false
}

@test "credentials: probe fails (container down / rails busy) → unverified, no false verdict" {
  _write_env "GITLAB_ROOT_PASSWORD=abc123def456abc123def456abc123de"
  FAKE_VERIFY=""
  export FAKE_VERIFY
  docker() { _fake_docker "$@"; }
  export -f docker _fake_docker
  run bash "$GITLAB_SVC" credentials
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not verify"* ]] || false
  [[ "$output" != *"INVALID"* ]] || false
}

@test "start: seeds the password before compose up (legacy .env self-heal)" {
  _write_env ""
  docker() { return 0; }
  export -f docker
  # nothing listens on 8929 → the start loop runs to its 1s timeout; we only
  # need the seed side effect (ensure_root_password runs BEFORE compose up)
  GITLAB_START_TIMEOUT=1 run bash "$GITLAB_SVC" start
  grep -q '^GITLAB_ROOT_PASSWORD=' "$(_envf)" || false
}

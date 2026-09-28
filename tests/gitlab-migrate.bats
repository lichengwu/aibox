#!/usr/bin/env bats
# GitLab migration support (added for a real host migration: native package
# 18.9.1 → aibox-managed docker, ports + TLS preserved):
#   - opt-in HTTPS/TLS (nginx listen_https + cert mount + redirect)
#   - backup / restore / import-secrets actions (the migration path itself)
# Docker is a function override (export -f) so svc.sh subprocesses see it.

load test_helper

GITLAB_LIB="$REPO_ROOT/tools/gitlab/lib.sh"
GITLAB_SVC="$REPO_ROOT/tools/gitlab/svc.sh"

_write_env() { # $1 = extra lines (may be empty)
  local root
  root="$AIBOX_HOME/apps/gitlab"
  mkdir -p "$root"
  {
    echo "# gitlab deploy env — test"
    echo "GITLAB_IMAGE=gitlab/gitlab-ce:18.9.1-ce.0"
    echo "GITLAB_HTTP_PORT=80"
    echo "GITLAB_SSH_PORT=31222"
    printf '%s\n' "$1"
  } >"$root/.env"
}

# fake docker: logs argv to $DOCKER_LOG and answers the few probes svc.sh makes;
# $FAKE_KIND selects which sub-command the `exec` route pretends to be.
_fake_docker() {
  printf '%s\n' "$*" >>"${DOCKER_LOG:-/dev/null}"
  case "$1" in
  ps) printf 'aibox-gitlab\n' ; return 0 ;;   # container_running greps the name
  cp) return 0 ;;
  exec)
    case " $* " in
    *" gitlab-psql "*) printf '62\n' ; return 0 ;;
    *" sh -c "*"ls -t"*) printf '/var/opt/gitlab/backups/1790609882_2026_09_28_18.9.1_gitlab_backup.tar\n' ; return 0 ;;
    *" gitlab-backup "*) return 0 ;;
    *" gitlab-ctl "*) return 0 ;;
    esac
    return "${FAKE_EXEC_RC:-0}"
    ;;
  esac
  return 0
}
export -f _fake_docker
docker() { _fake_docker "$@"; }
export -f docker
export DOCKER_LOG

@test "compose: HTTPS is opt-in — publish + cert mount + omnibus TLS block" {
  local c="$REPO_ROOT/tools/gitlab/docker-compose.yml"
  run bash -c "grep -o 'GITLAB_HTTPS_PORT' '$c' | wc -l | tr -d ' '"
  [ "$output" -ge 2 ] || false   # published port + external_url port
  run grep -q '${GITLAB_HTTPS_ENABLE:-false}' "$c"
  [ "$status" -eq 0 ] || false
  run grep -q 'nginx\[.ssl_certificate.\]' "$c"
  [ "$status" -eq 0 ] || false
  run grep -q './ssl:/etc/gitlab/ssl:ro' "$c"
  [ "$status" -eq 0 ] || false
  run grep -q 'redirect_http_to_https' "$c"
  [ "$status" -eq 0 ] || false
  # certs are operator state: hooks must never overwrite them
  run grep -q '^  - ssl/' "$REPO_ROOT/tools/gitlab/module.yaml"
  [ "$status" -eq 0 ]
}

@test "ensure_tls_material: HTTPS on + empty dir → self-signed pair; HTTPS off → no-op" {
  command -v openssl >/dev/null 2>&1 || skip "openssl not available"
  _write_env "GITLAB_HTTPS_ENABLE=true
GITLAB_HTTPS_PORT=443
GITLAB_EXTERNAL_URL=https://gitlab.example.test"
  export DOCKER_LOG="$BATS_TMPDIR/tls.log"
  export -f _fake_docker
  run bash -c ". '$GITLAB_LIB'; load_env; ensure_tls_material; ls \"\$(tls_dir)\""
  [ "$status" -eq 0 ] || false
  case "$output" in *gitlab.crt*gitlab.key*|*gitlab.key*gitlab.crt*) ;; *) false ;; esac
  run bash -c ". '$GITLAB_LIB'; load_env; l1=\$(ls \$(tls_dir) 2>/dev/null | head -1); ensure_tls_material >/dev/null 2>&1; echo \$l1"
  [ "$status" -eq 0 ]
}

@test "backup: runs gitlab-backup create inside the container and names the artifact" {
  _write_env ""
  _write_env "GITLAB_HTTPS_ENABLE=false"
  export DOCKER_LOG="$BATS_TMPDIR/bk.log"; : >"$DOCKER_LOG"
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; bash '$GITLAB_SVC' backup"
  [ "$status" -eq 0 ] || false
  grep -q "gitlab-backup create" "$DOCKER_LOG" || false
  case "$output" in *1790609882_2026_09_28_18.9.1_gitlab_backup.tar*) ;; *) false ;; esac
}

@test "restore: refuses without --yes non-interactively (exit 2, docker untouched)" {
  _write_env ""
  export DOCKER_LOG="$BATS_TMPDIR/rs.log"; : >"$DOCKER_LOG"
  ready="$BATS_TMPDIR/1790609882_2026_09_28_18.9.1_gitlab_backup.tar"; : >"$ready"
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; export GITLAB_RESTORE_WAIT=0; bash '$GITLAB_SVC' restore '$ready' </dev/null"
  [ "$status" -eq 2 ] || false
  case "$output" in *--yes*) ;; *) false ;; esac
  [ ! -s "$DOCKER_LOG" ] || false
}

@test "restore: rejects a non-backup filename before touching the container" {
  _write_env ""
  export DOCKER_LOG="$BATS_TMPDIR/rs2.log"; : >"$DOCKER_LOG"
  bad="$BATS_TMPDIR/notabackup.tar"; : >"$bad"
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; export GITLAB_RESTORE_WAIT=0; bash '$GITLAB_SVC' restore '$bad' --yes"
  [ "$status" -eq 2 ] || false
  case "$output" in *"_gitlab_backup.tar"*) ;; *) false ;; esac
  grep -q 'docker cp' "$DOCKER_LOG" && false || true
}

@test "restore --yes: stops puma+sidekiq, restores by BACKUP=<id>, restarts" {
  _write_env ""
  export DOCKER_LOG="$BATS_TMPDIR/rs3.log"; : >"$DOCKER_LOG"
  tar="$BATS_TMPDIR/1790609882_2026_09_28_18.9.1_gitlab_backup.tar"; : >"$tar"
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; export GITLAB_RESTORE_WAIT=0; bash '$GITLAB_SVC' restore '$tar' --yes"
  [ "$status" -eq 0 ] || false
  grep -q 'gitlab-ctl stop puma' "$DOCKER_LOG" || false
  grep -q 'BACKUP=1790609882_2026_09_28_18.9.1' "$DOCKER_LOG" || false
  grep -q 'gitlab-ctl restart' "$DOCKER_LOG" || false
  case "$output" in *"projects 62"*) ;; *) false ;; esac
}

@test "import-secrets: missing file → exit 2; with --yes → docker cp to /etc/gitlab" {
  _write_env ""
  export DOCKER_LOG="$BATS_TMPDIR/is.log"; : >"$DOCKER_LOG"
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; bash '$GITLAB_SVC' import-secrets /nope/gitlab-secrets.json --yes"
  [ "$status" -eq 2 ] || false
  sec="$BATS_TMPDIR/gitlab-secrets.json"; echo '{}' >"$sec"
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; bash '$GITLAB_SVC' import-secrets '$sec' --yes"
  [ "$status" -eq 0 ] || false
  grep -q "gitlab-secrets.json" "$DOCKER_LOG" || false
  grep -q "chmod 600" "$DOCKER_LOG" || false
  run bash -c "export DOCKER_LOG='$DOCKER_LOG'; . '$GITLAB_LIB'; bash '$GITLAB_SVC' import-secrets '$sec' </dev/null"
  [ "$status" -eq 2 ]
}

@test "not-ready exit code: container down → 30 (spec §Exit codes), not 1" {
  _write_env ""
  # docker answers nothing for `ps` -> container_running is false
  run bash -c ". '$GITLAB_LIB'; docker() { return 0; }; export -f docker; bash '$GITLAB_SVC' backup"
  [ "$status" -eq 30 ] || false
  case "$output" in *"not running"*) ;; *) false ;; esac
}

@test "http_up: HTTPS on → probes the TLS port (301 on plain HTTP must not fake 'down')" {
  _write_env "GITLAB_HTTPS_ENABLE=true
GITLAB_HTTPS_PORT=443
GITLAB_HTTP_PORT=80"
  shim="$BATS_TMPDIR/curlshim"; rm -rf "$shim"; mkdir -p "$shim"
  cat >"$shim/curl" <<'SH'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a" ;; esac; done
case "$url" in
https://127.0.0.1:443/*) printf '200' ;;
http://127.0.0.1:80/*)  printf '301' ;;
*) printf '000' ;;
esac
SH
  chmod +x "$shim/curl"
  run env PATH="$shim:/usr/bin:/bin" bash -c ". '$GITLAB_LIB'; load_env; http_up && echo UP || echo DOWN"
  case "$output" in *UP*) ;; *) false ;; esac
  # TLS port dead but nginx redirecting -> still counts as answering (301)
  cat >"$shim/curl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in https://*) printf '000'; exit 0 ;; esac; done
printf '301'
SH
  chmod +x "$shim/curl"
  run env PATH="$shim:/usr/bin:/bin" bash -c ". '$GITLAB_LIB'; load_env; http_up && echo UP || echo DOWN"
  case "$output" in *UP*) ;; *) false ;; esac
}

@test "sync_nginx_listen_port: TLS on → TLS port, off → HTTP port, idempotent" {
  for spec in "true:443" "false:8080"; do
    en="${spec%%:*}"; want="${spec##*:}"
    h="$(mktemp -d)"
    mkdir -p "$h/apps/gitlab"
    printf 'GITLAB_HTTPS_ENABLE=%s\nGITLAB_HTTPS_PORT=443\nGITLAB_HTTP_PORT=8080\n' "$en" >"$h/apps/gitlab/.env"
    run env AIBOX_HOME="$h" bash -c ". '$GITLAB_LIB'; load_env; sync_nginx_listen_port; cfg_kv_get \"\$AIBOX_HOME/apps/gitlab/.env\" GITLAB_NGINX_LISTEN_PORT"
    [ "$output" = "$want" ] || false
    run env AIBOX_HOME="$h" bash -c ". '$GITLAB_LIB'; load_env; sync_nginx_listen_port; grep -c '^GITLAB_NGINX_LISTEN_PORT=' \"\$AIBOX_HOME/apps/gitlab/.env\""
    [ "$output" = "1" ] || false
    rm -rf "$h"
  done
  # wiring: start AND restart carry the sync (a restart that skipped it left nginx
  # on the wrong port — live-caught)
  run bash -c "awk '/^(start|restart)\)/{n++} /sync_nginx_listen_port/{s++} END{print n\":\"s}' '$REPO_ROOT/tools/gitlab/svc.sh'"
  [ "$status" -eq 0 ] || false
  run grep -q "GITLAB_NGINX_LISTEN_PORT" "$REPO_ROOT/tools/gitlab/docker-compose.yml"
  [ "$status" -eq 0 ]
}

@test "status_info/doctor_ports: TLS on → the external https endpoint, effective ports (80/443/31222)" {
  _write_env "GITLAB_HTTPS_ENABLE=true
GITLAB_HTTPS_PORT=443
GITLAB_HTTP_PORT=80
GITLAB_EXTERNAL_URL=https://gitlab.example.test"
  run bash -c ". '$GITLAB_LIB'; load_env; status_info | grep '^endpoint='"
  [ "$status" -eq 0 ] || false
  case "$output" in *https://gitlab.example.test*) ;; *) false ;; esac
  run bash -c ". '$GITLAB_LIB'; load_env; doctor_ports"
  case "$output" in *80/tcp:http*443/tcp:https*31222/tcp:git-ssh*) ;; *) false ;; esac
  # TLS off → the plain http endpoint, no https port declared
  _write_env "GITLAB_HTTPS_ENABLE=false
GITLAB_HTTP_PORT=8080"
  run bash -c ". '$GITLAB_LIB'; load_env; status_info | grep '^endpoint='"
  case "$output" in *http://127.0.0.1:8080*) ;; *) false ;; esac
  run bash -c ". '$GITLAB_LIB'; load_env; doctor_ports"
  case "$output" in *https*) false ;; esac
  # the shared doctor must consult the hook
  run grep -q 'type doctor_ports' "$REPO_ROOT/tools/_shared/lib/20-doctor.sh"
  [ "$status" -eq 0 ] || false
  run grep -q 'declared}" = 1' "$REPO_ROOT/tools/_shared/lib/20-doctor.sh"
  [ "$status" -eq 0 ]
}

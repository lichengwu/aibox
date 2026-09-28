# gitlab module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/gitlab.

MODULE_NAME="gitlab"
CONTAINER_NAME="aibox-gitlab"
DEFAULT_HTTP_PORT="31110"
DEFAULT_SSH_PORT="31222"
DEFAULT_IMAGE="gitlab/gitlab-ce:19.2.6-ce.0"
# Shared library (output helpers + docker.io pool): repo tools/_shared/common.sh,
# shipped per-module as _common.sh (module.yaml includes: [common]).
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache layout (aibox install): _common.sh sits next to lib.sh. Repo layout
# (direct execution / bats): ../_shared/common.sh. Cache wins when present.
LIB_COMMON="${LIB_SELF}/_common.sh"
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"
# shellcheck disable=SC1091
. "${LIB_COMMON}"
# a hook; direct execution (bats, a hook run by hand) uses the ONE shared reader.
MODULE_VERSION="${AIBOX_MODULE_VERSION:-$(meta_version "${LIB_SELF}/module.yaml")}"

# Deploy root per the aibox convention ($AIBOX_HOME/apps/<name>; module-spec
# §Deploy directory). The guard is mandatory: systemd service contexts may
# lack HOME, and path derivation must fail loudly rather than produce "/apps/...".
deploy_root() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "$root" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  # profile-scoped (spec §Deploy root): two profiles must never share one deploy
  # .env/compose. The default profile keeps the unsuffixed path (no migration).
  printf '%s' "${root}/apps/${MODULE_NAME}$(profile_suffix)"
}

# Load the deploy .env (KEY=VALUE, written by the install hook) into the
# environment so hooks/svc see GITLAB_HTTP_PORT / GITLAB_IMAGE / etc.
load_env() {
  local envf
  envf="$(deploy_root)/.env"
  [ -f "$envf" ] || return 0
  # Parsed, not executed: data is not code (a corrupted .env must never run).
  cfg_kv_load_export "$envf" 
}

# Deterministic root password (replaces the fragile initial_root_password file
# mechanism — live-caught on a deploy host: the file's password is REGENERATED
# by every reconfigure while the DB keeps the first-seed one, so the file
# becomes a lie; official docker docs: the file is best-effort only).
# Model: install seeds GITLAB_ROOT_PASSWORD into the deploy .env; the compose
# passes it to the container where ENV wins over random generation (omnibus
# source: initial_root_password = ENV['GITLAB_ROOT_PASSWORD'] || random).
# It APPLIES at first boot with fresh volumes; volumes seeded earlier ignore
# it — `credentials` verifies against the live account and says so.
ensure_root_password() { # seeds GITLAB_ROOT_PASSWORD into the .env when missing OR empty (never rotates a real value)
  local envf pw cur tmp
  envf="$(deploy_root)/.env"
  [ -f "${envf}" ] || return 0
  cur="$(sed -n 's/^GITLAB_ROOT_PASSWORD=//p' "${envf}" | head -1)"
  [ -n "${cur}" ] && return 0
  # missing OR EMPTY: an empty value would seed a BLANK root password (Ruby
  # treats "" as truthy in ENV['GITLAB_ROOT_PASSWORD'] || random — the env
  # still wins, with nothing in it). Strip the blank line, then (re)seed so
  # exactly ONE key line remains.
  if grep -q '^GITLAB_ROOT_PASSWORD=$' "${envf}" 2>/dev/null; then
    tmp="$(mktemp "${envf}.tmp.XXXXXX")" || return 0
    grep -v '^GITLAB_ROOT_PASSWORD=$' "${envf}" >"${tmp}" 2>/dev/null || true
    cat "${tmp}" >"${envf}"   # write into the original inode: the 600 mode survives
    rm -f "${tmp}"
  fi
  pw="$(openssl rand -hex 16 2>/dev/null || true)"
  if [ -z "${pw}" ]; then
    pw="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [ -n "${pw}" ] || return 0
  chmod 600 "${envf}"
  printf '\n# seeded by aibox gitlab — applies at first boot with fresh volumes\nGITLAB_ROOT_PASSWORD=%s\n' "${pw}" >>"${envf}"
}

# ---------- TLS (opt-in: GITLAB_HTTPS_ENABLE=true) ----------
# The certs are OPERATOR state (state_files: ssl/ in module.yaml): hooks only
# ever CREATE a missing pair, never overwrite a real one. Omnibus wants a cert
# that already includes the chain, so a single gitlab.crt + gitlab.key pair is
# what the compose points nginx at.
tls_dir() {
  printf '%s' "${GITLAB_TLS_DIR:-$(deploy_root)/ssl}"
}

ensure_tls_material() {
  case "${GITLAB_HTTPS_ENABLE:-false}" in true|1|yes) ;; *) return 0 ;; esac
  local dir crt key host
  dir="$(tls_dir)"; crt="${dir}/gitlab.crt"; key="${dir}/gitlab.key"
  [ -s "${crt}" ] && [ -s "${key}" ] && return 0
  mkdir -p "${dir}" 2>/dev/null || true
  host="$(printf '%s' "${GITLAB_EXTERNAL_URL:-}" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
  [ -n "${host}" ] || host="$(detect_external_host)"
  if command -v openssl >/dev/null 2>&1; then
    log "no certificate in ${dir} — generating a self-signed pair for ${host} (drop your real cert in as gitlab.crt/gitlab.key and restart)"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "${key}" -out "${crt}" -subj "/CN=${host}" \
      -addext "subjectAltName=DNS:${host}" >/dev/null 2>&1 || {
      warn "self-signed generation failed; provide ${crt} + ${key} yourself"
      return 0
    }
    chmod 600 "${key}" 2>/dev/null || true
    ok "self-signed certificate written to ${dir}"
  else
    warn "HTTPS is enabled but ${crt}/${key} are missing and openssl is unavailable"
  fi
  return 0
}

# ---------- backup / restore (migration) ----------
db_count() { # $1 = table (users|projects) — prints the count, "" when unavailable
  case "${1:-}" in ''|*[!a-z_]*) return 0 ;; esac
  docker exec "$CONTAINER_NAME" gitlab-psql -tAc "select count(*) from ${1}" 2>/dev/null | tr -d '[:space:]'
}

backup_tars() { # newest-first list of in-container backup tars
  docker exec "$CONTAINER_NAME" sh -c 'ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null' 2>/dev/null || true
}

# Verify a password against the LIVE root account (the truth — never trust
# a file). Prints "true" / "false" / "" (probe failed: container down or
# rails busy — NOT a verdict). Passwords with single quotes would break the
# runner string; hex seeds and sane user values are safe, and a broken probe
# just degrades to "unverified".
# Derived key: nginx's listen port must match the protocol in external_url.
# TLS on  -> the TLS port (omnibus still serves the plain-HTTP redirect itself,
#            on 80, because redirect_http_to_https is set)
# TLS off -> the plain HTTP port
# Written into the deploy .env (compose interpolates it) — idempotent.
sync_nginx_listen_port() {
  local envf want cur tmp
  envf="$(deploy_root)/.env"
  [ -f "${envf}" ] || return 0
  case "$(cfg_kv_get "${envf}" GITLAB_HTTPS_ENABLE 2>/dev/null || true)" in
  true | 1 | yes) want="$(cfg_kv_get "${envf}" GITLAB_HTTPS_PORT 2>/dev/null || true)" ;;
  *) want="$(cfg_kv_get "${envf}" GITLAB_HTTP_PORT 2>/dev/null || true)" ;;
  esac
  [ -n "${want}" ] || return 0
  cur="$(cfg_kv_get "${envf}" GITLAB_NGINX_LISTEN_PORT 2>/dev/null || true)"
  [ "${cur}" = "${want}" ] && return 0
  tmp="$(mktemp "${envf}.tmp.XXXXXX")" || return 0
  grep -v '^GITLAB_NGINX_LISTEN_PORT=' "${envf}" >"${tmp}" 2>/dev/null || true
  printf '\n# derived by aibox gitlab: nginx listens on this port (external_url protocol)\nGITLAB_NGINX_LISTEN_PORT=%s\n' "${want}" >>"${tmp}"
  cat "${tmp}" >"${envf}"   # keep the inode: the 600 mode survives
  rm -f "${tmp}"
  return 0
}

root_password_verify() { # $1=password
  local out
  out="$(docker exec "$CONTAINER_NAME" gitlab-rails runner "puts User.find_by(username: 'root').valid_password?('${1}')" 2>/dev/null || true)"
  case "${out}" in
  *true*) printf 'true' ;;
  *false*) printf 'false' ;;
  *) printf '' ;;
  esac
}

# Best-effort LAN IP for external_url (clone URLs embed it); overridable via
# GITLAB_EXTERNAL_URL at install time. Falls back to localhost.
detect_external_host() {
  local ip=""
  case "$(uname -s)" in
  Linux) ip="$(hostname -I 2>/dev/null | awk '{print $1}')" ;;
  Darwin) ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)" ;;
  esac
  [ -n "$ip" ] || ip="localhost"
  printf '%s' "$ip"
}

# compose wrapper: always runs in the deploy root (project name = "gitlab",
# so named volumes become gitlab_gitlab_{config,logs,data}).
compose() {
  local root
  root="$(deploy_root)"
  [ -f "$root/docker-compose.yml" ] || die "not installed (run: aibox install gitlab)"
  require_docker
  (cd "$root" && docker compose "$@")
}

# Image list from the (mode-aware) compose definition — what `up` would pull.
compose_images() {
  compose config --images 2>/dev/null || true
}

# GitLab answers 200 on the sign-in page once rails+puma are up (302 on /).
http_up() { # $1 = HTTP port override; with HTTPS on, the TLS listener is the probe
  local port code https_port
  port="${1:-${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}}"
  case "${GITLAB_HTTPS_ENABLE:-false}" in
  true | 1 | yes)
    # nginx redirects plain HTTP to TLS in this mode, so /users/sign_in on the
    # HTTP port answers 301 forever and the probe would never see the app. Ask
    # the TLS listener (-k: the cert is the operator's, possibly self-signed).
    https_port="${GITLAB_HTTPS_PORT:-31143}"
    code="$(curl -s -k --noproxy '*' -o /dev/null --max-time 5 -w '%{http_code}' "https://127.0.0.1:${https_port}/users/sign_in" 2>/dev/null || true)"
    case "$code" in
    200 | 302) return 0 ;;
    esac
    ;;
  esac
  # --noproxy: this probes 127.0.0.1 — an inherited http_proxy env (manual
  # exports; aibox's own proxy flow already sets no_proxy) would route the
  # loopback probe through the proxy and return 000 (measured live).
  code="$(curl -s --noproxy '*' -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/users/sign_in" 2>/dev/null || true)"
  case "$code" in
  200 | 302) return 0 ;;
  301) return 0 ;; # nginx serving the TLS redirect: the web endpoint answers
  *) return 1 ;;
  esac
}
upgrade_stops() { # $1=cur_major.minor $2=tgt_major.minor (range for derivation)
  local cur="${1:-0.0}" tgt="${2:-0.0}"
  # Frozen history ≤17.4 (upstream config/upgrade_path.yml; conditional stops
  # 16.0/16.1/16.2/17.1 included — safe default, they only cost minutes)
  printf '%s\n' 8.11 8.12 8.17 9.5 10.0 10.8 11.0 11.11 \
    12.0 12.1 12.10 13.0 13.1 13.8 13.12 \
    14.0 14.3 14.9 14.10 15.0 15.4 15.11 \
    16.0 16.1 16.2 16.3 16.7 16.11 17.1 17.3 17.5 17.8 17.11
  # ≥18: derived from the official cadence — generate x.2/x.5/x.8/x.11 for
  # every major from 18 up to the target's major (one extra major is harmless).
  local cmin tmin tmaj mj mn
  cmin="${cur#*.}"
  [ "${cmin}" = "${cur}" ] && cmin=0
  tmaj="${tgt%%.*}"
  tmin="${tgt#*.}"
  [ "${tmin}" = "${tgt}" ] && tmin=0
  for ((mj = 18; mj <= tmaj; mj++)); do
    for mn in 2 5 8 11; do
      printf '%s.%s\n' "${mj}" "${mn}"
    done
  done
}

status_info() {
  local port url health
  load_env
  port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  case "${GITLAB_HTTPS_ENABLE:-false}" in
  true | 1 | yes)
    # The operator-facing endpoint is the TLS one: with redirect_http_to_https the
    # plain port only answers 301, so reporting it (and calling 301 "ok") was
    # misleading (live-caught on a migration).
    url="${GITLAB_EXTERNAL_URL:-https://127.0.0.1:${GITLAB_HTTPS_PORT:-31143}}"
    ;;
  *) url="http://127.0.0.1:${port}" ;;
  esac
  echo "version=$(app_version)"
  echo "endpoint=${url}"
  echo "credential=root / password: aibox gitlab credentials (verified live)"
  if container_running; then
    health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
    if http_up "$port"; then
      echo "state=ok"
      echo "health=ok (web endpoint answering; container health: ${health})"
    else
      echo "state=starting"
      echo "health=starting (container health: ${health}; first boot takes 3-5 min)"
    fi
  else
    echo "state=stopped"
    echo "health=stopped"
  fi
}

ssh_clone_url() {
  local host port
  host="$(detect_external_host)"
  port="${GITLAB_SSH_PORT:-$DEFAULT_SSH_PORT}"
  printf 'ssh://git@%s:%s' "$host" "$port"
}

doctor_ports() { # EFFECTIVE deployment ports (module.yaml holds defaults only)
  load_env
  printf '%s/tcp:http ' "${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  case "${GITLAB_HTTPS_ENABLE:-false}" in
  true | 1 | yes) printf '%s/tcp:https ' "${GITLAB_HTTPS_PORT:-31143}" ;;
  esac
  printf '%s/tcp:git-ssh\n' "${GITLAB_SSH_PORT:-31222}"
}

render_status() {
  load_env
  local port st state code
  port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  st="$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1 || true)"
  if [ -n "${st}" ]; then
    if http_up "${port}"; then
      state="ok"
    else
      state="starting"
    fi
  else
    state="stopped"
  fi
  status_header "gitlab" "$(app_version)" "${state}"
  if [ -n "${st}" ]; then
    status_row "container" "${st}"
    code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    [ -z "${code}" ] && code="000"
    case "${code}" in
    2?? | 3?? | 401) status_row "web" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓ HTTP ${code}${C_RST:-}" ;;
    *) status_row "web" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_YEL:-}HTTP ${code}${C_RST:-}" ;;
    esac
    status_row "ssh" ":${GITLAB_SSH_PORT:-31222} (git over SSH)"
  else
    status_row "container" "${C_YEL:-}not running (aibox gitlab start)${C_RST:-}"
  fi
  status_row "auth" "root / password (see: aibox gitlab credentials, verified live)"
  status_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/gitlab/"
}

effective_image() {
  printf '%s' "${GITLAB_IMAGE:-$DEFAULT_IMAGE}"
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

app_version() {
  local img tag
  load_env
  img="${GITLAB_IMAGE:-$DEFAULT_IMAGE}"
  tag="${img##*:}"
  printf '%s' "${tag#v}"
}

# pattern as the credentials flow). Falls back to http_up when the exec probe
# is unavailable (older deploys without the whitelist, curl-less images) so
# the gate never BLOCKS an otherwise-healthy hop.
http_up_readiness() {
  local port="${1:-$DEFAULT_HTTP_PORT}" code
  code="$(docker exec "${CONTAINER_NAME}" curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:8080/-/readiness" 2>/dev/null || true)"
  case "$code" in
  200) return 0 ;;
  *) http_up "${port}" ;;
  esac
}

#!/usr/bin/env bash
# new-module.sh — scaffold a spec-compliant aibox module skeleton.
#
# Generates tools/<name>/ with module.yaml (incl. the mandatory checks: section),
# lib.sh, the four hooks, svc.sh, README.md, docs/DEVELOPMENT.md and (default) a
# docker-compose.yml, then runs scripts/validate-module.sh so the skeleton is
# provably conformant from the first second. Conventions: docs/module-spec.md.
#
# Usage:
#   scripts/new-module.sh <name> [--desc "one-line description"] [--no-compose] [--out <tools-dir>]
#
# <name>: lowercase letters/digits/hyphens, must start with a letter (e.g. gitlab).
# --out:  write to <tools-dir>/<name> instead of this repo's tools/ (used by tests).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-module.sh"

NAME=""
DESC=""
WITH_COMPOSE=1
OUT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
  --desc)
    DESC="${2:-}"
    shift 2
    ;;
  --no-compose)
    WITH_COMPOSE=0
    shift
    ;;
  --out)
    OUT_DIR="${2:-}"
    shift 2
    ;;
  -h | --help)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*)
    printf 'unknown flag: %s\n' "$1" >&2
    exit 2
    ;;
  *)
    [ -z "$NAME" ] && NAME="$1"
    shift
    ;;
  esac
done

[ -n "$NAME" ] || {
  printf 'usage: new-module.sh <name> [--desc "..."] [--no-compose] [--out <tools-dir>]\n' >&2
  exit 2
}
printf '%s' "$NAME" | grep -qE '^[a-z][a-z0-9-]*$' ||
  {
    printf 'invalid module name "%s": lowercase letters/digits/hyphens, start with a letter\n' "$NAME" >&2
    exit 2
  }
  [ "$NAME" != self ] || { printf 'the name "self" is reserved (the manager module)\n' >&2; exit 2; }

[ -n "$DESC" ] || DESC="$NAME module (TODO: one-line description)"

TOOLS_DIR="${OUT_DIR:-$REPO_ROOT/tools}"
DEST="$TOOLS_DIR/$NAME"
[ -e "$DEST" ] && {
  printf 'refusing to overwrite: %s (remove it first)\n' "$DEST" >&2
  exit 1
}

mkdir -p "$DEST/docs"

# Placeholder substitution: templates use quoted heredocs (no shell expansion),
# then sed swaps __NAME__/__DESC__. The desc is escaped for the | delimiter.
ESC_DESC="$(printf '%s' "$DESC" | sed -e 's/[\\&|]/\\&/g')"
render() { # $1 = target file; stdin = template
  sed -e "s|__NAME__|$NAME|g" -e "s|__DESC__|$ESC_DESC|g" >"$1"
}

# ---------- module.yaml ----------
if [ "$WITH_COMPOSE" = 1 ]; then
  render "$DEST/module.yaml" <<'EOF'
name: __NAME__
version: 0.1.0
description: "__DESC__"
platform: ""
dir: tools/__NAME__

# Runtime deps (cmd / cmd@platform / cmd:majorVersion) — checked strictly by the
# install/update preflight; missing deps abort unless --skip-checks.
deps:
  - docker
  - docker-compose

# Declared ports (NNN/proto:usage). CI + validate-module.sh detect cross-module
# conflicts. TODO: replace with the real ports.
ports:
  - 8080/tcp:http

# Extra files (beyond the standard 5) that aibox must download alongside hooks.
files:
  - docker-compose.yml

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

# Actions svc.sh implements. Service-type modules MUST provide the full
# lifecycle set (start/stop/restart/status/logs) — the validator enforces it.
actions:
  - start
  - stop
  - restart
  - status
  - logs

upstream:
  homepage: https://example.com/TODO
  docs: https://example.com/TODO/docs

dashboard:
  endpoints: http://127.0.0.1:8080
  hint: TODO where credentials live (file/env), one line

# MANDATORY preflight contract (enforced by aibox install/update; see
# docs/module-spec.md §Preflight checks). Declare what THIS module needs:
#   disk_gb        min free disk (GB) at $AIBOX_HOME's filesystem
#   domains        HOST-probed domains (git/npm/curl consumers)
#   docker_pull    DAEMON-routed pull probe (tiny image) — for registry consumers;
#                  the docker daemon's egress differs from the host's
#   docker_images  when ALL cached locally, domain+pull probes are skipped
#   commands       binaries that must exist (cmd@platform; no auto-install)
checks:
  disk_gb: 5
  docker_pull: hello-world
EOF
else
  render "$DEST/module.yaml" <<'EOF'
name: __NAME__
version: 0.1.0
description: "__DESC__"
platform: ""
dir: tools/__NAME__

# Runtime deps (cmd / cmd@platform / cmd:majorVersion).
deps:
  - curl

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

# CLI-dispatch style (like openmaic/windmill): list the passthrough actions.
actions:
  - status

upstream:
  homepage: https://example.com/TODO
  docs: https://example.com/TODO/docs

# MANDATORY preflight contract (docs/module-spec.md §Preflight checks).
checks:
  disk_gb: 1
  domains:
    - github.com
EOF
fi

# ---------- lib.sh ----------
render "$DEST/lib.sh" <<'EOF'
# __NAME__ module shared library (sourced by hooks, not executed directly)
# Conventions: docs/module-spec.md — deploy root = $AIBOX_HOME/apps/__NAME__.

MODULE_NAME="__NAME__"

# Output helpers: colors are inherited from aibox via exported C_* env vars
# (single source of truth); ${C_*:-} falls back to plain output when this lib
# is sourced standalone.
log()  { printf '%s[%s]%s %s\n' "${C_CYA:-}" "${AIBOX_MODULE:-$MODULE_NAME}" "${C_RST:-}" "${*}"; }
warn() { printf '%s[!]%s %s\n' "${C_YEL:-}" "${C_RST:-}" "${*}" >&2; }
ok()   { printf '%s[ok]%s %s\n' "${C_GRN:-}" "${C_RST:-}" "${*}"; }
die()  { printf '%s[x]%s %s\n' "${C_RED:-}" "${C_RST:-}" "${*}" >&2; exit 1; }

# Deploy root per the aibox convention ($AIBOX_HOME/apps/<name>; module-spec
# §Deploy directory). The guard is mandatory: systemd service contexts may
# lack HOME, and path derivation must fail loudly rather than produce "/apps/...".
deploy_root() {
  local root
  root="${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"
  [ -n "$root" ] || die "cannot determine deploy root: HOME and AIBOX_HOME are both empty"
  printf '%s' "$root/apps/$MODULE_NAME"
}
EOF

# ---------- install.sh ----------
render "$DEST/install.sh" <<'EOF'
#!/usr/bin/env bash
# __NAME__ module — install hook (contract: docs/module-spec.md §Hook contract).
# Runs AFTER the aibox preflight gate; must be idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
mkdir -p "$ROOT"

# TODO: real install work (place config, build, fetch releases, ...).
if [ -f "$DIR/docker-compose.yml" ]; then
  cp "$DIR/docker-compose.yml" "$ROOT/docker-compose.yml"
  log "compose placed: $ROOT/docker-compose.yml"
fi

log "installed module files → $ROOT"
log "Start:    aibox __NAME__ start"
EOF

# ---------- uninstall.sh ----------
render "$DEST/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
# __NAME__ module — uninstall hook (idempotent; data volumes are preserved).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
if [ -f "$ROOT/docker-compose.yml" ]; then
  ( cd "$ROOT" && docker compose down --remove-orphans ) >/dev/null 2>&1 || true
  rm -f "$ROOT/docker-compose.yml"
  log "stopped containers and removed the compose file (data volumes retained)"
else
  log "nothing to uninstall"
fi
warn "data volumes are retained; to delete them: docker volume ls (look for __NAME__)"
EOF

# ---------- update.sh ----------
render "$DEST/update.sh" <<'EOF'
#!/usr/bin/env bash
# __NAME__ module — update hook (refresh deployed files; aibox passes
# --restart/--no-restart through; restart policy is the module's choice).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
if [ -f "$DIR/docker-compose.yml" ] && [ -d "$ROOT" ]; then
  cp "$DIR/docker-compose.yml" "$ROOT/docker-compose.yml"
  log "compose refreshed ($ROOT/docker-compose.yml)"
fi
log "apply changes: aibox __NAME__ restart"
EOF

# ---------- svc.sh ----------
render "$DEST/svc.sh" <<'EOF'
#!/usr/bin/env bash
# __NAME__ module — service ops hook: aibox __NAME__ <action> [args]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/lib.sh"

ROOT="$(deploy_root)"
[ -d "$ROOT" ] || die "not installed (run: aibox install __NAME__)"
cd "$ROOT"

action="${1:-status}"
[ $# -gt 0 ] && shift
case "$action" in
  start)
    docker compose up -d "$@"
    ok "started"
    ;;
  stop)
    docker compose stop "$@"
    ok "stopped"
    ;;
  restart)
    docker compose restart "$@"
    ok "restarted"
    ;;
  status)
    docker compose ps
    ;;
  logs)
    docker compose logs --tail 100 "$@"
    ;;
  *)
    die "unknown action: $action (declared: start stop restart status logs)"
    ;;
esac
EOF

# ---------- README.md ----------
render "$DEST/README.md" <<'EOF'
# __NAME__

__DESC__

## Commands

```text
aibox install __NAME__
aibox __NAME__ start|stop|restart|status|logs
aibox update __NAME__ [--restart|--no-restart]
aibox uninstall __NAME__
```

## How it works

TODO: architecture in 5-10 lines — what gets deployed where (deploy root is
`$AIBOX_HOME/apps/__NAME__`), which ports/containers/volumes it uses, and how
it integrates with the shared base (if it consumes `services:`).

## Configuration (env overrides)

TODO: table of env vars honored by hooks/svc (ports, passwords, image tags).

## Preflight

Declared in `module.yaml` `checks:` — enforced by `aibox install/update`
(see `docs/module-spec.md` §Preflight checks). Re-run manually:

```text
aibox check __NAME__
```
EOF

# ---------- docs/DEVELOPMENT.md ----------
render "$DEST/docs/DEVELOPMENT.md" <<'EOF'
# __NAME__ — development notes

- Upstream: TODO (homepage)
- Docs: TODO (upstream docs URL)
- Image/package: TODO (exact ref + how to bump)

## Design decisions

TODO: why this deployment shape; what the hooks do; upgrade/rollback strategy;
known upstream quirks (version pins, migrations, resource floors).

## Local testing

```bash
scripts/validate-module.sh __NAME__      # conformance (same rules as CI)
bats tests/*.bats                        # fast suite
# integration (docker + network): bats tests/integration/
```
EOF

# ---------- docker-compose.yml ----------
if [ "$WITH_COMPOSE" = 1 ]; then
  render "$DEST/docker-compose.yml" <<'EOF'
# __NAME__ deploy compose — placed into $AIBOX_HOME/apps/__NAME__ by the install
# hook. Conventions (docs/module-spec.md §Deploy directory): named volumes only
# (Docker Desktop does not share /opt — bind mounts there fail with
# "Mounts denied"); no hardcoded credentials; ports/env overridable.
services:
  app:
    image: ${APP_IMAGE:-alpine:3.20}
    container_name: aibox-__NAME__
    restart: unless-stopped
    ports:
      - "${APP_PORT:-8080}:8080"
    volumes:
      - app_data:/data

volumes:
  app_data:
EOF
fi

chmod +x "$DEST/install.sh" "$DEST/uninstall.sh" "$DEST/update.sh" "$DEST/svc.sh"

printf 'Scaffolded module skeleton: %s\n' "$DEST"
printf '  module.yaml lib.sh install.sh uninstall.sh update.sh svc.sh README.md docs/DEVELOPMENT.md%s\n' \
  "$([ "$WITH_COMPOSE" = 1 ] && printf ' docker-compose.yml')"
printf '\nNext: fill in the TODOs, then re-validate:\n'
printf '  scripts/validate-module.sh %s\n\n' "$NAME"

# Prove the skeleton is conformant from the start (run against the scaffold's
# own tools dir when --out is used).
if [ -f "$VALIDATOR" ]; then
  VALIDATE_TOOLS_DIR="$TOOLS_DIR" bash "$VALIDATOR" "$NAME" || {
    printf 'scaffold produced validator findings — fix the template or the module\n' >&2
    exit 1
  }
fi

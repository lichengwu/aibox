#!/usr/bin/env bash
# windmill module — service action hook
# This module has no resident process of its own (stack is managed by docker compose), so here we only **pass through**:
#   aibox windmill status   ->  windmill status
#   aibox windmill doctor   ->  module_doctor (the shared uniform diagnostics)
#   aibox windmill check    ->  windmill check (the CLI's deep, deploy-aware check)
# All real actions are performed by the local windmill CLI (including its own confirmation, concurrency lock, and exit codes).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

action="${1:-}"
if [ -z "${action}" ]; then
  die "usage: aibox windmill <action> [args] (see: windmill help for actions)"
fi
shift

# Naming collision reminder: aibox's install installs the "module", while windmill's init/destroy
# deploys/tears down Windmill itself. One word apart, worth a one-time reminder.
case "${action}" in
# config: /etc/windmill/windmill.conf is the store (spec §Configuration).
# CLI-type module — applies at the NEXT invocation (no restart).
config)
  CFG_YAML="${DIR}/module.yaml" \
    CFG_STORE="/etc/windmill/windmill.conf" \
    CFG_APPLY="" \
    cfg_action "$@"
  exit $? # handled here — never falls through to the CLI dispatch
  ;;
init | destroy)
  warn "note: windmill ${action} here means 'deploy / tear down Windmill itself'"
  warn "      to install this module use: aibox install windmill"
  ;;
esac

# Prefer the module install destination to avoid a stale copy elsewhere in PATH
CLI=""
if [ -x "${CLI_DEST}" ]; then
  CLI="${CLI_DEST}"
else
  CLI="$(command -v windmill || true)"
fi
if [ -z "${CLI}" ]; then
  die "windmill command not found, run first: aibox install windmill"
fi

# dashboard maps to the CLI's own status (dispatch-only module — the CLI's
# output IS the rich view; no separate render here)
case "${action}" in
# Standard lifecycle aliases: this is a dispatch CLI whose own spelling is
# up/down, but `aibox <module> start|stop|restart` must work everywhere
# (spec §CLI surface). `restart` maps to `up`, which reconciles and recreates
# whatever drifted — the closest thing the CLI has to a restart.
# `start` must work on a fresh install: windmill separates MODULE install (this
# aibox module) from DEPLOYMENT (render + secrets + stack), so a first `start`
# has no docker-compose.yml yet. Self-heal instead of surfacing the CLI's raw
# "run init or deploy first": never deployed → init; rendered once but the
# artifacts are gone → deploy --recreate (keeps .env/secrets); healthy → up.
start | restart)
  action="up"
  if [ ! -f "${WM_DIR:-$HOME/.aibox/apps/windmill}/docker-compose.yml" ]; then
    if [ -f "${WM_DIR:-$HOME/.aibox/apps/windmill}/.env" ]; then
      warn "windmill: no docker-compose.yml in the deploy root — re-rendering it first (aibox windmill deploy --recreate)"
      action="deploy"
      set -- --recreate "$@"
    else
      warn "windmill: not deployed yet — initializing (secrets + config + stack)"
      action="init"
    fi
  fi
  ;;
stop)    action="down" ;;
dashboard) action="status" ;;
# Standard diagnostic verb: the CLI calls it `check`.
doctor) module_doctor windmill ;;
esac

exec "${CLI}" "${action}" "$@"

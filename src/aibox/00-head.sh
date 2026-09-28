#!/usr/bin/env bash
# aibox — a lightweight, zero-dependency module manager for AI coding toolkits
# Repo: https://github.com/lichengwu/aibox
#
# GENERATED FILE — do not edit: sources live in src/aibox/*.sh (rebuild: scripts/bundle.sh)
# Usage (one grammar: everything is a module — 'self' is the manager module):
#   aibox install <module> [--skip-checks]
#   aibox uninstall <module>|self [--purge] [--yes]
#   aibox update <module>|self|--all [--restart|--no-restart] [--skip-checks]
#   aibox check <module>|self [--json]  module preflight / environment check
#   aibox dashboard [--available|--json] [<module>]   overview(+ports) / catalog / detail
#   aibox purge [<module>...|self] [--apply] [--stop] [--yes]
#   aibox <module> <action> [args]      module action pass-through
#   aibox proxy {set <url>|on|off|unset|check [url]|env}
#   aibox version | help
set -euo pipefail

# Coverage probe hook (scripts/coverage.sh): bash 4.1+ only (BASH_XTRACEFD),
# silently inert otherwise — on the macOS 3.2 runtime this is a no-op (coverage
# runs on bash-5 hosts: CI's ubuntu job, or any dev box with bash 5). Top-level
# on purpose: tests that SOURCE this file (load test_helper) get traced too —
# dispatch-only tracing undercounts them. xtrace goes to fd 9 (never stdout/
# stderr, so bats assertions are untouched); the open is failure-tolerant (a
# bad trace path degrades to plain behavior, never breaks the CLI).
if [ -n "${AIBOX_TRACE:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ] 2>/dev/null; then
  # NOTE: no 2>/dev/null on the exec — exec's redirections become PERMANENT shell
  # state, so "exec 9>>f 2>/dev/null" would silently eat every die/warn forever.
  # A plain failure (bad path) prints one error to the real stderr and disables
  # tracing — the right degradation.
  if exec 9>>"${AIBOX_TRACE}"; then
    BASH_XTRACEFD=9
    PS4='+|${FUNCNAME[0]:-main}|${LINENO}|'
    set -x
  fi
fi

AIBOX_REPO="lichengwu/aibox"
AIBOX_BRANCH="${AIBOX_BRANCH:-main}"
AIBOX_RAW="${AIBOX_RAW:-https://raw.githubusercontent.com/${AIBOX_REPO}/${AIBOX_BRANCH}}"
AIBOX_HOME="${AIBOX_HOME:-$HOME/.aibox}"
AIBOX_MOD_DIR="$AIBOX_HOME/modules"
AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
# Bin-dir preference (mirrors install.sh): an explicit AIBOX_BIN_DIR always
# wins; otherwise ~/.local/bin when it is ALREADY in PATH (no churn for
# existing installs); otherwise an in-PATH writable system dir — on deploy
# hosts the module CLIs then land next to the manager and work immediately;
# ~/.local/bin is the last resort. AIBOX_SYSTEM_BIN_DIRS overrides the list.
if [ -z "${AIBOX_BIN_DIR:-}" ]; then
  case ":${PATH}:" in
  *":$HOME/.local/bin:"*) AIBOX_BIN_DIR="$HOME/.local/bin" ;;
  *)
    for _bd in ${AIBOX_SYSTEM_BIN_DIRS:-/usr/local/bin /opt/homebrew/bin}; do
      case ":${PATH}:" in *":${_bd}:"*) ;; *) continue ;; esac
      if [ -d "${_bd}" ] && [ -w "${_bd}" ]; then AIBOX_BIN_DIR="${_bd}"; break; fi
    done
    [ -n "${AIBOX_BIN_DIR:-}" ] || AIBOX_BIN_DIR="$HOME/.local/bin"
    ;;
  esac
fi
AIBOX_VERSION="0.22.0"
AIBOX_LAST_DEST=""
AIBOX_CONFIG="${AIBOX_CONFIG:-$AIBOX_HOME/config}"

# Registry cache (avoids hitting the unauthenticated GitHub API on every call;
# the 60 req/hour/IP limit bites users behind shared NAT). TTL in seconds.
AIBOX_REGISTRY_CACHE="${AIBOX_REGISTRY_CACHE:-$AIBOX_HOME/registry.cache}"
AIBOX_REGISTRY_TTL="${AIBOX_REGISTRY_TTL:-3600}"


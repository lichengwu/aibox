#!/usr/bin/env bash
# aibox function-coverage probe — makes UNTESTED paths visible (bash has no
# coverage tooling; this is the zero-dependency substitute).
#
# How it works:
#   1. bin/aibox honors AIBOX_TRACE=<file> (bash 4.1+): xtrace is redirected to
#      fd 9 (BASH_XTRACEFD) so test stdout/stderr assertions are untouched; PS4
#      marks every executed line with +|<function>|<lineno>|.
#   2. --bats runs the fast suite with AIBOX_TRACE exported → one aggregated trace.
#   3. The parser diffs "functions with ≥1 executed line" against the function
#      inventory (grep) and reports the never-executed list.
#
# Scope: bin/aibox only (module hooks don't honor AIBOX_TRACE — module-level
# coverage would need per-module wiring; the gap this closes is the manager's).
#
# Requirements: bash 4.1+ as `bash` for tracing (the dev mac runs 3.2 — on such
# hosts use --trace with a file produced elsewhere, or rely on the CI report).
#
# Usage:
#   scripts/coverage.sh --bats            run the suite + report (CI does this)
#   scripts/coverage.sh --trace FILE      parse an existing trace file
#   scripts/coverage.sh --list            function inventory only
#
# Exit code: always 0 (informational — a threshold gate would rot; the report
# is the deliverable).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_CLI="$REPO_ROOT/bin/aibox"
TRACE_FILE="${AIBOX_COVERAGE_TRACE:-/tmp/aibox-coverage.trace}"

inv_funcs() {
  grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$MAIN_CLI" | sed 's/()$//' | sort -u
}

hit_funcs() { # $1 = trace file
  [ -f "$1" ] || return 0
  # '+|func|lineno|' prefix on every xtrace line; set-union across the whole run.
  # (leading +/space = xtrace depth repetition; func = field between pipes 1 and 2)
  sed -n 's/^[+ ]*|\([^|]*\)|.*/\1/p' "$1" | sort -u
}

report() { # $1 = trace file
  local inv hit n_inv n_hit miss
  inv="$(inv_funcs)"
  # the hit set can contain NON-inventory names (bats @test bodies / test_helper
  # helpers get traced too once the CLI is sourced) — intersect FIRST, then count.
  hit="$(hit_funcs "$1" | comm -12 <(inv_funcs) -)"
  n_inv="$(printf '%s\n' "$inv" | grep -c .)"
  n_hit="$(printf '%s\n' "$hit" | grep -c . || true)"
  # functions present in the inventory but never hit
  miss="$(comm -23 <(printf '%s\n' "$inv") <(printf '%s\n' "${hit}"))"

  echo "aibox function coverage (bin/aibox)"
  echo "  inventory : $n_inv functions"
  echo "  executed : $n_hit functions"
  echo "  coverage : $((n_hit * 100 / n_inv))%"

  # user-facing commands first (cmd_* = the public surface), then internals
  local miss_cmd miss_rest
  miss_cmd="$(printf '%s\n' "$miss" | grep '^cmd_' || true)"
  miss_rest="$(printf '%s\n' "$miss" | grep -v '^cmd_' || true)"
  if [ -n "$miss_cmd" ]; then
    echo
    echo "  NEVER EXECUTED — user-facing commands (cmd_*):"
    printf '%s\n' "$miss_cmd" | sed 's/^cmd_/    cmd_/; s/_/ /g' || true
  fi
  if [ -n "$miss_rest" ]; then
    echo
    echo "  never executed (internal helpers): $(printf '%s' "$miss_rest" | tr '\n' ' ')"
  fi
  echo
  echo "  (informational — not a gate; add bats coverage where it matters)"
}

case "${1:-}" in
--list)
  inv_funcs
  ;;
--trace)
  [ -n "${2:-}" ] || { echo "usage: coverage.sh --trace FILE" >&2; exit 2; }
  report "$2"
  ;;
--bats)
  # bash 4.1+ required for BASH_XTRACEFD (tracing is a no-op under 3.2 — the
  # report would show 0% and mislead). Detect and refuse loudly.
  if ! bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }' 2>/dev/null; then
    echo "coverage: this host's bash is < 4.1 — tracing is a silent no-op there." >&2
    echo "  run on a bash-5 host (CI's ubuntu job does), or parse a trace: --trace FILE" >&2
    exit 0
  fi
  command -v bats >/dev/null 2>&1 || { echo "coverage: bats not installed (npm i -g bats)" >&2; exit 2; }
  rm -f "$TRACE_FILE"
  echo "running: bats tests/*.bats (AIBOX_TRACE=$TRACE_FILE)"
  bats_rc=0
  (cd "$REPO_ROOT" && AIBOX_TRACE="$TRACE_FILE" bats tests/*.bats >/tmp/aibox-cov-bats.log 2>&1) || bats_rc=$?
  echo "suite: $(grep -c '^ok ' /tmp/aibox-cov-bats.log) passed, $(grep -c '^not ok' /tmp/aibox-cov-bats.log 2>/dev/null || true) failed (failures gate on the tests job; the report below still measures), trace: $(wc -l <"$TRACE_FILE" | tr -d ' ') lines"
  echo
  report "$TRACE_FILE"
  ;;
*)
  echo "usage: scripts/coverage.sh {--bats|--trace FILE|--list}" >&2
  exit 2
  ;;
esac

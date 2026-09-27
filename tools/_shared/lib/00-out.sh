# aibox shared module library — output helpers + docker.io download source pool.
# Repo: tools/_shared/common.sh (single source). Ships INTO each module cache as
# _common.sh (declared via `includes: [common]` in module.yaml) — modules stay
# self-contained per-directory; the repo stays single-source. Sourced by lib.sh:
#   LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${LIB_SELF}/_common.sh"
# (no shebang / no strict-mode line — it is a sourced library, like lib.sh)

# ---------- output helpers ----------
# Colors are inherited from aibox via exported C_* env vars (single source of
# truth); ${C_*:-} falls back to plain output standalone. Symbols: ⚠ warn / ✓ ok
# / ✗ die, two-space gap (spec §Output conventions).
log() { printf '%s\n' "$*"; }
warn() { printf '%s⚠%s  %s\n' "${C_YEL:-}" "${C_RST:-}" "$*" >&2; }
ok() { printf '%s✓%s  %s\n' "${C_GRN:-}" "${C_RST:-}" "$*"; }
info() { printf '%s  %s%s\n' "${C_DIM:-}" "$*" "${C_RST:-}"; }
die() {
  printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2
  exit 1
}

# Guard for docker-dependent actions. Without it a missing docker binary
# surfaced as a raw shell error from a deep lib line (live-caught:
# `aibox base status` → "tools/base/lib.sh: line 138: docker: command not
# found", exit 127) with no hint about what the action actually needs.
require_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  die "docker CLI not found — this action needs it (install docker, then: aibox check ${AIBOX_MODULE:-<module>})"
}

# Path to the sibling base module's svc.sh. In the dispatched cache layout the
# manager injects AIBOX_MOD_DIR, which is authoritative — its absence means base
# is NOT installed. Direct repo execution (bats / dev) falls back to the sibling
# dir: _common.sh sits next to lib.sh in the cache and in tools/_shared in the
# repo, both exactly one level below the sibling module dir.
shared_base_svc_path() {
  if [ -n "${AIBOX_MOD_DIR:-}" ]; then
    printf '%s/base/svc.sh' "${AIBOX_MOD_DIR}"
    return 0
  fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/../base/svc.sh' "${d}"
}

# Usage errors are exit 2 everywhere (manager and module hooks) — automation can
# tell "you called it wrong" (2) from "it ran and failed" (1).
usage_die() { printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2; exit 2; }
# Arbitrary stable exit codes are part of the hook contract (3 deps missing /
# 4 precheck failed / 10 rolled back / 20 manual / 30/40/50) — spec §Exit codes.
die_code() { local _c="$1"; shift; printf '%s✗%s  %s\n' "${C_RED:-}" "${C_RST:-}" "$*" >&2; exit "${_c}"; }

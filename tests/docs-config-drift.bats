#!/usr/bin/env bats
# Docs / config drift guards (0.17.0).
# The audit found the config side clean (every declared env: key IS referenced in
# its module's code) but the docs side not: base/pi-web documented hardcoded
# profile-derived ports as if they were universal, and the upgrade exit-code
# table promised 10/20 while the code only ever returned 20.
# These tests keep both classes from returning:
#   - env: key ↔ code reference (declared but unread = not really settable)
#   - profile-deriving modules must point at `aibox dashboard` for derived values
#   - the convention itself is documented (spec §Doc hygiene + AGENTS rule) and
#     enforced by the validator
#   - the documented exit-code contract is implemented

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "config drift: every declared env: key is referenced in the module's code" {
  local m f k missing=""
  for f in "$REPO_ROOT"/tools/*/module.yaml; do
    m="$(basename "$(dirname "$f")")"
    local keys
    keys="$(sed -n '/^env:/,/^[a-zA-Z]/p' "$f" | grep -oE '^  [A-Z_][A-Z0-9_]*' | sed 's/^  //')"
    [ -n "${keys}" ] || continue
    for k in ${keys}; do
      # a knob counts as settable when SOME code reads it: the module itself, the
      # shared include (tools/_shared — cached per module as _<name>.sh) or the
      # manager. AIBOX_DOCKER_* are shared-pool knobs: declared per module so
      # `aibox <m> config list` shows them, implemented in the include.
      grep -rq "${k}" "$REPO_ROOT/tools/$m" --exclude='*.md' --exclude='module.yaml' 2>/dev/null \
        || grep -rq "${k}" "$REPO_ROOT/tools/_shared" "$REPO_ROOT/bin/aibox" 2>/dev/null \
        || missing="${missing} ${m}:${k}"
    done
  done
  [ -z "${missing}" ] || { echo "declared but never referenced in code:${missing}"; false; }
}

@test "doc hygiene: profile-deriving modules point at the dashboard for derived values" {
  local m f bad="" rd
  for f in "$REPO_ROOT"/tools/*/lib.sh; do
    m="$(basename "$(dirname "$f")")"
    grep -qE '_profile_load|_profile_hash' "$f" 2>/dev/null || continue
    rd="$REPO_ROOT/tools/$m/README.md"
    [ -f "${rd}" ] || continue
    if grep -qE '[0-9]{4,5}' "${rd}" 2>/dev/null && ! grep -q 'aibox dashboard' "${rd}" 2>/dev/null; then
      bad="${bad} ${m}"
    fi
  done
  [ -z "${bad}" ] || { echo "numeric values documented with no dashboard pointer:${bad}"; false; }
}

@test "doc hygiene: base/pi-web docs label the default-profile values and point at the dashboard" {
  grep -q 'aibox dashboard base' "$REPO_ROOT/tools/base/README.md" || { false; }
  grep -q 'Default-profile defaults, not universal truth' "$REPO_ROOT/tools/base/README.md" || false
  grep -q 'aibox dashboard pi-web' "$REPO_ROOT/tools/pi-web/README.md" || false
  grep -q 'DEFAULT profile' "$REPO_ROOT/tools/pi-web/README.md" || false
  grep -q 'aibox dashboard pi-web' "$REPO_ROOT/tools/pi-web/docs/DEVELOPMENT.md" || false
}

@test "doc hygiene: the convention is normative (spec + AGENTS) and validator-enforced" {
  grep -q 'Doc hygiene' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'aibox dashboard <module>' "$REPO_ROOT/docs/module-spec.md" || { false; }
  grep -q 'Never hardcode derived values' "$REPO_ROOT/AGENTS.md" || { false; }
  grep -q 'Doc hygiene' "$REPO_ROOT/scripts/validate-module.sh" || { false; }
}

@test "dashboard surfaces the derived values the docs point at" {
  grep -q 'dash_row "containers"' "$REPO_ROOT/tools/base/lib.sh" || { false; }
  grep -q 'dash_row "env"' "$REPO_ROOT/tools/base/lib.sh" || false
  grep -q '_upgrade_state_get "\$name" status' "$REPO_ROOT/bin/aibox" || false
  grep -q 'key(s) · aibox \${name} config list' "$REPO_ROOT/bin/aibox" || false
}

@test "exit codes: the documented upgrade contract (10/20) is implemented" {
  grep -q '| 10 | upgrade failed, rolled back' "$REPO_ROOT/docs/module-spec.md" || { false; }
  grep -q '| 20 | manual intervention needed' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'return 10' "$REPO_ROOT/bin/aibox" || false
  grep -q 'return 20' "$REPO_ROOT/bin/aibox" || false
  # and the state file is what makes the rollback point possible
  grep -q 'upgrades/<module>.state' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '_upgrade_state_set' "$REPO_ROOT/bin/aibox" || false
}

@test "the superseded design draft stays banner-marked (its numbers are historical)" {
  head -25 "$REPO_ROOT/docs/module-system-spec.md" | grep -qi 'superseded' || { false; }
}

@test "the docs index keeps module-spec.md as the normative source" {
  grep -q 'THE normative module contract' "$REPO_ROOT/docs/README.md" || { false; }
  grep -qi 'Superseded by' "$REPO_ROOT/docs/README.md" || false
}

@test "port tables: no module README presents a derived port without the dashboard" {
  local rd bad="" m
  for rd in "$REPO_ROOT"/tools/*/README.md; do
    m="$(basename "$(dirname "$rd")")"
    # only the modules that actually derive ports from the profile are at risk
    grep -qE '_profile_load|_profile_hash' "$REPO_ROOT/tools/$m/lib.sh" 2>/dev/null || continue
    grep -qE '\| `?[A-Z_]*PORT' "${rd}" 2>/dev/null || continue
    grep -q 'aibox dashboard' "${rd}" 2>/dev/null || bad="${bad} ${m}"
  done
  [ -z "${bad}" ] || { echo "PORT row documented without a dashboard pointer:${bad}"; false; }
}

@test "port declarations: every declared port is actually published by the module" {
  # A declared port is rendered by `aibox dashboard` (with a listen mark) and
  # reserved by the port-conflict gate — declaring one that nothing publishes is
  # drift that misleads both. Live catch: openmaic declared 5432/tcp:postgres
  # while the upstream compose publishes ONLY 3000 (its PG is compose-internal).
  local m f p ports missing=""
  for f in "$REPO_ROOT"/tools/*/module.yaml; do
    m="$(basename "$(dirname "$f")")"
    ports="$(sed -n '/^ports:/,/^[a-z_]/p' "$f" | grep -oE '^  - [0-9]+/' | grep -oE '[0-9]+')"
    [ -n "${ports}" ] || continue
    for p in ${ports}; do
      grep -rqE "(^|[^0-9])${p}([^0-9]|\$)" "$REPO_ROOT/tools/$m" --exclude='*.md' --exclude='module.yaml' 2>/dev/null \
        || grep -rqE "(^|[^0-9])${p}([^0-9]|\$)" "$REPO_ROOT/tools/_shared" "$REPO_ROOT/bin/aibox" 2>/dev/null \
        || missing="${missing} ${m}:${p}"
    done
  done
  [ -z "${missing}" ] || { echo "declared port not referenced by any compose/config:${missing}"; false; }
}
#!/usr/bin/env bats
# Module tooling tests: scaffolder (scripts/new-module.sh) + validator
# (scripts/validate-module.sh). Hermetic: scaffolds land in a temp tools dir
# (VALIDATE_TOOLS_DIR); the validator is static analysis only (no docker/network).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-modtools.$$")"
  OUT="$SANDBOX/tools"
  mkdir -p "$OUT"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

# --- scaffolder ---------------------------------------------------------------

@test "scaffold: compose-style skeleton validates clean (0 errors, 0 warnings)" {
  run bash "$REPO_ROOT/scripts/new-module.sh" scfmt --desc "Scaffold test module" --out "$OUT"
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"PASS: 0 error(s), 0 warning(s)"* ]]
  [ -f "$OUT/scfmt/module.yaml" ]
  [ -f "$OUT/scfmt/lib.sh" ]
  [ -f "$OUT/scfmt/svc.sh" ]
  [ -f "$OUT/scfmt/docker-compose.yml" ]
  [ -f "$OUT/scfmt/README.md" ]
  [ -f "$OUT/scfmt/docs/DEVELOPMENT.md" ]
  [ -x "$OUT/scfmt/install.sh" ]
  [ -x "$OUT/scfmt/uninstall.sh" ]
  [ -x "$OUT/scfmt/update.sh" ]
  [ -x "$OUT/scfmt/svc.sh" ]
  # the mandatory checks: section is scaffolded in
  grep -q '^checks:' "$OUT/scfmt/module.yaml"
}

@test "scaffold: cli-style (--no-compose) validates clean, no compose file" {
  run bash "$REPO_ROOT/scripts/new-module.sh" sccli --no-compose --out "$OUT"
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"PASS: 0 error(s), 0 warning(s)"* ]]
  [ ! -f "$OUT/sccli/docker-compose.yml" ]
}

@test "scaffold: rejects invalid names and refuses to overwrite" {
  run bash "$REPO_ROOT/scripts/new-module.sh" "Bad Name" --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid module name"* ]]

  bash "$REPO_ROOT/scripts/new-module.sh" okmod --out "$OUT" >/dev/null 2>&1
  run bash "$REPO_ROOT/scripts/new-module.sh" okmod --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to overwrite"* ]]
}

# --- validator: negative cases (rules must actually fire) ----------------------

@test "validator: flags a missing checks: section (mandatory preflight contract)" {
  bash "$REPO_ROOT/scripts/new-module.sh" nochecks --out "$OUT" >/dev/null 2>&1
  sed -i.bak '/^checks:/,$d' "$OUT/nochecks/module.yaml"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" nochecks
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing checks: section"* ]]
}

@test "validator: detects cross-module port conflicts" {
  # Scaffold two CLI-style modules (no ports declared), then inject the SAME
  # port into both — note: compose-style scaffolds declare 8080 by default and
  # the scaffolder's own end-validation would (correctly) refuse the second one.
  bash "$REPO_ROOT/scripts/new-module.sh" p1 --no-compose --out "$OUT" >/dev/null 2>&1
  bash "$REPO_ROOT/scripts/new-module.sh" p2 --no-compose --out "$OUT" >/dev/null 2>&1
  printf 'ports:\n  - 8080/tcp:http\n' >> "$OUT/p1/module.yaml"
  printf 'ports:\n  - 8080/tcp:http\n' >> "$OUT/p2/module.yaml"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflicts with module"* ]]
}

@test "validator: gotcha #8 detector catches same-line local forward-reference" {
  bash "$REPO_ROOT/scripts/new-module.sh" g8 --out "$OUT" >/dev/null 2>&1
  printf 'f() {\n  local a="/x" b="${a}/y"\n  printf "%%s" "$b"\n}\n' > "$OUT/g8/lib.sh"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" g8
  [ "$status" -eq 1 ]
  [[ "$output" == *"gotcha #8"* ]]
}

@test "validator: sequential locals (split lines) are NOT gotcha #8" {
  bash "$REPO_ROOT/scripts/new-module.sh" g8ok --out "$OUT" >/dev/null 2>&1
  printf 'f() {\n  local a="/x"\n  local b="${a}/y"\n  printf "%%s" "$b"\n}\n' > "$OUT/g8ok/lib.sh"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" g8ok
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" != *"gotcha #8"* ]]
}

@test "validator: flags hardcoded shared-PG credentials in compose (non-base module)" {
  bash "$REPO_ROOT/scripts/new-module.sh" credmod --out "$OUT" >/dev/null 2>&1
  printf 'services:\n  app:\n    image: alpine\n    environment:\n      - DATABASE_URL=postgres://aibox:aibox@db:5432/x\n' > "$OUT/credmod/docker-compose.yml"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" credmod
  [ "$status" -eq 1 ]
  [[ "$output" == *"hardcoded shared-PG credentials"* ]]
}

@test "validator: service-type module missing lifecycle actions → error" {
  bash "$REPO_ROOT/scripts/new-module.sh" halfsvc --out "$OUT" >/dev/null 2>&1
  # strip stop/restart/status/logs from actions, keep start
  sed -i.bak '/^actions:/,/^$/c\
actions:\
  - start\
' "$OUT/halfsvc/module.yaml"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" halfsvc
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing lifecycle action: stop"* ]]
}

@test "validator: unknown module → usage error" {
  run bash "$REPO_ROOT/scripts/validate-module.sh" nosuchmodule
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown module"* ]]
}

# --- validator: the real repo --------------------------------------------------

@test "validator: all repo modules pass --all with 0 errors" {
  run bash "$REPO_ROOT/scripts/validate-module.sh" --all
  [ "$status" -eq 0 ] || echo "$output"
  [[ "$output" == *"PASS: 0 error(s)"* ]]
}

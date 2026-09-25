#!/usr/bin/env bats
# CLI consistency (0.18.0) — the instruction-system audit turned into guards.
# Found & fixed: per-verb help existed only for `purge` (install/check/dashboard
# treated `--help` as a MODULE name and even hit the registry; the rest reported
# an unknown option, exit 1), usage() drifted from the real sub-verbs, usage
# errors exited 1 while the spec documents 2, preflight failures exited 1 while
# the spec documents 3/4, five modules had no `doctor` (and one hint pointed at a
# non-existent `aibox base doctor`), openmaic lacked the standard lifecycle verbs,
# and module hooks used `die` for usage errors.
# Offline: file:// fixtures + local metadata only.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AIBOX_BIN="$REPO_ROOT/bin/aibox"
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-cli.$$")"
  export AIBOX_HOME="$SANDBOX/home"
  export AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  export AIBOX_BIN_DIR="$SANDBOX/bin"
  mkdir -p "$AIBOX_HOME" "$AIBOX_MOD_DIR" "$AIBOX_BIN_DIR"
  export AIBOX_RAW="file://$REPO_ROOT"
  unset AIBOX_PROFILE
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true; }

# ---------- per-verb help -----------------------------------------------------

@test "help: every verb answers --help with its own usage block, exit 0" {
  local v out
  for v in install uninstall update upgrade check dashboard purge proxy version; do
    run bash "$AIBOX_BIN" "$v" --help
    [ "$status" -eq 0 ] || { echo "verb=${v} exit=${status}"; echo "$output"; false; }
    out="$(head -1 <<<"$output")"
    [ "$out" = "usage: aibox ${v}" ] || [ "${out#usage: aibox ${v}}" != "$out" ] || { echo "verb=${v} first-line=[${out}]"; false; }
  done
}

@test "help: -h behaves exactly like --help" {
  run bash "$AIBOX_BIN" upgrade -h
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"usage: aibox upgrade"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--rollback"* ]] || false
}

@test "help: aibox help <verb> renders the same block as <verb> --help" {
  local a b
  a="$(bash "$AIBOX_BIN" help purge 2>&1)"
  b="$(bash "$AIBOX_BIN" purge --help 2>&1)"
  [ "${a}" = "${b}" ] || { echo "help <verb> and <verb> --help differ"; false; }
}

@test "help: aibox help with an unknown verb prints the overview and exits 2" {
  run bash "$AIBOX_BIN" help definitely-not-a-verb
  [ "$status" -eq 2 ] || { echo "exit=${status}"; false; }
  [[ "$output" == *"aibox"*"module manager"* ]] || { echo "$output"; false; }
}

@test "help: the option is recognized in ANY position (no registry fetch)" {
  # `install --help` used to fall through as a MODULE NAME (registry + "Unknown module")
  run bash "$AIBOX_BIN" install --skip-checks --help
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"usage: aibox install"* ]] || false
  run bash "$AIBOX_BIN" update --all --help
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"usage: aibox update"* ]] || false
}

@test "help drift: every dispatch arm has a _verb_help block and is listed in usage()" {
  local verbs v
  verbs="$(sed -n '/# ---------- dispatch ----------/,/^  case "\${1:-help}" in/p' "$AIBOX_BIN" \
    | grep -oE '^[[:space:]]+(install\|uninstall\|update\|upgrade\|check\|dashboard\|purge\|proxy\|version)[^)]*\)' \
    | tr -d ' )' | tr '|' '\n' | sort -u)"
  for v in ${verbs}; do
    # a help block exists for it…
    sed -n '/^_verb_help()/,/^  \*) return 1 ;;/p' "$AIBOX_BIN" | grep -qE "^  ${v}\)" \
      || { echo "missing _verb_help block: ${v}"; false; }
  done
  #… and the overview lists each verb
  local overview; overview="$(bash "$AIBOX_BIN" help 2>&1)"
  for v in install uninstall update upgrade check dashboard purge proxy version; do
    [[ "$overview" == *"${v}"* ]] || { echo "usage() does not mention ${v}"; false; }
  done
}

@test "help: the overview documents the real sub-verbs (no stale set)" {
  local overview; overview="$(bash "$AIBOX_BIN" help 2>&1)"
  [[ "$overview" == *"proxy show|set <url>|unset|on|off|check [url]|env"* ]] || { echo "$overview"; false; }
  [[ "$overview" == *"clash set <sub-url>|on|off|status|refresh|select|test|logs|doctor"* ]] || false
  [[ "$overview" == *"--rollback"* ]] || false
  [[ "$overview" == *"exit codes"* ]] || false
}

# ---------- exit-code convention ---------------------------------------------

@test "exit codes: usage errors are 2, not 1" {
  run bash "$AIBOX_BIN" install nosuchmodule-xyz
  [ "$status" -eq 2 ] || { echo "unknown module exit=${status}"; false; }
  run bash "$AIBOX_BIN" uninstall --bogus-flag
  [ "$status" -eq 2 ] || { echo "unknown option exit=${status}"; false; }
  run bash "$AIBOX_BIN" purge --bogus-flag
  [ "$status" -eq 2 ] || false
  run bash "$AIBOX_BIN" upgrade
  [ "$status" -eq 2 ] || false
}

@test "exit codes: a module's unknown action is 2 (usage_die in every hook)" {
  # fixture: a module whose svc.sh follows the shared convention
  mkdir -p "$AIBOX_MOD_DIR/fx"
  printf 'name: fx\nversion: 1.0.0\ndescription: "d"\ndir: tools/fx\n' >"$AIBOX_MOD_DIR/fx/module.yaml"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '. "$REPO_ROOT/tools/_shared/common.sh"' \
    'action="${1:-status}"' 'case "$action" in status) echo ok ;; *) usage_die "unknown action: $action" ;; esac' \
    >"$AIBOX_MOD_DIR/fx/svc.sh"
  printf 'AIBOX_INSTALLED_fx="1.0.0"\n' >"$AIBOX_INSTALLED"
  run env REPO_ROOT="$REPO_ROOT" bash "$AIBOX_BIN" fx badaction
  [ "$status" -eq 2 ] || { echo "exit=${status}"; echo "$output"; false; }
  [[ "$output" == *"unknown action"* ]] || false
}

@test "exit codes: preflight failures are 3 (hard deps) / 4 (soft)" {
  local repo="$SANDBOX/repo"
  mkdir -p "$repo/tools/depmod" "$repo/tools/softmod"
  cat >"$repo/tools/depmod/module.yaml" <<'YAML'
name: depmod
version: 1.0.0
description: "missing hard dep"
dir: tools/depmod
hooks:
  install: install.sh
  svc: svc.sh
deps:
  - zz-no-such-binary
YAML
  cat >"$repo/tools/softmod/module.yaml" <<'YAML'
name: softmod
version: 1.0.0
description: "soft failure only"
dir: tools/softmod
hooks:
  install: install.sh
  svc: svc.sh
checks:
  disk_gb: 99999999
YAML
  for m in depmod softmod; do
    for h in install uninstall update svc; do
      printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$repo/tools/$m/$h.sh"
    done
    printf '%s\n' '# lib' >"$repo/tools/$m/lib.sh"
    chmod +x "$repo/tools/$m"/*.sh
  done
  export AIBOX_RAW="file://$repo"
  run env AIBOX_NO_AUTO_DEPS=1 bash "$AIBOX_BIN" install depmod
  [ "$status" -eq 3 ] || { echo "hard-dep exit=${status}"; echo "$output"; false; }
  [[ "$output" == *"can't be bypassed"* ]] || false
  run bash "$AIBOX_BIN" install softmod
  [ "$status" -eq 4 ] || { echo "soft exit=${status}"; echo "$output"; false; }
  [[ "$output" == *"--skip-checks"* ]] || false
}

@test "exit codes: the spec's table and the manager agree" {
  local spec_10 spec_20
  grep -q '| 1 | runtime error' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '| 2 | usage error' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '| 3 | dependency missing' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '| 4 | precheck failed' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'die_usage()' "$REPO_ROOT/bin/aibox" || false
  grep -q 'return 3$' "$REPO_ROOT/bin/aibox" || false
  grep -q 'return 4$' "$REPO_ROOT/bin/aibox" || false
}

# ---------- doctor: one verb, every module -----------------------------------

@test "doctor: every module declares the standard action set" {
  local f m acts
  for f in "$REPO_ROOT"/tools/*/module.yaml; do
    m="$(basename "$(dirname "$f")")"
    acts="$(awk '/^actions:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{print $2}' "$f")"
    for need in start stop restart status dashboard logs doctor; do
      printf '%s\n' ${acts} | grep -qx "$need" || { echo "${m}: missing action ${need}"; false; }
    done
  done
}

@test "doctor: the shared implementation reports deps/state/ports and exits 3 when a dep is missing" {
  run bash -c "
    export AIBOX_MODULE=pi-web AIBOX_HOME='$AIBOX_HOME'
    export PATH=/usr/bin:/bin
    . '$REPO_ROOT/tools/_shared/common.sh'
    module_doctor pi-web
  "
  [ "$status" -eq 3 ] || { echo "exit=${status}"; echo "$output"; false; }
  [[ "$output" == *"dep"* ]] || { echo "$output"; false; }
  [[ "$output" == *"not healthy"* ]] || false
}

@test "doctor: a stopped service exits 30 (spec: service not ready)" {
  # cache-layout fixture: _common.sh + module.yaml + lib.sh sit together, which is
  # exactly how module_doctor finds the metadata (no network, no real service)
  local mod="$AIBOX_MOD_DIR/statmod"
  mkdir -p "$mod"
  cp "$REPO_ROOT/tools/_shared/common.sh" "$mod/_common.sh"
  printf 'name: statmod\nversion: 1.0.0\ndescription: "d"\ndir: tools/statmod\nports:\n  - 19/tcp:x\n' >"$mod/module.yaml"
  printf '%s\n' 'dashboard_info() { printf "version=1.2.3\nstate=stopped\nendpoint=http://127.0.0.1:19\n"; }' >"$mod/lib.sh"
  run bash -c "
    export AIBOX_MODULE=statmod AIBOX_HOME='$AIBOX_HOME'
    . '$mod/_common.sh'
    . '$mod/lib.sh'
    module_doctor statmod
  "
  [ "$status" -eq 30 ] || { echo "exit=${status}"; echo "$output"; false; }
  [[ "$output" == *"not ready"* ]] || { echo "$output"; false; }
  [[ "$output" == *"statmod start"* ]] || false
}

@test "doctor: the base failure hint points at an action that exists" {
  grep -q 'aibox base doctor' "$REPO_ROOT/tools/base/lib.sh" || skip "hint changed"
  grep -qE '^doctor\)' "$REPO_ROOT/tools/base/svc.sh" || { echo "hint points at a non-existent action"; false; }
  grep -q '^  - doctor$' "$REPO_ROOT/tools/base/module.yaml" || false
}

@test "dispatch modules alias the standard lifecycle verbs" {
  grep -qE '^start\) +action="up"' "$REPO_ROOT/tools/openmaic/svc.sh" || { echo "openmaic: no start alias"; false; }
  grep -qE '^stop\) +action="down"' "$REPO_ROOT/tools/openmaic/svc.sh" || false
  grep -q '^  - start$' "$REPO_ROOT/tools/openmaic/module.yaml" || false
  # windmill's CLI already speaks start/stop/restart; it only needed the doctor alias
  grep -qE '^doctor\) module_doctor windmill' "$REPO_ROOT/tools/windmill/svc.sh" || false
}

@test "hooks: usage errors go through usage_die (exit 2), not die" {
  local f bad=""
  for f in "$REPO_ROOT"/tools/*/svc.sh; do
    if grep -nE '(^|[^_[:alnum:]])die "(Usage:|unknown action:|unknown option)' "$f" >/dev/null 2>&1; then
      bad="${bad} $(basename "$(dirname "$f")")"
    fi
  done
  [ -z "${bad}" ] || { echo "die used for usage errors:${bad}"; false; }
  grep -q '^usage_die()' "$REPO_ROOT/tools/_shared/common.sh" || false
}

@test "clash use-external: the missing-assignment crash is fixed" {
  # `port="${1:-}" ext="" desc guessed=""` ran `desc` as a COMMAND (exit 127)
  run bash -c "AIBOX_MODULE=clash AIBOX_HOME='$AIBOX_HOME' bash '$REPO_ROOT/tools/clash/svc.sh' use-external"
  [[ "$output" != *"desc: command not found"* ]] || { echo "$output"; false; }
  [[ "$output" == *"use-external"* ]] || { echo "$output"; false; }
}
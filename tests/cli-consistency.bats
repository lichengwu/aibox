#!/usr/bin/env bats
# CLI consistency (0.18.0) — the instruction-system audit turned into guards.
# Found & fixed: per-verb help existed only for one verb (install/check/status
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
  for v in install uninstall update upgrade check status autoclean proxy version; do
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
  a="$(bash "$AIBOX_BIN" help autoclean 2>&1)"
  b="$(bash "$AIBOX_BIN" autoclean --help 2>&1)"
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
    | grep -oE '^[[:space:]]+(install\|uninstall\|update\|upgrade\|check\|status\|autoclean\|proxy\|version)[^)]*\)' \
    | tr -d ' )' | tr '|' '\n' | sort -u)"
  for v in ${verbs}; do
    # a help block exists for it…
    sed -n '/^_verb_help()/,/^  \*) return 1 ;;/p' "$AIBOX_BIN" | grep -qE "^  ${v}\)" \
      || { echo "missing _verb_help block: ${v}"; false; }
  done
  #… and the overview lists each verb
  local overview; overview="$(bash "$AIBOX_BIN" help 2>&1)"
  for v in install uninstall update upgrade check status autoclean proxy version; do
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
  run bash "$AIBOX_BIN" autoclean --bogus-flag
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
description: "disk is informational only"
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
  # disk no longer gates: an impossible disk_gb must still INSTALL (with a warning)
  run bash "$AIBOX_BIN" install softmod
  [ "$status" -eq 0 ] || { echo "informational-disk exit=${status}"; echo "$output"; false; }
  [[ "$output" == *"recommends 99999999G"* ]] || false
}

@test "exit codes: the spec's table and the manager agree" {
  local spec_10 spec_20
  grep -q '| 1 | runtime error' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '| 2 | usage error' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '| 3 | dependency missing' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q '| 4 | precheck failed' "$REPO_ROOT/docs/module-spec.md" || false
  grep -q 'usage_die()' "$REPO_ROOT/bin/aibox" || false
  grep -q 'die_code()' "$REPO_ROOT/bin/aibox" || false
  grep -q 'return 3$' "$REPO_ROOT/bin/aibox" || false
  grep -q 'return 4$' "$REPO_ROOT/bin/aibox" || false
}

# ---------- doctor: one verb, every module -----------------------------------

@test "doctor: every module declares the standard action set" {
  local f m acts
  for f in "$REPO_ROOT"/tools/*/module.yaml; do
    m="$(basename "$(dirname "$f")")"
    acts="$(awk '/^actions:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{print $2}' "$f")"
    for need in start stop restart status status logs doctor; do
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
  printf '%s\n' 'status_info() { printf "version=1.2.3\nstate=stopped\nendpoint=http://127.0.0.1:19\n"; }' >"$mod/lib.sh"
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
  # the start arm may carry a first-run preparation call before the alias, so scan the arm
  awk '/^start\)/{f=1} f&&/action="up"/{ok=1} f&&/;;/{f=0} END{exit !ok}' \
    "$REPO_ROOT/tools/openmaic/svc.sh" || { echo "openmaic: no start alias"; false; }
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

@test "dispatch CLIs: the standard lifecycle verbs resolve (alias or the CLI's own)" {
  local m d svc cli_f cf found
  for d in "$REPO_ROOT"/tools/*/; do
    m="$(basename "${d%/}")"; svc="${d%/}/svc.sh"
    [ -f "${svc}" ] || continue
    grep -qE 'exec "\$\{?CLI\}?"' "${svc}" || continue
    for v in start stop restart; do
      found=0
      grep -qE "^[[:space:]]*[a-z_|[:space:]]*${v}[a-z_|[:space:]]*\)" "${svc}" && found=1
      if [ "${found}" = "0" ]; then
        for cf in "${d%/}"/cli/*; do
          [ -f "${cf}" ] || continue
          grep -qE "^[[:space:]]*[a-z_|[:space:]]*${v}[a-z_|[:space:]]*\)" "${cf}" && found=1
        done
      fi
      [ "${found}" = "1" ] || { echo "${m}: '${v}' would reach the CLI as an unknown command"; false; }
    done
  done
}

@test "windmill: aibox windmill start dispatches to the CLI's up verb" {
  # svc.sh resolves the CLI from the install destination or PATH (it refuses to
  # guess) — provide the repo CLI on PATH; -h is parsed before docker is needed,
  # so this stays a pure dispatch check.
  mkdir -p "$AIBOX_HOME/bin"
  ln -sf "$REPO_ROOT/tools/windmill/cli/windmill" "$AIBOX_HOME/bin/windmill"
  local env="PATH='$AIBOX_HOME/bin:$PATH' WM_DIR='$AIBOX_HOME/apps/windmill' WM_CONF_FILE='$AIBOX_HOME/windmill.conf'"
  run bash -c "cd '$REPO_ROOT' && env $env bash tools/windmill/svc.sh start --help"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"up"* ]] || { echo "start did not reach the CLI's up: $output"; false; }
  run bash -c "cd '$REPO_ROOT' && env $env bash tools/windmill/svc.sh stop --help"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run bash -c "cd '$REPO_ROOT' && env $env bash tools/windmill/svc.sh restart --help"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "openmaic: up without a deployed app explains the missing step (exit 30, no raw cd error)" {
  local d="$BATS_TMPDIR/omc-empty" b="$BATS_TMPDIR/omc-bin"
  rm -rf "$d" "$b"; mkdir -p "$d" "$b"
  printf '#!/bin/sh\nexit 0\n' >"$b/docker"; chmod +x "$b/docker"
  run env PATH="$b:$PATH" OPENMAIC_BASE_DIR="$d" bash "$REPO_ROOT/tools/openmaic/cli/openmaic" up
  [ "$status" -eq 30 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *"not deployed on this host yet"* ]] || false
  [[ "$output" == *"aibox openmaic install"* ]] || false
  [[ "$output" != *"No such file or directory"* ]] || false
}

@test "first-run preparation: helper no-ops, refuses (--no-prepare) and runs the declared step" {
  local frag y art s
  frag="$(mktemp)"; s="$(mktemp)"
  sed -n '/^module_ensure_deployed() {/,/^}/p' "$REPO_ROOT/tools/_shared/lib/58-prepare.sh" >"$frag"
  [ -s "$frag" ] || false
  y="$BATS_TMPDIR/fr.yaml"; art="$BATS_TMPDIR/fr-artifact"
  printf 'first_run: install\nfirst_run_note: "clone + build"\n' >"$y"
  cat >"$s" <<'SH'
# the output helpers live in the shared include (00-out.sh) — stub them here
warn() { printf '%s\n' "$*" >&2; }
log()  { printf '%s\n' "$*"; }
meta_field() { case "$2" in first_run) printf install ;; first_run_note) printf 'clone + build' ;; esac; }
. "$FRAG"
module_ensure_deployed x "$FR_YAML" "$FR_ART" "$FR_PREP"
SH
  # (a) artifact present -> silent no-op
  : >"$art"
  run bash -c "env FRAG='$frag' FR_YAML='$y' FR_ART='$art' FR_PREP='touch $art' bash '$s' 2>&1"
  [ "$status" -eq 0 ] || false
  [ -z "$output" ] || false
  # (b) missing + --no-prepare -> exit 30, prints the command, runs NOTHING
  rm -f "$art"
  run bash -c "env AIBOX_NO_PREPARE=1 FRAG='$frag' FR_YAML='$y' FR_ART='$art' FR_PREP='touch $art' bash '$s' 2>&1"
  [ "$status" -eq 30 ] || false
  case "$output" in *"skipped (--no-prepare)"*) ;; *) false ;; esac
  [ ! -e "$art" ] || false
  # (c) missing + a prepare command that creates the artifact -> runs it and succeeds
  run bash -c "env FRAG='$frag' FR_YAML='$y' FR_ART='$art' FR_PREP='touch $art' bash '$s' 2>&1"
  [ "$status" -eq 0 ] || false
  case "$output" in *"first run:"*) ;; *) false ;; esac
  [ -e "$art" ] || false
  rm -f "$frag" "$s"
}

@test "first-run preparation: openmaic start refuses the heavy deploy with --no-prepare (exit 30)" {
  local d="$BATS_TMPDIR/omc-fr" b="$BATS_TMPDIR/omc-fr-bin"
  rm -rf "$d" "$b"; mkdir -p "$d" "$b"
  printf '#!/bin/sh\nexit 0\n' >"$b/docker"; chmod +x "$b/docker"
  # Pre-seed the trap that fooled the old guard: upstream's docker-compose.yml exists as
  # soon as the source is cloned, so an interrupted deploy looked "done" while .env.local
  # (the config artifact `up` cannot create) was missing.
  mkdir -p "$d/app"; : >"$d/app/docker-compose.yml"
  # the hook requires the ops CLI on PATH first (that is what `aibox install openmaic` does)
  run env PATH="$REPO_ROOT/tools/openmaic/cli:$b:$PATH" OPENMAIC_BASE_DIR="$d" AIBOX_NO_PREPARE=1 \
    bash "$REPO_ROOT/tools/openmaic/svc.sh" start 2>&1
  [ "$status" -eq 30 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *"first-run step skipped"* ]] || false
  [[ "$output" == *"aibox openmaic install"* ]] || false
  [[ "$output" != *"No such file or directory"* ]] || false
}

@test "openmaic: version resolution falls back to git ls-remote when the release API fails" {
  # The API is rate-limited and can be blocked while the git endpoint works (live on
  # 50.55: api.github.com empty, ls-remote listed every tag) — the CLI must not die on
  # "cannot determine target version" while the fetch channel is perfectly usable.
  run grep -q 'ls-remote --tags --refs' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'OPENMAIC_TAG' "$REPO_ROOT/tools/openmaic/svc.sh"
  [ "$status" -eq 0 ] || false
  run grep -q 'OPENMAIC_TAG' "$REPO_ROOT/tools/openmaic/module.yaml"
  [ "$status" -eq 0 ]
}

@test "openmaic: first-run config bootstrap creates .env + .env.local and prints the access code" {
  local frag dir s
  frag="$(mktemp)"; s="$(mktemp)"; dir="$BATS_TMPDIR/omc-boot"; rm -rf "$dir"; mkdir -p "$dir"
  sed -n '/^bootstrap_config() {/,/^}/p' "$REPO_ROOT/tools/openmaic/cli/openmaic" >"$frag"
  [ -s "$frag" ] || false
  printf 'PERSISTENCE_DEV_TOKEN=\nACCESS_CODE=\nOPENAI_API_KEY=\n' >"$dir/.env.example"
  cat >"$s" <<'SH'
C_BLU=""; C_RST=""
. "$FRAG"
APP_DIR="$FR_APP" bootstrap_config
SH
  # (a) generated: both files exist, the token is non-empty, the code is PRINTED
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$dir/.env" ] || false
  [ -f "$dir/.env.local" ] || false
  grep -qE '^PERSISTENCE_DEV_TOKEN=.{16,}$' "$dir/.env.local" || false
  grep -qE '^ACCESS_CODE=.{16,}$' "$dir/.env.local" || false
  grep -qE '^OPENMAIC_PORT=31140$' "$dir/.env" || false
  grep -qE '^OPENMAIC_PUBLISH_ADDRESS=0\.0\.0\.0$' "$dir/.env" || false
  case "$output" in *"ACCESS CODE:"*) ;; *) false ;; esac
  # (b) OPENMAIC_ACCESS_CODE is honoured (and nothing is regenerated)
  rm -rf "$dir"; mkdir -p "$dir"; printf 'ACCESS_CODE=\n' >"$dir/.env.example"
  run bash -c "env FRAG='$frag' FR_APP='$dir' OPENMAIC_ACCESS_CODE=my-code bash '$s' 2>&1"
  grep -q '^ACCESS_CODE=my-code$' "$dir/.env.local" || false
  # (c) an existing config is left alone (no-op)
  before="$(cat "$dir/.env.local")"
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$(cat "$dir/.env.local")" = "$before" ] || false
  rm -f "$frag" "$s"
}

@test "openmaic: published binding defaults to 0.0.0.0 at the reserved port (not upstream's 3000)" {
  # Upstream's compose template binds loopback-only at the common-service port 3000
  # ('${OPENMAIC_PUBLISH_ADDRESS:-127.0.0.1}:${OPENMAIC_PORT:-3000}:3000') — the CLI must
  # render 0.0.0.0:<reserved band> instead (env/conf > .env > defaults), and the exports
  # must actually reach compose (conf values are sourced unexported).
  local frag dir s
  frag="$(mktemp)"; s="$(mktemp)"; dir="$BATS_TMPDIR/omc-pub"; rm -rf "$dir"; mkdir -p "$dir"
  {
    sed -n '/^published_host_port() {/,/^}/p' "$REPO_ROOT/tools/openmaic/cli/openmaic"
    sed -n '/^published_address() {/,/^}/p' "$REPO_ROOT/tools/openmaic/cli/openmaic"
    sed -n '/^publish_env_exports() {/,/^}/p' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  } >"$frag"
  [ -s "$frag" ] || false
  cat >"$s" <<'SH'
. "$FRAG"
APP_DIR="$FR_APP"
echo "port=$(published_host_port) addr=$(published_address)"
SH
  # (a) defaults: reserved-band port on all interfaces
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$output" = "port=31140 addr=0.0.0.0" ] || false
  # (b) the deploy's .env wins when no env/conf value is set
  printf 'OPENMAIC_PORT=31500\nOPENMAIC_PUBLISH_ADDRESS=192.0.2.10\n' >"$dir/.env"
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$output" = "port=31500 addr=192.0.2.10" ] || false
  # (c) environment overrides the .env (compose interpolation: env > .env)
  run bash -c "env FRAG='$frag' FR_APP='$dir' OPENMAIC_PORT=31600 OPENMAIC_PUBLISH_ADDRESS=127.0.0.1 bash '$s' 2>&1"
  [ "$output" = "port=31600 addr=127.0.0.1" ] || false
  # (d) publish_env_exports exports both (unexported conf values must reach compose)
  cat >"$s" <<'SH'
. "$FRAG"
APP_DIR="$FR_APP"
publish_env_exports
env | grep -E '^OPENMAIC_(PORT|PUBLISH_ADDRESS)=' | sort
SH
  rm -f "$dir/.env"
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  printf '%s\n' "$output" | grep -q '^OPENMAIC_PORT=31140$' || false
  printf '%s\n' "$output" | grep -q '^OPENMAIC_PUBLISH_ADDRESS=0\.0\.0\.0$' || false
  # (e) the compose seam actually invokes the exports
  run grep -c 'publish_env_exports' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$output" -ge 3 ] || false
  rm -f "$frag" "$s"
}

@test "openmaic: the access code is re-stated at deploy-complete and hinted in status" {
  # It was printed once mid-deploy (step 2/6) and drowned in the build output; the
  # summary now repeats it + the retrieval command, and status points at the command
  # (the code itself stays out of status — that output gets pasted/screenshotted).
  run grep -q 'log-in password' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 're-display: openmaic config get ACCESS_CODE' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q "printf '  login" "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
}

@test "openmaic: the publish knobs are injected into upstream v1.1.2's hardcoded ports" {
  # v1.1.2 ships `- '3000:3000'` (all-interfaces common port); the ${OPENMAIC_PORT}
  # interpolation exists only in unreleased upstream main. The CLI must inject it so the
  # knobs render on any version — live-caught on 50.55: the exports landed in a template
  # with nothing to interpolate, so the binding stayed 0.0.0.0:3000.
  local frag dir s
  frag="$(mktemp)"; s="$(mktemp)"; dir="$BATS_TMPDIR/omc-ports"; rm -rf "$dir"; mkdir -p "$dir"
  sed -n '/^patch_publish_ports() {/,/^}/p' "$REPO_ROOT/tools/openmaic/cli/openmaic" >"$frag"
  [ -s "$frag" ] || false
  cat >"$s" <<'SH'
C_YEL=""; C_RST=""; C_GRN=""; C_RED=""
warn() { printf 'warn %s\n' "$*"; }
dim()  { printf 'dim %s\n'  "$*"; }
ok()   { printf 'ok %s\n'   "$*"; }
err()  { printf 'err %s\n'  "$*"; }
DRY_RUN=0
. "$FRAG"
APP_DIR="$FR_APP"
patch_publish_ports
SH
  # (a) v1.1.2 shape -> interpolated, idempotent on the second run
  cat >"$dir/docker-compose.yml" <<'YML'
services:
  openmaic:
    ports:
      - '3000:3000'
    env_file:
      - .env.local
YML
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'OPENMAIC_PUBLISH_ADDRESS:-0.0.0.0}:\${OPENMAIC_PORT:-31140}:3000' "$dir/docker-compose.yml" || false
  after="$(cat "$dir/docker-compose.yml")"
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$(cat "$dir/docker-compose.yml")" = "$after" ] || false
  # (b) upstream-main shape -> untouched
  cat >"$dir/docker-compose.yml" <<'YML'
    ports:
      - '${OPENMAIC_PUBLISH_ADDRESS:-127.0.0.1}:${OPENMAIC_PORT:-3000}:3000'
YML
  before="$(cat "$dir/docker-compose.yml")"
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$(cat "$dir/docker-compose.yml")" = "$before" ] || false
  # (c) unexpected format -> warns, exits 0, file untouched
  printf "    ports:\n      - '9999:9999'\n" >"$dir/docker-compose.yml"
  run bash -c "env FRAG='$frag' FR_APP='$dir' bash '$s' 2>&1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  case "$output" in *warn*) ;; *) false ;; esac
  grep -q "9999:9999" "$dir/docker-compose.yml" || false
  rm -f "$frag" "$s"
}

@test "openmaic: the health probe follows the PUBLISHED port (the 31140 default must not fake 'not ready')" {
  run grep -q 'deployed_health_url()' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'effective_health_url' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'OPENMAIC_APP_PORT' "$REPO_ROOT/tools/openmaic/module.yaml"
  [ "$status" -eq 0 ]
}

@test "openmaic: the source fetch retries and gets progressively shallower (throttled links)" {
  run grep -q 'OPENMAIC_FETCH_ATTEMPTS' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'shallow="--depth 1"' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'FETCH_ATTEMPTS' "$REPO_ROOT/tools/openmaic/module.yaml"
  [ "$status" -eq 0 ]
}

@test "openmaic: each fetch attempt is time-bounded (a throttled link must not burn the window)" {
  run grep -q 'OPENMAIC_FETCH_TIMEOUT' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'TO="timeout ' "$REPO_ROOT/tools/openmaic/cli/openmaic"
  [ "$status" -eq 0 ] || false
  run grep -q 'OPENMAIC_FETCH_TIMEOUT' "$REPO_ROOT/tools/openmaic/module.yaml"
  [ "$status" -eq 0 ]
}


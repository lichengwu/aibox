#!/usr/bin/env bats
# Integration: `aibox autoclean` against a REAL docker daemon — the proofs must
# hold with real objects: a volume of an UNINSTALLED module (attributable via the
# residue declaration captured at install time) is reclaimed, while the volume of
# an INSTALLED module is never touched.

setup_file() {
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  SANDBOX="$(mktemp -d 2>/dev/null || echo /tmp/aibox-it-ac.$$)"
  export SANDBOX AIBOX_HOME="$SANDBOX/home" AIBOX_BIN_DIR="$SANDBOX/bin"
  export AIBOX_RAW="file://$REPO_ROOT" AIBOX_MOD_DIR="$AIBOX_HOME/modules"
  export AIBOX_INSTALLED="$AIBOX_HOME/installed.sh"
  mkdir -p "$AIBOX_HOME/modules/installedmod" "$AIBOX_BIN_DIR"
  # installed module (cache dir present) declares vol_ac_installed
  printf 'name: installedmod\nversion: 1.0.0\n' >"$AIBOX_HOME/modules/installedmod/module.yaml"
  printf 'installedmod_residue_volumes=^vol_ac_installed$\norphanmod_residue_volumes=^vol_ac_orphan$\n' >"$AIBOX_HOME/residue.conf"
  docker volume create vol_ac_installed >/dev/null
  docker volume create vol_ac_orphan >/dev/null
  docker volume create vol_ac_foreign >/dev/null
}

teardown_file() {
  docker volume rm -f vol_ac_installed vol_ac_orphan vol_ac_foreign >/dev/null 2>&1 || true
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true
}

@test "reclaim half: the orphan goes, an installed module's volume and a foreign one stay" {
  # The RECLAIM half is asserted in isolation: the no-args `--apply` ALSO sweeps
  # every module's declared residue (purge's documented semantics, kept on
  # purpose), which would legitimately include the installed module's volume.
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$AIBOX_MOD_DIR' AIBOX_INSTALLED='$AIBOX_INSTALLED' AIBOX_RAW='file://$REPO_ROOT'
    source '$REPO_ROOT/bin/aibox'
    _autoclean_reclaim_scan
    _autoclean_reclaim_report"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"vol_ac_orphan"* ]] || { echo "orphan volume not reported: $output"; false; }
  [[ "$output" != *"vol_ac_installed"* ]] || { echo "installed module's volume reported by the reclaim half"; false; }
  [[ "$output" != *"vol_ac_foreign"* ]] || { echo "foreign volume reported by the reclaim half"; false; }
  docker volume inspect vol_ac_orphan >/dev/null 2>&1 || { echo "the report deleted something!"; false; }

  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_MOD_DIR='$AIBOX_MOD_DIR' AIBOX_INSTALLED='$AIBOX_INSTALLED' AIBOX_RAW='file://$REPO_ROOT'
    source '$REPO_ROOT/bin/aibox'
    _autoclean_reclaim_scan
    _autoclean_reclaim_apply
    echo applied"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ! docker volume inspect vol_ac_orphan >/dev/null 2>&1 || { echo "orphan volume survived --apply"; false; }
  docker volume inspect vol_ac_installed >/dev/null 2>&1 || { echo "installed module's DATA was deleted!"; false; }
  docker volume inspect vol_ac_foreign >/dev/null 2>&1 || { echo "foreign volume was deleted!"; false; }
}

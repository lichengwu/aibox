#!/usr/bin/env bats
# Safe reclamation (`aibox autoclean`): only objects that pass BOTH proofs —
# aibox can prove ownership, and nothing references them — may go. docker is
# stubbed; the stub records every mutation so we can assert exactly what was
# touched (and what never was).

load test_helper

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-reclaim.$$")"
  export HOME="$SANDBOX/userhome"; mkdir -p "$HOME"
  export AIBOX_HOME="$SANDBOX/home"; mkdir -p "$AIBOX_HOME/apps"
  export AIBOX_BIN_DIR="$SANDBOX/bin"; mkdir -p "$AIBOX_BIN_DIR"
  export AIBOX_RAW="file://$REPO_ROOT"
  export DOCKER_LOG="$SANDBOX/docker.log"; : >"$DOCKER_LOG"
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1 $2" in
'image ls')
  case "$*" in
  *'--filter dangling=true -q'*) printf '%s\n' sha256:dangling1 sha256:dangling2 ;;
  *'{{.ID}}'*) printf '%s\n' sha256:keep1 sha256:keep2 sha256:keep3 ;;
  *'{{.Repository}}:{{.Tag}} {{.CreatedAt}}'*)
    printf '%s\n' \
      'reg/app:old 2026-01-01' 'reg/app:new 2026-06-01' \
      'reg/app:pinned 2025-01-01' 'reg/other:stale 2026-05-01' ;;
  *'{{.Repository}}:{{.Tag}}'*) printf '%s\n' reg/app:old reg/app:new reg/app:pinned reg/other:stale ;;
  esac ;;
'image inspect') printf '104857600\n' ;;
'image rm') printf '%s\n' "REMOVED-IMAGE $3" >>"$DOCKER_LOG" ;;
'ps -a')
  case "$*" in
  *'--format {{.Image}}'*) printf '%s\n' 'reg/app:pinned' ;;
  *'--filter volume=vol_busy -aq'*) printf '%s\n' c123 ;;
  *'--filter volume='*) : ;;
  esac ;;
'volume ls') printf '%s\n' vol_orphan vol_busy vol_installed vol_foreign ;;
'volume inspect') printf '/var/lib/docker/volumes/x/_data\n' ;;
'volume rm') printf '%s\n' "REMOVED-VOLUME $3" >>"$DOCKER_LOG" ;;
'builder du') printf 'Total: 3.4GB\n' ;;
'builder prune') printf '%s\n' "PRUNED-CACHE" >>"$DOCKER_LOG" ;;
'system df') printf 'Images=5.0GB\n' ;;
*) : ;;
esac
STUB
  chmod +x "$SANDBOX/bin/docker"
  export PATH="$SANDBOX/bin:$PATH"
  # knowledge: which modules exist and what residue they declare
  mkdir -p "$AIBOX_HOME/modules/installedmod"
  printf 'name: installedmod\nversion: 1.0.0\n' >"$AIBOX_HOME/modules/installedmod/module.yaml"
  printf 'installedmod_residue_volumes=^vol_installed$\norphanmod_residue_volumes=^vol_orphan$\n' >"$AIBOX_HOME/residue.conf"
  # a rollback point pins reg/app:pinned; a backup pins reg/app:old
  mkdir -p "$AIBOX_HOME/upgrades" "$AIBOX_HOME/apps/data"
  printf 'from=reg/app:old\nto=reg/app:new\n' >"$AIBOX_HOME/upgrades/data.state"
  printf 'DATA_IMAGE=reg/app:old\n' >"$AIBOX_HOME/apps/data/.env"
  printf 'DATA_IMAGE=reg/app:backup\n' >"$AIBOX_HOME/apps/data/.env.bak.20260101.1"
  printf 'DATA_IMAGE=reg/app:older\n' >"$AIBOX_HOME/apps/data/.env.bak.20250101.1"
  printf 'DATA_IMAGE=reg/app:newest\n' >"$AIBOX_HOME/apps/data/.env.bak.20260301.1"
  # distinct mtimes, set AFTER every write (the function orders by mtime — which is
  # exactly what real timestamped backup names do)
  touch -t 202501010101 "$AIBOX_HOME/apps/data/.env.bak.20250101.1" 2>/dev/null || true
  touch -t 202601010101 "$AIBOX_HOME/apps/data/.env.bak.20260101.1" 2>/dev/null || true
  touch -t 202603010101 "$AIBOX_HOME/apps/data/.env.bak.20260301.1" 2>/dev/null || true
}
teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX" 2>/dev/null || true; }

@test "dangling images are reclaimable; tagged ones are not touched" {
  run bash -c "source '$AIBOX_BIN'; reclaim_dangling_images"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"sha256:dangling1"* ]] && [[ "$output" == *"sha256:dangling2"* ]] || { echo "$output"; false; }
  [[ "$output" != *"keep1"* ]] || false
}

@test "stale tags: pins, rollback points, backups and containers are protected" {
  run bash -c "source '$AIBOX_BIN'; reclaim_stale_tags 2"
  [ "$status" -eq 0 ] || false
  # reg/app:pinned is referenced by a container; reg/app:old is a pin AND a rollback point
  [[ "$output" != *"reg/app:pinned"* ]] || { echo "container-referenced tag listed: $output"; false; }
  [[ "$output" != *"reg/app:old"* ]] || { echo "rollback-point tag listed: $output"; false; }
  # the newest 2 per repo (app:new + other:stale) are the buffer — the third app tag goes
  [[ "$output" != *"reg/app:new"* ]] || { echo "buffer tag listed: $output"; false; }
  [[ "$output" != *"reg/other:stale"* ]] || { echo "buffer tag (other repo) listed: $output"; false; }
}

@test "orphan volumes: only proven-ours + unreferenced + module uninstalled" {
  run bash -c "source '$AIBOX_BIN'; reclaim_orphan_volumes"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"vol_orphan"* ]] || { echo "$output"; false; }
  [[ "$output" != *"vol_busy"* ]] || { echo "container-referenced volume listed"; false; }
  [[ "$output" != *"vol_installed"* ]] || { echo "installed module's data listed"; false; }
  [[ "$output" != *"vol_foreign"* ]] || { echo "foreign volume listed"; false; }
}

@test "stale .env backups: newest 2 stay, older ones are listed" {
  run bash -c "source '$AIBOX_BIN'; reclaim_stale_env_backups 2"
  [[ "$output" == *"20250101"* ]] || { echo "$output"; false; }
  [[ "$output" != *"20260301"* ]] || { echo "newest backup listed"; false; }
  [[ "$output" != *"apps/data/.env "* ]] || { echo "the live .env must never be listed"; false; }
}

@test "autoclean --apply deletes exactly what was reported (and nothing else)" {
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT' PATH='$SANDBOX/bin:$PATH'
    source '$AIBOX_BIN'
    _autoclean_reclaim_scan; _autoclean_reclaim_apply
    cat '$DOCKER_LOG'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"REMOVED-IMAGE sha256:dangling1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"REMOVED-VOLUME vol_orphan"* ]] || false
  [[ "$output" == *"PRUNED-CACHE"* ]] || false
  [[ "$output" != *"REMOVED-VOLUME vol_installed"* ]] || { echo "deleted an installed module's data!"; false; }
  [[ "$output" != *"REMOVED-VOLUME vol_busy"* ]] || false
  [[ "$output" != *"REMOVED-VOLUME vol_foreign"* ]] || false
  [[ "$output" != *"REMOVED-IMAGE reg/app:old"* ]] || { echo "deleted a rollback image!"; false; }
}

@test "the purge verb is gone; autoclean is the single cleanup verb" {
  run bash -c "export AIBOX_HOME='$AIBOX_HOME' AIBOX_RAW='file://$REPO_ROOT'; bash '$AIBOX_BIN' purge"
  [ "$status" -ne 0 ] || { echo "purge still exists"; false; }
  [[ "$output" == *"Unknown"* ]] || { echo "$output"; false; }
  run bash -c "source '$AIBOX_BIN'; _verb_help autoclean"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"safe reclamation"* || "$output" == *"reclaim what is provably safe"* ]] || { echo "$output" | head -3; false; }
  ! grep -rq 'aibox purge' "$REPO_ROOT/src/aibox" || { echo "src still advertises the purge verb"; false; }
  grep -q 'autoclean' "$REPO_ROOT/docs/module-spec.md" || false
}

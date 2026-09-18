#!/usr/bin/env bash
# aibox-purge — standalone residue cleaner for aibox and its modules.
#
# WHY standalone: after `aibox self uninstall` (or a manual rm) the manager and
# module hooks are gone, but data/config residue remains — docker volumes,
# apps/ directories, /etc/<module> configs, systemd/launchd units, dispatched
# binaries (mihomo/openmaic/windmill), the npm global package, rc PATH blocks.
# This script is SELF-CONTAINED (embedded residue map, zero dependencies,
# bash 3.2 compatible, offline) so it works when nothing else does.
#
# Get it anytime (even after aibox is gone):
#   curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/scripts/purge.sh -o aibox-purge && bash aibox-purge
#
# Usage:
#   aibox-purge                       scan + categorized report (dry-run, default)
#   aibox-purge --apply [--yes]       delete what the scan found (confirm unless --yes)
#   aibox-purge --apply --only=base,gitlab   limit to modules ('manager' is a scope too)
#   aibox-purge --apply --except=base        keep base data, purge the rest
#   aibox-purge --apply --only=manager       clean just the aibox manager residue
#   aibox-purge --apply --stop        also stop RUNNING containers/mihomo before deleting
#   aibox-purge --apply --keep-manager     purge module residue, keep aibox itself
#
# Safety: deletion targets come ONLY from the embedded map + existence checks;
# volumes of RUNNING containers are refused without --stop; dry-run is default.
#
# MODULE AUTHORS: when adding a module, extend the residue_* map functions below
# (validator warns when a tools/<name> module has no map entry).
set -uo pipefail

# ---------- roots (env-overridable — used by tests and exotic installs) ----------
USER_HOME="${PURGE_HOME:-$HOME}"
AIBOX_HOME="${PURGE_AIBOX_HOME:-${AIBOX_HOME:-$USER_HOME/.aibox}}"
BIN_DIR="${PURGE_BIN_DIR:-${AIBOX_BIN_DIR:-$USER_HOME/.local/bin}}"
ETC_ROOT="${PURGE_ETC:-/etc}"
SYSTEMD_SYSTEM_DIR="${PURGE_SYSTEMD_DIR:-/etc/systemd/system}"
USE_DOCKER=1
if [ "${PURGE_NO_DOCKER:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
  USE_DOCKER=0
fi
DOCKER_UP=0
if [ "$USE_DOCKER" = 1 ] && docker info >/dev/null 2>&1; then DOCKER_UP=1; fi

MODULES_KNOWN="base clash pi-web openmaic windmill gitlab"

# ---------- output ----------
if [ -t 1 ]; then
  C_RED="$(printf '\033[31m')"; C_YEL="$(printf '\033[33m')"; C_GRN="$(printf '\033[32m')"
  C_CYA="$(printf '\033[36m')"; C_DIM="$(printf '\033[2m')"; C_RST="$(printf '\033[0m')"
else
  C_RED=""; C_YEL=""; C_GRN=""; C_CYA=""; C_DIM=""; C_RST=""
fi
log()  { printf '%s[purge]%s %s\n' "$C_CYA" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
bad()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
die()  { bad "$*"; exit 1; }

# ---------- args ----------
APPLY=0; ASSUME_YES=0; KEEP_MANAGER=0; STOP_RUNNING=0
ONLY=""; EXCEPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)         APPLY=1 ;;
    --yes|-y)        ASSUME_YES=1 ;;
    --keep-manager)  KEEP_MANAGER=1 ;;
    --stop)          STOP_RUNNING=1 ;;
    --only=*)        ONLY="${1#--only=}" ;;
    --except=*)      EXCEPT="${1#--except=}" ;;
    -h|--help)       sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown option: $1 (try: aibox-purge --help)" ;;
  esac
  shift
done

_in_csv() {
  needle="$1"; csv="$2"; old_ifs="$IFS"; IFS=','
  for t in $csv; do
    if [ "$t" = "$needle" ]; then IFS="$old_ifs"; return 0; fi
  done
  IFS="$old_ifs"; return 1
}

module_selected() { # $1 = module name → 0 if in scope
  m="$1"
  if [ -n "$ONLY" ]; then _in_csv "$m" "$ONLY" || return 1; fi
  if [ -n "$EXCEPT" ] && _in_csv "$m" "$EXCEPT"; then return 1; fi
  return 0
}

# ---------- the residue map (single source of cleanup knowledge) ----------
# Filesystem residues: directories/files that may survive uninstall.
residue_paths() { # $1 = module → one path per line (may not exist; scan filters)
  case "$1" in
    base)
      printf '%s\n' "$AIBOX_HOME/apps/base"
      for f in "$AIBOX_HOME"/base*.env; do [ -e "$f" ] && printf '%s\n' "$f"; done ;;
    clash)     printf '%s\n' "$AIBOX_HOME/apps/clash" "$BIN_DIR/mihomo" ;;
    pi-web)
      printf '%s\n' "$AIBOX_HOME/apps/pi-web" \
        "$USER_HOME/.config/systemd/user/pi-web.service" \
        "$USER_HOME/.config/systemd/user/com.agegr.pi-web.service" \
        "$USER_HOME/.local/share/pi-web" \
        "$USER_HOME/Library/LaunchAgents/pi-web.plist" \
        "$USER_HOME/Library/LaunchAgents/com.agegr.pi-web.plist" ;;
    openmaic)  printf '%s\n' "$AIBOX_HOME/apps/openmaic" "$BIN_DIR/openmaic" "$ETC_ROOT/openmaic" ;;
    windmill)  printf '%s\n' "$AIBOX_HOME/apps/windmill" "$BIN_DIR/windmill" "$ETC_ROOT/windmill" ;;
    gitlab)    printf '%s\n' "$AIBOX_HOME/apps/gitlab" ;;
  esac
}

residue_volume_patterns() { # $1 = module → docker volume name ERE (empty = none)
  case "$1" in
    base)     printf '%s' '^aibox_(pg|redis)_data' ;;
    windmill) printf '%s' '^windmill_' ;;
    openmaic) printf '%s' '^app_openmaic' ;;
    gitlab)   printf '%s' '^gitlab_gitlab_(config|logs|data)$' ;;
  esac
}

residue_container_patterns() { # $1 = module → docker container-name ERE
  case "$1" in
    base)     printf '%s' '^aibox-base(-[A-Za-z0-9]+)?-(postgres|redis)$' ;;
    clash)    printf '%s' '^mihomo$' ;;
    windmill) printf '%s' '^windmill-' ;;
    openmaic) printf '%s' '^app-(openmaic|postgres|render-service)-[0-9]+$' ;;
    gitlab)   printf '%s' '^aibox-gitlab$' ;;
  esac
}

residue_systemd_system_globs() { # $1 = module → unit file globs under SYSTEMD_SYSTEM_DIR
  case "$1" in
    windmill) printf '%s\n' "$SYSTEMD_SYSTEM_DIR/windmill-backup.service" "$SYSTEMD_SYSTEM_DIR/windmill-backup.timer" \
                            "$SYSTEMD_SYSTEM_DIR/windmill-update-check.service" "$SYSTEMD_SYSTEM_DIR/windmill-update-check.timer" ;;
  esac
}

residue_npm_packages() { # $1 = module → global npm package
  case "$1" in
    pi-web) printf '%s' '@agegr/pi-web' ;;
  esac
}

residue_processes() { # $1 = module → pgrep pattern for lingering user-space processes
  case "$1" in
    clash) printf '%s' 'mihomo' ;;
  esac
}

# Manager residue (aibox itself) — handled separately from modules.
manager_paths() {
  printf '%s\n' "$BIN_DIR/aibox"
  if [ -d "$AIBOX_HOME" ]; then
    for d in "$AIBOX_HOME"/*; do
      [ -e "$d" ] || continue
      case "$(basename "$d")" in apps) continue ;; esac   # apps/ belongs to the modules
      printf '%s\n' "$d"
    done
  fi
}

# ---------- scan helpers ----------
dir_size() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

docker_names() { # $1 = 'volumes'|'containers' $2 = ERE
  [ "$DOCKER_UP" = 1 ] || return 0
  if [ "$1" = volumes ]; then
    docker volume ls -q 2>/dev/null | grep -E "$2" || true
  else
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$2" || true
  fi
}

container_state() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || printf 'unknown'; }

rc_files_with_marker() {
  for rc in "$USER_HOME/.zshrc" "$USER_HOME/.bashrc" "$USER_HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -q '^# aibox$' "$rc" 2>/dev/null && printf '%s\n' "$rc"
  done
  return 0
}

# ---------- collect findings into a flat list ----------
# Item format: "<scope>\t<kind>\t<target>\t<note>"  (scope = module name or 'manager')
FINDINGS=""
add_finding() { FINDINGS="${FINDINGS}$1	$2	$3	$4
"; FOUND_COUNT=$((FOUND_COUNT + 1)); }
FOUND_COUNT=0

scan_module() {
  m="$1"
  # filesystem paths
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      add_finding "$m" "dir" "$p" "$(dir_size "$p")"
    elif [ -e "$p" ]; then
      add_finding "$m" "file" "$p" ""
    fi
  done <<PATHS
$(residue_paths "$m")
PATHS
  # docker volumes / containers
  if [ "$DOCKER_UP" = 1 ]; then
    vpat="$(residue_volume_patterns "$m")"
    if [ -n "$vpat" ]; then
      for v in $(docker_names volumes "$vpat"); do
        add_finding "$m" "volume" "$v" ""
      done
    fi
    cpat="$(residue_container_patterns "$m")"
    if [ -n "$cpat" ]; then
      for c in $(docker_names containers "$cpat"); do
        add_finding "$m" "container" "$c" "$(container_state "$c")"
      done
    fi
  fi
  # systemd system units
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ -e "$u" ] && add_finding "$m" "systemd" "$u" ""
  done <<UNITS
$(residue_systemd_system_globs "$m")
UNITS
  # npm global package (guard: PURGE_NO_NPM=1 for tests/CI — never touch host globals)
  np=""
  if [ "${PURGE_NO_NPM:-0}" != 1 ]; then np="$(residue_npm_packages "$m")"; fi
  if [ -n "$np" ] && command -v npm >/dev/null 2>&1; then
    if npm ls -g "$np" --depth=0 >/dev/null 2>&1; then
      add_finding "$m" "npm" "$np" "global"
    fi
  fi
  # lingering processes (guard: PURGE_NO_PROCS=1 for tests/CI — never touch host processes)
  pp=""
  [ "${PURGE_NO_PROCS:-0}" = 1 ] || pp="$(residue_processes "$m")"
  if [ -n "$pp" ]; then
    pids="$(pgrep -x "$pp" 2>/dev/null | tr '\n' ' ' || true)"
    [ -n "$pids" ] && add_finding "$m" "process" "$pp" "pids: $pids"
  fi
  return 0
}

scan_manager() {
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      add_finding "manager" "dir" "$p" "$(dir_size "$p")"
    elif [ -e "$p" ]; then
      add_finding "manager" "file" "$p" ""
    fi
  done <<MP
$(manager_paths)
MP
  for rc in $(rc_files_with_marker); do
    add_finding "manager" "rc" "$rc" "# aibox PATH block"
  done
  return 0
}

# ---------- scan ----------
for m in $MODULES_KNOWN; do
  module_selected "$m" && scan_module "$m"
done
# 'manager' is itself a scope: --only/--except filter it like a module
# (--only=windmill must NOT delete bin/aibox; --only=manager cleans just aibox).
if [ "$KEEP_MANAGER" = 0 ] && module_selected manager; then
  scan_manager
fi

# ---------- report ----------
printf '\n%s── aibox residue scan%s (%s)\n' "$C_CYA" "$C_RST" "$([ "$APPLY" = 1 ] && printf 'apply mode' || printf 'dry-run — nothing will be deleted')"
scope=""
printf '%s' "$FINDINGS" | while IFS="$(printf '\t')" read -r s k t n; do
  [ -n "$s" ] || continue
  if [ "$s" != "$scope" ]; then
    scope="$s"
    printf '\n%s[%s]%s\n' "$C_GRN" "$scope" "$C_RST"
  fi
  case "$k" in
    dir)       printf '  %-10s %s %s(%s)%s\n' "dir"    "$t" "$C_DIM" "$n" "$C_RST" ;;
    container) printf '  %-10s %s %s(%s)%s\n' "docker"  "$t" "$C_DIM" "$n" "$C_RST" ;;
    *)         printf '  %-10s %s %s%s%s\n'   "$k"      "$t" "$C_DIM" "${n:+ [$n]}" "$C_RST" ;;
  esac
done
# note: the while runs in a pipe subshell; FOUND_COUNT lives in the parent
if [ "$FOUND_COUNT" = 0 ]; then
  printf '\n  (no residue found — clean)\n\n'
  exit 0
fi
printf '\n  total: %s item(s). ' "$FOUND_COUNT"
if [ "$APPLY" != 1 ]; then
  printf 'Delete them: aibox-purge --apply [--only=m1,m2] [--stop] [--yes]\n\n'
  exit 0
fi
printf 'Applying...\n'

# ---------- apply ----------
if [ "$ASSUME_YES" != 1 ]; then
  [ -t 0 ] || die "refusing to --apply without --yes in a non-interactive shell"
  printf '%s[?]%s Delete all %s residue items listed above? This is IRREVERSIBLE (volumes, configs, apps data) [y/N] ' "$C_YEL" "$C_RST" "$FOUND_COUNT"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) warn "cancelled, nothing deleted"; exit 2 ;; esac
fi

if [ "$STOP_RUNNING" != 1 ] && [ "$DOCKER_UP" = 1 ]; then
  for c in $(printf '%s' "$FINDINGS" | awk -F'\t' '$2=="container" && ($4=="running" || $4=="restarting") {print $3}'); do
    warn "container '$c' is RUNNING — rerun with --stop to stop it first (its volumes are skipped meanwhile)"
  done
fi

deleted=0; skipped=0
purge_item() { # scope kind target note
  s="$1"; k="$2"; t="$3"
  case "$k" in
    dir|file)
      rm -rf "$t" && { deleted=$((deleted + 1)); log "  removed $k: $t"; } ;;
    container)
      state="$(container_state "$t")"
      if [ "$state" = "running" ] || [ "$state" = "restarting" ]; then
        if [ "$STOP_RUNNING" = 1 ]; then
          docker stop -t 15 "$t" >/dev/null 2>&1 || true
          docker rm -f "$t" >/dev/null 2>&1 && { deleted=$((deleted + 1)); log "  stopped+removed container: $t"; }
        else
          skipped=$((skipped + 1)); warn "  skipped RUNNING container: $t (use --stop)"
        fi
      else
        docker rm -f "$t" >/dev/null 2>&1 && { deleted=$((deleted + 1)); log "  removed container: $t"; }
      fi ;;
    volume)
      # refuse volumes still attached to a running container unless --stop handled it
      if docker volume inspect "$t" >/dev/null 2>&1; then
        docker volume rm "$t" >/dev/null 2>&1 \
          && { deleted=$((deleted + 1)); log "  removed volume: $t"; } \
          || { skipped=$((skipped + 1)); warn "  volume busy (in use by a container?): $t"; }
      fi ;;
    systemd)
      unit="$(basename "$t")"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
      fi
      rm -f "$t" && { deleted=$((deleted + 1)); log "  removed systemd unit: $t"; }
      ;;
    npm)
      if command -v npm >/dev/null 2>&1 && npm uninstall -g "$t" >/dev/null 2>&1; then
        deleted=$((deleted + 1)); log "  removed npm global: $t"
      else
        skipped=$((skipped + 1)); warn "  npm uninstall failed: $t (manual: npm uninstall -g $t)"
      fi ;;
    process)
      if [ "$STOP_RUNNING" = 1 ]; then
        pkill -x "$t" >/dev/null 2>&1 || true
        deleted=$((deleted + 1)); log "  terminated process: $t"
      else
        skipped=$((skipped + 1)); warn "  process '$t' still running — rerun with --stop"
      fi ;;
    rc)
      tmp="${t}.aibox-purge.$$"
      awk '
        /^# aibox$/ { skip = 1; next }
        skip == 1 && /^export PATH=/ { skip = 0; next }
        { skip = 0; print }
      ' "$t" > "$tmp" && cat "$tmp" > "$t" && rm -f "$tmp"
      deleted=$((deleted + 1)); log "  removed # aibox block from $t" ;;
  esac
}

# containers before volumes (a live container pins its volumes); user units reload after
while IFS="$(printf '\t')" read -r s k t n; do
  [ -n "$s" ] || continue
  [ "$k" = container ] && purge_item "$s" "$k" "$t" "$n"
done <<C1
$FINDINGS
C1
if command -v systemctl >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
while IFS="$(printf '\t')" read -r s k t n; do
  [ -n "$s" ] || continue
  [ "$k" != container ] && purge_item "$s" "$k" "$t" "$n"
done <<C2
$FINDINGS
C2

printf '\n'
ok "purge complete: ${deleted} removed, ${skipped} skipped"
# tidy finish: drop now-empty apps/ and AIBOX_HOME shells (best-effort)
if [ "$KEEP_MANAGER" = 0 ]; then
  rmdir "$AIBOX_HOME/apps" 2>/dev/null || true
  rmdir "$AIBOX_HOME" 2>/dev/null || true
fi
if [ "$KEEP_MANAGER" = 0 ] && [ -e "$BIN_DIR/aibox-purge" ]; then
  log "note: aibox-purge itself was kept (delete manually when done: rm $BIN_DIR/aibox-purge)"
fi
exit 0

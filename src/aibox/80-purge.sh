# ---------- residue purge (workspace-level data cleanup) ----------
# `aibox purge` cleans what uninstall hooks could not: data/config residue left
# AFTER modules (or aibox itself) are gone — docker volumes/containers, apps/
# directories, /etc/<module>, systemd/launchd units, dispatched binaries, npm
# globals, lingering processes, the rc PATH block. The residue MAP below is the
# single source of cleanup knowledge — module authors MUST extend it (see
# docs/module-spec.md §Residue cleanup; validate-module.sh WARNs when missing).
# Default is a dry-run report; --apply deletes. Rescue when aibox itself is
# already deleted:
#   curl -fsSL <repo-raw>/bin/aibox -o /tmp/aibox && bash /tmp/aibox purge --apply
# Test/exotic-install overrides: PURGE_ETC, PURGE_SYSTEMD_DIR, PURGE_NO_DOCKER,
# PURGE_NO_PROCS, PURGE_NO_NPM.

_purge_rc_strip() { # $1=rc file: remove the marked "# aibox" + export PATH block
  local tmp=".aibox-rcstrip.33083"
  awk '
    /^# aibox$/ { skip = 1; next }
    skip == 1 && /^export PATH=/ { skip = 0; next }
    { skip = 0; print }
  ' "$1" > "$tmp" && cat "$tmp" > "$1" && rm -f "$tmp"
}

_purge_etc_root()     { printf '%s' "${PURGE_ETC:-/etc}"; }
# Module CLIs may exist in the resolved bin dir AND in the legacy ~/.local/bin
# (pre-0.15 default) — scan both so an old copy is never reported as "clean".
# Named-profile deploy roots (apps/<name>-<profile>, profile-scoped since 0.19):
# purge must reach residue from ANY profile, not just the default one.
_purge_apps_profile_paths() { # $1=module
  local d
  for d in "$AIBOX_HOME"/apps/"$1"-*; do
    [ -e "$d" ] || continue
    printf '%s\n' "$d"
  done
}

_purge_bin_path() { # $1=binary name
  printf '%s\n' "$AIBOX_BIN_DIR/$1"
  [ "$AIBOX_BIN_DIR" = "$HOME/.local/bin" ] || printf '%s\n' "$HOME/.local/bin/$1"
}
_purge_systemd_dir()  { printf '%s' "${PURGE_SYSTEMD_DIR:-/etc/systemd/system}"; }

_purge_docker_up() {
  if [ "${PURGE_NO_DOCKER:-0}" = "1" ]; then return 1; fi
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}
_purge_dir_size() { du -sh "$1" 2>/dev/null | awk '{print $1}' || printf '?'; }
_purge_container_state() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || printf 'unknown'; }

# ---- the residue map (extend when adding a module!) ----
residue_paths() { # $1=module → candidate paths (scan filters by existence)
  local f
  case "$1" in
    base)
      printf '%s\n' "$AIBOX_HOME/apps/base"
      for f in "$AIBOX_HOME"/base*.env; do
        if [ -e "$f" ]; then printf '%s\n' "$f"; fi
      done ;;
    clash)    printf '%s\n' "$AIBOX_HOME/apps/clash"
              _purge_bin_path mihomo ;;
    pi-web)   printf '%s\n' "$AIBOX_HOME/apps/pi-web" \
                "$HOME/.config/systemd/user/pi-web.service" \
                "$HOME/.config/systemd/user/com.agegr.pi-web.service" \
                "$HOME/.local/share/pi-web" \
                "$HOME/Library/LaunchAgents/pi-web.plist" \
                "$HOME/Library/LaunchAgents/com.agegr.pi-web.plist" ;;
    openmaic) printf '%s\n' "$AIBOX_HOME/apps/openmaic" "$(_purge_etc_root)/openmaic"
              _purge_bin_path openmaic ;;
    windmill) printf '%s\n' "$AIBOX_HOME/apps/windmill" "$(_purge_etc_root)/windmill"
              _purge_bin_path windmill ;;
    gitlab)   printf '%s\n' "$AIBOX_HOME/apps/gitlab" "$(_purge_apps_profile_paths gitlab)" ;;
    dify)     printf '%s\n' "$AIBOX_HOME/apps/dify" "$(_purge_apps_profile_paths dify)" ;;
    new-api)  printf '%s\n' "$AIBOX_HOME/apps/new-api" "$(_purge_apps_profile_paths new-api)" ;;
    xiaozhi)  printf '%s\n' "$AIBOX_HOME/apps/xiaozhi" "$(_purge_apps_profile_paths xiaozhi)" ;;
  esac
  return 0
}
residue_volume_patterns() { # $1=module → docker volume name ERE (empty = none)
  case "$1" in
    base)     printf '%s' '^aibox_(pg|redis)_data' ;;
    windmill) printf '%s' '^windmill_' ;;
    openmaic) printf '%s' '^app_openmaic' ;;
    gitlab)   printf '%s' '^gitlab_gitlab_(config|logs|data)$' ;;
    dify)     printf '%s' '^dify_(storage|db|redis|sandbox_deps|sandbox_conf|plugin_daemon|weaviate)$' ;;
    new-api)  printf '%s' '^aibox_new_api_(data|logs)$' ;;
    xiaozhi)  printf '%s' '^aibox_xiaozhi_(models|uploadfile|mysql)$' ;;
  esac
  return 0
}
residue_container_patterns() { # $1=module → container-name ERE
  case "$1" in
    base)     printf '%s' '^aibox-base(-[A-Za-z0-9]+)?-(postgres|redis)$' ;;
    windmill) printf '%s' '^windmill-' ;;
    openmaic) printf '%s' '^app-(openmaic|postgres|render-service)-[0-9]+$' ;;
    gitlab)   printf '%s' '^aibox-gitlab$' ;;
    dify)     printf '%s' '^dify-' ;;
    new-api)  printf '%s' '^aibox-new-api$' ;;
    xiaozhi)  printf '%s' '^aibox-xiaozhi-(server|web|mysql)$' ;;
  esac
  return 0
}
residue_systemd_units() { # $1=module → system-level unit file paths
  local sd; sd="$(_purge_systemd_dir)"
  case "$1" in
    windmill) printf '%s\n' "$sd/windmill-backup.service" "$sd/windmill-backup.timer" \
                            "$sd/windmill-update-check.service" "$sd/windmill-update-check.timer" ;;
  esac
  return 0
}
residue_npm_packages() { case "$1" in pi-web) printf '%s' '@agegr/pi-web' ;; esac; return 0; }
residue_processes()    { case "$1" in clash)   printf '%s' 'mihomo' ;;        esac; return 0; }

manager_paths() { # the manager's own residue ('self' scope)
  local d
  printf '%s\n' "$AIBOX_BIN_DIR/aibox"
  [ "$AIBOX_BIN_DIR" = "$HOME/.local/bin" ] || printf '%s\n' "$HOME/.local/bin/aibox"
  if [ -d "$AIBOX_HOME" ]; then
    for d in "$AIBOX_HOME"/*; do
      [ -e "$d" ] || continue
      case "$(basename "$d")" in apps) continue ;; esac   # apps/ belongs to the modules
      printf '%s\n' "$d"
    done
  fi
  return 0
}

# ---- scan ----
PURGE_MODULES_KNOWN="base clash pi-web openmaic windmill gitlab dify new-api xiaozhi"
PURGE_FINDINGS=""
PURGE_COUNT=0
_purge_add() { # scope kind target note  (tab-separated findings list)
  PURGE_FINDINGS="${PURGE_FINDINGS}$1	$2	$3	$4
"
  PURGE_COUNT=$((PURGE_COUNT + 1))
}

_purge_scan_module() {
  local m="$1" p v c n pids vpat cpat
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      _purge_add "$m" dir "$p" "$(_purge_dir_size "$p")"
    elif [ -e "$p" ]; then
      _purge_add "$m" file "$p" ""
    fi
  done <<RP
$(residue_paths "$m")
RP
  if _purge_docker_up; then
    vpat="$(residue_volume_patterns "$m")"
    if [ -n "$vpat" ]; then
      for v in $(docker volume ls -q 2>/dev/null | grep -E "$vpat" || true); do
        _purge_add "$m" volume "$v" ""
      done
    fi
    cpat="$(residue_container_patterns "$m")"
    if [ -n "$cpat" ]; then
      for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$cpat" || true); do
        _purge_add "$m" container "$c" "$(_purge_container_state "$c")"
      done
    fi
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -e "$n" ]; then _purge_add "$m" systemd "$n" ""; fi
  done <<RU
$(residue_systemd_units "$m")
RU
  n="$(residue_npm_packages "$m")"
  if [ -n "$n" ] && [ "${PURGE_NO_NPM:-0}" != 1 ] && command -v npm >/dev/null 2>&1; then
    if npm ls -g "$n" --depth=0 >/dev/null 2>&1; then _purge_add "$m" npm "$n" "global"; fi
  fi
  n="$(residue_processes "$m")"
  if [ -n "$n" ] && [ "${PURGE_NO_PROCS:-0}" != 1 ]; then
    pids="$(pgrep -x "$n" 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "$pids" ]; then _purge_add "$m" process "$n" "pids: $pids"; fi
  fi
  return 0
}

_purge_scan_self() {
  local p rc
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      _purge_add self dir "$p" "$(_purge_dir_size "$p")"
    elif [ -e "$p" ]; then
      _purge_add self file "$p" ""
    fi
  done <<MP
$(manager_paths)
MP
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if grep -q '^# aibox$' "$rc" 2>/dev/null; then _purge_add self rc "$rc" "# aibox PATH block"; fi
  done
  return 0
}

# ---- apply one finding ----
PURGE_DELETED=0
PURGE_SKIPPED=0
_purge_apply_item() { # $1=kind $2=target $3=stop(0|1)
  local k="$1" t="$2" stop="$3" state unit
  case "$k" in
    dir|file)
      if rm -rf "$t"; then
        PURGE_DELETED=$((PURGE_DELETED + 1)); info "removed ${k}: $t"
      else
        PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  failed to remove ${k}: $t"
      fi ;;
    container)
      state="$(_purge_container_state "$t")"
      if [ "$state" = running ] || [ "$state" = restarting ]; then
        if [ "$stop" = 1 ]; then
          docker stop -t 15 "$t" >/dev/null 2>&1 || true
          if docker rm -f "$t" >/dev/null 2>&1; then
            PURGE_DELETED=$((PURGE_DELETED + 1)); info "stopped+removed container: $t"
          else
            PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  failed to remove container: $t"
          fi
        else
          PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  skipped (running): $t"
        fi
      else
        if docker rm -f "$t" >/dev/null 2>&1; then
          PURGE_DELETED=$((PURGE_DELETED + 1)); info "removed container: $t"
        else
          PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  failed to remove container: $t"
        fi
      fi ;;
    volume)
      if docker volume rm "$t" >/dev/null 2>&1; then
        PURGE_DELETED=$((PURGE_DELETED + 1)); info "removed volume: $t"
      else
        PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  volume busy or gone: $t"
      fi ;;
    systemd)
      unit="$(basename "$t")"
      if command -v systemctl >/dev/null 2>&1; then systemctl disable --now "$unit" >/dev/null 2>&1 || true; fi
      if rm -f "$t"; then PURGE_DELETED=$((PURGE_DELETED + 1)); info "removed systemd unit: $t"; fi ;;
    npm)
      if command -v npm >/dev/null 2>&1 && npm uninstall -g "$t" >/dev/null 2>&1; then
        PURGE_DELETED=$((PURGE_DELETED + 1)); info "removed npm global: $t"
      else
        PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  npm uninstall failed: $t (manual: npm uninstall -g $t)"
      fi ;;
    process)
      if [ "$stop" = 1 ]; then
        pkill -x "$t" >/dev/null 2>&1 || true
        PURGE_DELETED=$((PURGE_DELETED + 1)); info "terminated process: $t"
      else
        PURGE_SKIPPED=$((PURGE_SKIPPED + 1)); warn "  process '$t' still running — rerun with --stop"
      fi ;;
    rc)
      if _purge_rc_strip "$t"; then PURGE_DELETED=$((PURGE_DELETED + 1)); info "removed # aibox block from $t"; fi ;;
  esac
  return 0
}

cmd_purge() {
  local apply=0 stop=0 scope="" a m s k t n scope_seen=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --stop)  stop=1 ;;
      --yes|-y) ASSUME_YES=1 ;;   # the global flag loop stops at 'purge'; accept it here too
      -h|--help) _verb_help purge; return 0 ;;
      -*) die_usage "unknown option for purge: $1 (usage: aibox purge [<module>...|self] [--apply] [--stop] [--yes])" ;;
      *)  scope="${scope} $1" ;;
    esac
    shift
  done
  PURGE_FINDINGS=""; PURGE_COUNT=0; PURGE_DELETED=0; PURGE_SKIPPED=0
  if [ -z "$scope" ]; then
    for m in $PURGE_MODULES_KNOWN; do _purge_scan_module "$m"; done
    _purge_scan_self
  else
    for m in $scope; do
      if [ "$m" = self ]; then _purge_scan_self; else _purge_scan_module "$m"; fi
    done
  fi

  # ---- report ----
  printf '\n%s%saibox residue scan%s (%s)\n' "$C_BOLD" "$C_CYA" "$C_RST" "$([ "$apply" = 1 ] && printf 'apply mode' || printf 'dry-run — nothing will be deleted')"
  printf '%s' "$PURGE_FINDINGS" | while IFS="$(printf '\t')" read -r s k t n; do
    [ -n "$s" ] || continue
    if [ "$s" != "$scope_seen" ]; then
      scope_seen="$s"
      printf '\n%s[%s]%s\n' "$C_GRN" "$scope_seen" "$C_RST"
    fi
    case "$k" in
      dir)       printf '  %-10s %s %s(%s)%s\n' dir    "$t" "${C_DIM:-}" "$n" "$C_RST" ;;
      container) printf '  %-10s %s %s(%s)%s\n' docker "$t" "${C_DIM:-}" "$n" "$C_RST" ;;
      *)         printf '  %-10s %s %s%s%s\n'   "$k"    "$t" "${C_DIM:-}" "${n:+ [$n]}" "$C_RST" ;;
    esac
  done
  if [ "$PURGE_COUNT" = 0 ]; then
    printf '\n  (no residue found — clean)\n\n'
    return 0
  fi
  printf '\n  total: %s item(s). ' "$PURGE_COUNT"
  if [ "$apply" != 1 ]; then
    printf 'Delete them: aibox purge --apply [--stop] [--yes]\n\n'
    return 0
  fi
  printf 'Applying...\n'

  # ---- confirm ----
  # Purge reaches into the shared base (scope 'base'/'self'/all) — name the
  # dependents before the irreversible gate: deleting base's volumes empties the
  # consumers' databases on their next start.
  local _purge_hits_base=0 _scope_tok
  if [ -z "$scope" ]; then
    _purge_hits_base=1
  else
    for _scope_tok in $scope; do
      case "${_scope_tok}" in base | self) _purge_hits_base=1 ;; esac
    done
  fi
  if [ "${_purge_hits_base}" = "1" ]; then
    local _deps; _deps="$(_base_dependents)"
    if [ -n "${_deps}" ]; then
      warn "this purge includes the shared base; installed modules depend on its DATA: ${_deps}"
      warn "  keep a copy first: aibox base dump"
    fi
  fi
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    if [ -t 0 ]; then
      ask_confirm "Delete all ${PURGE_COUNT} residue items listed above? This is IRREVERSIBLE" || { warn "Cancelled, nothing deleted"; return 2; }
    else
      die "refusing to --apply without --yes in a non-interactive shell"
    fi
  fi

  # ---- running containers: inline stop decision (the two-gate pattern, same
  # as the uninstall data question — the old flow warned per-container during
  # pre-warn AND again per-skip in the apply loop, then forced a full re-run
  # with --stop while the half-applied state had already deleted dirs).
  #   --stop = explicit intent (pre-answered yes)
  #   interactive = asked inline; decline → containers skipped, volumes stay
  #   non-interactive / --yes-without-stop = safe default (skip + ONE hint) ----
  local running_cs="" n_running=0
  if _purge_docker_up; then
    running_cs="$(printf '%s' "$PURGE_FINDINGS" | awk -F'\t' '$2=="container" && ($4=="running" || $4=="restarting") {print $3}')"
    [ -n "${running_cs}" ] && n_running="$(printf '%s\n' "${running_cs}" | grep -c .)"
  fi
  if [ "${n_running}" -gt 0 ] && [ "${stop}" != 1 ]; then
    if [ -t 0 ] && [ "${ASSUME_YES:-0}" != "1" ]; then
      if ask_confirm "${n_running} container(s) are RUNNING — stop them as part of this purge? (docker stop + rm; declining leaves their volumes mounted and busy)"; then
        stop=1
      fi
    else
      warn "${n_running} running container(s) will be SKIPPED (stop them: rerun with --stop)"
    fi
  fi

  # ---- apply: containers first (a live container pins its volumes), then the rest ----
  while IFS="$(printf '\t')" read -r s k t n; do
    [ -n "$s" ] || continue
    if [ "$k" = container ]; then _purge_apply_item "$k" "$t" "$stop"; fi
  done <<PF1
$PURGE_FINDINGS
PF1
  if [ "$(uname -s)" = Linux ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  while IFS="$(printf '\t')" read -r s k t n; do
    [ -n "$s" ] || continue
    if [ "$k" != container ]; then _purge_apply_item "$k" "$t" "$stop"; fi
  done <<PF2
$PURGE_FINDINGS
PF2
  # tidy finish: drop now-empty shells (best-effort; only succeeds when empty)
  rmdir "$AIBOX_HOME/apps" 2>/dev/null || true
  rmdir "$AIBOX_HOME" 2>/dev/null || true
  printf '\n'
  ok "purge complete: ${PURGE_DELETED} removed, ${PURGE_SKIPPED} skipped"
  # when containers were skipped, the busy volumes are the CONSEQUENCE — one
  # actionable closing line instead of the old raw per-volume "busy or gone"s
  if [ "${n_running}" -gt 0 ] && [ "${stop}" != 1 ]; then
    info "running container(s) + their volumes kept — stop + sweep in one run: aibox purge${scope:+${scope}} --apply --stop"
  fi
  return 0
}

# Self-update = idempotent re-bootstrap. Defense in depth: if AIBOX_SHA256 is set, the
# bootstrap verifies the downloaded bin/aibox against it; if AIBOX_VERIFY=1, the bootstrap
# tries to fetch and check the release SHA256SUMS sidecar (graceful if absent).

cmd_self_update() {
  local before after boot_body
  before="$AIBOX_VERSION"
  log "aibox self-update: currently ${before}, re-bootstrapping ..."
  # AIBOX_RAW must be PASSED THROUGH to install.sh (it re-derives RAW from its
  # own env): without this, a pinned/mirrored AIBOX_RAW only affects the
  # install.sh fetch here while the payload still comes from the default branch
  # CDN (measured live on remote1: SHA-pinned `update self` silently kept the
  # stale binary via branch-CDN lag, defeating the pin).
  #
  # The fetch is separated from the pipe (previously `gh_pool_fetch | bash`):
  # a failed fetch could leave bash running EMPTY input (exit 0) and the wrapper
  # printed "already latest" (a FALSE success). Every failure mode now has an
  # explicit message (the silent ones were measured live: the pool's no-winner
  # path returns 1 with zero output, and the old else-branch was a bare
  # `return 1` with no message at all).
  if ! boot_body="$(gh_pool_fetch "$AIBOX_RAW/install.sh" 2>/dev/null)"; then
    bad "self-update FAILED: could not fetch install.sh from ${AIBOX_RAW} (the source pool was tried — the binary is UNCHANGED at ${before})"
    warn "network? try: aibox clash on / aibox proxy on; or pin a mirror: AIBOX_GH_MIRROR=https://gh-proxy.com"
    return 1
  fi
  if [ -z "${boot_body}" ]; then
    bad "self-update FAILED: install.sh came back EMPTY (broken mirror?) — the binary is UNCHANGED at ${before}"
    return 1
  fi
  if ! printf '%s' "${boot_body}" | AIBOX_RAW="$AIBOX_RAW" AIBOX_VERIFY="${AIBOX_VERIFY:-0}" AIBOX_SHA256="${AIBOX_SHA256:-}" bash; then
    bad "self-update FAILED: the bootstrap (download/checksum) did not complete — the binary is UNCHANGED at ${before}"
    warn "see the bootstrap's message above; network hints: aibox clash on / aibox proxy on"
    return 1
  fi
  # New CLI and new module metadata go together: drop the registry cache so the
  # next load_registry refetches (measured live: `aibox ports` kept showing a
  # stale declared port for up to the 1h TTL after self-update).
  rm -f "$AIBOX_REGISTRY_CACHE" 2>/dev/null || true
  after="$($AIBOX_BIN_DIR/aibox version 2>/dev/null | awk '{print $2}')"
  if [ -z "${after}" ]; then
    warn "self-update: the new binary did not report a version — inspect: $AIBOX_BIN_DIR/aibox version"
    after="unknown"
  fi
  if [ "${before}" = "${after}" ]; then
    log "aibox self-update complete: already latest (${after})"
  else
    log "aibox self-update complete: ${before} -> ${after}"
  fi
  return 0
}

# Fail-closed: $AIBOX_HOME/apps/ holds deploy instances (databases, backups, logs, data
# volume mounts) whose lifecycle outlasts aibox itself — removing the manager does NOT
# mean removing them. A bare `rm -rf "$AIBOX_HOME"` with a prompt line is not protection;
# it must actually block.
# Is $1 an exact member of the comma-separated list $2?
# Print "<module> <profile>" for every installed (module, profile) pair —
# installed.sh keys are AIBOX_INSTALLED_<mu>[__<profile>]=<version>.
_self_uninstall_entries() {
  [ -f "$AIBOX_INSTALLED" ] || return 0
  sed -nE 's/^AIBOX_INSTALLED_([a-z0-9_]+)(__[A-Za-z0-9_]+)?=.*/\1\2/p' "$AIBOX_INSTALLED" 2>/dev/null |
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      mu="${key%%__*}"
      prof="base"
      case "$key" in *__*) prof="${key#*__}" ;; esac
      printf '%s %s\n' "$(printf '%s' "$mu" | tr '_' '-')" "$prof"
    done
}

# Run one module's cached uninstall hook for a profile. Offline-safe: uses the
# module cache directly (no load_registry / network). AIBOX_PURGE_DATA=1 asks
# the hook to also delete the module's DATA (volumes/state//etc config) per the
# hook contract in docs/module-spec.md.
_self_teardown_one() { # $1=module $2=profile $3=purge(0|1)
  local m="$1" p="$2" purge_env="${3:-0}"
  local dest="$AIBOX_MOD_DIR/$m"
  if [ -f "$dest/uninstall.sh" ]; then
    if [ "$purge_env" = 1 ]; then
      info "removing ${m}@${p} via its uninstall hook (PURGE: hook will delete data) ..."
    else
      info "removing ${m}@${p} via its uninstall hook ..."
    fi
    ( AIBOX_MODULE="$m" AIBOX_PROFILE="$p" AIBOX_PURGE_DATA="$purge_env" \
      bash "$dest/uninstall.sh" ) || warn "  hook for ${m}@${p} exited non-zero (continuing)"
  else
    warn "  no cached uninstall hook for ${m}@${p} — remove its service manually if still running"
  fi
}

# Remove the marked "# aibox" + export PATH block that install.sh appended.
_self_rc_cleanup() {
  local rc n=0
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -q '^# aibox$' "$rc" || continue
    _purge_rc_strip "$rc"
    n=$((n + 1))
    info "removed the aibox PATH block from $rc"
  done
  if [ "$n" = 0 ]; then info "no marked aibox PATH block found in shell rc files"; fi
  return 0
}

# Self uninstall — remove the manager. Two modes, one flag:
#   aibox self uninstall          manager only: binary + state + rc PATH block.
#                                 Module services and data are KEPT; apps/ is
#                                 preserved so survivors stay manageable.
#   aibox self uninstall --purge  cascade FULL teardown: run every installed
#                                 (module, profile)'s uninstall hook with
#                                 AIBOX_PURGE_DATA=1 (services + data), then the
#                                 manager + rc block.
# Confirm gate: TTY asks; non-interactive requires --yes. Selectivity lives in
# the composed commands (aibox uninstall <m> [--purge] / aibox purge), not in
# flag matrices here.
cmd_self_uninstall() {
  local purge=0 a entries d ctrs m p
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)   purge=1 ;;
      --yes|-y)  ASSUME_YES=1 ;;
      -h|--help) _verb_help uninstall; return 0 ;;
      *)         die_usage "unknown option: $1 (usage: aibox uninstall self [--purge] [--yes])" ;;
    esac
    shift
  done

  # ---- inventory ----
  entries="$(_self_uninstall_entries)"
  log "aibox self uninstall — inventory"
  info "manager : $AIBOX_BIN_DIR/aibox + $AIBOX_HOME"
  if [ -n "$entries" ]; then
    info "installed (module@profile):"
    printf '%s\n' "$entries" | while IFS=' ' read -r em ep; do
      if [ -n "$em" ]; then info "  - ${em}@${ep}"; fi
    done
  else
    info "installed modules: none"
  fi
  if [ -d "$AIBOX_HOME/apps" ]; then
    for d in "$AIBOX_HOME"/apps/*/; do
      if [ -d "$d" ]; then info "deploy  : ${d%/}"; fi
    done
  fi
  if _purge_docker_up; then
    ctrs="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(aibox-|windmill|gitlab|app-|openmaic|dify-)' | tr '\n' ' ' || true)"
    if [ -n "$ctrs" ]; then info "running containers: ${ctrs}"; fi
  fi
  if [ "$purge" = 1 ]; then
    info "plan    : PURGE — uninstall every module WITH its data (hooks), then remove manager + rc block"
  else
    info "plan    : remove the manager only; module services and data are KEPT"
  fi

  # ---- confirm ----
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    if [ -t 0 ]; then
      if [ "$purge" = 1 ]; then
        ask_confirm "Proceed with the FULL teardown? Module data will be DELETED (irreversible)" || { warn "Cancelled, nothing changed"; return 2; }
      else
        ask_confirm "Remove the aibox manager? (module services and data are kept)" || { warn "Cancelled, nothing changed"; return 2; }
      fi
    else
      die "non-interactive shell: re-run with --yes to confirm"
    fi
  fi

  # ---- cascade teardown (--purge): hooks from the module cache, offline-safe ----
  if [ -n "$entries" ] && [ "$purge" = 1 ]; then
    while IFS=' ' read -r m p; do
      [ -n "$m" ] || continue
      _self_teardown_one "$m" "$p" 1
    done <<ENTRIES
$entries
ENTRIES
    rm -rf "$AIBOX_HOME/apps"
  fi

  # ---- manager artifacts ----
  if [ -d "$AIBOX_HOME" ]; then
    if [ "$purge" = 1 ]; then
      rm -rf "$AIBOX_HOME"
    else
      # Keep apps/ (deploy data + compose files) so surviving services stay manageable.
      find "$AIBOX_HOME" -mindepth 1 -maxdepth 1 ! -name apps -exec rm -rf {} + 2>/dev/null || true
      rmdir "$AIBOX_HOME/apps" 2>/dev/null || true
      rmdir "$AIBOX_HOME" 2>/dev/null || true
    fi
  fi
  rm -f "$AIBOX_BIN_DIR/aibox"
  _self_rc_cleanup

  # ---- summary ----
  ok "aibox manager removed (binary + state + rc PATH block)"
  if [ "$purge" != 1 ]; then
    warn "module services and data were KEPT. Teardown paths:"
    warn "  one module : reinstall aibox, then  aibox uninstall <module> --purge"
    warn "  residue    : curl -fsSL ${AIBOX_RAW}/bin/aibox -o /tmp/aibox && bash /tmp/aibox purge --apply"
  fi
  return 0
}

usage() {
  printf '%s%saibox %s%s %s— module manager for AI coding toolkits%s\n\n' "$C_BOLD" "$C_CYA" "$AIBOX_VERSION" "$C_RST" "$C_DIM" "$C_RST"

  printf '%sCommands\n\n' "${C_BOLD}${C_CYA}"
  cat <<'EOF'
  install <module> [--skip-checks]   Install a module (preflight-gated)
  uninstall <module>|self [--purge] [--yes]
                                    Uninstall; --purge also deletes DATA
  update <module>|self|--all [--restart|--no-restart] [--skip-checks]
                                    Refresh module SCRIPTS (repo-pinned floor)
  upgrade <module> [--check|--rollback|--history] [--to <ver>] [--no-backup] [--yes]
                                    Upgrade the deployed UPSTREAM app version
                                    (update ≠ upgrade: scripts vs app version)
  <module> <action> [args]          Invoke a module action (e.g. aibox pi-web start)

EOF

  printf '%sInspection\n\n' "${C_BOLD}${C_CYA}"
  cat <<'EOF'
  check <module>|self        Preflight dry-run (self = environment: egress, docker, node, disk)
  dashboard [--available]    Overview + ports + listeners; --available = registry catalog
  dashboard <module>         Detail + health + config keys + upgrade/rollback state
  purge [module...|self] [--apply] [--stop] [--yes]
                             Residue scan/cleanup (dry-run by default)
  version, -v, --version     Manager version

EOF

  printf '%sProxy & Clash\n\n' "${C_BOLD}${C_CYA}"
  cat <<'EOF'
  proxy show|set <url>|unset|on|off|check [url]|env [--remote]
                             Static proxy config (global; covers module hooks)
  clash set <sub-url>|on|off|status|refresh|select|test|logs|doctor|use-external
                             Clash pool (mihomo kernel; takes priority when on)
  --no-proxy <command>       Bypass the proxy for one invocation
  --profile <name>           Named profile (deterministic ports/volumes)

EOF

  printf '%sHelp & Global Flags\n\n' "${C_BOLD}${C_CYA}"
  cat <<'EOF'
  help, -h, --help           This overview
  <verb> --help              One verb's usage/options (also: aibox help <verb>)
  <module> --help            A module's actions (from its usage: stanza)
  --yes, -y                  Skip interactive confirmations
  --skip-checks              Bypass preflight checks
  AIBOX_SHA256=<hash>        Verify bin/aibox checksum (bootstrap defense)
  AIBOX_VERIFY=1             Check release SHA256SUMS sidecar

  exit codes: 1 runtime · 2 usage · 3 dependency missing · 4 precheck failed
              10 upgrade rolled back · 20 manual intervention (module hooks: 30 not ready,
              40 lock conflict, 50 cancelled — docs/module-spec.md §Exit codes)

EOF

  info "module help: aibox <module> --help  ·  get started: aibox install pi-web  ·  https://github.com/lichengwu/aibox"
}


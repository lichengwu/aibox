# ---------- residue purge (workspace-level data cleanup) ----------
# Residue knowledge is DECLARED by the module (module.yaml `residue:` stanza) and
# derived generically by the manager (deploy root + every profile variant, module
# cache, /etc/<name>, declared bin). The manager used to carry a per-module `case`
# map for every residue kind — module-internal knowledge living in the manager, so
# every new path (profiles, contract files) needed a manager edit. A module's own
# lib.sh may still override any residue_* function (escape hatch for dynamic
# cases; base's per-profile env files use it).
_purge_rc_strip() { # $1=rc file: remove the marked "# aibox" + export PATH block
  local tmp=".aibox-rcstrip.33083"
  awk '
    /^# aibox$/ { skip = 1; next }
    skip == 1 && /^export PATH=/ { skip = 0; next }
    { skip = 0; print }
  ' "$1" > "$tmp" && cat "$tmp" > "$1" && rm -f "$tmp"
}
_purge_etc_root()     { printf '%s' "${PURGE_ETC:-/etc}"; }
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
# The residue DECLARATION is captured into $AIBOX_HOME/residue.conf right after a
# module is downloaded (install/update) — `aibox purge` must clean leftovers even
# when the module cache is gone AND the host is offline, and at that point the
# only surviving knowledge is this file (the registry cache may be stale too).
# Plain KEY=VALUE lines, never sourced (data is not code).
_residue_store() { printf '%s/residue.conf' "${AIBOX_HOME}"; }

_residue_record() { # $1=module → capture its residue declaration (idempotent)
  local m="$1" f field v tmp store
  store="$(_residue_store)"
  f="$AIBOX_MOD_DIR/$m/module.yaml"
  [ -f "${f}" ] || return 0
  tmp="$(mktemp)"
  [ -f "${store}" ] && grep -v "^${m}_residue_" "${store}" >"${tmp}" 2>/dev/null || true
  for field in paths containers volumes units bin npm process; do
    v="$(meta_sub_field "$f" residue "${field}")"
    [ -n "${v}" ] && printf '%s_residue_%s=%s\n' "${m}" "${field}" "${v}" >>"${tmp}"
  done
  if [ -s "${tmp}" ]; then
    mv "${tmp}" "${store}"
    chmod 600 "${store}" 2>/dev/null || true
  else
    rm -f "${tmp}"
  fi
  return 0
}

_residue_decl() { # $1=module $2=field (paths|containers|volumes|units|bin|npm|process)
  local m="$1" field="$2" v mu
  mu="${m//-/_}"
  if [ -f "$AIBOX_MOD_DIR/$m/module.yaml" ]; then
    v="$(meta_sub_field "$AIBOX_MOD_DIR/$m/module.yaml" residue "${field}")"
    [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  fi
  local store
  store="$(_residue_store)"
  if [ -f "${store}" ]; then
    v="$(grep "^${m}_residue_${field}=" "${store}" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  fi
  v="$(eval "printf '%s' \"\${AIBOX_MODULE_${mu}_residue_${field}:-}\"" 2>/dev/null)"
  [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  v="$( ( . "$AIBOX_REGISTRY_CACHE" 2>/dev/null; eval "printf '%s' \"\${AIBOX_MODULE_${mu}_residue_${field}:-}\"" ) 2>/dev/null )"
  printf '%s' "${v}"
}

# A module lib may override a residue_* function: run it in a child shell that
# sources the module's lib (the same pattern the upgrade engine uses for
# deploy_root / upgrade_stops) — only when the module cache is still present.
_residue_lib_call() { # $1=module $2=function; args after that
  local m="$1" fn="$2" lib out
  shift 2
  lib="$AIBOX_MOD_DIR/$m/lib.sh"
  [ -f "${lib}" ] || return 0
  out="$(AIBOX_MODULE="${m}" AIBOX_HOME="${AIBOX_HOME}" bash -c "
    . '${lib}' >/dev/null 2>&1 || exit 0
    type -t ${fn} >/dev/null 2>&1 || exit 0
    ${fn} \"\$@\"
  " -- "$@" 2>/dev/null || true)"
  [ -n "${out}" ] && printf '%s' "${out}"
  return 0
}

_residue_expand() { # expand the path placeholders the stanza may use
  local s="$1"
  s="${s//\$HOME/${HOME}}"
  s="${s//\$AIBOX_HOME/${AIBOX_HOME}}"
  s="${s//\$ETC_DIR/$(_purge_etc_root)}"
  printf '%s' "${s}"
}

residue_paths() { # $1=module → candidate paths (the scan filters by existence)
  local m="$1" lib p b
  lib="$(_residue_lib_call "$m" residue_paths)"
  [ -n "${lib}" ] && { printf '%s\n' "${lib}"; return 0; }
  # generic: canonical deploy root + every named profile's variant, the module
  # cache, and the conventional /etc config dir
  {
    printf '%s\n' "$AIBOX_HOME/apps/$m"
    _purge_apps_profile_paths "$m"
    printf '%s\n' "$AIBOX_HOME/modules/$m" "$(_purge_etc_root)/$m"
    for p in $(_residue_decl "$m" paths); do
      printf '%s\n' "$(_residue_expand "$p")"
    done
    for b in $(_residue_decl "$m" bin); do
      _purge_bin_path "$b"
    done
  } | sort -u
}

residue_volume_patterns() { # $1=module → docker volume name ERE (empty = none)
  _residue_decl "$1" volumes
}
residue_container_patterns() { # $1=module → container-name ERE
  _residue_decl "$1" containers
}
residue_systemd_units() { # $1=module → system-level unit file paths
  local m="$1" u sd
  sd="$(_purge_systemd_dir)"
  for u in $(_residue_decl "$m" units); do
    printf '%s\n' "${sd}/${u}"
  done
  return 0
}
residue_npm_packages() { _residue_decl "$1" npm; }
residue_processes()    { _residue_decl "$1" process; }

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
      -*) usage_die "unknown option for purge: $1 (usage: aibox purge [<module>...|self] [--apply] [--stop] [--yes])" ;;
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
      *)         usage_die "unknown option: $1 (usage: aibox uninstall self [--purge] [--yes])" ;;
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
  dashboard [--available]    Overview + ports + listeners; --available = registry catalog; --json = machine-readable
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


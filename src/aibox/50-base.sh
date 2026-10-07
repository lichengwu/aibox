# ---------- profile-aware shared-base linking (helpers live in tools/_shared/lib/10-base.sh,
# injected into this bundle by scripts/bundle.sh — one implementation, not a twin) ----------
# The single-file CLI cannot source tools/_shared/common.sh, so these mirror
# base_profile_suffix/base_env_file/base_network_name/base_env_check there. Keep
# them in sync — they are the reason a consumer can never look at the DEFAULT
# profile's base.env while base runs under a named profile.






# Installed modules that declare a HARD base dependency (services: base:*) — the
# reverse direction of the install-time guarantee, used to warn before
# stopping/uninstalling/purging the provider. Local metadata only.
_base_dependents() { # [exclude-module] → space-separated names
  local excl="${1:-}" f m deps out=""
  for f in "$AIBOX_MOD_DIR"/*/module.yaml; do
    [ -f "$f" ] || continue
    m="$(awk -F': *' '/^name:/{gsub(/"/,"",$2); print $2; exit}' "$f" 2>/dev/null)"
    [ -n "${m}" ] || m="$(basename "$(dirname "$f")")"
    [ "${m}" = "base" ] && continue
    [ "${m}" = "${excl}" ] && continue
    is_installed "${m}" || continue
    deps="$(awk '/^services:/{d=1;next} /^[a-z_]+:/{d=0} d&&/^  - /{sub(/^  - /,""); gsub(/"/,""); printf "%s ", $0}' "$f" 2>/dev/null)"
    case " ${deps} " in *" base:"*) out="${out}${out:+ }${m}" ;; esac
  done
  printf '%s' "${out}"
}

# Action-time declared-deps guard: existence only — no auto-install, no
# network, so it is cheap enough for every start. A missing node for pi-web
# used to surface only as "the service did not come up" after a silent crash;
# name the dep and the fix instead. Warn-only: a module may still work in some
# setups, and the real verdict belongs to the action itself.
_runtime_dep_guard() { # $1=module
  local name="$1" deps dep cmd ptag os missing=""
  deps="$(_module_meta_local "${name}" deps)"
  [ -n "$deps" ] || return 0
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  for dep in $deps; do
    cmd="$dep"; ptag=""
    cmd="${cmd%\"}"; cmd="${cmd#\"}"   # quoted list entries ("node:22") — strip here too
    case "$cmd" in *@*) ptag="${cmd##*@}"; cmd="${cmd%@*}" ;; esac
    if [ -n "$ptag" ] && [ "$ptag" != "$os" ]; then continue; fi
    case "$cmd" in *:*) cmd="${cmd%%:*}" ;; esac
    if [ "$cmd" = "docker-compose" ]; then
      # modern hosts ship the compose v2 PLUGIN (`docker compose`), not the legacy
      # standalone binary — `command -v docker-compose` false-positived on them
      # (live-caught: "⚠ base: missing docker-compose" on a healthy host whose
      # compose file was present and whose plugin works)
      docker compose version >/dev/null 2>&1 && continue
    fi
    command -v "$cmd" >/dev/null 2>&1 || missing="${missing}${missing:+ }${cmd}"
  done
  [ -n "$missing" ] || return 0
  warn "${name}: missing ${missing} — without it the service will not come up"
  warn "  fix: aibox check ${name} (preflight shows the required version) · the install/update preflight auto-installs deps"
  return 0
}

cmd_uninstall() {
  local name="" purge=0 a
  for a in "$@"; do
    case "$a" in
      --purge)  purge=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help) _verb_help uninstall; exit 0 ;;
      -*)       usage_die "unknown option for uninstall: $a (usage: aibox uninstall <module>|self [--purge] [--yes])" ;;
      *)        [ -z "$name" ] && name="$a" ;;
    esac
  done
  [ -n "$name" ] || usage_die "Usage: aibox uninstall <module>|self [--purge] [--yes]"
  if [ "$name" = self ]; then
    # 'self' = the manager module (one grammar, no self sub-family)
    if [ "$purge" = 1 ]; then cmd_self_uninstall --purge; else cmd_self_uninstall; fi
    return $?
  fi
  is_installed "$name" || { warn "$name not installed; residue left behind? scan it: aibox autoclean $name"; return; }

  # Reverse-dependency gate (base is a provider): removing it breaks every
  # consumer — name them before the confirmation so the decision is informed.
  if [ "$name" = "base" ]; then
    local _deps; _deps="$(_base_dependents)"
    if [ -n "${_deps}" ]; then
      warn "installed modules depend on the shared base: ${_deps}"
      warn "  uninstalling base leaves them pointing at a missing provider (restore with: aibox install base && aibox base start)"
    fi
  fi

  # Interaction contract (spec §Interactive confirmation — the same two-gate
  # model for every destructive verb; the old plain uninstall ran with ZERO
  # confirmation, live-caught on the deploy host):
  #   gate 1 — the uninstall itself (stops containers, removes the deploy):
  #     interactive [y/N] default N; --yes skips; non-interactive w/o --yes → exit 2.
  #   gate 2 — data cleanup (volumes + .env), asked INLINE so the single hook
  #     invocation carries the decision (the old flow forced a dead round-trip:
  #     `uninstall --purge` AFTER uninstalling warns "not installed").
  #     --purge = explicit intent (skips the question); non-interactive w/o
  #     --purge keeps data (safe default) + prints the residue hint.
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    ask_confirm "Uninstall ${name}? (stops containers, removes the compose deployment; data volumes + .env are kept)" \
      || { warn "Cancelled, nothing changed"; return 2; }
  fi
  if [ "${purge}" != "1" ] && [ -t 0 ]; then
    if ask_confirm "Also DELETE the data? (volumes + deploy .env — irreversible; the default keeps them)"; then
      purge=1
    fi
  fi

  local dest="$AIBOX_MOD_DIR/$name"
  load_registry
  local uninst; uninst="$(module_field "$name" uninstall)"
  if [ -n "$uninst" ] && [ -f "$dest/$uninst" ]; then
    # --purge: the hook ALSO deletes the module's DATA (volumes, state, /etc dirs)
    # per the AIBOX_PURGE_DATA contract (docs/module-spec.md).
    AIBOX_MODULE="$name" AIBOX_PURGE_DATA="$purge" bash "$dest/$uninst"
  else
    warn "No uninstall hook; cleaning cache only"
  fi
  if [ "$purge" = 1 ]; then
    rm -rf "$AIBOX_HOME/apps/$name"
    log "purged: hook data contract + $AIBOX_HOME/apps/$name"
    # Manager-side sweep for the classes a hook was never asked to own: the module's
    # docker NETWORKS (a crashed `compose down` loses that race — live-caught with a
    # crash-looping container) and its declared IMAGES (built/pulled program
    # artifacts, not data). Same two proofs as the reclamation half: declared
    # pattern + no container references (+ not claimed by another installed module).
    _purge_sweep_declared "$name"
  fi
  unmark_installed "$name"
  # data verdict rides the final line regardless of the profile/cache branch
  local verdict
  if [ "${purge}" = "1" ]; then
    verdict=" — data deleted (volumes + deploy .env)"
  else
    verdict=" — data RETAINED (cleanup: aibox autoclean ${name})"
  fi
  # The script cache is shared across profiles: delete it only when no OTHER profile
  # still has this module installed (else a prod uninstall would break the default install).
  if _installed_any_profile "$name"; then
    log "Uninstalled $name${verdict} (profile: ${AIBOX_PROFILE:-base}; script cache retained — still installed under another profile)"
  else
    rm -rf "$dest"
    log "Uninstalled $name${verdict}"
    # --purge: verify instead of trusting the flag — hooks can miss (the leftover
    # network was invisible until an independent sweep found it). Only when no
    # other profile remains (the hint's verb skips live deployments by design).
    if [ "$purge" = 1 ]; then
      local _left
      _left="$(_purge_count_module_residue "$name")"
      if [ "${_left:-0}" -gt 0 ]; then
        warn "  ${_left} leftover item(s) remain — clean: aibox autoclean ${name} --apply"
      fi
    fi
  fi
}

# No-op gate for `aibox update <module>`: 0 when the REMOTE module.yaml's
# version equals the local cache's AND the local standard-6 is intact (a
# broken cache always re-fetches — the re-fetch is the self-heal). One pooled
# fetch of module.yaml only; any failure → 1 (fall through to the full update,
# which dies loudly if the network is truly gone).
_update_noop() { # $1=module $2=current(local) version
  local f2 dir yaml remote_ver extra
  for f2 in module.yaml lib.sh install.sh uninstall.sh update.sh svc.sh; do
    [ -s "$AIBOX_MOD_DIR/$1/$f2" ] || return 1
  done
  load_registry
  # declared extra files (compose, vendored templates, dispatched CLIs) are
  # consumed by the hook — a missing one must re-fetch, not skip
  for extra in $(module_field "$1" files); do
    [ -s "$AIBOX_MOD_DIR/$1/$extra" ] || return 1
  done
  dir="$(module_field "$1" dir)"
  [ -n "${dir}" ] || return 1
  yaml="$(gh_pool_fetch "${AIBOX_RAW%/}/${dir}/module.yaml" 2>/dev/null)" || return 1
  remote_ver="$(printf '%s\n' "${yaml}" | sed -n 's/^version:[[:space:]]*//p' | head -1)"
  [ -n "${remote_ver}" ] && [ "${remote_ver}" = "$2" ]
}

cmd_update() {
  local name="" self_flag=0 restart_arg="" a
  for a in "$@"; do
    case "$a" in
      --all)                  self_flag=1 ;;
      --restart|--no-restart) restart_arg="$a" ;;
      --skip-checks)          PREFLIGHT_SKIP=1 ;;
      --yes|-y)               ASSUME_YES=1 ;;
      -h|--help)              _verb_help update; exit 0 ;;
      -*)                     usage_die "unknown option for update: $a (usage: aibox update <module>|self|--all [--restart|--no-restart] [--skip-checks])" ;;
      *)                      [ -z "$name" ] && name="$a" ;;
    esac
  done

  if [ -n "$name" ]; then
    if [ "$name" = self ]; then cmd_self_update; return $?; fi
    is_installed "${name}" || die "${name} not installed"
    # The SCRIPT re-fetch is skippable (remote version unchanged + an intact
    # local file set — one pooled module.yaml probe decides); the update HOOK
    # always runs: it owns the module's app-level refreshes (pi-web's npm app
    # + the pi CLI, clash's kernel, openmaic/windmill's dispatched CLI, the
    # docker modules' compose refresh). "nothing to do" is the HOOK's verdict
    # to make and report — the manager must not swallow it.
    local cur_ver new_ver dest upd skip_fetch=0
    cur_ver="$(_module_version_local "${name}")"
    if [ -n "${cur_ver}" ] && _update_noop "${name}" "${cur_ver}"; then
      skip_fetch=1
      log "${name} scripts already at ${cur_ver} (no re-fetch) — running the update hook"
      dest="$AIBOX_MOD_DIR/$name"
      load_registry   # module_field lookups for the hook below (subsequent lines)
    else
      log "Updating ${name} (re-fetching module scripts) ..."
      download_module "${name}"
      dest="$AIBOX_LAST_DEST"
    fi
    local prc=0
    preflight_module "${name}" || prc=$?
    if [ "${prc}" = "3" ]; then
      die_code 3 "Update aborted: a hard requirement is missing (fix the issues above; --skip-checks cannot bypass it)"
    elif [ "${prc}" != "0" ]; then
      die_code 4 "Update aborted: the environment check failed (fix the issues above, or re-run with --skip-checks)"
    fi
    upd="$(module_field "${name}" update)"
    if [ -n "$upd" ] && [ -f "$dest/$upd" ]; then
      # The hook's own output shows above; wrap its failure with module context
      # (previously set -e killed the command here with no wrapper message).
      # shellcheck disable=SC2086
      if ! AIBOX_MODULE="${name}" bash "$dest/$upd" ${restart_arg:+"$restart_arg"}; then
        die "update ${name} FAILED: the module's update hook did not complete (apply manually: aibox ${name} restart)"
      fi
    else
      warn "No update hook; script cache left as-is"
    fi
    mark_installed "${name}" "$(module_field "${name}" version)"
    # script-part transition report (the ask: "from what TO what"). TWO version
    # namespaces: the aibox MODULE version (module.yaml packaging — this line)
    # vs the upstream APP version (the update hook's / `aibox upgrade`'s output
    # above). The manager reports ONLY the script half; the app half is the
    # hook's own reporting — that split is what keeps this unambiguous.
    new_ver="$(module_field "${name}" version)"
    if [ "${skip_fetch}" = "1" ]; then
      log "${name} module scripts unchanged at ${cur_ver} · update hook ran above"
    elif [ -n "${cur_ver}" ] && [ "${new_ver}" != "${cur_ver}" ]; then
      log "${name} module scripts updated: ${cur_ver} → ${new_ver}"
    else
      log "${name} module scripts refreshed at ${new_ver} (no version change)"
    fi
    local _usrc; _usrc="$(module_field "${name}" upgrade_source)"
    [ -n "${_usrc}" ] && info "upstream app version floats separately: aibox upgrade ${name} [--check]"
  elif [ "$self_flag" = "1" ]; then
    log "Updating all installed modules ..."
    # Per-module failure tolerance: one bad module must not abort the remaining
    # updates (previously set -e killed the whole loop at the first failure,
    # silently skipping the rest + the self-update never ran).
    local m failed_list=""
    for m in $(installed_names); do
      if ! cmd_update "${m}"; then
        warn "update ${m} failed — continuing with the remaining modules"
        failed_list="${failed_list} ${m}"
      fi
    done
    [ -n "${failed_list}" ] && bad "update --all: FAILED for:${failed_list} (see each module's output above)"
  else
    usage_die "Usage: aibox update <module> [--restart|--no-restart] [--all] | --all"
  fi

  if [ "$self_flag" = "1" ]; then
    log "Updating aibox itself ..."
    cmd_self_update || warn "aibox self-update failed (network?); modules were updated"
  fi
}


# ---------- upgrade state / rollback points ----------
# One state file + an append-only log per module under $AIBOX_HOME/upgrades/.
# The engine's AUTOMATIC rollback only covers a failed upgrade; `--rollback`
# (a user-level rollback POINT) needs to know the previous pin, where its .env
# backup lives, and whether a data snapshot was taken. State is local-only:
# the dashboard renders it with zero network.
_upgrade_dir()        { printf '%s/upgrades' "${AIBOX_HOME}"; }
_upgrade_state_file() { printf '%s/%s.state' "$(_upgrade_dir)" "$1"; }
_upgrade_log_file()   { printf '%s/%s.log'   "$(_upgrade_dir)" "$1"; }

_upgrade_state_set() { # $1=module $2=key $3=value (merge; single line)
  local m="$1" k="$2" v="$3" f tmp
  f="$(_upgrade_state_file "${m}")"
  mkdir -p "$(_upgrade_dir)" 2>/dev/null || true
  tmp="${f}.tmp.$$"
  : >"${tmp}"
  if [ -f "${f}" ]; then grep -vE "^${k}=" "${f}" >"${tmp}" 2>/dev/null || true; fi
  printf '%s=%s\n' "${k}" "$(printf '%s' "${v}" | tr '\n' ' ')" >>"${tmp}"
  mv "${tmp}" "${f}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
  return 0
}

_upgrade_state_get() { # $1=module $2=key → value ("" when absent)
  local f; f="$(_upgrade_state_file "$1")"
  [ -f "${f}" ] || return 0
  sed -n "s/^$2=//p" "${f}" | head -1
}

_upgrade_log_append() { # $1=module $2=line
  local f; f="$(_upgrade_log_file "$1")"
  mkdir -p "$(_upgrade_dir)" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >>"${f}" 2>/dev/null || true
  return 0
}

# The running app's version, via the module's own dashboard_info (local probe).
# Recorded after an upgrade: the image tag is a promise, this is the evidence.
_upgrade_live_version() { # $1=module
  local m="$1" mod_dir="${AIBOX_MOD_DIR}/$1" out
  [ -f "${mod_dir}/lib.sh" ] || return 0
  out="$(AIBOX_MODULE="${m}" AIBOX_HOME="${AIBOX_HOME}" bash -c ". '${mod_dir}/lib.sh' 2>/dev/null && type dashboard_info >/dev/null 2>&1 && dashboard_info 2>/dev/null || true" 2>/dev/null | sed -n 's/^version=//p' | head -1)"
  out="${out#v}"; out="${out%% *}"
  [ -n "${out}" ] && printf '%s' "${out}"
  return 0
}

# Shared-base DB name for a module (services: base:postgres#<db>) → "" when none.
_upgrade_db_name() { # $1=module
  local svcs svc
  svcs="$(_module_meta_local "$1" services)"
  [ -n "${svcs}" ] || svcs="$(module_field "$1" services 2>/dev/null || true)"
  for svc in ${svcs}; do
    case "$svc" in base:postgres#*) printf '%s' "${svc#base:postgres#}"; return 0 ;; esac
  done
  return 0
}

# Pre-upgrade DATA snapshot, generic for shared-base consumers: the DB lives in
# the base container (base.env carries its name/user — single source), so the
# engine can dump it without any module-specific code. Prints the snapshot path
# ("" when there is nothing to snapshot or the dump failed).
_upgrade_db_snapshot() { # $1=module $2=db
  local m="$1" db="$2" envf c u ts out
  envf="${AIBOX_HOME}/base.env"
  [ -f "${envf}" ] || return 0
  c="$(grep -E '^AIBOX_POSTGRES_HOST=' "${envf}" 2>/dev/null | cut -d= -f2- | head -1)"
  u="$(grep -E '^AIBOX_POSTGRES_USER=' "${envf}" 2>/dev/null | cut -d= -f2- | head -1)"
  [ -n "${c}" ] || return 0
  [ -n "${u}" ] || u="aibox"
  command -v docker >/dev/null 2>&1 || return 0
  mkdir -p "$(_upgrade_dir)" 2>/dev/null || true
  ts="$(date +%Y%m%d%H%M%S)"
  out="$(_upgrade_dir)/${m}-db-${ts}.sql.gz"
  if docker exec "${c}" pg_dump -U "${u}" -d "${db}" 2>/dev/null | gzip -c >"${out}" 2>/dev/null && [ -s "${out}" ]; then
    printf '%s' "${out}"
    return 0
  fi
  rm -f "${out}" 2>/dev/null || true
  return 0
}

# Manual data-restore recipe (printed, never auto-run: restoring data over a live
# instance is a deliberate act).
_upgrade_db_restore_hint() { # $1=snapshot $2=db
  local snap="$1" db="$2" envf c u
  envf="${AIBOX_HOME}/base.env"
  c="$(grep -E '^AIBOX_POSTGRES_HOST=' "${envf}" 2>/dev/null | cut -d= -f2- | head -1)"; [ -n "${c}" ] || c="<base-pg-container>"
  u="$(grep -E '^AIBOX_POSTGRES_USER=' "${envf}" 2>/dev/null | cut -d= -f2- | head -1)"; [ -n "${u}" ] || u="aibox"
  log "  data    : gunzip -c ${snap} | docker exec -i ${c} psql -U ${u} -d ${db}"
}

# Verified rollback: restore the recorded .env pin and re-run the module's start,
# then CHECK the result. The old flow restored + started but never verified — it
# claimed "rolled back" and returned 20 even when the module was still broken,
# while docs/module-spec.md §Exit codes promises 10 (failed, rolled back) and
# 20 (not ready after rollback).
_upgrade_rollback() { # $1=module $2=svc $3=envfile $4=envbak $5=prev_ver
  local name="$1" svc="$2" envf="$3" bak="$4" prev="$5"
  [ -f "${bak}" ] || { warn "no .env backup to roll back to (${bak})"; return 1; }
  cp "${bak}" "${envf}" || { warn "cannot restore ${envf} from ${bak}"; return 1; }
  log "restored ${envf} from ${bak} (pin back to ${prev})"
  if AIBOX_MODULE="${name}" bash "${svc}" start; then
    ok "rolled back to ${prev} — the previous version is healthy"
    return 0
  fi
  warn "the rollback to ${prev} did NOT come up healthy"
  return 1
}

cmd_upgrade() {
  local name="" target="" check_only=0 pinned=0 mode="" no_backup=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)      check_only=1; shift ;;
      --rollback)   mode="rollback"; shift ;;
      --history)    mode="history"; shift ;;
      --no-backup)  no_backup=1; shift ;;
      -h|--help)    _verb_help upgrade; exit 0 ;;
      --to)         target="${2:-}"; [ -n "${target}" ] || die "--to needs a version (e.g. --to 1.17.2)"; pinned=1; shift 2 ;;
      --yes | -y)   ASSUME_YES=1; shift ;;
      -*)           usage_die "unknown option for upgrade: $1 (usage: aibox upgrade <module> [--check|--rollback|--history] [--to <version>] [--no-backup] [--yes])" ;;
      *)            [ -z "${name}" ] && name="$1"; shift ;;
    esac
  done
  [ -n "${name}" ] || usage_die "Usage: aibox upgrade <module> [--check|--rollback|--history] [--to <version>] [--no-backup] [--yes] — upstream component upgrade, independent of aibox releases (vs: aibox update = re-fetch module scripts)"
  # --history / --rollback are LOCAL-ONLY (state file + deploy .env) and must work
  # offline, like the rest of the local-first surface; every other path resolves a
  # TARGET version and therefore needs the registry (and its stanza).
  local src repo images mapping pattern
  if [ "${mode}" = "history" ] || [ "${mode}" = "rollback" ]; then
    is_installed "${name}" || die "${name} not installed (first: aibox install ${name})"
  else
    load_registry
    module_exists "${name}" || die_unknown_module "${name}"
    is_installed "${name}" || die "${name} not installed (first: aibox install ${name})"
    src="$(module_field "${name}" upgrade_source)"
    repo="$(module_field "${name}" upgrade_repo)"
    images="$(module_field "${name}" upgrade_images)"
    mapping="$(module_field "${name}" upgrade_mapping_url)"
    pattern="$(module_field "${name}" upgrade_tag_pattern)"
    if [ -z "${src}" ]; then
      # Modules that OWN their upgrade path (base's infra image pins, the dispatch
      # CLIs) say so, instead of a bare "no support" that reads like a bug.
      case " $(_module_meta_local "${name}" actions) $(module_field "${name}" actions 2>/dev/null || true) " in
      *" upgrade "*) die "${name} owns its upgrade path — use: aibox ${name} upgrade --help   (the manager engine drives modules with an 'upgrade:' stanza; this one implements its own verbs)" ;;
      esac
      die "${name} does not declare upgrade support (module.yaml 'upgrade:' stanza — see docs/module-spec.md §Component upgrades)"
    fi
    [ -n "${repo}" ] || die "${name} upgrade stanza missing repo"
    [ -n "${images}" ] || die "${name} upgrade stanza missing the images list"
  fi

  # Locate the module cache + the deploy .env via the module's own lib.sh
  # (the same pattern dashboard_info uses) — shared by every mode.
  local mod_dir="${AIBOX_MOD_DIR}/${name}" envf root svc
  [ -f "${mod_dir}/lib.sh" ] || die "Missing ${mod_dir}/lib.sh (try: aibox update ${name})"
  root="$(AIBOX_MODULE="${name}" AIBOX_HOME="${AIBOX_HOME}" bash -c ". '${mod_dir}/lib.sh' 2>/dev/null; deploy_root 2>/dev/null" 2>/dev/null || true)"
  [ -n "${root}" ] || die "cannot locate ${name} deploy root (lib.sh deploy_root)"
  envf="${root}/.env"
  [ -f "${envf}" ] || die "${name} deploy .env not found (${envf}; reinstall: aibox install ${name})"
  svc="${mod_dir}/svc.sh"

  # --history: the recorded transitions (local state, zero network)
  if [ "${mode}" = "history" ]; then
    local lf st st_from st_to st_ts st_live
    lf="$(_upgrade_log_file "${name}")"
    st="$(_upgrade_state_get "${name}" status)"
    st_from="$(_upgrade_state_get "${name}" from)"; st_to="$(_upgrade_state_get "${name}" to)"
    st_ts="$(_upgrade_state_get "${name}" ts)";   st_live="$(_upgrade_state_get "${name}" live)"
    if [ -z "${st}" ] && [ ! -f "${lf}" ]; then
      log "no upgrade recorded for ${name} yet (nothing to show)"
      return 0
    fi
    log "${name} — last recorded upgrade:"
    [ -n "${st}" ] && log "  state   : ${st}$( [ -n "${st_ts}" ] && printf ' (%s)' "${st_ts}" )"
    [ -n "${st_from}" ] && log "  pin     : ${st_from} → ${st_to:-?}$( [ -n "${st_live}" ] && printf '   live: %s' "${st_live}" )"
    [ -n "${st_from}" ] && log "  rollback: aibox upgrade ${name} --rollback   (back to ${st_from})"
    if [ -f "${lf}" ]; then
      log "  history :"
      tail -n "${AIBOX_UPGRADE_HISTORY_LINES:-10}" "${lf}" | sed 's/^/    /'
    fi
    return 0
  fi

  # --rollback: restore the recorded pre-upgrade pin (a rollback POINT). Local
  # first: it needs no network unless the pin has to be resolved manually.
  if [ "${mode}" = "rollback" ]; then
    local r_from r_bak r_snap r_db r_to r_now r_newbak
    r_from="$(_upgrade_state_get "${name}" from)"
    r_bak="$(_upgrade_state_get "${name}" envbak)"
    r_snap="$(_upgrade_state_get "${name}" databak)"
    r_to="$(_upgrade_state_get "${name}" to)"
    r_db="$(_upgrade_db_name "${name}")"
    [ -n "${r_from}" ] || die "no rollback point recorded for ${name} — nothing to roll back to (pin explicitly: aibox upgrade ${name} --to <version>)"
    if [ "${ASSUME_YES:-0}" != 1 ]; then
      ask_confirm "Roll ${name} back to ${r_from}? (restores the version pin and recreates the containers)" \
        || { warn "declined (non-interactive? add --yes)"; return 2; }
    fi
    [ -f "${r_bak}" ] || die "the recorded .env backup is gone (${r_bak}) — pin manually: aibox upgrade ${name} --to ${r_from}"
    # Symmetric: the version we are leaving becomes the next rollback point, so a
    # second --rollback undoes this one (git-revert semantics, not a dead end).
    r_now="$(_upgrade_live_version "${name}")"
    [ -n "${r_now}" ] || r_now="${r_to}"
    r_newbak="${envf}.bak.$(date +%Y%m%d%H%M%S).$$"
    cp "${envf}" "${r_newbak}" 2>/dev/null || true
    if _upgrade_rollback "${name}" "${svc}" "${envf}" "${r_bak}" "${r_from}"; then
      _upgrade_state_set "${name}" status rolled-back
      _upgrade_state_set "${name}" from "${r_now:-?}"
      _upgrade_state_set "${name}" to "${r_from}"
      _upgrade_state_set "${name}" envbak "${r_newbak}"
      _upgrade_state_set "${name}" databak ""
      _upgrade_state_set "${name}" live "$(_upgrade_live_version "${name}")"
      _upgrade_log_append "${name}" "${r_now:-?} → ${r_from} rolled-back-by-user"
      [ -n "${r_snap}" ] && info "the upgrade's data snapshot is still available: ${r_snap}"
      [ -n "${r_snap}" ] && [ -n "${r_db}" ] && _upgrade_db_restore_hint "${r_snap}" "${r_db}"
      return 0
    fi
    _upgrade_state_set "${name}" status manual
    _upgrade_log_append "${name}" "${r_now:-?} → ${r_from} rollback-failed"
    warn "rollback failed — manual intervention needed"
    log "  inspect : aibox ${name} logs"
    log "  pin     : ${envf}"
    return 20
  fi

  # Current live version: the first declared image key's tag (fallback: compose floor).
  local first k prefix cur_img cur_ver
  first="$(printf '%s' "${images}" | awk '{print $1}')"
  k="${first%%=*}"
  prefix="${first#*=}"
  cur_img="$(grep -m1 "^${k}=" "${envf}" 2>/dev/null | cut -d= -f2-)"
  [ -n "${cur_img}" ] || cur_img="$(upgrade_floor_image "${mod_dir}/docker-compose.yml" "${k}")"
  [ -n "${cur_img}" ] || die "cannot determine the current image for ${k} (neither ${envf} nor the compose default)"
  cur_ver="${cur_img#"${prefix}"}"

  # Resolve the target version.
  if [ -z "${target}" ]; then
    case "${src}" in
      github-release)
        target="$(upgrade_fetch "https://api.github.com/repos/${repo}/releases/latest" \
          | grep -m1 -oE '"tag_name": *"[^"]+"' | sed -e 's/.*"tag_name": *"//' -e 's/"$//' || true)"
        ;;
      dockerhub-tags)
        target="$(dockerhub_tags_fetch "${repo}" | upgrade_pick_tag "${pattern}" || true)"
        ;;
      *)
        die "${name}: unknown upgrade source '${src}' (github-release | dockerhub-tags)"
        ;;
    esac
    target="${target#v}"
  fi
  [ -n "${target}" ] || die "cannot resolve the latest version for ${name} — the official registry, the local registry-mirrors and the acceleration pool all timed out (dockerpool.cache invalidated; try: aibox clash on / aibox proxy on; or pin explicitly: aibox upgrade ${name} --to <version>)"

  if [ "$(upgrade_ver_cmp "${target}" "${cur_ver}")" = "0" ]; then
    log "${name} is already at ${cur_ver}"
    if [ "${check_only}" = 1 ]; then
      local rb_pt; rb_pt="$(_upgrade_state_get "${name}" from)"
      [ -n "${rb_pt}" ] && log "rollback: ${rb_pt}   application: aibox upgrade ${name} --rollback"
    fi
    return 0
  fi

  # Multi-hop provider: the module's cached lib.sh may define upgrade_stops()
  # (gitlab's required-upgrade-stops rule — docs.gitlab.com/update/upgrade_paths).
  # Absent → the single-hop behavior below, completely unchanged.
  local stops_out="" stops_fn hop_list=() hop_ver i n_hops
  stops_fn="$(AIBOX_MODULE="${name}" AIBOX_HOME="${AIBOX_HOME}" bash -c ". '${mod_dir}/lib.sh' 2>/dev/null; type -t upgrade_stops" 2>/dev/null || true)"
  if [ "${stops_fn}" = "function" ]; then
    local cur_mm tgt_mm
    cur_mm="$(printf '%s' "${cur_ver%%-*}" | cut -d. -f1,2)"
    tgt_mm="$(printf '%s' "${target%%-*}" | cut -d. -f1,2)"
    stops_out="$(AIBOX_MODULE="${name}" AIBOX_HOME="${AIBOX_HOME}" bash -c ". '${mod_dir}/lib.sh' 2>/dev/null; upgrade_stops '${cur_mm}' '${tgt_mm}'" 2>/dev/null || true)"
    # intermediate stops (each resolves to its minor's LATEST PATCH) + the final target
    while IFS= read -r hop_ver; do
      [ -n "${hop_ver}" ] && hop_list+=("${hop_ver}")
    done <<HOPSLIST
$(printf '%s\n' "${stops_out}" | _upgrade_path_compute "${cur_ver}" "${target}")
HOPSLIST
    hop_list+=("${target}")
  fi
  n_hops="${#hop_list[@]}"

  # Guardrail: auto-latest refuses to cross a major version (migration/data risk)
  # — EXCEPT for multi-hop modules: the hop sequence IS the migration-safe path.
  if [ "${pinned}" = 0 ] && [ "${target%%.*}" != "${cur_ver%%.*}" ] && [ "${n_hops}" -le 1 ]; then
    die "latest ${target} crosses a major version (current ${cur_ver}) — major upgrades can require migrations/data steps; pin explicitly: aibox upgrade ${name} --to ${target}"
  fi

  # Downgrade honesty: schema/data migrations are usually one-way, so a version
  # rollback alone may leave the app unable to start on the old code.
  if [ "$(upgrade_ver_cmp "${target}" "${cur_ver}")" = "-1" ]; then
    warn "downgrade ${cur_ver} → ${target}: data migrations are usually one-way"
    warn "  a version rollback alone may not be enough — aibox upgrade ${name} --history shows the recorded data snapshot"
  fi

  # Rollback point (recorded from a previous upgrade) — surfaced by --check so the
  # user knows the way back BEFORE applying.
  local rb_from rb_ts
  rb_from="$(_upgrade_state_get "${name}" from)"
  rb_ts="$(_upgrade_state_get "${name}" ts)"

  if [ "${check_only}" = 1 ]; then
    log "current : ${cur_ver}"
    log "target  : ${target}"
    [ -n "${rb_from}" ] && log "rollback: ${rb_from}$( [ -n "${rb_ts}" ] && printf ' (recorded %s)' "${rb_ts}" )   application: aibox upgrade ${name} --rollback"
    if [ "${n_hops}" -gt 1 ]; then
      log "path    : $((n_hops - 1)) required upgrade stop(s) — official rule: every stop between current and target, each hop on the minor's latest patch, migrations must finish before the next hop"
      i=0
      for hop_ver in "${hop_list[@]}"; do
        i=$((i + 1))
        if [ "${i}" -eq "${n_hops}" ]; then
          log "  hop ${i}/${n_hops}  ${hop_ver}    target"
        else
          log "  hop ${i}/${n_hops}  ${hop_ver}.z → latest patch of ${hop_ver}    required stop"
        fi
      done
      log "note    : omnibus boot 3-5 min/hop; the readiness gate (incl. db migrations) runs between hops"
    fi
    if [ "$(upgrade_ver_cmp "${target}" "${cur_ver}")" = "1" ]; then
      log "status  : upgrade available (apply: aibox upgrade ${name} [--to ${target}] [--yes])"
    else
      log "status  : current is newer than the resolved target (downgrade only with --to)"
    fi
    return 0
  fi

  if [ "${ASSUME_YES:-0}" != 1 ]; then
    if [ "${n_hops}" -gt 1 ]; then
      ask_confirm "Upgrade ${name} ${cur_ver} → ${target} through $((n_hops - 1)) required stop(s)? (each hop recreates the container + health-waits; omnibus boots 3-5 min/hop)" \
        || { warn "declined (non-interactive? add --yes)"; return 2; }
    else
      ask_confirm "Upgrade ${name} ${cur_ver} → ${target}? (recreates containers; data volumes are preserved)" \
        || { warn "declined (non-interactive? add --yes)"; return 2; }
    fi
  fi

  # The apply path recreates via the module's own svc start — require it before touching anything.
  [ -f "${svc}" ] || die "Missing ${svc} (try: aibox update ${name})"

  # ---- multi-hop execution: gitlab-style required upgrade stops ----
  if [ "${n_hops}" -gt 1 ]; then
    _upgrade_multi_hop "${name}" "${cur_ver}" "${envf}" "${svc}" "${images}" "${pattern}" "${repo}" "${src}" "${no_backup}" "${hop_list[@]}"
    return $?
  fi

  # Build the new image values: pairing comes from the upstream compose at the target tag
  # (mapping_url), or tag == target when there is no mapping (dockerhub single-image).
  local mapping_body="" newvals=() kv tag
  if [ -n "${mapping}" ]; then
    mapping_body="$(upgrade_fetch "${mapping//<VER>/${target}}")" \
      || die "cannot fetch the image mapping at ${target} (${mapping//<VER>/<version>}) — bad tag, or network (aibox clash on)"
  fi
  # shellcheck disable=SC2086
  for kv in $images; do
    k="${kv%%=*}"
    prefix="${kv#*=}"
    if [ -n "${mapping}" ]; then
      tag="$(printf '%s' "${mapping_body}" | upgrade_extract_tag "${prefix}")" \
        || die "cannot extract the image tag for ${prefix} in the upstream mapping at ${target}"
    else
      tag="${target}"
    fi
    newvals+=("${k}=${prefix}${tag}")
  done

  # Pull every new image BEFORE touching anything — but a direct-pull failure no
  # longer aborts (compose modules now carry a docker.io mirror pool that retries
  # at svc start; the health gate + auto-rollback remain the safety net).
  local img
  for kv in "${newvals[@]}"; do
    img="${kv#*=}"
    if docker image inspect "${img}" >/dev/null 2>&1; then
      log "Already cached: ${img}"
      continue
    fi
    log "pulling ${img} …"
    if ! docker pull "${img}" >/dev/null 2>&1; then
      warn "direct docker pull failed: ${img} — continuing (mirror pool retries at svc start; health gate + rollback protect)"
    fi
  done

  # Back up the pin, snapshot the data (when the module's DB is knowable), then
  # rewrite ONLY the declared image keys and recreate + health-wait via svc start.
  # Every phase is recorded, so a failed upgrade still leaves a usable rollback
  # point and the dashboard can show the state.
  local ts bak db snap=""
  ts="$(date +%Y%m%d%H%M%S)"
  # $$ keeps the name unique: two runs inside the same second would otherwise
  # share a path — and a rollback in that window would clobber its own rollback
  # point (caught by tests/upgrade-rollback.bats).
  bak="${envf}.bak.${ts}.$$"
  cp "${envf}" "${bak}"
  log "backed up ${envf} → ${bak}"
  db="$(_upgrade_db_name "${name}")"
  if [ "${no_backup}" = 1 ]; then
    log "data snapshot skipped (--no-backup) — rollback restores the version pin only"
  elif [ -n "${db}" ]; then
    log "snapshotting the shared-base database '${db}' before the upgrade …"
    snap="$(_upgrade_db_snapshot "${name}" "${db}")"
    if [ -n "${snap}" ]; then ok "  data snapshot: ${snap}"
    else warn "  snapshot failed — rollback restores the version pin only"; fi
  else
    log "no shared-base database declared for ${name} — rollback restores the version pin only"
    log "  (schema migrations may be one-way; see docs/module-spec.md §Component upgrades)"
  fi
  _upgrade_state_set "${name}" ts "${ts}"
  _upgrade_state_set "${name}" from "${cur_ver}"
  _upgrade_state_set "${name}" to "${target}"
  _upgrade_state_set "${name}" envbak "${bak}"
  _upgrade_state_set "${name}" databak "${snap}"
  _upgrade_state_set "${name}" status started
  _upgrade_log_append "${name}" "${cur_ver} → ${target} started${snap:+ snapshot=${snap}}"
  upgrade_env_rewrite "${envf}" "${newvals[@]}"
  log "rewrote image tags in ${envf} (${cur_ver} → ${target})"

  if ! AIBOX_MODULE="${name}" bash "${svc}" start; then
    warn "upgrade failed the health check (${cur_ver} → ${target})"
    if _upgrade_rollback "${name}" "${svc}" "${envf}" "${bak}" "${cur_ver}"; then
      _upgrade_state_set "${name}" status rolled-back
      _upgrade_state_set "${name}" live "$(_upgrade_live_version "${name}")"
      _upgrade_log_append "${name}" "${cur_ver} → ${target} rolled-back"
      warn "inspect: aibox ${name} logs; retry once fixed: aibox upgrade ${name} --to ${target}"
      return 10
    fi
    _upgrade_state_set "${name}" status manual
    _upgrade_log_append "${name}" "${cur_ver} → ${target} rollback-failed"
    warn "manual intervention needed — the rollback did not come up either"
    log "  inspect : aibox ${name} logs"
    log "  pin     : ${envf} (backup: ${bak})"
    log "  retry   : aibox upgrade ${name} --to ${cur_ver}    (re-apply the previous pin)"
    [ -n "${snap}" ] && [ -n "${db}" ] && _upgrade_db_restore_hint "${snap}" "${db}"
    return 20
  fi
  # NOTE: the module's installed-marker version is NOT overwritten with the app
  # version: the marker means "module version" (what `aibox update` compares),
  # and the app version now lives in the upgrade state where the dashboard reads
  # it. Overwriting it made `aibox update` report a bogus version transition on
  # the next run (app 1.19.0 vs module 1.4.3).
  # Post-upgrade verification: what does the RUNNING app report? (recorded; a
  # mismatch warns but never fails — the module's own health gate already passed)
  local live
  live="$(_upgrade_live_version "${name}")"
  _upgrade_state_set "${name}" live "${live}"
  _upgrade_state_set "${name}" status ok
  _upgrade_log_append "${name}" "${cur_ver} → ${target} ok${snap:+ snapshot=${snap}}"
  ok "${name} upgraded ${cur_ver} → ${target} (data volumes preserved; backup: ${bak})"
  if [ -n "${live}" ] && [ "${live#v}" != "${target}" ]; then
    warn "the running app reports ${live} (pin: ${target}) — the image tag and the app version can differ per module"
  fi
  log "rollback point: aibox upgrade ${name} --rollback   (back to ${cur_ver})"
  log "reclaim the old images: docker image prune"
}

cmd_list_available() {
  # The catalog IS the network view — but degrade gracefully: an unreachable
  # registry falls back to the installed modules (local) instead of dying.
  if ! ( load_registry ) >/dev/null 2>&1; then
    warn "registry unreachable — showing installed modules only (the full catalog needs the network)"
    printf '%s%s%s\n' "$C_BOLD" "aibox modules (installed)" "$C_RST"
    while read -r m prof ver; do
      [ -n "${m}" ] || continue
      printf '  ✓ %-14s %-8s profile %s\n' "${m}" "${ver}" "${prof}"
    done <<CATALOGFB
$(_installed_pairs)
CATALOGFB
    return 0
  fi
  # the subshell refresh wrote the cache — load it without the network
  load_registry
  printf '%s%s%s\n' "$C_BOLD" "aibox module catalog" "$C_RST"
  printf '%sregistry @ %s\n\n' "$C_DIM" "${AIBOX_BRANCH}"
  printf '%s  %-14s  %-8s  %-30s  %s%s\n' "$C_DIM" "MODULE" "VERSION" "DESCRIPTION" "STATUS" "$C_RST"
  local m desc ver inst
  for m in ${AIBOX_MODULES:-}; do
    desc="$(module_field "$m" description)"
    ver="$(module_field "$m" version)"
    if is_installed "$m"; then
      inst="${C_GRN}✓ installed${C_RST}"
    else
      inst="${C_DIM}—${C_RST}"
    fi
    printf '  %-14s  %-8s  %-30s  %s\n' "$m" "$ver" "$(_trunc "${desc:-}" 30)" "$inst"
  done
  printf '\n%sVERSION = the aibox module version · the deployed app version: aibox dashboard <module>%s\n' "$C_DIM" "$C_RST"
}

# Dashboard: module status + endpoint + credentials, visualized.
# `aibox dashboard` — global overview table; `aibox <module> dashboard` — module detail + health probe.
cmd_dashboard() {
  case "${1:-}" in
    -h|--help)   _verb_help dashboard; return 0 ;;
    --available) cmd_list_available ;;
    "")          cmd_dashboard_overview ;;
    *)           cmd_dashboard_detail "$1" ;;
  esac
}

# Truncate a string to N visible columns, appending an ellipsis if it was cut.
# Values come from dashboard_info()/module.yaml hints (ASCII), so byte-slicing is safe here.
_trunc() { local s="$1" n="$2"; [ "${#s}" -gt "$n" ] && printf '%s…' "${s:0:$((n-1))}" || printf '%s' "$s"; }


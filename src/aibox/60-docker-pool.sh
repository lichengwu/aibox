# ---------- docker source selector: TAGS family (dockerhub version resolution) ----------
# The PULL/GHCR pool families live in tools/_shared/lib (30-dockerio.sh,
# 35-ghcr.sh) and are injected into this bundle; the manager is no longer a copy
# (the old comment here claimed a twin — the manager never
# sources the shared include — SAME cache file $AIBOX_HOME/dockerpool.cache,
# SAME grammar "TAGS<TAB>token…", TTL AIBOX_DOCKER_POOL_TTL). Resolves the tag
# list of a dockerhub repo with STRICT priority (spec §Docker source selector,
# user-pinned):
#   ① hub.docker.com direct — the default address (bounded)
#   ② local addresses — the user knob (AIBOX_DOCKER_MIRROR) + the daemon's
#      own registry-mirrors (docker info; the mirrors the host already has)
#   ③ the acceleration pool below — engaged ONLY when ①② time out or die:
#      concurrent race on the ACTUAL repo, speed-ranked, fastest-first
#      failover; ①② ③  failures are death-cached (a cache line without a
#      "direct" token skips the official route's timeout tax until the TTL
#      re-probes it — mirrors die AND revive, networks change).
# Output: tag names, one per line (both JSON shapes normalized: hub v2
# "results" and registry v2 "tags"); rc 1 when unresolvable.
# Live-verified DIRECT (no proxy) 2026-09-23 — keep in sync with common.sh's
# DOCKER_POOL_MIRRORS (the families probe-prune per channel: daocloud 401s
# the tags API but pulls fine; hub3/hub4/367231 serve tags but not pulls).
# Knobs: AIBOX_DOCKER_POOL (mirror list override; "direct|none|off" = pool
# off), AIBOX_DOCKER_MIRROR (user mirror, priority),
# AIBOX_DOCKER_TAGS_TIMEOUT (8s per candidate), AIBOX_DOCKER_POOL_TTL (600).

# (the cache helpers themselves live in the shared lib: one implementation)

# Tags from the official hub v2 API (the default address).

# Tags from a registry-v2 mirror (the acceleration form).

# The daemon's own registry-mirrors — LOCAL addresses the host already has
# (e.g. a NAS mirror configured in daemon.json). "[https://a.b:5443/]" → hosts.

# Resolve a dockerhub repo's tag list (priority: direct → local → ranked
# pool). rc 1 when nothing answers.

# Fetch a URL for the component-upgrade engine: routed through the source pool
# (gh_pool_fetch) — the pool's ghapi pseudo-candidate and mirror candidates
# subsume the old chain (direct → raw→api rewrite → CLASH_MIRROR); dockerhub and
# other non-GitHub hosts go direct + the user mirror, preserving old semantics.
upgrade_fetch() {
  gh_pool_fetch "$1"
}

# Resolve the LATEST PATCH tag of a given major.minor from dockerhub (gitlab hops
# must land on the latest patch, never the first: official rule). stdin (optional)
# = an already-fetched tag-name list to reuse; empty result triggers a targeted
# ?name=<major.minor> fetch (substring filter — the strict tag pattern weeds out
# the cross matches like 8.17.8 vs 17.8).
# Resolve the LATEST PATCH tag of a given major.minor from dockerhub (gitlab
# hops must land on the latest patch of the stop's minor, never the first —
# official rule). Targeted ?name=<major.minor> fetch (substring filter: the
# ^<stop>. prefix anchor weeds out the cross matches like 8.17.8 vs 17.8);
# the module's official tag pattern is the final cross-check.
_upgrade_hop_latest_patch() { # $1=repo $2=pattern $3=stop(major.minor)
  local repo="$1" pat="$2" stop="$3" anchor cand
  anchor="^${stop//./\.}\.[0-9]"
  # dockerhub_tags_fetch: direct → local → ranked pool (spec §Docker source
  # selector); the full tag list + the stop-anchored pattern below subsume the
  # old ?name=<stop> substring filter (the ^<stop>. prefix weeds out the cross
  # matches like 8.17.8 vs 17.8).
  cand="$(dockerhub_tags_fetch "${repo}" | upgrade_pick_tag "${anchor}" || true)"
  if [ -n "${cand}" ] && [ -n "${pat}" ] && ! printf '%s' "${cand}" | grep -qE "${pat}"; then
    cand=""
  fi
  printf '%s' "${cand}"
}

# Multi-hop upgrade execution (gitlab-style required upgrade stops).
# $1=module $2=cur_ver $3=envf $4=svc $5=images $6=pattern $7=repo $8=src
# $9...=hop versions (intermediate "major.minor" stops + the final full version).
# Each hop: resolve version → pull → backup .env → rewrite → svc start (health
# gate incl. readiness) → settle → mark_installed. Failure rolls back to the
# PREVIOUS hop's version (the .env backup taken at hop start holds it) → exit 20.
_upgrade_multi_hop() {
  local name="$1" cur_ver="$2" envf="$3" svc="$4" images="$5" pattern="$6" repo="$7" src="$8" no_backup="$9"
  shift 9
  local hop_list=("$@")
  local n_hops="${#hop_list[@]}" i=0 hop_spec hop_ver k first prefix tag bak ts img
  first="$(printf '%s' "${images}" | awk '{print $1}')"
  k="${first%%=*}"
  prefix="${first#*=}"

  # Recorded rollback point for the WHOLE path (the original pin). Per-hop backups
  # would be overwritten by later hops, and after a partial path the user needs to
  # be able to go back to where they started, not just one hop.
  local rp_ts rp_bak rp_snap="" db
  rp_ts="$(date +%Y%m%d%H%M%S)"
  rp_bak="${envf}.prepath.${rp_ts}.$$"
  cp "${envf}" "${rp_bak}"
  db="$(_upgrade_db_name "${name}")"
  if [ "${no_backup}" = 1 ]; then
    log "data snapshot skipped (--no-backup) — rollback restores the version pin only"
  elif [ -n "${db}" ]; then
    log "snapshotting the shared-base database '${db}' before the path …"
    rp_snap="$(_upgrade_db_snapshot "${name}" "${db}")"
    if [ -n "${rp_snap}" ]; then ok "  data snapshot: ${rp_snap}"; else warn "  snapshot failed — rollback restores the version pin only"; fi
  fi
  _upgrade_state_set "${name}" ts "${rp_ts}"
  _upgrade_state_set "${name}" from "${cur_ver}"
  _upgrade_state_set "${name}" to "${hop_list[$((n_hops - 1))]}"
  _upgrade_state_set "${name}" envbak "${rp_bak}"
  _upgrade_state_set "${name}" databak "${rp_snap}"
  _upgrade_state_set "${name}" status started
  _upgrade_log_append "${name}" "${cur_ver} → ${hop_list[$((n_hops - 1))]} path-started ($((n_hops - 1)) stops)${rp_snap:+ snapshot=${rp_snap}}"

  log "hop path: ${cur_ver} → ${hop_list[*]} ($((n_hops - 1)) required stop(s); omnibus boots 3-5 min each)"
  for hop_spec in "${hop_list[@]}"; do
    i=$((i + 1))
    # intermediate stops arrive as "major.minor" — resolve the latest patch; the
    # final hop is the user's/target full version.
    case "${hop_spec}" in
    *.*.*) hop_ver="${hop_spec}" ;;
    *)
      hop_ver="$(_upgrade_hop_latest_patch "${repo}" "${pattern}" "${hop_spec}")"
      [ -n "${hop_ver}" ] || die "cannot resolve the latest patch for required stop ${hop_spec} (dockerhub tags unreachable? retry, or hop manually: aibox upgrade ${name} --to ${hop_spec}.<latest-patch>-ce.0, then re-run)"
      ;;
    esac

    log ""
    log "hop ${i}/${n_hops}: ${hop_ver}"
    img="${prefix}${hop_ver}"
    if docker image inspect "${img}" >/dev/null 2>&1; then
      log "  image cached: ${img}"
    else
      log "  pulling ${img} …"
      if ! docker pull "${img}" >/dev/null 2>&1; then
        warn "  direct docker pull failed — continuing (mirror pool retries at svc start; health gate + rollback protect)"
      fi
    fi

    ts="$(date +%Y%m%d%H%M%S)"
    bak="${envf}.hop${i}.${ts}.$$"
    cp "${envf}" "${bak}"
    upgrade_env_rewrite "${envf}" "${k}=${img}"
    log "  ${cur_ver} → ${hop_ver} (backup: ${bak})"

    if ! AIBOX_MODULE="${name}" bash "${svc}" start; then
      # The version we are rolling back TO: read it from the hop backup (the
      # previous hop's resolved version, not its "major.minor" spec).
      local prev cur_pin
      prev="$(grep -m1 "^${k}=" "${bak}" 2>/dev/null | cut -d= -f2- || true)"
      prev="${prev#"${prefix}"}"
      [ -n "${prev}" ] || { prev="${cur_ver}"; [ "${i}" -gt 1 ] && prev="${hop_list[$((i - 2))]}"; }
      cur_pin="${hop_ver}"
      warn "hop ${i}/${n_hops} (${cur_pin}) failed the health gate"
      if _upgrade_rollback "${name}" "${svc}" "${envf}" "${bak}" "${prev}"; then
        _upgrade_state_set "${name}" status rolled-back
        _upgrade_state_set "${name}" live "$(_upgrade_live_version "${name}")"
        _upgrade_log_append "${name}" "hop ${i}/${n_hops} ${hop_ver} rolled-back to ${prev}"
        warn "resume the path when ready: aibox upgrade ${name}   (start-over rollback: aibox upgrade ${name} --rollback)"
        return 10
      fi
      _upgrade_state_set "${name}" status manual
      _upgrade_log_append "${name}" "hop ${i}/${n_hops} ${hop_ver} rollback-failed"
      warn "manual intervention needed — the rollback to ${prev} did not come up either"
      log "  inspect : aibox ${name} logs"
      log "  pin     : ${envf} (hop backup: ${bak}; path backup: ${rp_bak})"
      [ -n "${rp_snap}" ] && [ -n "${db}" ] && _upgrade_db_restore_hint "${rp_snap}" "${db}"
      return 20
    fi

    # Settle knob: extra wait between hops for background migrations on big
    # instances (readiness already gates the db-migration checks).
    if [ "${i}" -lt "${n_hops}" ] && [ "${AIBOX_UPGRADE_HOP_SETTLE:-0}" -gt 0 ] 2>/dev/null; then
      log "  settling ${AIBOX_UPGRADE_HOP_SETTLE}s (background migrations)…"
      sleep "${AIBOX_UPGRADE_HOP_SETTLE}"
    fi
    _upgrade_log_append "${name}" "hop ${i}/${n_hops} ${hop_ver} ok"
    ok "  hop ${i}/${n_hops} healthy at ${hop_ver}"
    cur_ver="${hop_ver}"
  done
  _upgrade_state_set "${name}" live "$(_upgrade_live_version "${name}")"
  _upgrade_state_set "${name}" status ok
  _upgrade_log_append "${name}" "path complete at ${hop_ver}"
  ok "${name} upgraded to ${hop_ver} through $((n_hops - 1)) required stop(s) — data volumes preserved"
  log "rollback point: aibox upgrade ${name} --rollback   (back to the path start)"
  log "reclaim the old images: docker image prune"
  return 0
}


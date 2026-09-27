# ---------- docker source selector: GHCR family (ghcr.io, pull-via-mirror + tag) ----------
# Migrated from tools/xiaozhi/lib.sh (spec §Docker source selector — one
# selector, per-family transport). ghcr.io is a DIFFERENT registry family
# than docker.io (the docker.io mirrors do NOT proxy it). Mechanism (the
# windmill WM_GHCR_MIRROR technique): mirrors transparently proxy IDENTICAL
# digests, so pull `<mirror>/<path>` then `docker tag` it as the official
# ghcr.io/<path> — compose keeps official refs and finds the images cached.
# Priority: ① ghcr.io direct (bounded — the default address; fast links
# finish with zero overhead, slow-but-alive links get cut harmlessly and fall
# through) ② the user mirror (AIBOX_GHCR_MIRROR) ③ the pool below in order.
# The WINNING mirror is STICKY: recorded in dockerpool.cache (GHCR family,
# TTL) — the next run skips the known-dead direct route and leads with the
# winner ("fastest first, failover to the next" in the big-image regime,
# where concurrent duplicate pulls through every mirror would multiply
# traffic); all-fail invalidates (self-heal).
# Knobs: AIBOX_GHCR_POOL (mirror list override; "direct" = pool disabled),
# AIBOX_GHCR_MIRROR (your mirror, tried first), AIBOX_GHCR_DIRECT_TIMEOUT
# (120), AIBOX_GHCR_PULL_TIMEOUT (1800), AIBOX_DOCKER_POLL (watchdog
# interval), AIBOX_DOCKER_POOL_TTL (sticky-record TTL).
# Live-verified DIRECT 2026-09-23: ghcr.nju.edu.cn (NJU — the only mirror
# serving arbitrary ghcr repos: 140 tags + a real 5s pull of the xiaozhi web
# image), ghcr.1ms.run (fast 0.26s but LAZY — popular repos only, e.g. 0 tags
# for the xiaozhi repo → second). ghcr.dockerproxy.net swung dead the same
# day → documented example, NOT default. ghcr.m.daocloud.io 401s the
# anonymous v2 API (sync-allowlist registry).
GHCR_POOL_MIRRORS="ghcr.nju.edu.cn ghcr.1ms.run"

# Mirror-prefixed ref for a ghcr.io image (empty for non-ghcr refs).
_ghcr_mirror_ref() { # $1=mirror-host $2=image-ref
  case "${2}" in
  ghcr.io/*) printf '%s/%s' "${1}" "${2#ghcr.io/}" ;;
  *) printf '%s' "" ;;
  esac
}

# Pre-pull uncached ghcr.io images through the mirror pool.
ghcr_pool_prepull() { # $@ = image refs
  case "${AIBOX_GHCR_POOL:-}" in
  direct | none | off) return 0 ;;
  esac
  local img uncached="" cached order=""
  # 1. filter: cached images + non-ghcr refs
  for img in "$@"; do
    docker image inspect "${img}" >/dev/null 2>&1 && continue
    case "${img}" in
    ghcr.io/*) uncached="${uncached}${uncached:+ }${img}" ;;
    esac
  done
  [ -n "${uncached}" ] || return 0
  # 2. sticky-winner record: a mirror order means the direct route is known
  #    dead within the TTL → skip its timeout tax and lead with the winner;
 #    a "direct" record (or no record) keeps the honest direct-first flow.
  cached="$(_dkcache_read GHCR)"
  if [ -n "${cached}" ] && [ "${cached%% *}" != "direct" ]; then
    order="${cached}"
    log "ghcr: using the cached mirror ranking (TTL-bound): ${order}"
  fi
  # 3. per image: direct (bounded) when the order is unknown, else the mirrors
  # shellcheck disable=SC2086
  for img in ${uncached}; do
    if [ -z "${order}" ]; then
      if _dk_bounded "${AIBOX_GHCR_DIRECT_TIMEOUT:-120}" pull "${img}"; then
        ok "pulled ${img} (direct)"
        _dkcache_write GHCR "direct"
        continue
      fi
      warn "ghcr: direct route slow/unusable for ${img} — engaging the mirror pool"
    fi
    if _ghcr_mirror_pull "${img}" "${order}"; then
      # lead with the proven winner for the remaining images of this run
      order="$(_dkcache_read GHCR)"
    else
      warn "ghcr: mirror pool could not pull ${img} — compose will try direct"
    fi
  done
}

# Pull ONE image via the ordered mirror list, per-source failover + retag;
# records the sticky winner (promoted to the front) on success, invalidates
# on total failure.
_ghcr_mirror_pull() { # $1 = official ghcr.io ref, $2 = order override ("" = default list)
  local img="$1" m mirrors full done1 won others
  if [ -n "${2}" ]; then
    mirrors="${2}"
  else
    mirrors="${AIBOX_GHCR_MIRROR:-}"
    mirrors="${mirrors}${mirrors:+ }${AIBOX_GHCR_POOL:-${GHCR_POOL_MIRRORS}}"
  fi
  done1=0
  won=""
  # shellcheck disable=SC2086
  for m in ${mirrors}; do
    full="$(_ghcr_mirror_ref "${m}" "${img}")"
    [ -n "${full}" ] || continue
    log "docker pull ${full} (mirror ${m}, watchdog ${AIBOX_GHCR_PULL_TIMEOUT:-1800}s)"
    if _dk_bounded "${AIBOX_GHCR_PULL_TIMEOUT:-1800}" pull "${full}"; then
      docker tag "${full}" "${img}" || {
        warn "docker tag failed: ${full} → ${img}"
        continue
      }
      docker rmi "${full}" >/dev/null 2>&1 || true
      ok "pulled ${img} via ${m}"
      done1=1
      won="${m}"
      break
    fi
    warn "ghcr: mirror ${m} failed for ${img} — trying the next"
  done
  if [ "${done1}" = "1" ]; then
    # sticky winner: promote it to the front of the full candidate list
    others="$(printf '%s\n' ${mirrors} | grep -vxF "${won}" | tr '\n' ' ' || true)"
    _dkcache_write GHCR "${won}${others:+ ${others}}"
  else
    # self-heal: a dead order is not trusted for the next round (direct retried)
    _dkcache_write GHCR ""
  fi
  [ "${done1}" = "1" ]
}

# Unified pre-pull entry: routes each image to its registry family's pool
# (ghcr → ghcr pool; docker.io → docker.io pool; other registries → direct).
images_pool_prepull() { # $@ = image refs
  local imgs_all="$*"
  # shellcheck disable=SC2086
  ghcr_pool_prepull ${imgs_all} || true
  # shellcheck disable=SC2086
  docker_pool_prepull ${imgs_all} || true
}


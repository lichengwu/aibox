# ---------- docker hub tag resolution (the TAGS family) ----------
# Shared: both the manager (component upgrades, dashboards) and module hooks
# (upgrade stanzas) resolve a repo's tag list through the same direct →
# local-mirror → pool order the image pulls use, with the sticky winner cached
# in $AIBOX_HOME/dockerpool.cache.
DK_TAGS_POOL_DEFAULT="docker.1ms.run hub.rat.dev docker.1panel.live hub.1panel.dev proxy.vvvv.ee docker.m.daocloud.io hub3.nat.tf hub4.nat.tf docker.367231.xyz docker.apiba.cn"

dockerhub_tags_fetch() { # $1=repo (e.g. gitlab/gitlab-ce) → tag names, one per line
  local repo="$1" cached order m tags seen_direct=0 pool
  local tmo="${AIBOX_DOCKER_TAGS_TIMEOUT:-8}"
  pool=""
  case "${AIBOX_DOCKER_POOL:-}" in
  direct | none | off) ;;
  *) pool="${AIBOX_DOCKER_POOL:-${DK_TAGS_POOL_DEFAULT}}" ;;
  esac
  # 1. walk the cached order (failover; demote a dead official route)
  cached="$(_dkcache_read TAGS)"
  if [ -n "${cached}" ]; then
    for m in ${cached}; do
      if [ "${m}" = "direct" ]; then
        seen_direct=1
        if tags="$(_dk_tags_direct "${repo}")"; then
          _dkcache_write TAGS "direct"
          printf '%s\n' "${tags}"
          return 0
        fi
        continue
      fi
      if tags="$(_dk_tags_mirror "${m}" "${repo}")"; then
        # death-cache: an official route that failed in front of the winner is
        # dropped from the order until the TTL re-probes it
        if [ "${seen_direct}" = "1" ]; then
          _dkcache_write TAGS "$(printf '%s\n' ${cached} | awk -v m="${m}" '$0==m {f=1; print; next} f {print}' | tr '\n' ' ')"
        fi
        printf '%s\n' "${tags}"
        return 0
      fi
    done
    _dkcache_write TAGS ""   # everything failed → self-heal: re-resolve now
  fi
  # 2. ① the default address (hub.docker.com direct)
  if tags="$(_dk_tags_direct "${repo}")"; then
    _dkcache_write TAGS "direct"
    printf '%s\n' "${tags}"
    return 0
  fi
  # 3. ② local addresses: the user knob + the daemon's registry-mirrors
  local locals=""
  [ -n "${AIBOX_DOCKER_MIRROR:-}" ] && locals="${AIBOX_DOCKER_MIRROR}"
  locals="${locals}${locals:+ }$(_dk_tags_local_mirrors)"
  # shellcheck disable=SC2086
  for m in ${locals}; do
    if tags="$(_dk_tags_mirror "${m}" "${repo}")"; then
      _dkcache_write TAGS "${m}"
      printf '%s\n' "${tags}"
      return 0
    fi
  done
  # 4. ③ the acceleration pool: concurrent race on the ACTUAL repo (the same
  #    t bounds each candidate), rank by measured response time
  [ -n "${pool}" ] || return 1
  local tmpd pid pids="" i=0
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/dktags.XXXXXX")" || return 1
  # shellcheck disable=SC2086
  for m in ${pool}; do
    i=$(( i + 1 ))
    (
      t="$(curl -fsSL --max-time "${tmo}" -o /dev/null -w '%{time_total}' \
        "https://${m}/v2/${repo}/tags/list" 2>/dev/null)" || exit 0
      printf '%s %s\n' "${t}" "${m}" >"${tmpd}/r${i}.res"
    ) &
    pids="${pids} $!"
  done
  # shellcheck disable=SC2086
  for pid in ${pids}; do wait "${pid}" 2>/dev/null || true; done
  order="$(cat "${tmpd}"/r*.res 2>/dev/null | sort -n | awk '{print $2}' | tr '\n' ' ' || true)"
  rm -rf "${tmpd}" 2>/dev/null || true
  [ -n "${order}" ] || return 1
  _dkcache_write TAGS "${order}"
  # the winner serves this fetch (one bounded re-fetch — simpler than wiring
  # the race bodies through; ~0.3s on the measured mirrors)
  if tags="$(_dk_tags_mirror "${order%% *}" "${repo}")"; then
    printf '%s\n' "${tags}"
    return 0
  fi
  return 1
}

_dk_tags_direct() { # $1=repo → tags on stdout; rc 1 when dead/empty
  local body
  body="$(curl -fsSL --max-time "${AIBOX_DOCKER_TAGS_TIMEOUT:-8}" \
    "https://hub.docker.com/v2/repositories/${1}/tags?page_size=100&ordering=last_updated" 2>/dev/null)" || return 1
  printf '%s' "${body}" | grep -oE '"name": *"[^"]+"' | cut -d'"' -f4 | grep -v '^$' || return 1
}

_dk_tags_mirror() { # $1=mirror-host $2=repo → tags on stdout; rc 1 when dead/empty
  local body
  body="$(curl -fsSL --max-time "${AIBOX_DOCKER_TAGS_TIMEOUT:-8}" \
    "https://${1}/v2/${2}/tags/list" 2>/dev/null)" || return 1
  printf '%s' "${body}" | sed -e 's/.*"tags": *\[//' -e 's/\].*//' \
    | tr ',' '\n' | tr -d ' "[]' | grep -v '^$' || return 1
}

_dk_tags_local_mirrors() {
  local out
  command -v docker >/dev/null 2>&1 || return 0
  out="$(docker info --format '{{.RegistryConfig.Mirrors}}' 2>/dev/null || true)"
  printf '%s\n' "${out}" | tr ' ' '\n' | tr -d '[]' \
    | sed -E 's#^https?://##; s#/$##' | grep -v '^$' || true
}

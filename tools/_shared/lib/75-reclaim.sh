# ---------- safe reclamation (the `aibox autoclean` engine) ----------
# What may be reclaimed automatically is defined by TWO proofs:
#   1. OWNERSHIP — aibox can prove the object is ours (a module's residue
#      declaration now, or the residue.conf captured at install time);
#   2. NON-REFERENCE — nothing needs it: no container (running OR stopped)
#      references it, no module pins it, no upgrade/rollback point needs it.
# Anything failing either proof is left alone (foreign volumes, data of an
# installed module, images required for a rollback). These helpers only LIST
# what passed both proofs; the apply helpers receive that list verbatim.

# docker system df summary line ("" when the daemon is unreachable)
reclaim_df_summary() {
  command -v docker >/dev/null 2>&1 || return 0
  docker system df --format '{{.Type}}={{.Size}}' 2>/dev/null | tr '\n' ' '
  return 0
}

# bytes → human (1.2G)
reclaim_human_size() { # $1=bytes
  local b="${1:-0}"
  case "${b}" in '' | *[!0-9]*) printf '?'; return 0 ;; esac
  if [ "${b}" -ge 1073741824 ]; then
    awk -v b="${b}" 'BEGIN{printf "%.1fG", b/1073741824}'
  elif [ "${b}" -ge 1048576 ]; then
    awk -v b="${b}" 'BEGIN{printf "%.0fM", b/1048576}'
  elif [ "${b}" -ge 1024 ]; then
    awk -v b="${b}" 'BEGIN{printf "%.0fK", b/1024}'
  else
    printf '%sB' "${b}"
  fi
}

# image IDs that carry a tag (used to keep the NEWEST tags per repo)
_reclaim_tagged_ids() {
  docker image ls --format '{{.ID}}' 2>/dev/null | sort -u || true
}

# dangling (untagged, unreferenced) images → "<id> <size>"
reclaim_dangling_images() {
  command -v docker >/dev/null 2>&1 || return 0
  local id size
  for id in $(docker image ls --filter dangling=true -q 2>/dev/null | sort -u); do
    size="$(docker image inspect --format '{{.Size}}' "${id}" 2>/dev/null | head -1)"
    printf '%s %s\n' "${id}" "$(reclaim_human_size "${size}")"
  done
  return 0
}

# Build cache: nothing references it and no data lives there.
reclaim_build_cache() {
  command -v docker >/dev/null 2>&1 || return 0
  local n
  n="$(docker builder du 2>/dev/null | tail -1 | awk '{print $NF}')"
  [ -n "${n}" ] && printf '%s\n' "${n}"
  return 0
}
reclaim_apply_build_cache() {
  docker builder prune -f --filter until=24h >/dev/null 2>&1 || true
  return 0
}

# Image tags nothing needs: not used by any container (running or stopped), not a
# module's pin (.env/conf), not an upgrade/rollback point (upgrades/*.state,
# .env.bak.*). The newest <keep> tags per repository stay as a buffer.
reclaim_stale_tags() { # $1=keep per repo (default 2)
  command -v docker >/dev/null 2>&1 || return 0
  local keep="${1:-2}"
  local protected ref repo tag size
  protected=""
  # live/stopped containers
  protected="${protected} $(docker ps -a --format '{{.Image}}' 2>/dev/null | tr '\n' ' ')"
  # module pins + rollback knowledge
  local f pf
  for f in "$AIBOX_HOME"/apps/*/.env; do
    [ -f "${f}" ] || continue
    protected="${protected} $(grep -hE '^[A-Z_]*IMAGE=|^[A-Z_]*_IMAGE=|^[A-Z_]*_TAG=' "${f}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr '\n' ' ')"
  done
  if [ -d "${AIBOX_HOME}/upgrades" ]; then
    for f in "$AIBOX_HOME"/upgrades/*.state; do
      [ -f "${f}" ] || continue
      protected="${protected} $(grep -hE '^(from|to|live)=' "${f}" 2>/dev/null | cut -d= -f2- | tr '\n' ' ')"
    done
  fi
  for f in "$AIBOX_HOME"/apps/*/.env.bak.*; do
    [ -f "${f}" ] || continue
    protected="${protected} $(grep -hE '_IMAGE=|_TAG=' "${f}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr '\n' ' ')"
  done
  # newest `keep` tags per repo
  local keepers
  keepers="$(docker image ls --format '{{.Repository}}:{{.Tag}} {{.CreatedAt}}' 2>/dev/null |
    grep -v '<none>' | sort -k1,1 -k2,2r | awk -v k="${keep}" '{ if (!(seen[$1]++ < k)) next; print $1 }' || true)"
  # space-separated: the membership test below is a " ref " substring match, and a
  # newline between entries would make the trailing space never match (same family
  # as the profile-conflict bug: a separator mismatch makes a check a no-op)
  keepers="$(printf '%s' "${keepers}" | tr '\n' ' ')"
  while IFS= read -r ref; do
    [ -n "${ref}" ] || continue
    repo="${ref%%:*}"
    tag="${ref#*:}"
    case "${ref}" in *'<none>'*) continue ;; esac
    case " ${protected} " in *" ${ref} "*) continue ;; *" ${tag} "*) continue ;; esac
    # the newest `keep` per repo are the buffer — never listed
    case " ${keepers} " in *" ${ref} "*) continue ;; esac
    size="$(docker image inspect --format '{{.Size}}' "${ref}" 2>/dev/null | head -1)"
    printf '%s %s\n' "${ref}" "$(reclaim_human_size "${size}")"
  done <<TAGS
$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | sort -u)
TAGS
  return 0
}

# Volumes that are provably aibox's AND nobody's: attributable to a module whose
# residue we know (declaration or residue.conf), zero container references, and
# the owning module is NOT installed any more. A stopped-but-installed module's
# volumes are DATA and stay.
reclaim_orphan_volumes() {
  command -v docker >/dev/null 2>&1 || return 0
  local v owner size
  for v in $(docker volume ls -q 2>/dev/null | sort -u); do
    [ -n "${v}" ] || continue
    # referenced by any container (running or stopped)? → keep
    [ -n "$(docker ps -aq --filter "volume=${v}" 2>/dev/null)" ] && continue
    # attributable to an aibox module?
    owner=""
    local m
    for m in $(_reclaim_known_modules); do
      local vpat
      vpat="$(residue_volume_patterns "${m}")"
      [ -n "${vpat}" ] || continue
      if printf '%s' "${v}" | grep -qE "${vpat}"; then owner="${m}"; break; fi
    done
    [ -n "${owner}" ] || continue           # not ours → never touch
    # still installed → its data, keep
    local moddir="${AIBOX_MOD_DIR:-${AIBOX_HOME}/modules}"
    local instf="${AIBOX_INSTALLED:-${AIBOX_HOME}/installed.sh}"
    if [ -f "${moddir}/${owner}/module.yaml" ] ||
      { [ -f "${instf}" ] && grep -q "^AIBOX_INSTALLED_$(printf '%s' "${owner}" | tr '-' '_')" "${instf}" 2>/dev/null; }; then
      continue
    fi
    size="$(docker volume inspect --format '{{.Mountpoint}}' "${v}" 2>/dev/null | head -1)"
    printf '%s %s %s\n' "${v}" "$(reclaim_dir_bytes "${size}")" "${owner}"
  done
  return 0
}

_reclaim_known_modules() {
  { local moddir="${AIBOX_MOD_DIR:-${AIBOX_HOME}/modules}"
    for d in "${moddir}"/*/; do [ -f "${d}module.yaml" ] && basename "${d}"; done
    if [ -f "${AIBOX_HOME}/residue.conf" ]; then
      awk -F'_residue_' '/^[a-z0-9][a-z0-9-]*_residue_/ { print $1 }' "$AIBOX_HOME/residue.conf"
    fi
  } 2>/dev/null | grep -E '^[a-z0-9][a-z0-9-]*$' | sort -u
}

reclaim_dir_bytes() { # $1=path → human size of that subtree ("" → ?)
  local p="${1:-}"
  [ -n "${p}" ] && [ -d "${p}" ] || { printf '?'; return 0; }
  if command -v du >/dev/null 2>&1; then
    du -sk "${p}" 2>/dev/null | awk '{printf "%.0fM", $1/1024}'
  else
    printf '?'
  fi
}

# Stale .env backups (plain copies — never the live .env). Keeps the newest N per
# deploy root, which is exactly what the rollback machinery may still want.
reclaim_stale_env_backups() { # $1=keep (default 2)
  local keep="${1:-2}" root f
  for root in "$AIBOX_HOME"/apps/*/; do
    [ -d "${root}" ] || continue
    ls -1t "${root}".env.bak.* 2>/dev/null | tail -n "+$((keep + 1))" | while IFS= read -r f; do
      [ -f "${f}" ] || continue
      printf '%s %s\n' "${f}" "$(reclaim_human_size "$(wc -c <"${f}" 2>/dev/null | tr -d ' ')")"
    done
  done
  return 0
}

# ---- apply helpers (only ever called with a list that passed the proofs) ----
reclaim_apply_images() { # args: image refs/ids
  local r
  for r in "$@"; do
    [ -n "${r}" ] || continue
    docker image rm "${r}" >/dev/null 2>&1 || true
  done
  return 0
}
reclaim_apply_volumes() { # args: volume names
  local v
  for v in "$@"; do
    [ -n "${v}" ] || continue
    docker volume rm "${v}" >/dev/null 2>&1 || true
  done
  return 0
}
reclaim_apply_paths() { # args: file paths
  local p
  for p in "$@"; do
    [ -n "${p}" ] || continue
    rm -f "${p}" 2>/dev/null || true
  done
  return 0
}

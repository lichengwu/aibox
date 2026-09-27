# ---------- profiles (name → deterministic ports, registered + conflict-checked) ----------
# A "profile" is a second instance of a module family (base, pi-web, …). Ports are
# DERIVED from the name so the same name means the same ports on every machine —
# but derived is not the same as free: two names can hash into the same slot, and a
# profile's port may already be taken by something else. So every profile is
# REGISTERED in $AIBOX_HOME/ports.conf and checked against live listeners before a
# stack starts. (Derivation used to be copied in base/pi-web/CLIs; one copy now.)

profile_hash() { # $1=profile name → deterministic hash (stable across machines)
  local name="${1:-}" sum=0 i=0 ch
  while [ "${i}" -lt "${#name}" ]; do
    ch="${name:${i}:1}"
    sum=$(( sum + $(printf '%d' "'${ch}") * (i + 1) ))
    i=$(( i + 1 ))
  done
  printf '%d' "${sum}"
}

# Port families: fixed ranges keep a family's instances far apart, and the +hash
# offsets spread instances inside the range. The DEFAULT profile never uses these
# (it keeps the module's declared ports).
profile_port() { # $1=family (pg|redis|web) $2=hash → port
  local fam="${1:-}" h="${2:-0}"
  case "${fam}" in
  pg)    printf '%d' $(( 35100 + h % 332 )) ;;
  redis) printf '%d' $(( 36100 + h % 279 )) ;;
  web)   printf '%d' $(( 37100 + h % 100 )) ;;
  *) return 1 ;;
  esac
}

profile_ports_file() { printf '%s/ports.conf' "${AIBOX_HOME:-${HOME:+$HOME/.aibox}}"; }

# Register a profile's derived ports (idempotent; plain KEY=VALUE data).
profile_register() { # $1=profile name
  local name="${1:-}" h pf line pg rd wb tmp
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  pg="$(profile_port pg "${h}")"
  rd="$(profile_port redis "${h}")"
  wb="$(profile_port web "${h}")"
  pf="$(profile_ports_file)"
  mkdir -p "$(dirname "${pf}")"
  line="${name} pg=${pg} redis=${rd} web=${wb}"
  tmp="$(mktemp)"
  [ -f "${pf}" ] && grep -v "^${name} " "${pf}" >"${tmp}" 2>/dev/null || true
  printf '%s\n' "${line}" >>"${tmp}"
  sort -o "${tmp}" "${tmp}"
  mv "${tmp}" "${pf}"
  chmod 600 "${pf}" 2>/dev/null || true
  return 0
}

profile_owner() { # $1=port → the profile that registered it ("" when none)
  local port="${1:-}" pf name pg rd wb
  pf="$(profile_ports_file)"
  [ -n "${port}" ] && [ -f "${pf}" ] || return 0
  while read -r name pg rd wb; do
    case "${pg}" in "pg=${port}") printf '%s' "${name}"; return 0 ;; esac
    case "${rd}" in "redis=${port}") printf '%s' "${name}"; return 0 ;; esac
    case "${wb}" in "web=${port}") printf '%s' "${name}"; return 0 ;; esac
  done <"${pf}"
  return 0
}

# Which container publishes a host port ("" when docker is unavailable / nobody
# does). This is the authoritative answer for "is this port already taken, and by
# whose container" — the registry only knows about aibox profiles.
_port_owner_container() { # $1=port → aibox container publishing it ("" = unknown)
  command -v docker >/dev/null 2>&1 || return 0
  # TWO filters on purpose: `publish=` alone is unreliable across daemon versions
  # (measured on a CI runner: unrelated containers came back as the "owner" of
  # 35177), and only aibox-named containers can be a profile conflict anyway.
  # No daemon / empty answer → "" (callers fall back to the registry view).
  docker ps --filter "name=aibox-" --filter "publish=${1}" --format '{{.Names}}' 2>/dev/null |
    grep -v '^$' | head -1 || true
}

# Conflicts for a profile: a derived port is a conflict when it is LIVE and the
# listener is not one of OUR containers (passed by the caller), whether or not it
# belongs to a registered aibox profile. Live-caught: a fresh profile name whose
# slot is held by another tenant's container — docker reports only
# "Bind for 127.0.0.1:35177 failed: port is already allocated".
# Prints "<what> <port>" per conflict (empty = clean).
profile_conflicts() { # $1=profile name; rest = container names that belong to US
  local name="${1:-}" h pg rd wb p other mine owner
  shift 2>/dev/null || true
  mine=" $* "
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  pg="$(profile_port pg "${h}")"
  rd="$(profile_port redis "${h}")"
  wb="$(profile_port web "${h}")"
  for p in "${pg}" "${rd}" "${wb}"; do
    port_listening "${p}" || continue
    owner="$(_port_owner_container "${p}")"
    # only when we actually learned an owner: with owner="" the "is it ours"
    # pattern would degenerate to two spaces and swallow every port
    if [ -n "${owner}" ]; then
      case "${mine}" in *" ${owner} "*) continue ;; esac
    fi
    other="$(profile_owner "${p}")"
    if [ -n "${other}" ] && [ "${other}" != "${name}" ]; then
      printf '%s %s\n' "${other}" "${p}"
      continue
    fi
    if [ -n "${owner}" ]; then
      printf '%s %s\n' "${owner}" "${p}"
    fi
  done
  return 0
}

# Ensure the profile exists (conf file + registration) and refuse to start into a
# LIVE port owned by another profile (exit 4 = precheck failed, spec §Exit codes).
profile_ensure() { # $1=profile name $2=conf path; rest = our own container names
  local name="${1:-}" conf="${2:-}" h conflicts
  shift 2
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  if [ ! -f "${conf}" ]; then
    mkdir -p "$(dirname "${conf}")"
    cat >"${conf}" <<CONF
# aibox profile: ${name}
# Auto-generated deterministically from the profile name.
# Same name → same values on every machine. Edit to override.
PROFILE_NAME=${name}
PROFILE_HASH=${h}
CONF
    log "Created profile '${name}' (hash=${h})"
    _PROFILE_JUST_CREATED=1
  fi
  profile_register "${name}"
  # shellcheck disable=SC2046
  conflicts="$(profile_conflicts "${name}" "$@")"
  if [ -n "${conflicts}" ]; then
    warn "profile '${name}' would reuse ports already in use by another profile:"
    printf '%s\n' "${conflicts}" | while read -r other p; do
      warn "  ${p} is already published by '${other}' (pick another profile name, or stop that stack)"
    done
    die_code 4 "profile '${name}' cannot start: port collision on $(printf '%s' "${conflicts}" | head -1 | cut -d' ' -f2) (holder: $(printf '%s' "${conflicts}" | head -1 | cut -d' ' -f1))"
  fi
  return 0
}

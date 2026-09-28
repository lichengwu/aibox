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

# Port families: fixed ranges inside the aibox reserved band (spec §Port allocation —
# never Linux's ephemeral 32768-60999) keep a family's instances far apart, and the +hash
# offsets spread instances inside the range. The DEFAULT profile never uses these
# (it keeps the module's declared ports).
profile_port() { # $1=family (pg|redis|web) $2=hash → port
  local fam="${1:-}" h="${2:-0}"
  case "${fam}" in
  pg)    printf '%d' $(( 32100 + h % 332 )) ;;
  redis) printf '%d' $(( 32600 + h % 279 )) ;;
  web)   printf '%d' $(( 31150 + h % 100 )) ;;
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

# Conflicts for a profile: a derived port is a conflict when it is LIVE and NOT
# registered to this profile.
#
#   registry says another profile → conflict, that profile is named
#   registry says this profile    → fine (idempotent re-start of a running stack)
#   registry says nothing         → conflict with an "unknown" holder: the port is
#                                   held by something we cannot attribute, and the
#                                   stack could not bind anyway. This is the case
#                                   that used to surface as docker's raw
#                                   "Bind for 127.0.0.1:35177 failed: port is
#                                   already allocated" (a real deployment on the
#                                   same host holding the slot).
#
# Ownership comes from the registry + the live listener probe ONLY. It used to ask
# `docker ps --filter publish=<port>`, which returned UNRELATED containers as the
# owner on two different machines (CI runner, dev host) — a wrong "owner" is worse
# than no owner.
# Prints "<holder> <port>" per conflict ("" = clean).
profile_conflicts() { # $1=profile name
  local name="${1:-}" h pg rd wb p other
  [ -n "${name}" ] && [ "${name}" != "base" ] || return 0
  h="$(profile_hash "${name}")"
  pg="$(profile_port pg "${h}")"
  rd="$(profile_port redis "${h}")"
  wb="$(profile_port web "${h}")"
  for p in "${pg}" "${rd}" "${wb}"; do
    port_listening "${p}" || continue
    other="$(profile_owner "${p}")"
    [ "${other}" = "${name}" ] && continue
    printf '%s %s\n' "${other:-unknown}" "${p}"
  done
  return 0
}

# Ensure the profile exists (conf file + registration) and refuse to start into a
# LIVE port owned by another profile (exit 4 = precheck failed, spec §Exit codes).
profile_ensure() { # $1=profile name $2=conf path
  local name="${1:-}" conf="${2:-}" h conflicts
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
  # Check BEFORE registering: a squatted port must not look like "ours" just
  # because we are about to claim it. A re-start of an already-registered profile
  # still sees its own entry (owner == us) and stays clean.
  conflicts="$(profile_conflicts "${name}")"
  if [ -n "${conflicts}" ]; then
    warn "profile '${name}' cannot use its derived ports — they are already taken:"
    printf '%s\n' "${conflicts}" | while read -r other p; do
      if [ "${other}" = "unknown" ]; then
        warn "  ${p} is in use, but no aibox profile registered it (another service? pick another profile name)"
      else
        warn "  ${p} belongs to profile '${other}' (pick another profile name, or stop that stack)"
      fi
    done
    die_code 4 "profile '${name}' cannot start: port collision on $(printf '%s' "${conflicts}" | head -1 | cut -d' ' -f2) (holder: $(printf '%s' "${conflicts}" | head -1 | cut -d' ' -f1))"
  fi
  profile_register "${name}"
  return 0
}

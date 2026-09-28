# ---------- commands ----------

# Probe declared ports for external occupation (lsof/ss) at install time; warn if taken (env-overridable).
check_ports() {
  local name="$1" ports p port pid
  ports="$(module_field "$name" ports)"
  [ -n "$ports" ] || return 0
  command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || return 0
  for p in $ports; do
    port="${p%%/*}"
    port_listening "$port" || continue
    pid=""
    if command -v lsof >/dev/null 2>&1; then
      pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1)"
    else
      # ss -p PIDs need root; best-effort.
      pid="$(ss -Htlnp "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    fi
    warn "Port ${port} already in use${pid:+ (PID ${pid})}; overridable via env var"
    _phint="$(port_policy_hint "${port}")"
    [ -n "${_phint}" ] && warn "  and it is ${_phint} (prefer the aibox band: 31000-31999 services / 32000-32999 infra — spec §Port allocation)"
  done
}

# Recursively install MISSING service providers (module.yaml `services:`)
# BEFORE the target. The preflight services gate requires the provider to be
# installed; failing a user's `aibox install xiaozhi` with "fix: aibox install
# base" when the dependency is DECLARED and deterministic is pure friction
# (live-caught on a deploy host). Providers install with the same process
# state (PREFLIGHT_SKIP / AIBOX_PROFILE inherit); a failed provider aborts the
# target; cycles and self-references die cleanly. AIBOX_NO_AUTO_DEPS=1 restores
# the manual gate (preflight then reports the install hint as before).
_INSTALL_CHAIN=""   # ancestors currently being installed (cycle guard)
_install_ensure_deps() { # $1=module
  [ "${AIBOX_NO_AUTO_DEPS:-0}" = "1" ] && return 0
  local m="$1" svc prov saved depth=0
  load_registry
  for svc in $(module_field "${m}" services); do
    prov="${svc%%:*}"
    [ -n "${prov}" ] || continue
    [ "${prov}" = "${m}" ] && continue
    case " ${_INSTALL_CHAIN} " in
    *" ${prov} "*) die "dependency cycle: ${_INSTALL_CHAIN} ${m} -> ${prov} (fix the services: declarations)" ;;
    esac
    is_installed "${prov}" && continue
    saved="${_INSTALL_CHAIN}"
    _INSTALL_CHAIN="${_INSTALL_CHAIN}${_INSTALL_CHAIN:+ }${m}"
    depth=0
    for _c in ${_INSTALL_CHAIN}; do depth=$(( depth + 1 )); done
    [ "${depth}" -ge 10 ] && die "dependency chain too deep (>=10): ${_INSTALL_CHAIN} — cycle?"
    log "${m} requires '${svc}' — installing ${prov} first ..."
    if ! cmd_install "${prov}"; then
      _INSTALL_CHAIN="${saved}"
      die "dependency ${prov} failed to install — cannot continue with ${m}"
    fi
    _INSTALL_CHAIN="${saved}"
  done
}

cmd_install() {
  local name="" a
  for a in "$@"; do
    case "$a" in
      --skip-checks) PREFLIGHT_SKIP=1 ;;
      -h|--help) _verb_help install; exit 0 ;;
      *) [ -z "$name" ] && name="$a" ;;
    esac
  done
  [ -n "$name" ] || usage_die "Usage: aibox install <module> [--skip-checks]"
  # analyze + install declared service deps FIRST (recursive, cycle-guarded)
  _install_ensure_deps "$name"
  download_module "$name"
  local dest="$AIBOX_LAST_DEST"
  local plat; plat="$(module_field "$name" platform)"
  if [ -n "$plat" ] && [ "$plat" != "$(uname -s | tr '[:upper:]' '[:lower:]')" ]; then
    warn "Module $name targets platform ${plat}, current is $(uname -s) (may error)"
  fi
  local prc=0
  preflight_module "$name" || prc=$?
  if [ "${prc}" = "3" ]; then
    die_code 3 "Install aborted: a hard requirement is missing (fix the issues above; --skip-checks cannot bypass it)"
  elif [ "${prc}" != "0" ]; then
    die_code 4 "Install aborted: the environment check failed (fix the issues above, or re-run with --skip-checks)"
  fi
  check_ports "$name"
  local inst; inst="$(module_field "$name" install)"
  # Re-install is supported (hooks are idempotent) — say so, so identical
  # output doesn't read as a silent no-op or as a fresh install.
  if is_installed "$name"; then
    log "${name} is already installed ($(_installed_version "$name")) — re-deploying (hooks are idempotent)"
  fi
  log "Installing $name ..."
  if [ -n "$inst" ] && [ -f "$dest/$inst" ]; then
    # explicit status check: when cmd_install runs in a CONDITION context (the
    # dependency path: `if ! cmd_install <dep>`), set -e is suspended for the
    # whole body — a failing hook would otherwise be swallowed and the module
    # still marked installed (live-caught by the dep-failure test)
    if ! AIBOX_MODULE="$name" bash "$dest/$inst"; then
      die "install ${name} FAILED: the module's install hook did not complete (state: partially deployed — inspect the output above)"
    fi
  fi
  mark_installed "$name" "$(module_field "$name" version)"
  local svc_rc=0
  ensure_services "$name" || svc_rc=1
  log "Installed $name module $(module_field "$name" version) -> $dest"
  # Module scripts are in place, but a declared service dependency that didn't
  # start means the module CANNOT work yet — the old flow exited 0 with the
  # failure buried mid-scroll (live-caught: install new-api → "✓ installed",
  # then every action failed). Loud warning by default; opt-in strict mode for
  # scripts that must branch on it.
  if [ "$svc_rc" != "0" ]; then
    warn "⚠ ${name} is installed, but its service dependency is NOT running — the module can't work yet"
    warn "  fix: aibox base start   (then verify: aibox status ${name})"
    if [ "${AIBOX_STRICT_SERVICES:-0}" = "1" ]; then
      die "install ${name}: service dependency not ready (AIBOX_STRICT_SERVICES=1)"
    fi
  fi
}

# Handle a module's services deps (module.yaml services field):
#   base:postgres#<db> → ensure base is up + create database <db>
#   base:redis         → ensure base is up (no resource to create)
# The resource-less form used to be skipped entirely, so `install xiaozhi`
# (services: base:redis) never started its provider (live-caught).
# Modes: install (default — always ensures the resources) and --action, a quiet
# fast path when the shared base is already up (the install path created the
# resources; re-printing them on every `aibox <m> start` is pure noise).
# Best-effort: failures warn and set rc (the module's own action-time guard is
# authoritative and dies with a clear message).
ensure_services() { # $1=module [$2=--action]
  local name="$1" mode="${2:-}"
  # local cache metadata first: the action path does not load_registry (and must
  # not — it can be offline), while an installed module ALWAYS has module.yaml
  local services; services="$(_module_meta_local "${name}" services)"
  [ -n "$services" ] || services="$(module_field "$name" services 2>/dev/null || true)"
  [ -n "$services" ] || return 0
  local svc component resource rc=0 started=0
  for svc in $services; do
    case "$svc" in
      base:*) ;;
      *) continue ;;
    esac
    component="${svc#base:}"
    case "$component" in
    *'#'*) resource="${component#*#}"; component="${component%%#*}" ;;
    *)     resource="" ;;
    esac
    if ! is_installed base; then
      warn "Module ${name} depends on base:${component}, but base isn't installed (first: aibox install base)"
      rc=1
      continue
    fi
    # --action and the base is already up → nothing to do (quiet). NOTE: the
    # fast path now also requires the CONTRACT env file (profile-aware) — a live
    # network with a missing base.env used to leave consumers with empty values.
    if [ "${mode}" = "--action" ] && [ "${started}" = "0" ] && shared_base_up; then
      base_env_check || true
      continue
    fi
    if [ "${started}" = "0" ]; then
      info "Starting shared base (${name} needs it)…"
      AIBOX_MODULE=base bash "$AIBOX_MOD_DIR/base/svc.sh" start || { warn "base start failed (start manually: aibox base start)"; rc=1; continue; }
      started=1
      base_env_check || true
    fi
    [ -n "${resource}" ] || continue
    info "Creating ${component} resource '${resource}' (shared base)…"
    AIBOX_MODULE=base bash "$AIBOX_MOD_DIR/base/svc.sh" create "${component}" "${resource}" || { warn "base create ${component} ${resource} failed (create manually: aibox base create ${component} ${resource})"; rc=1; }
  done
  return "$rc"
}

# Cheap "is the shared base up?" probe for the action-time fast path: base.env
# exists AND its docker network is present (both are written by `base start`).
# No docker → not up, so the caller's ensure runs and fails LOUDLY instead of
# silently skipping.

# ---------- status (local-first; the default view needs NO network) ----------
# Installed state lives in installed.sh + the module caches under
# $AIBOX_MOD_DIR/<name>/ — both LOCAL. The registry (network) is only needed
# for --available (the catalog) and detail views of NOT-installed modules.
# Latest upstream versions ARE fetched, but asynchronously: probes launch
# BEFORE rendering, the local content renders instantly, and the updates
# section waits at most AIBOX_STATUS_UPDATE_TIMEOUT (8s) — a slow/dead network
# never blocks the status (the previous design died on load_registry).

# "module profile version" lines for every installed (module, profile) pair
# (installed.sh keys: AIBOX_INSTALLED_<mu>[__<profile>]="<version>").
_installed_pairs() {
  [ -f "$AIBOX_INSTALLED" ] || return 0
  sed -nE 's/^AIBOX_INSTALLED_([a-z0-9_]+)(__[A-Za-z0-9_]+)?="([^"]*)".*/\1\2 \3/p' "$AIBOX_INSTALLED" 2>/dev/null |
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      key="${entry%% *}"
      ver="${entry#* }"
      mu="${key%%__*}"
      prof="base"
      case "${key}" in *__*) prof="${key#*__}" ;; esac
      printf '%s %s %s\n' "$(printf '%s' "${mu}" | tr '_' '-')" "${prof}" "${ver}"
    done
}

# Local metadata reader: the per-module cache ships only hooks (module.yaml
# lives in the REGISTRY), so read the field from (1) the per-module cache
# when a module.yaml happens to ship there, else (2) the LOCAL registry cache
# file — a subshell source, zero network, graceful when absent/stale.
_module_meta_local() { # $1=module $2=field (scalar OR flat list like actions)
  local m="$1" field="$2" mu v
  mu="${1//-/_}"
  if [ -f "$AIBOX_MOD_DIR/$m/module.yaml" ]; then
    v="$(meta_field "$AIBOX_MOD_DIR/$m/module.yaml" "$field")"
    [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  fi
  v="$(cfg_kv_get "$AIBOX_REGISTRY_CACHE" "AIBOX_MODULE_${mu}_${field}")"
  printf '%s' "${v}"
}

# Version from LOCAL sources (cache yaml > registry cache > installed.sh).
_module_version_local() { # $1=module
  local v
  v="$(_module_meta_local "$1" version)"
  [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  # installed.sh recorded the version at install/update time
  v="$(grep "^$(_ikey "$1")=" "$AIBOX_INSTALLED" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')"
  printf '%s' "${v}"
}

# Resolve the LATEST upstream version for one module from its CACHE's
# upgrade: stanza (network; runs as a background probe). Empty = no stanza /
# unresolved. Uses gh_pool_fetch (the pooled fetcher) + the engine's own tag
# picker; the AUTHORITATIVE comparison stays `aibox upgrade <m> --check`.
_status_probe_latest() { # $1=module → prints the latest version
  local m="$1" mu src repo pattern out yaml_body
  mu="${1//-/_}"
  src="$(_module_meta_local "${m}" upgrade_source)"
  repo="$(_module_meta_local "${m}" upgrade_repo)"
  pattern="$(_module_meta_local "${m}" upgrade_tag_pattern)"
  if [ -z "${src}" ]; then
    # stanza missing from the LOCAL registry cache (stale/absent) → fetch the
    # live module.yaml (pooled; this runs in the background probe — never
    # blocks the status) and extract the flat stanza fields.
    yaml_body="$(gh_pool_fetch "${AIBOX_RAW%/}/tools/${m}/module.yaml" 2>/dev/null || true)"
    [ -n "${yaml_body}" ] || return 0
    src="$(printf '%s\n' "${yaml_body}" | awk '/^upgrade:/{inup=1;next} /^[^ ]/{inup=0} inup&&$1=="source:"{gsub(/"/,"");print $2;exit}')"
    repo="$(printf '%s\n' "${yaml_body}" | awk '/^upgrade:/{inup=1;next} /^[^ ]/{inup=0} inup&&$1=="repo:"{gsub(/"/,"");print $2;exit}')"
    pattern="$(printf '%s\n' "${yaml_body}" | awk '/^upgrade:/{inup=1;next} /^[^ ]/{inup=0} inup&&$1=="tag_pattern:"{sub(/^tag_pattern: *"?/,"");sub(/"$/ ,"");print;exit}')"
  fi
  [ -n "${src}" ] || return 0
  [ -n "${repo}" ] || return 0
  case "${src}" in
  github-release)
    out="$(upgrade_fetch "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | grep -m1 -oE '"tag_name": *"[^"]+"' | sed -e 's/.*"tag_name": *"//' -e 's/"$//' || true)" 
    ;;
  dockerhub-tags)
    out="$(dockerhub_tags_fresh "${repo}" | upgrade_pick_tag "${pattern}" || true)"
    ;;
  *) return 0 ;;
  esac
  out="${out#v}"
  [ -n "${out}" ] && printf '%s\n' "${out}"
}

# keyline template: the shared helpers (spec §Status template) are injected
# into this bundle by scripts/bundle.sh — same code, not a copy of
# tools/_shared/common.sh's dash_* helpers; keep in sync via the spec. The
# manager is the single-file CLI: it does NOT source the shared include, so it
# inlines the same formats (as it already does for the yaml parsers).
# Rule width: TTY → tput cols clamped [40,72]; non-TTY → 64. The [ -t 1 ]
# check runs in the function's own body — never inside $(…) (command
# substitution turns stdout into a pipe; the branch would be dead code —
# live-caught by review).

# Render ONE module block from LOCAL data (cache lib.sh status_info +
# cache module.yaml ports) — keyline template (spec §Status template).
# The app version (status_info version=, v-stripped, full string shown) is
# the cyan header segment; its FIRST token is written to $3 for the async
# updates comparison. Module version is the dim fallback when version= is
# absent (stale caches) — and the sunk module row always.
# $4 = profile: module-level state marking is default-profile only — a named
# profile's ports are DERIVED (base prod → 35177), so the declared-port probe
# would false-mark them stopped.
_status_block() { # $1=module $2=module-version $3=cur-upstream-outfile $4=profile
  local m="$1" mver="$2" cur_out="$3" prof="${4:-base}" info aver
  local mstate ports entry port h down="0" sym="" running="0"
  info=""
  [ -f "$AIBOX_MOD_DIR/$m/lib.sh" ] && \
    info="$(AIBOX_MODULE="$m" AIBOX_HOME="$AIBOX_HOME" bash -c ". '$AIBOX_MOD_DIR/$m/lib.sh' 2>/dev/null && type status_info >/dev/null 2>&1 && status_info 2>/dev/null || true" 2>/dev/null)"
  aver="$(printf '%s\n' "${info}" | sed -n 's/^version=//p' | head -1)"
  aver="${aver#v}"
  if [ -n "${cur_out}" ]; then
    printf '%s\n' "${aver%% *}" >"${cur_out}" 2>/dev/null || true
  fi
  # module state: the machine-readable state= contract (module's lib.sh probes
  # locally — pg_isready / http_up / docker health; local-first holds). ICON
  # ONLY on the header line (no state word — the endpoint row's merged health
  # carries the nuance):
  #   ok=✓ (green) · starting=⚠ (yellow) · stopped=○ (dim) · na=(none — CLI modules)
  # Fallback for stale caches without state=: declared-port listening heuristic
  # (default profile only — named profiles use derived ports, probe would false-mark).
  mstate="$(printf '%s\n' "${info}" | sed -n 's/^state=//p' | head -1)"
  ports="$(_module_meta_local "${m}" ports)"
  case "${mstate}" in
    ok)       sym="${C_GRN}✓${C_RST}" ;;
    starting) sym="${C_YEL}⚠${C_RST}" ;;
    stopped)  sym="${C_DIM}○${C_RST}"; down="1" ;;
    na)       sym="" ;;
    *)
      if [ -n "${ports}" ] && [ "${prof}" = "base" ]; then
        for entry in ${ports}; do
          port_listening "${entry%%/*}" && running="1"
        done
        if [ "${running}" = "1" ]; then
          sym="${C_GRN}✓${C_RST}"
        else
          sym="${C_DIM}○${C_RST}"; down="1"
        fi
      else
        sym="${C_GRN}✓${C_RST}"
      fi
      ;;
  esac
  # header: <icon> <bold name> <version> — app version cyan; module-version
  # dim fallback (a stale cache distinguishes itself by the color)
  printf '  %s%s%s%s' "${sym:+${sym} }" "${C_BOLD}" "${m}" "${C_RST}"
  if [ -n "${aver}" ]; then
    printf ' %s%s%s\n' "${C_CYA}" "${aver}" "${C_RST}"
  else
    printf ' %s%s%s\n' "${C_DIM}" "${mver}" "${C_RST}"
  fi
  # rows: endpoint (health merged / stopped hint), auth, log, other keys;
  # state= feeds the header icon, version= the header segment — never rows
  printf '%s\n' "${info}" | while IFS='=' read -r k v; do
    [ -n "${k}" ] || continue
    [ "${k}" = "state" ] && continue
    [ "${k}" = "version" ] && continue
    # health= is consumed by the endpoint merge — never a standalone row
    [ "${k}" = "health" ] && continue
    [ "${k}" = "credential" ] && k="auth"
    if [ "${k}" = "endpoint" ]; then
      h="$(printf '%s\n' "${info}" | sed -n 's/^health=//p' | head -1)"
      if [ "${down}" = "1" ]; then
        v="${v} ${C_DIM}(stopped — aibox ${m} start)${C_RST}"
      elif [ -n "${h}" ]; then
        v="${v} ${C_DIM}·${C_RST} ${h}"
      fi
    fi
    printf '     %s%-10s%s %s\n' "${C_DIM}" "${k}" "${C_RST}" "${v}"
  done
  # ports from LOCAL metadata (registry-cache subshell; zero network) + listen marks
  if [ -n "${ports}" ]; then
    local plist="" mark
    for entry in ${ports}; do
      port="${entry%%/*}"
      if port_listening "${port}"; then mark="${C_GRN}✓${C_RST}"; else mark="${C_DIM}—${C_RST}"; fi
      plist="${plist:+${plist}  }${entry} ${mark}"
    done
    printf '     %s%-10s%s %s\n' "${C_DIM}" "ports" "${C_RST}" "${plist}"
  fi
  printf '     %s%-10s %s · %s%s\n' "${C_DIM}" "module" "${mver}" "${AIBOX_MOD_DIR}/${m}/" "${C_RST}"
}

# The probe's process entry (invoked as `aibox __status-probe <module> <outfile>`):
# writes the latest version to <outfile> on success; removes it on failure.
_status_probe_cmd() {
  local m="$1" out="$2" v
  if v="$(_status_probe_latest "${m}" 2>/dev/null)" && [ -n "${v}" ]; then
    printf '%s\n' "${v}" >"${out}"
  else
    rm -f "${out}" 2>/dev/null || true
  fi
}

# `aibox status --json` — the machine-readable overview: everything the human
# view shows (installed modules with module/app version, state, endpoint, ports,
# upgrade state) as ONE JSON object on stdout. Local-first (no network), colors
# never leak (they are TTY-gated) and log lines stay on stderr.
_status_info_field() { # $1=module $2=key → the status_info contract field
  local m="$1" key="$2"
  [ -f "$AIBOX_MOD_DIR/$m/lib.sh" ] || return 0
  AIBOX_MODULE="$m" AIBOX_HOME="$AIBOX_HOME" bash -c "
    . '$AIBOX_MOD_DIR/$m/lib.sh' 2>/dev/null || exit 0
    type status_info >/dev/null 2>&1 || exit 0
    status_info 2>/dev/null
  " 2>/dev/null | sed -n "s/^${key}=//p" | head -1
}

cmd_status_json() {
  local pairs m prof ver aver state ep ports p st info_lines=0 first=1
  pairs="$(_installed_pairs)"
  printf '{\n'
  json_kv_str aibox_version "${AIBOX_VERSION}"; printf ',\n'
  json_kv_str profile "${AIBOX_PROFILE:-base}"; printf ',\n'
  printf '"modules": ['
  # note: plain `read` (default IFS) — the pairs are ONE line per module
  # ("name profile version"); `IFS= read` would swallow the whole line as the name
  while read -r m prof ver; do
    [ -n "${m}" ] || continue
    aver="$(_status_info_field "$m" version)"
    state="$(_status_info_field "$m" state)"
    ep="$(_status_info_field "$m" endpoint)"
    ports="$(_module_meta_local "$m" ports)"
    st="$(_upgrade_state_get "$m" status)"
    [ "${first}" = "1" ] || printf ','
    first=0
    printf '\n  {'
    json_kv_str name "$m"; printf ', '
    json_kv_str profile "${prof:-base}"; printf ', '
    json_kv_str module_version "${ver:-$(_module_version_local "$m")}"; printf ', '
    json_kv_str app_version "$aver"; printf ', '
    json_kv_str state "$state"; printf ', '
    json_kv_str endpoint "$ep"; printf ', '
    # shellcheck disable=SC2086
    json_arr ports ${ports}
    if [ -n "${st}" ]; then
      printf ', "upgrade": {'
      json_kv_str status "$st"; printf ', '
      json_kv_str from "$(_upgrade_state_get "$m" from)"; printf ', '
      json_kv_str to "$(_upgrade_state_get "$m" to)"
      printf '}'
    fi
    printf '}'
  done <<PAIRS
${pairs}
PAIRS
  [ "${first}" = "1" ] && printf ']' || printf '\n]'
  printf '\n}\n'
}

cmd_status_overview() {
  # ZERO-network default view: installed state (installed.sh) + module caches
  # are LOCAL; latest-version probes run ASYNC (bounded) so a dead network
  # never blocks the display. Default shows ONLY installed modules (grouped
  # by profile, one block each) + residue — with hundreds of modules the old
  # merged everything-and-the-catalog table stopped being readable.
  local pairs m prof ver p
  pairs="$(_installed_pairs)"

  # async probes: launch BEFORE rendering so the network overlaps the render.
  # Each probe is a SEPARATE PROCESS (bash $0 __status-probe …) — see the verb's
  # comment: the pool misbehaves inside nested background subshells.
  local tmpd pid pids="" waited timeout_s
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/dashupd.XXXXXX" 2>/dev/null)" || tmpd=""
  if [ -n "${tmpd}" ] && [ -n "${pairs}" ]; then
    while read -r m prof ver; do
      [ -n "${m}" ] || continue
      bash "${0}" __status-probe "${m}" "${tmpd}/${m}.latest" >/dev/null 2>&1 &
      pids="${pids} $!"
    done <<DASHPROBES
${pairs}
DASHPROBES
  fi

  printf '%s%saibox modules%s %s· %s%s\n' "${C_BOLD}" "${C_CYA}" "${C_RST}" "${C_DIM}" "$(date '+%Y-%m-%d %H:%M')" "${C_RST}"

  if [ -z "${pairs}" ]; then
    printf '\n'
    info "no modules installed (catalog: aibox status --available)"
    [ -n "${tmpd}" ] && rm -rf "${tmpd}"
    return 0
  fi

  # installed names (for residue filtering)
  local installed_names=""
  while read -r m prof ver; do
    case " ${installed_names} " in *" ${m} "*) ;; *) installed_names="${installed_names:+${installed_names} }${m}" ;; esac
  done <<DASHINST
${pairs}
DASHINST

  # per-PROFILE sections, one block per module (only installed; active marked)
  local dash_profiles=""
  while read -r m prof ver; do
    case " ${dash_profiles} " in *" ${prof} "*) ;; *) dash_profiles="${dash_profiles:+${dash_profiles} }${prof}" ;; esac
  done <<DASHPROFS
${pairs}
DASHPROFS
  for p in ${dash_profiles}; do
    local tag=""
    [ "${p}" = "${AIBOX_PROFILE:-base}" ] && tag=" (active)"
    status_secheader "profile ${p}${tag}"
    while read -r m prof ver; do
      [ "${prof}" = "${p}" ] || continue
      _status_block "${m}" "${ver}" "${tmpd}/${m}.cur"
      printf '\n'
    done <<DASHBLOCKS
${pairs}
DASHBLOCKS
  done

  # residue: NOT-installed modules with leftover artifacts (local scan)
  # reclamation overview: what `aibox autoclean` could free (docker system df)
  local _df; _df="$(reclaim_df_summary)"
  [ -n "${_df}" ] && printf '%s  %-10s %s%s\n' "${C_DIM}" "reclaim" "${_df}" "${C_RST}"
  PURGE_FINDINGS=""; PURGE_COUNT=0
  if command -v docker >/dev/null 2>&1; then
    local m2
    # derived list (cache dirs + installed + registry cache + residue.conf):
    # a new module shows up here without touching the manager
    for m2 in $(_purge_candidate_modules); do _purge_scan_module "${m2}" 2>/dev/null || true; done
    if [ "${PURGE_COUNT}" -gt 0 ]; then
      status_secheader "residue"
      printf '%s' "${PURGE_FINDINGS}" | awk -F'\t' -v inst=" ${installed_names} " '
        $1 != "" && index(inst, " " $1 " ") == 0 { cnt[$1]++ }
        END { for (s in cnt) printf "  · %s — %d item(s) · aibox autoclean %s\n", s, cnt[s], s }
      ' | sort
    fi
  fi

  # updates: bounded wait for the async probes, then the section (omitted
  # entirely when nothing resolved — no noise on offline/unchanged)
  if [ -n "${tmpd}" ] && [ -n "${pids}" ]; then
    timeout_s="${AIBOX_STATUS_UPDATE_TIMEOUT:-10}"
    waited=0
    while [ "${waited}" -lt "${timeout_s}" ]; do
      local alive=0
      for pid in ${pids}; do kill -0 "${pid}" 2>/dev/null && alive=1; done
      [ "${alive}" = "0" ] && break
      sleep 1
      waited=$((waited + 1))
    done
    for pid in ${pids}; do kill "${pid}" 2>/dev/null || true; done 2>/dev/null
    local upd_out="" f latest cur
    for f in "${tmpd}"/*.latest; do
      [ -f "${f}" ] || continue
      m="$(basename "${f}" .latest)"
      latest="$(cat "${f}" 2>/dev/null || true)"
      [ -n "${latest}" ] || continue
      cur=""
      [ -f "${tmpd}/${m}.cur" ] && cur="$(cat "${tmpd}/${m}.cur" 2>/dev/null || true)"
      if [ -n "${cur}" ] && [ "${cur}" = "${latest}" ]; then continue; fi
      if [ -n "${cur}" ]; then
        upd_out="${upd_out}  ${m}  ${cur} → ${latest}   (aibox upgrade ${m} --check)\n"
      else
        upd_out="${upd_out}  ${m}  latest: ${latest}   (aibox upgrade ${m} --check)\n"
      fi
    done
    if [ -n "${upd_out}" ]; then
      status_secheader "updates"
      printf '%b' "${upd_out}"
    fi
    rm -rf "${tmpd}"
  fi

  printf '\n'
  info "detail: aibox status <module>  ·  catalog: aibox status --available"
}

cmd_status_detail() {
  local name="$1" ver hint
  # local-first: installed (or cached) modules render WITHOUT the registry —
  # the version/hint come from the LOCAL cache module.yaml; only genuinely
  # unknown modules need the network (and die cleanly when it's down).
  if [ ! -f "${AIBOX_MOD_DIR}/$name/module.yaml" ] && ! _installed_any_profile "$name"; then
    load_registry
    module_exists "$name" || die_unknown_module "$name"
  fi
  ver="$(_module_version_local "$name")"
  [ -n "${ver}" ] || ver="$(module_field "$name" version)"
  if ! is_installed "$name"; then
    warn "$name is not installed"
    hint="$(module_field "$name" status_hint)"
    [ -n "${hint}" ] || hint="(registry offline; catalog: aibox status --available)"
    info "credentials: ${hint}"
    info "install: aibox install $name"
    return
  fi
  local info endpoint cred logf health state sym aver code ports entry port mark plist
  info="$(AIBOX_MODULE="$name" AIBOX_HOME="$AIBOX_HOME" bash -c ". '$AIBOX_MOD_DIR/$name/lib.sh' 2>/dev/null && status_info 2>/dev/null || true" 2>/dev/null)"
  aver="$(printf '%s\n' "$info" | sed -n 's/^version=//p' | head -1)"
  aver="${aver#v}"
  endpoint=$(printf '%s\n' "$info" | sed -n 's/^endpoint=//p')
  cred=$(printf '%s\n' "$info" | sed -n 's/^credential=//p')
  logf=$(printf '%s\n' "$info" | sed -n 's/^log=//p')
  health=$(printf '%s\n' "$info" | sed -n 's/^health=//p')
  state="$(printf '%s\n' "$info" | sed -n 's/^state=//p' | head -1)"
  # keyline header (spec §Status template): name + app version (dim
  # module-version fallback) + state word; then the rule
  sym=""
  case "${state}" in
  ok)       sym="${C_GRN}✓ ok${C_RST}" ;;
  starting) sym="${C_YEL}⚠ starting${C_RST}" ;;
  stopped)  sym="${C_DIM}○ stopped${C_RST}" ;;
  esac
  printf '%s%s%s' "$C_BOLD" "$name" "$C_RST"
  if [ -n "$aver" ]; then
    printf ' %s%s%s' "$C_CYA" "$aver" "$C_RST"
  else
    printf ' %s%s%s' "$C_DIM" "${ver:-?}" "$C_RST"
  fi
  [ -n "$sym" ] && printf ' %s·%s %s' "$C_DIM" "$C_RST" "$sym"
  printf '\n'
  status_rule
  # endpoint row: live HTTP probe verdict merged (same 3s curl the old view
  # ran — local-first holds); non-http endpoints use the module's health=
  if [ -n "$endpoint" ]; then
    local verdict=""
    case "$endpoint" in
    http://*|https://*)
      # 8s, not 3: a TLS endpoint costs a handshake plus (here) a rails request, and
      # a 3s budget reported a perfectly healthy https service as "unreachable"
      # (live-caught on a migrated GitLab).
      code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "$endpoint" 2>/dev/null) || code="000"
      [ -n "$code" ] || code="000"
      case "$code" in
      200|204|301|302|307|308|401) verdict=" ${C_DIM}·${C_RST} ${C_GRN}✓${C_RST} HTTP $code" ;;
      000) verdict=" ${C_DIM}(unreachable)${C_RST}" ;;
      *) verdict=" ${C_DIM}·${C_RST} HTTP $code" ;;
      esac ;;
    *) [ -n "$health" ] && verdict=" ${C_DIM}·${C_RST} $health" ;;
    esac
    printf '  %s%-10s%s %s%s\n' "$C_DIM" "endpoint" "$C_RST" "$endpoint" "$verdict"
  elif [ -n "$health" ]; then
    printf '  %s%-10s%s %s\n' "$C_DIM" "health" "$C_RST" "$health"
  fi
  [ -n "$cred" ] && printf '  %s%-10s%s %s\n' "$C_DIM" "auth" "$C_RST" "$cred"
  [ -n "$logf" ] && printf '  %s%-10s%s %s\n' "$C_DIM" "log" "$C_RST" "$logf"
  # ports from LOCAL metadata + listen marks
  plist=""
  ports="$(_module_meta_local "$name" ports)"
  if [ -n "$ports" ]; then
    for entry in ${ports}; do
      port="${entry%%/*}"
      if port_listening "${port}"; then mark="${C_GRN}✓${C_RST}"; else mark="${C_DIM}—${C_RST}"; fi
      plist="${plist:+${plist}  }${entry} ${mark}"
    done
    printf '  %s%-10s%s %s\n' "$C_DIM" "ports" "$C_RST" "$plist"
  fi
  # config keys: the settable knobs live in module.yaml env: — surfacing the count
  # answers "what can I tune here?" in the very view the docs point at
  local nkeys
  nkeys="$(_module_env_local "$name" 2>/dev/null | grep -c . || true)"
  if [ "${nkeys:-0}" -gt 0 ] 2>/dev/null; then
    printf '  %s%-10s%s %s\n' "$C_DIM" "config" "$C_RST" "${nkeys} key(s) · aibox ${name} config list"
  fi
  # upgrade state (local file, zero network): last transition + the rollback point
  local ust ufrom uto uts ulive
  ust="$(_upgrade_state_get "$name" status)"
  ufrom="$(_upgrade_state_get "$name" from)"
  uto="$(_upgrade_state_get "$name" to)"
  uts="$(_upgrade_state_get "$name" ts)"
  ulive="$(_upgrade_state_get "$name" live)"
  if [ -n "${ust}" ]; then
    printf '  %s%-10s%s %s\n' "$C_DIM" "upgrade" "$C_RST" "${ufrom:-?} → ${uto:-?} ${C_DIM}·${C_RST} ${ust}$( [ -n "${uts}" ] && printf ' %s(%s)%s' "$C_DIM" "${uts}" "$C_RST" )$( [ -n "${ulive}" ] && printf ' %s· live %s%s' "$C_DIM" "${ulive}" "$C_RST" )"
  elif grep -q '^upgrade:' "$AIBOX_MOD_DIR/$name/module.yaml" 2>/dev/null || [ -n "$(module_field "$name" upgrade_source 2>/dev/null || true)" ]; then
    printf '  %s%-10s%s %s\n' "$C_DIM" "upgrade" "$C_RST" "${C_DIM}no upgrade recorded · aibox upgrade ${name} --check${C_RST}"
  fi
  [ -n "${ufrom}" ] && printf '  %s%-10s%s %s\n' "$C_DIM" "rollback" "$C_RST" "${ufrom} ${C_DIM}· aibox upgrade ${name} --rollback${C_RST}"
  printf '  %s%-10s %s · %s%s\n' "$C_DIM" "module" "${ver:-?}" "$AIBOX_MOD_DIR/$name/" "$C_RST"
}

# Print a module dev guide (upstream links + DEVELOPMENT.md path), read from module.yaml upstream.
# Per-module help (local-first: installed state + the local registry cache —
# zero network for installed modules; unknown-module exploration may hit the
# registry). Bare `aibox <module>`, `help`, `-h`, `--help` all route here.
# Read one action's usage line from the per-module module.yaml (the `usage:`
# map stanza). Cache (installed modules) → in-process registry vars (load_registry
# already ran — file:// or remote) → registry cache file. Empty → bare action list.
# env: declaration for the help view — "KEY\tdefault\tdesc\tflags" lines.
# Cache module.yaml first (installed modules — offline); registry vars fallback
# (load_registry already ran when the cache is missing). Same local-first shape
# as _module_usage_local. NOTE: the manager is the single-file CLI — it does
# NOT source tools/_shared/common.sh, so this is the same parser inline.
_module_env_local() { # $1=module
  local f="$AIBOX_MOD_DIR/$1/module.yaml" mu var k v def rest flags desc
  if [ -f "$f" ]; then
    sed -n '/^env:/,/^[a-zA-Z]/p' "$f" | sed -n 's/^  \([A-Z_][A-Z0-9_]*\): *"\([^"]*\)".*/\1\t\2/p' 2>/dev/null | while IFS="$(printf '\t')" read -r k v; do
      def="${v%% —*}"; [ "${def}" = "${v}" ] && def="${v%%—*}"
      rest="${v#* —}"; [ "${rest}" = "${v}" ] && rest="${v}"
      flags=""; case "${v}" in *"["*"]"*) flags="$(printf '%s' "${v}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')" ;; esac
      desc="${rest%%\[*}"
      printf '%s\t%s\t%s\t%s\n' "${k}" "${def}" "$(printf '%s' "${desc}" | sed 's/^ *//; s/ *$//')" "${flags}"
    done
    return 0
  fi
  mu="${1//-/_}"
  for var in $(compgen -v 2>/dev/null | grep "^AIBOX_MODULE_${mu}_env_" || true); do
    k="${var#AIBOX_MODULE_${mu}_env_}"
    eval "v=\"\${${var}}\"" 2>/dev/null || v=""
    def="${v%% —*}"; [ "${def}" = "${v}" ] && def="${v%%—*}"
    rest="${v#* —}"; [ "${rest}" = "${v}" ] && rest="${v}"
    flags=""; case "${v}" in *"["*"]"*) flags="$(printf '%s' "${v}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')" ;; esac
    desc="${rest%%\[*}"
    printf '%s\t%s\t%s\t%s\n' "${k}" "${def}" "$(printf '%s' "${desc}" | sed 's/^ *//; s/ *$//')" "${flags}"
  done
  return 0
}

_module_usage_local() { # $1=module $2=action
  local f v mu act
  f="$AIBOX_MOD_DIR/$1/module.yaml"
  if [ -f "$f" ]; then
    v="$(meta_map_value "$f" usage "$2")"
    [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  fi
  mu="${1//-/_}"; act="${2//-/_}"
  v="$(eval "printf '%s' \"\${AIBOX_MODULE_${mu}_usage_${act}:-}\"" 2>/dev/null)"
  [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  v="$(cfg_kv_get "$AIBOX_REGISTRY_CACHE" "AIBOX_MODULE_${mu}_usage_${act}")"
  printf '%s' "${v}"
}

cmd_module_help() {
  local name="$1" ver desc acts ports docs act usage_line
  ver="$(_module_version_local "${name}")"
  desc="$(_module_meta_local "${name}" description)"
  acts="$(_module_meta_local "${name}" actions)"
  ports="$(_module_meta_local "${name}" ports)"
  docs="$(_module_meta_local "${name}" upstream_homepage)"
  if [ -z "${desc}" ] && [ -z "${acts}" ]; then
    # not in the local metadata → the registry (dies cleanly when unreachable);
    # also gives the authoritative "Unknown module" for typos.
    load_registry
    module_exists "${name}" || die_unknown_module "${name}"
    ver="$(module_field "${name}" version)"
    desc="$(module_field "${name}" description)"
    acts="$(module_field "${name}" actions)"
    ports="$(_module_meta_local "${name}" ports)"
    docs="$(module_field "${name}" upstream_homepage)"
  fi
  printf '%s%s%s %s· module %s%s\n' "$C_BOLD" "${name}" "$C_RST" "$C_DIM" "${ver:-\?}" "$C_RST"
  [ -n "${desc}" ] && printf '%s\n' "${desc}"
  echo
  info "usage:  aibox ${name} <action>"
  echo
  # Action table: one line per declared action, description from usage: stanza
  # (WARN-level gap in validator; falls back to bare list for un-covered actions)
  if [ -n "${acts}" ]; then
    for act in ${acts}; do
      usage_line="$(_module_usage_local "${name}" "${act}")"
      if [ -n "${usage_line}" ]; then
        printf '  %-24s %s\n' "${act}" "${usage_line}"
      else
        printf '  %-24s\n' "${act}"
      fi
    done
  fi
  # config keys: the env: declaration (spec §Configuration) — same local-first
  # source as the action table. Secrets are marked; `config` masks their values.
  local envdecl ek ed ef efl
  envdecl="$(_module_env_local "${name}")"
  if [ -n "${envdecl}" ]; then
    echo
    info "config:  aibox ${name} config [get|set|unset]"
    printf '  %-28s %-16s %s\n' "${C_DIM}KEY${C_RST}" "${C_DIM}default${C_RST}" "${C_DIM}description${C_RST}"
    printf '%s\n' "${envdecl}" | while IFS="$(printf '\t')" read -r ek ed ef efl; do
      [ -n "${ek}" ] || continue
      case " ${efl} " in *" knob "*) continue ;; esac
      [ -n "${efl}" ] && ef="${ef} [${efl}]"
      printf '  %-28s %-16s %s\n' "${ek}" "${ed}" "${ef}"
    done
  fi
  echo
  [ -n "${ports}" ] && info "ports:    ${ports}"
  [ -n "${docs}" ] && info "docs:     ${docs}"
  if is_installed "${name}"; then
    info "module:   $AIBOX_MOD_DIR/${name}/"
  else
    info "install:  aibox install ${name}"
  fi
}

# Action-level help: `aibox <module> <action> --help`. Renders the action's
# usage: line prominently — the args hint (leading <...>/[...] before " — ")
# becomes the usage tail, the rest is the description. Falls back to the
# module table when the action has no usage entry (or is unknown).
cmd_action_help() { # $1=module $2=action
  local name="$1" action="$2" line args desc ver
  line="$(_module_usage_local "${name}" "${action}")"
  if [ -z "${line}" ]; then
    # no usage entry → the module table already says everything (and catches
    # typos: an undeclared action shows the full action list)
    warn "no usage entry for '${action}' — the module table:"
    cmd_module_help "${name}"
    return 0
  fi
  ver="$(_module_version_local "${name}")"
  # split "<args> — description" (args hint optional)
  case "${line}" in
  *" — "*)
    args="${line%% — *}"
    desc="${line#* — }"
    ;;
  *)
    args=""
    desc="${line}"
    ;;
  esac
  printf '%s%s%s %s· module %s%s\n' "$C_BOLD" "${name} ${action}" "$C_RST" "$C_DIM" "${ver:-\?}" "$C_RST"
  echo
  info "usage:  aibox ${name} ${action}${args:+ ${args}}"
  echo
  printf '  %s\n' "${desc}"
  echo
  info "module:  aibox ${name} --help"
}

cmd_dev_guide() {
  local name="$1"
  load_registry
  module_exists "$name" || die_unknown_module "$name"
  printf '%s%s v%s%s\n' "$C_BOLD" "$name" "$(module_field "$name" version)" "$C_RST"
  info "homepage:   $(module_field "$name" upstream_homepage)"
  info "docs:       $(module_field "$name" upstream_docs)"
  info "install:    $(module_field "$name" upstream_install)"
  info "test:       $(module_field "$name" upstream_test)"
  info "dev guide:  tools/$name/docs/DEVELOPMENT.md"
}

# Dispatch a module action. NOTE: svc.sh is an "action entry point", NOT necessarily
# a daemon. pi-web uses it to manage a launchd/systemd service; openmaic passes actions
# through to the dispatched CLI; base implements `create postgres` here. The contract is "the file
# named by hooks.svc receives (action, args...)", nothing more. See docs/module-spec.md.
cmd_module_action() {
  [ $# -gt 0 ] && _iface_check "$1"
  local name="${1:-}"
  [ -n "$name" ] || usage_die "Usage: aibox <module> <action>  or  aibox help"
  shift
  local action="${1:-}" next
  # Per-module help: bare, help, -h, --help all route to it (aligned with the
  # top-level `aibox help`). Previously `aibox <module> --help` fell through to
  # the module's svc.sh which died with its unknown-action usage.
  case "${action}" in
  "" | help | -h | --help)
    cmd_module_help "${name}"
    return
    ;;
  esac
  # Action-level help: `aibox <module> <action> --help` (also -h) renders the
  # action's usage line prominently — args hint + description from the usage:
  # stanza, plus module context. Anything AFTER the action decides: a bare -h/
  # --help renders help; other args dispatch as before.
  next="${2:-}"
  case "${next}" in
  -h | --help)
    cmd_action_help "${name}" "${action}"
    return
    ;;
  esac
  shift
  # dev-guide special case: the main CLI reads module.yaml upstream, doesn't pass to svc.sh (works uninstalled).
  if [ "$action" = "dev-guide" ]; then
    cmd_dev_guide "$name"
    return
  fi
  if [ "${action}" = "dashboard" ]; then
    usage_die "the 'dashboard' action was merged into 'status' — run: aibox ${name} status"
  fi
  # status: module-OWNED rich view wins when the module declares a status action
  # (its svc.sh renders domain data — clash shows nodes+latency, base shows
  # databases, windmill forwards its own status...); otherwise the manager's
  # generic view (status_info + health). `status` was merged into `status`.
  if [ "${action}" = "status" ]; then
    local _acts=""
    _acts="$(_module_meta_local "${name}" actions)"
    [ -z "${_acts}" ] && _acts="$(module_field "${name}" actions 2>/dev/null || true)"
    case " ${_acts} " in
    *" status "*) ;; # module-owned: fall through to the svc.sh dispatch
    *)
      cmd_status_detail "${name}"
      return
      ;;
    esac
  fi
  is_installed "$name" || die "$name not installed (first: aibox install ${name})"
  # Reverse-dependency gate: base is a PROVIDER — stopping it breaks every
  # consumer (the consumer side checks the forward direction at start). Warn +
  # confirm; --yes skips (scripts).
  if [ "$name" = "base" ]; then
    case " ${action} " in
    *" stop "*)
      local _deps; _deps="$(_base_dependents)"
      if [ -n "${_deps}" ]; then
        warn "installed modules depend on the shared base: ${_deps}"
        warn "  they break until it is back — restart them afterwards: aibox <module> restart"
        case " $* " in *" --yes "* | *" -y "*) ;; *)
          ask_confirm "Continue with 'base ${action}' anyway?" || { warn "declined (non-interactive? add --yes)"; return 2; }
          ;;
        esac
      fi
      ;;
    esac
  fi
  # Bringing a module UP ensures its declared service deps first — live-caught:
  # `aibox xiaozhi start` died with "shared base not running — first: aibox base
  # start" (two commands for one intent). stop/logs/status never start anything.
  case " ${action} " in
  *" start "* | *" restart "*)
    ensure_services "${name}" --action || true
    _runtime_dep_guard "${name}"
    ;;
  esac
  local svc="$AIBOX_MOD_DIR/$name/svc.sh"
  [ -f "$svc" ] || die "Missing ${svc} (try aibox update ${name})"
  AIBOX_MODULE="$name" bash "$svc" "$action" "$@"
}


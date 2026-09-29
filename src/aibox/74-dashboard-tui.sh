# ---------- dashboard: view + interactive shell (P1–P4) ----------
# `aibox status` is the instantaneous snapshot (unchanged); `aibox dashboard` is the
# live monitor described in docs/design/dashboard-tui-design.md. The UI reads the
# snapshot file written by the sampler (72-dashboard-sample.sh) and NEVER runs docker
# or network calls itself — one blocked call in this loop would be felt immediately.
#
# Terminal handling is the risky part: the exact stty state is saved and restored by
# an idempotent signal trap, the alternate screen keeps the user's scrollback intact,
# and `kill -9` (untrappable) is documented to need `reset`.
#
# Test seams (documented knobs, used by tests/dashboard-*.bats):
#   AIBOX_DASH_SNAPSHOT  read this snapshot file instead of the newest one
#   AIBOX_DASH_KEYS      read keys from this file (one token per line) instead of a TTY
#   AIBOX_DASH_FRAMES    exit after N frames (0 = unlimited)
#   AIBOX_DASH_SIZE      terminal size override "COLxROW"
#   AIBOX_DASH_INTERVAL  refresh interval seconds (default 2)
#   AIBOX_NO_TUI=1       force the non-interactive path

_dash_panes="modules containers upgrades residue"

_dash_size() { # → "COLxROW" (override, then stty, then tput, then a sane default)
  local cols rows
  if [ -n "${AIBOX_DASH_SIZE:-}" ]; then
    printf '%s' "${AIBOX_DASH_SIZE}"
    return 0
  fi
  cols=""; rows=""
  if [ -t 0 ] || [ -t 1 ]; then
    cols="$(tput cols 2>/dev/null || true)"
    rows="$(tput lines 2>/dev/null || true)"
  fi
  case "${cols}" in '' | *[!0-9]*) cols="${COLUMNS:-}" ;; esac
  case "${rows}" in '' | *[!0-9]*) rows="${LINES:-}" ;; esac
  case "${cols}" in '' | *[!0-9]*) cols=100 ;; esac
  case "${rows}" in '' | *[!0-9]*) rows=30 ;; esac
  [ "${cols}" -ge 20 ] || cols=20
  [ "${rows}" -ge 6 ] || rows=6
  printf '%sx%s' "${cols}" "${rows}"
}

_dash_fit() { # $1=text $2=width → character-count truncation with an ellipsis
  local s="${1:-}" w="${2:-0}"
  [ "${w}" -le 0 ] && { printf ''; return 0; }
  printf "%.${w}s" "${s}"
}

_dash_pad() { # $1=text $2=width → left-aligned, space padded to width
  local s w n
  s="$(_dash_fit "${1:-}" "${2:-0}")"
  w="${2:-0}"
  n="${#s}"
  [ "${n}" -lt "${w}" ] || { printf '%s' "${s}"; return 0; }
  printf '%s%*s' "${s}" "$((w - n))" ''
}

_dash_snapshot_field() { # $1=file $2=key → value from the SNAPSHOT record
  local v
  v="$(sed -n 's/^SNAPSHOT //p' "${1}" 2>/dev/null | head -1)"
  _dash_kv_get "${v}" "${2}"
}

_dash_records() { # $1=file $2=record kind → the record bodies (kind token stripped)
  sed -n "s/^${2} //p" "${1}" 2>/dev/null || true
}

# Selected-row highlight (reverse video) when the terminal can show colors; empty
# pigment otherwise so the marker alone still reads.
C_REV=""
if [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ -n "${AIBOX_DASH_FORCE_COLOR:-}" ]; }; then C_REV=$'\033[7m'; fi

_dash_row_count() { # $1=file $2=pane $3=filter → rows the pane would render (pure bash)
  local file="$1" pane="$2" filter="$3" rec name n=0 kind=MODULE
  case "${pane}" in containers) kind=CONTAINER ;; esac
  while IFS= read -r rec; do
    [ -n "${rec}" ] || continue
    name="$(_dash_kv_get "${rec}" name)"
    case "${filter}" in '' | '-') ;; *) case "${name}" in *"${filter}"*) ;; *) continue ;; esac ;; esac
    n=$((n + 1))
  done <<DASHCNT
$(_dash_records "${file}" "${kind}")
DASHCNT
  printf '%s' "${n}"
}

_dash_state_seg() { # $1=state → colored one-glyph segment for the table
  case "${1:-}" in
  ok | running | healthy) printf '%s●%s' "${C_GRN}" "${C_RST}" ;;
  starting) printf '%s◐%s' "${C_YEL}" "${C_RST}" ;;
  stopped | down | failed) printf '%s✗%s' "${C_RED}" "${C_RST}" ;;
  na | '-') printf '%s○%s' "${C_DIM}" "${C_RST}" ;;
  *) printf '%s●%s' "${C_YEL}" "${C_RST}" ;;
  esac
}

# ---------- pane frames ----------

_dash_frame_modules() { # $1=file $2=width $3=filter $4=sortkey $5=sel
  local file="$1" w="$2" filter="$3" sortkey="$4" sel="$5"
  local rec name prof mver aver state health ep ports lit upgrade n=0 line
  local rows="" total=0 all=0
  while IFS= read -r rec; do
    [ -n "${rec}" ] || continue
    name="$(_dash_kv_get "${rec}" name)"
    all=$((all + 1))
    case "${filter}" in '' | '-') ;; *) case "${name}" in *"${filter}"*) ;; *) continue ;; esac ;; esac
    state="$(_dash_kv_get "${rec}" state)"
    health="$(_dash_kv_get "${rec}" health)"
    prof="$(_dash_kv_get "${rec}" profile)"
    mver="$(_dash_kv_get "${rec}" mver)"
    aver="$(_dash_kv_get "${rec}" aver)"
    ep="$(_dash_kv_get "${rec}" endpoint)"
    ports="$(_dash_kv_get "${rec}" ports)"
    lit="$(_dash_kv_get "${rec}" listening)"
    upgrade="$(_dash_kv_get "${rec}" upgrade)"
    case "${health}" in unhealthy | failed) state="drift" ;; esac
    [ "${upgrade}" = "-" ] && upgrade=""
    rows="${rows}$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "${name}" "${prof}" "${mver}" "${aver}" "${state}" "${ports}" "${ep}" "${upgrade}" "${lit}")
"
    total=$((total + 1))
  done <<DASHREC
$(_dash_records "${file}" MODULE)
DASHREC
  if [ "${total}" = "${all}" ]; then
    printf '%s%s%s %s· %s%d module(s)%s\n' "${C_BOLD}" "${C_CYA}" "MODULES" "${C_DIM}" "${C_RST}" "${total}" "${C_RST}"
  else
    printf '%s%s%s %s· %d of %d module(s) (filter: %s)%s\n' \
      "${C_BOLD}" "${C_CYA}" "MODULES" "${C_DIM}" "${total}" "${all}" "${filter}" "${C_RST}"
  fi
  printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}"
  # Narrow terminals: drop columns instead of truncating everything (design §6.5).
  local narrow=0 tiny=0
  if [ "${w}" -lt 80 ]; then narrow=1; fi
  if [ "${w}" -lt 40 ]; then tiny=1; fi
  local c_name c_profile c_mver c_app c_state c_ports c_ep c_up
  if [ "${tiny}" = 1 ]; then
    c_name=$((w * 60 / 100)); c_profile=0; c_mver=0; c_app=0; c_state=10; c_ports=0; c_ep=0; c_up=0
  elif [ "${narrow}" = 1 ]; then
    c_name=$((w * 30 / 100)); c_profile=0; c_mver=7; c_app=0; c_state=10; c_ports=18; c_ep=0; c_up=12
  else
    c_name=$((w * 14 / 100)); c_profile=8; c_mver=7; c_app=14; c_state=10
    c_ports=16; c_ep=$((w * 26 / 100)); c_up=12
  fi
  if [ "${tiny}" = 1 ]; then
    printf '%s%s%s\n' "${C_BOLD}" "$(printf '%s %s' "$(_dash_pad MODULE "${c_name}")" "$(_dash_pad STATE "${c_state}")")" "${C_RST}"
  elif [ "${narrow}" = 1 ]; then
    printf '%s%s%s\n' "${C_BOLD}" "$(printf '%s %s %s %s %s' "$(_dash_pad MODULE "${c_name}")" "$(_dash_pad MVER "${c_mver}")" \
      "$(_dash_pad STATE "${c_state}")" "$(_dash_pad PORTS "${c_ports}")" "$(_dash_pad UPGRADE "${c_up}")")" "${C_RST}"
  else
    printf '%s%s%s\n' "${C_BOLD}" "$(printf '%s %s %s %s %s %s %s %s' \
      "$(_dash_pad MODULE "${c_name}")" "$(_dash_pad PROFILE "${c_profile}")" "$(_dash_pad MVER "${c_mver}")" \
      "$(_dash_pad APP "${c_app}")" "$(_dash_pad STATE "${c_state}")" "$(_dash_pad PORTS "${c_ports}")" \
      "$(_dash_pad ENDPOINT "${c_ep}")" "$(_dash_pad UPGRADE "${c_up}")" | cut -c"1-${w}")" "${C_RST}"
  fi
  local i=0
  while IFS='	' read -r name prof mver aver state ports ep upgrade lit; do
    [ -n "${name}" ] || continue
    if [ "${tiny}" = 1 ]; then
      line="$(printf '%s %s' "$(_dash_pad "${name}" "${c_name}")" "$(_dash_pad "${state}" "${c_state}")")"
    elif [ "${narrow}" = 1 ]; then
      line="$(printf '%s %s %s %s %s' "$(_dash_pad "${name}" "${c_name}")" "$(_dash_pad "${mver}" "${c_mver}")" \
        "$(_dash_pad "${state}" "${c_state}")" "$(_dash_pad "${ports}" "${c_ports}")" "$(_dash_pad "${upgrade}" "${c_up}")")"
    else
      line="$(printf '%s %s %s %s %s %s %s %s' \
        "$(_dash_pad "${name}" "${c_name}")" "$(_dash_pad "${prof}" "${c_profile}")" \
        "$(_dash_pad "${mver}" "${c_mver}")" "$(_dash_pad "${aver}" "${c_app}")" \
        "$(_dash_pad "${state}" "${c_state}")" "$(_dash_pad "${ports}" "${c_ports}")" \
        "$(_dash_pad "${ep}" "${c_ep}")" "$(_dash_pad "${upgrade}" "${c_up}")")"
    fi
    if [ "${i}" = "${sel}" ]; then
      printf '%s▸%s %s%s%s%s\n' "${C_BOLD}" "${C_RST}" "$(_dash_state_seg "${state}")" "${C_REV}" "${line}" "${C_RST}"
    else
      printf '  %s %s\n' "$(_dash_state_seg "${state}")" "${line}"
    fi
    i=$((i + 1))
  done <<DASHROWS
${rows}
DASHROWS
  [ "${total}" -gt 0 ] || printf '%s(no modules match the filter)%s\n' "${C_DIM}" "${C_RST}"
}

_state_marker() { # $1=index $2=selected → "▸ " / "  "
  if [ "${1}" = "${2}" ]; then printf '%s▸%s' "${C_BOLD}" "${C_RST}"; else printf ' '; fi
}

_dash_frame_containers() { # $1=file $2=width $3=filter $4=sortkey $5=sel
  local file="$1" w="$2" filter="$3" sortkey="$4" sel="$5"
  local rec name image cpu mem up restarts health ports total=0
  local rows=""
  while IFS= read -r rec; do
    [ -n "${rec}" ] || continue
    name="$(_dash_kv_get "${rec}" name)"
    case "${filter}" in '' | '-') ;; *) case "${name}" in *"${filter}"*) ;; *) continue ;; esac ;; esac
    image="$(_dash_kv_get "${rec}" image)"
    cpu="$(_dash_kv_get "${rec}" cpu)"
    mem="$(_dash_kv_get "${rec}" mem)"
    up="$(_dash_kv_get "${rec}" uptime)"
    restarts="$(_dash_kv_get "${rec}" restarts)"
    health="$(_dash_kv_get "${rec}" health)"
    ports="$(_dash_kv_get "${rec}" ports)"
    rows="${rows}$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${name}" "${image}" "${cpu}" "${mem}" "${up}" "${restarts}" "${health}")
"
    total=$((total + 1))
  done <<DASHREC
$(_dash_records "${file}" CONTAINER)
DASHREC
  printf '%s%s%s %s· %s%d container(s)%s\n' "${C_BOLD}" "${C_CYA}" "CONTAINERS" "${C_DIM}" "${C_RST}" "${total}" "${C_RST}"
  printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}"
  printf '%s%s%s\n' "${C_BOLD}" "$(printf '%s %s %s %s %s %s %s' \
    "$(_dash_pad CONTAINER $((w * 26 / 100)))" "$(_dash_pad IMAGE $((w * 26 / 100)))" \
    "$(_dash_pad CPU% 7)" "$(_dash_pad MEM $((w * 16 / 100)))" "$(_dash_pad UPTIME 10)" \
    "$(_dash_pad RST 4)" "HEALTH" | cut -c"1-${w}")" "${C_RST}"
  local i=0
  while IFS='	' read -r name image cpu mem up restarts health; do
    [ -n "${name}" ] || continue
    line="$(printf '%s %s %s %s %s %s %s' \
      "$(_dash_pad "${name}" $((w * 26 / 100)))" "$(_dash_pad "${image}" $((w * 26 / 100)))" \
      "$(_dash_pad "${cpu}" 7)" "$(_dash_pad "${mem}" $((w * 16 / 100)))" \
      "$(_dash_pad "${up}" 10)" "$(_dash_pad "${restarts}" 4)" "${health}" | cut -c"1-${w}")"
    if [ "${i}" = "${sel}" ]; then
      printf '%s▸%s %s%s%s%s\n' "${C_BOLD}" "${C_RST}" "$(_dash_state_seg "${health}")" "${C_REV}" "${line}" "${C_RST}"
    else
      printf '  %s %s\n' "$(_dash_state_seg "${health}")" "${line}"
    fi
    i=$((i + 1))
  done <<DASHROWS
${rows}
DASHROWS
  [ "${total}" -gt 0 ] || printf '%s(no containers — docker unavailable or none running)%s\n' "${C_DIM}" "${C_RST}"
}

_dash_frame_upgrades() { # $1=file $2=width
  local file="$1" w="$2" rec name aver upgrade n=0
  printf '%s%s%s %s· cached latest-version probes (15 min)%s\n' "${C_BOLD}" "${C_CYA}" "UPGRADES" "${C_DIM}" "${C_RST}"
  printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}"
  printf '%s\n' "$(printf '%s %s %s %s' "$(_dash_pad MODULE $((w * 20 / 100)))" \
    "$(_dash_pad DEPLOYED 20)" "$(_dash_pad LATEST 20)" "NOTE" | cut -c"1-${w}")"
  while IFS= read -r rec; do
    [ -n "${rec}" ] || continue
    name="$(_dash_kv_get "${rec}" name)"
    aver="$(_dash_kv_get "${rec}" aver)"
    upgrade="$(_dash_kv_get "${rec}" upgrade)"
    [ "${upgrade}" = "-" ] && upgrade=""
    [ -n "${upgrade}" ] || continue
    n=$((n + 1))
    printf '%s %s %s %s\n' "$(_dash_pad "${name}" $((w * 20 / 100)))" \
      "$(_dash_pad "${aver}" 20)" "$(printf '%s%s%s' "${C_CYA}" "$(_dash_pad "${upgrade}" 20)" "${C_RST}")" \
      "apply: aibox upgrade ${name} --check"
  done <<DASHREC
$(_dash_records "${file}" MODULE)
DASHREC
  [ "${n}" -gt 0 ] || printf '%s(everything is up to date, or probes have not run yet)%s\n' "${C_DIM}" "${C_RST}"
}

_dash_frame_residue() { # $1=file $2=width
  local file="$1" w="$2" rec
  rec="$(_dash_records "${file}" RESIDUE | head -1)"
  printf '%s%s%s %s· READ-ONLY preview of what `aibox autoclean --apply` would free%s\n' \
    "${C_BOLD}" "${C_CYA}" "RESIDUE" "${C_DIM}" "${C_RST}"
  printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}"
  if [ -z "${rec}" ]; then
    printf '%s(no docker daemon — nothing to inspect)%s\n' "${C_DIM}" "${C_RST}"
    return 0
  fi
  printf '  dangling images : %s\n' "$(_dash_kv_get "${rec}" dangling)"
  printf '  build cache     : %s\n' "$(_dash_kv_get "${rec}" buildcache)"
  printf '  orphan volumes  : %s\n' "$(_dash_kv_get "${rec}" volumes)"
  printf '  stale tags      : %s\n' "$(_dash_kv_get "${rec}" staletags)"
  printf '  df summary      : %s\n' "$(_dash_kv_get "${rec}" total)"
  printf '\n  %sapply with an explicit command: aibox autoclean --apply%s\n' "${C_DIM}" "${C_RST}"
}

_dash_frame_help() { # $1=width
  local w="$1"
  cat <<DASHHELP
$(printf '%s%s%s' "${C_BOLD}" "Help — aibox dashboard" "${C_RST}")
$(printf '%s%s%s' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}")
  q / Esc        quit (restores the terminal)      Tab / Shift-Tab  switch pane
  r              resample now                      ↑ ↓ j k          move selection
  p / space      pause / resume                    g / G            first / last
  + / -          interval 1·2·5·10·30s             PgUp / PgDn      page
  /              filter (name/state)               d  (Enter)       module detail
  s              sort key                          a                about
$(printf '%s%s%s' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}")
  ${C_BOLD}READ-ONLY${C_RST}: the dashboard changes nothing. Writes stay explicit:
    aibox <module> start|stop|restart  ·  aibox autoclean --apply  ·  aibox upgrade <module>
  legend: ● ok   ◐ starting   ✗ down/drift   ○ n/a   ⬆ upgrade available
DASHHELP
}

_dash_frame_about() { # $1=file $2=width
  local file="$1" w="$2"
  printf '%s%s%s\n' "${C_BOLD}" "About — aibox dashboard" "${C_RST}"
  printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' $(seq 1 "${w}"))" "${C_RST}"
  printf '  aibox          : %s\n' "${AIBOX_VERSION}"
  printf '  home           : %s\n' "${AIBOX_HOME}"
  printf '  snapshot       : %s\n' "${file}"
  printf '  sampled        : ts=%s cost_ms=%s stale=%s docker=%s load=%s interval=%s\n' \
    "$(_dash_snapshot_field "${file}" ts)" "$(_dash_snapshot_field "${file}" cost_ms)" \
    "$(_dash_snapshot_field "${file}" stale)" "$(_dash_snapshot_field "${file}" docker)" \
    "$(_dash_snapshot_field "${file}" load)" "$(_dash_snapshot_field "${file}" interval)"
  printf '\n  samplers run as separate processes: %s\n' "aibox __dashboard-sample"
  printf '  the UI never calls docker or the network itself (see docs/design/dashboard-tui-design.md)\n'
}

_dash_status_line() { # $1=file $2=pane $3=interval $4=paused $5=filter $6=sortkey $7=frames
  local file="$1" pane="$2" interval="$3" paused="$4" filter="$5" sortkey="$6" frames="$7"
  local stale docker load age ts now
  stale="$(_dash_snapshot_field "${file}" stale)"
  docker="$(_dash_snapshot_field "${file}" docker)"
  load="$(_dash_snapshot_field "${file}" load)"
  # How old is the sample the frame is showing? (the AGE column was a stub — this is
  # the honest number, and it makes a stalled sampler visible at a glance.)
  age=""
  ts="$(_dash_snapshot_field "${file}" ts)"
  case "${ts}" in '' | *[!0-9]*) ts="" ;; esac
  if [ -n "${ts}" ]; then
    now="$(date +%s)"
    case "${now}" in '' | *[!0-9]*) now="${ts}" ;; esac
    local age_s=$((now - ts))
    [ "${age_s}" -ge 0 ] 2>/dev/null || age_s=0
    if [ "${age_s}" -lt 60 ]; then
      age="  age:${age_s}s"
    elif [ "${age_s}" -lt 3600 ]; then
      age="  age:$((age_s / 60))m"
    else
      age="  age:$((age_s / 3600))h"
    fi
  fi
  printf '%s  pane:%s  interval:%ss%s  filter:%s  sort:%s  load:%s  docker:%s%s%s' \
    "$(date '+%H:%M:%S')" "${pane}" "${interval}" \
    "$([ "${paused}" = 1 ] && printf ' PAUSED' || true)" "${filter}" "${sortkey}" \
    "${load}" "${docker}" "${age}" \
    "$([ "${stale}" = 1 ] && printf ' %s(stale — showing the last good sample)%s' "${C_YEL}" "${C_RST}" || true)"
}

_dash_keybar() {
  printf '%s Tab pane · ↑↓ select · d detail · / filter · s sort · p pause · +/- interval · r resample · ? help · q quit %s' \
    "${C_DIM}" "${C_RST}"
}

# ---------- one-shot rendering (P1: --once, --json, the degrade path) ----------

_dash_render_once() { # $1=file $2=pane $3=width $4=filter $5=sortkey
  local file="$1" pane="$2" w="$3" filter="$4" sortkey="$5"
  case "${pane}" in
  containers) _dash_frame_containers "${file}" "${w}" "${filter}" "${sortkey}" 0 ;;
  upgrades) _dash_frame_upgrades "${file}" "${w}" ;;
  residue) _dash_frame_residue "${file}" "${w}" ;;
  *) _dash_frame_modules "${file}" "${w}" "${filter}" "${sortkey}" 0 ;;
  esac
}

_dash_json() { # $1=file → snapshot as one JSON object (superset of status --json)
  local file="$1" rec first=1
  printf '{\n'
  printf '  %s,\n' "$(json_kv_str aibox_version "${AIBOX_VERSION}")"
  printf '  %s,\n' "$(json_kv_str profile "$(printf '%s' "${AIBOX_PROFILE:-default}")")"
  printf '  %s,\n' "$(json_kv_str snapshot "v1")"
  printf '  %s,\n' "$(json_kv_num ts "$(_dash_snapshot_field "${file}" ts)")"
  printf '  %s,\n' "$(json_kv_num cost_ms "$(_dash_snapshot_field "${file}" cost_ms)")"
  printf '  %s,\n' "$(json_kv_num stale "$(_dash_snapshot_field "${file}" stale)")"
  printf '  %s,\n' "$(json_kv_str docker "$(_dash_snapshot_field "${file}" docker)")"
  printf '  %s,\n' "$(json_kv_str load "$(_dash_snapshot_field "${file}" load)")"
  printf '  "modules": ['
  while IFS= read -r rec; do
    [ -n "${rec}" ] || continue
    [ "${first}" = 1 ] || printf ','
    first=0
    printf '\n    {%s, %s, %s, %s, %s, %s, %s, %s, %s, %s}' \
      "$(json_kv_str name "$(_dash_kv_get "${rec}" name)")" \
      "$(json_kv_str profile "$(_dash_kv_get "${rec}" profile)")" \
      "$(json_kv_str module_version "$(_dash_kv_get "${rec}" mver)")" \
      "$(json_kv_str app_version "$(_dash_kv_get "${rec}" aver)")" \
      "$(json_kv_str state "$(_dash_kv_get "${rec}" state)")" \
      "$(json_kv_str health "$(_dash_kv_get "${rec}" health)")" \
      "$(json_kv_str endpoint "$(_dash_kv_get "${rec}" endpoint)")" \
      "$(json_kv_str ports "$(_dash_kv_get "${rec}" ports)")" \
      "$(json_kv_str listening "$(_dash_kv_get "${rec}" listening)")" \
      "$(json_kv_str upgrade "$(_dash_kv_get "${rec}" upgrade)")"
  done <<DASHJM
$(_dash_records "${file}" MODULE)
DASHJM
  printf '\n  ],\n'
  first=1
  printf '  "containers": ['
  local rst
  while IFS= read -r rec; do
    [ -n "${rec}" ] || continue
    [ "${first}" = 1 ] || printf ','
    first=0
    rst="$(_dash_kv_get "${rec}" restarts)"
    case "${rst}" in '' | *[!0-9]*) rst=0 ;; esac
    printf '\n    {%s, %s, %s, %s, %s, %s, %s}' \
      "$(json_kv_str name "$(_dash_kv_get "${rec}" name)")" \
      "$(json_kv_str image "$(_dash_kv_get "${rec}" image)")" \
      "$(json_kv_str cpu "$(_dash_kv_get "${rec}" cpu)")" \
      "$(json_kv_str mem "$(_dash_kv_get "${rec}" mem)")" \
      "$(json_kv_str uptime "$(_dash_kv_get "${rec}" uptime)")" \
      "$(json_kv_num restarts "${rst}")" \
      "$(json_kv_str health "$(_dash_kv_get "${rec}" health)")"
  done <<DASHJC
$(_dash_records "${file}" CONTAINER)
DASHJC
  printf '\n  ],\n'
  rec="$(_dash_records "${file}" RESIDUE | head -1)"
  printf '  "residue": {%s, %s, %s, %s, %s}\n' \
    "$(json_kv_str dangling "$(_dash_kv_get "${rec}" dangling)")" \
    "$(json_kv_str buildcache "$(_dash_kv_get "${rec}" buildcache)")" \
    "$(json_kv_str volumes "$(_dash_kv_get "${rec}" volumes)")" \
    "$(json_kv_str stale_tags "$(_dash_kv_get "${rec}" staletags)")" \
    "$(json_kv_str df "$(_dash_kv_get "${rec}" total)")"
  printf '}\n'
}

# ---------- interactive shell (P2–P4) ----------

_dash_cleanup() {
  [ "${_DASH_CLEANED:-0}" = 1 ] && return 0
  _DASH_CLEANED=1
  if [ "${_DASH_TTY:-0}" = 1 ]; then
    [ -n "${SAVED_STTY:-}" ] && stty "${SAVED_STTY}" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
  fi
  [ -n "${SAMPLER_PID:-}" ] && kill "${SAMPLER_PID}" 2>/dev/null || true
  return 0
}

_dash_key_read() { # → one key token on stdout ("" when the source is exhausted)
  local k cc seq
  if [ -n "${AIBOX_DASH_KEYS:-}" ]; then
    [ -f "${AIBOX_DASH_KEYS}" ] || return 0
    k="$(head -1 "${AIBOX_DASH_KEYS}" 2>/dev/null || true)"
    if [ -n "${k}" ]; then
      tail -n +2 "${AIBOX_DASH_KEYS}" >"${AIBOX_DASH_KEYS}.next" 2>/dev/null || : >"${AIBOX_DASH_KEYS}.next"
      mv "${AIBOX_DASH_KEYS}.next" "${AIBOX_DASH_KEYS}" 2>/dev/null || true
    fi
    printf '%s' "${k}"
    return 0
  fi
  IFS= read -r -s -n 1 -t 1 k 2>/dev/null || k=""
  if [ "${k}" = "$(printf '\033')" ]; then
    # Nav keys arrive as ESC + a sequence, in EITHER form:
    #   CSI  \033[A   — what most terminals send in normal mode
    #   SS3  \033OA   — "application cursor keys" (DECCKM), which many terminals
    #                   switch to and which made Up/Down look DEAD (reported live)
    # plus numeric variants (\033[5~, \033[1;2A …). Read the tail until its final
    # byte, then map both spellings.
    local seq="" cc
    IFS= read -r -s -n 1 -t 1 cc 2>/dev/null || cc=""
    if [ -z "${cc}" ]; then
      printf 'ESC'
      return 0
    fi
    seq="${cc}"
    local last=""
    while [ "${#seq}" -lt 6 ]; do
      # Completeness rule: SS3 is exactly ESC O <letter>; CSI is ESC [ … <letter>|~,
      # where the tail may carry digits/';' (ESC[1;2A). Breaking on the FIRST letter
      # was the bug that kept SS3 arrows dead (caught by the parser regression test).
      case "${seq}" in
      'O'*) [ "${#seq}" -ge 2 ] && break ;;
      '['*)
        # CSI is complete at its final byte (a letter or '~'); digits and ';' mean more
        # is coming (ESC[5~, ESC[1;2A). `last` = the last character of seq.
        last="${seq%?}"
        last="${seq#"${last}"}"
        case "${last}" in
        [A-Za-z] | '~') break ;;
        *) : ;;
        esac
        ;;
      *) break ;;
      esac
      IFS= read -r -s -n 1 -t 1 cc 2>/dev/null || break
      [ -n "${cc}" ] || break
      seq="${seq}${cc}"
    done
    case "${seq}" in
    '[A' | 'OA') printf 'UP' ;;
    '[B' | 'OB') printf 'DOWN' ;;
    '[C' | 'OC') printf 'RIGHT' ;;
    '[D' | 'OD') printf 'LEFT' ;;
    '[H' | 'OH' | '[1~' | '[7~') printf 'HOME' ;;
    '[F' | 'OF' | '[4~' | '[8~') printf 'END' ;;
    '[Z') printf 'BTAB' ;;
    '[5~' | '[5') printf 'PGUP' ;;
    '[6~' | '[6') printf 'PGDN' ;;
    *'A') printf 'UP' ;;
    *'B') printf 'DOWN' ;;
    *) printf 'ESC' ;;
    esac
    return 0
  fi
  case "${k}" in
  '') printf 'TICK' ;;
  ' ') printf 'SPACE' ;;
  "$(printf '\t')") printf 'TAB' ;;
  # NOTE: bash 3.2 has no `read -N`, and `read -n 1` returns "" both on timeout and
  # when Enter is pressed (the newline is the delimiter) — so Enter is NOT
  # distinguishable in the TTY path (see docs/design/dashboard-tui-design.md). The
  # detail key is `d`; the injected key source (tests) may still send `ENTER`.
  *) printf '%s' "${k}" ;;
  esac
}

_dash_interval_cycle() { # $1=current → next in 1·2·5·10·30
  case "${1}" in
  1) printf '2' ;;
  2) printf '5' ;;
  5) printf '10' ;;
  10) printf '30' ;;
  *) printf '1' ;;
  esac
}

_dash_sort_cycle() { # $1=current → next key
  case "${1}" in
  name) printf 'state' ;;
  state) printf 'ports' ;;
  ports) printf 'upgrade' ;;
  *) printf 'name' ;;
  esac
}

cmd_dashboard() {
  local pane=modules once=0 as_json=0 interval="${AIBOX_DASH_INTERVAL:-2}"
  local filter="-" sortkey=name focus="" frames_max="${AIBOX_DASH_FRAMES:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help) _verb_help dashboard && return 0; return 2 ;;
    --once) once=1 ;;
    --json) as_json=1 ;;
    --pane) shift; pane="${1:-modules}" ;;
    --pane=*) pane="${1#--pane=}" ;;
    --interval) shift; interval="${1:-2}" ;;
    --interval=*) interval="${1#--interval=}" ;;
    --no-color) C_RST=""; C_DIM=""; C_BOLD=""; C_GRN=""; C_YEL=""; C_RED=""; C_CYA="" ;;
    -*) usage_die "unknown option: $1 (see: aibox dashboard --help)" ;;
    *) focus="$1" ;;
    esac
    shift
  done
  case "${interval}" in '' | *[!0-9]*) interval=2 ;; esac
  [ "${interval}" -ge 1 ] || interval=1
  [ -n "${focus}" ] && filter="${focus}"
  case " ${_dash_panes} " in *" ${pane} "*) ;; *) usage_die "unknown pane: ${pane} (modules|containers|upgrades|residue)" ;; esac

  local dir file size w h
  dir="$(_dash_dir)" || die "cannot determine the dashboard directory (AIBOX_HOME/HOME unset)"
  mkdir -p "${dir}" 2>/dev/null || true

  # A fresh sample for the non-interactive paths so --once/--json never show a stale
  # or missing snapshot. The interactive path instead spawns the long-lived sampler.
  # Decide up front: do we need a fresh sample, and are we in the non-interactive
  # (degraded) path? Written as explicit booleans: a nested `! { … && … }` inside the
  # condition mis-evaluated under bash 3.2 (measured: keys injected yet it still
  # degraded). Interactive needs BOTH a TTY and no injected key source.
  local want_sample=0 degrade=0
  if [ "${as_json}" = 1 ] || [ "${once}" = 1 ]; then want_sample=1; degrade=1; fi
  if [ -z "${AIBOX_DASH_KEYS:-}" ]; then
    # No injected key source -> the real-terminal rules apply. With an injected
    # source the loop is explicitly headless (tests: TERM is often "dumb" inside CI
    # containers, and no stty/alternate-screen is touched anyway).
    if [ -n "${AIBOX_NO_TUI:-}" ] || [ "${TERM:-}" = dumb ]; then want_sample=1; degrade=1; fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then want_sample=1; degrade=1; fi
  fi
  if [ "${want_sample}" = 1 ]; then
    bash "$(_dash_self)" __dashboard-sample "${dir}" --once --interval "${interval}" >/dev/null 2>&1 || true
  fi
  file="$(_dash_latest_snapshot "${dir}" || true)"

  if [ "${as_json}" = 1 ]; then
    [ -n "${file}" ] || die "no dashboard snapshot could be sampled (see: aibox dashboard --once)"
    _dash_json "${file}"
    return 0
  fi

  size="$(_dash_size)"
  w="${size%x*}"
  h="${size#*x}"

  if [ "${degrade}" = 1 ]; then
    if [ -z "${file}" ]; then
      die "no dashboard snapshot available (sampler could not run: is docker/aibox state readable?)"
    fi
    _dash_render_once "${file}" "${pane}" "${w}" "${filter}" "${sortkey}"
    if ! { [ -t 0 ] && [ -t 1 ]; } && [ "${AIBOX_DASH_QUIET:-}" != 1 ]; then
      printf '%s(not a TTY — printed a single frame; use --json for machine-readable output)%s\n' "${C_DIM}" "${C_RST}"
    fi
    return 0
  fi

  # ---------- interactive ----------
  # AIBOX_DASH_KEYS (tests): the loop runs headless — no stty, no alternate screen,
  # frames go to stdout so assertions can read them.
  local _DASH_TTY=1 SAVED_STTY SAMPLER_PID _DASH_CLEANED=0
  if [ -n "${AIBOX_DASH_KEYS:-}" ]; then _DASH_TTY=0; fi
  if [ "${_DASH_TTY}" = 1 ]; then
    SAVED_STTY="$(stty -g 2>/dev/null || true)"
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    stty -echo -icanon min 1 time 0 2>/dev/null || true
  fi
  # Ctrl-C / SIGTERM must actually EXIT (a trap that merely cleans up resumes the
  # loop: `expect eof` then never returns and the pty test hangs — measured risk on
  # slower runners). The EXIT trap still runs the (idempotent) cleanup exactly once.
  trap '_dash_cleanup; exit 130' INT TERM HUP QUIT
  trap '_dash_cleanup' EXIT
  bash "$(_dash_self)" __dashboard-sample "${dir}" --interval "${interval}" >/dev/null 2>&1 &
  SAMPLER_PID=$!

  local key sel=0 paused=0 frames=0 pane_idx=0 need_resample=0 npane=1
  local panes_list=" ${_dash_panes} "
  local pane_now="${pane}"
  npane="$(printf '%s' "${panes_list}" | tr ' ' '\n' | grep -c . || true)"
  [ "${npane}" -ge 1 ] 2>/dev/null || npane=1
  while :; do
    file="$(_dash_latest_snapshot "${dir}" || true)"
    if [ -z "${file}" ]; then
      file="${dir}/snapshot.1"
      printf '\033[H\033[2J%swaiting for the first sample…%s\n' "${C_DIM}" "${C_RST}"
      key="$(_dash_key_read)"
      case "${key}" in q | ESC | $'\003') break ;; esac
      continue
    fi
    size="$(_dash_size)"
    w="${size%x*}"
    h="${size#*x}"
    # One frame per pass; `head -n` keeps it inside the window, and the trailing
    # `|| true` absorbs the SIGPIPE that head's early exit causes under pipefail.
    {
      printf '\033[H'
      printf '%s%saibox dashboard%s %s· pane %s (%s/%s)%s\n' \
        "${C_BOLD}" "${C_CYA}" "${C_RST}" "${C_DIM}" "${pane_now}" \
        "$((pane_idx + 1))" "${npane}" "${C_RST}"
      printf '%s%s%s\n' "${C_DIM}" \
        "$(_dash_status_line "${file}" "${pane_now}" "${interval}" "${paused}" "${filter}" "${sortkey}" "${frames}")" "${C_RST}"
      _dash_render_once "${file}" "${pane_now}" "${w}" "${filter}" "${sortkey}"
      _dash_keybar
      printf '\033[J'
    } 2>/dev/null | head -n "${h}" || true
    frames=$((frames + 1))
    if [ "${frames_max}" != 0 ] && [ "${frames}" -ge "${frames_max}" ]; then break; fi
    key="$(_dash_key_read)"
    case "${key}" in
    q | ESC | $'\003') break ;;   # the control byte 003 = Ctrl-C arriving as a keystroke (no ISIG, or a pty)
    r) need_resample=1 ;;
    p | SPACE) [ "${paused}" = 1 ] && paused=0 || paused=1 ;;
    '+') interval="$(_dash_interval_cycle "${interval}")" ;;
    '-') interval="$(_dash_interval_cycle "${interval}")" ;;
    TAB | BTAB)
      if [ "${key}" = TAB ]; then pane_idx=$((pane_idx + 1)); else pane_idx=$((pane_idx - 1)); fi
      pane_idx=$(((pane_idx % npane + npane) % npane))
      pane_now="$(printf '%s' "${panes_list}" | tr ' ' '\n' | grep . | sed -n "$((pane_idx + 1))p" || true)"
      [ -n "${pane_now}" ] || pane_now=modules
      sel=0
      ;;
    DOWN | j) sel=$((sel + 1)) ;;
    UP | k) [ "${sel}" -gt 0 ] && sel=$((sel - 1)) ;;
    g | HOME) sel=0 ;;
    G | END) sel=999 ;;
    PGDN) sel=$((sel + 10)) ;;
    PGUP) [ "${sel}" -gt 10 ] && sel=$((sel - 10)) || sel=0 ;;
    s) sortkey="$(_dash_sort_cycle "${sortkey}")" ;;
    \? | h) _dash_frame_help "${w}"; printf '\n%s(any key returns)%s' "${C_DIM}" "${C_RST}"; _dash_key_read >/dev/null ;;
    a) _dash_frame_about "${file}" "${w}"; printf '\n%s(any key returns)%s' "${C_DIM}" "${C_RST}"; _dash_key_read >/dev/null ;;
    d | ENTER)
      _dash_cleanup
      _DASH_CLEANED=0
      if [ "${_DASH_TTY}" = 1 ]; then
        tput rmcup 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        stty "${SAVED_STTY}" 2>/dev/null || true
      fi
      local m
      m="$(_dash_kv_get "$(_dash_records "${file}" MODULE | sed -n "$((sel + 1))p")" name)"
      if [ -n "${m}" ]; then cmd_status_detail "${m}"; else info "no module on this row"; fi
      printf '\n%s(press any key to return to the dashboard)%s' "${C_DIM}" "${C_RST}"
      IFS= read -r -s -n 1 -t 30 _ 2>/dev/null || true
      if [ "${_DASH_TTY}" = 1 ]; then
        tput smcup 2>/dev/null || true
        tput civis 2>/dev/null || true
        stty -echo -icanon min 1 time 0 2>/dev/null || true
      fi
      ;;
    /)
      # Headless mode (injected keys) reads the filter from the SAME source — reading
      # stdin there would silently skip the test's input.
      if [ -n "${AIBOX_DASH_KEYS:-}" ]; then
        filter="$(_dash_key_read)"
      else
        stty echo icanon 2>/dev/null || true
        printf '\n%s filter (empty clears): %s' "${C_DIM}" "${C_RST}"
        IFS= read -r filter 2>/dev/null || filter=""
        stty -echo -icanon min 1 time 0 2>/dev/null || true
      fi
      [ -n "${filter}" ] || filter="-"
      sel=0
      ;;
    esac
    if [ "${need_resample}" = 1 ]; then
      need_resample=0
      bash "$(_dash_self)" __dashboard-sample "${dir}" --once --interval "${interval}" >/dev/null 2>&1 &
    fi
    # Keep the cursor INSIDE the visible rows: pressing Down past the last row used to
    # move the marker off-screen, which reads as "up/down does not work" (reported).
    local nrows
    nrows="$(_dash_row_count "${file}" "${pane_now}" "${filter}")"
    case "${nrows}" in '' | *[!0-9]*) nrows=0 ;; esac
    if [ "${nrows}" -ge 1 ]; then
      [ "${sel}" -ge "${nrows}" ] && sel=$((nrows - 1))
    else
      sel=0
    fi
    [ "${sel}" -lt 0 ] && sel=0
    # NO sleep here: `_dash_key_read` already waits up to a second, so a pressed key is
    # handled IMMEDIATELY. The old unconditional `sleep 1` made every keypress feel
    # sluggish (reported live as "other keys are slow").
  done
  _dash_cleanup
  return 0
}

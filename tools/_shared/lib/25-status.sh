# ---------- status keyline template (spec §Status template) ----------

# Shared render helpers for module-owned rich views (render_status); the
# manager (bin/aibox, a single-file CLI that cannot source this file) inlines
# the SAME shapes — keep them in sync via the spec. Plain (NO_COLOR) shapes:
#   <name> <appver> · ✓ running
#   ─────────────────────────────────────────────────────────────────
#     service    launchd · pid 38243
#     module     1.3.5 · ~/.aibox/modules/<name>/        (whole row dim)
# Colors inherit aibox's exported C_* (empty standalone → plain). Rule width:
# TTY → tput cols clamped [40,72]; non-TTY → 64 (pipes/tests get a stable
# shape). NOTE: the [ -t 1 ] check MUST run in the function's own body —
# never inside $(…): command substitution turns stdout into a pipe and the
# TTY branch would never fire (live-caught by review: width was dead-fixed
# 64 everywhere). Rules repeat COMPLETE ─ literals — never sliced (#6).

_status_w() { # prints the rule width; $1 = stdout-is-tty flag ("1"/"0")
  local w=64
  if [ "${1:-0}" = "1" ]; then
    # stty talks to the CONTROLLING terminal via /dev/tty — works even inside
    # $(…) (tput's stdout would be the substitution pipe, not the tty, and
    # ncurses would fall back to terminfo's cols — live-measured: 80 on an
    # xterm pty set to 50 cols).
    local sz
    sz="$(stty size </dev/tty 2>/dev/null || true)"
    case "${sz}" in
    *" "*) w="${sz##* }" ;;
    esac
  fi
  case "${w}" in '' | *[!0-9]*) w=64 ;; esac
  [ "${w}" -lt 40 ] && w=40
  [ "${w}" -gt 72 ] && w=72
  printf '%s' "${w}"
}

# state word → colored "<icon> <word>" segment; empty for na/unknown words
_status_state_seg() { # $1=state word (ok|running|starting|stopped|na|"")
  case "${1:-}" in
  ok | running) printf '%s✓ %s%s' "${C_GRN:-}" "${1}" "${C_RST:-}" ;;
  starting) printf '%s⚠ %s%s' "${C_YEL:-}" "${1}" "${C_RST:-}" ;;
  stopped) printf '%s○ %s%s' "${C_DIM:-}" "${1}" "${C_RST:-}" ;;
  *) printf '' ;;
  esac
}

status_header() { # $1=name $2=app_version (""=omit) $3=state word (see _status_state_seg)
  local seg
  printf '%s%s%s' "${C_BOLD:-}" "${1}" "${C_RST:-}"
  [ -n "${2}" ] && printf ' %s%s%s' "${C_CYA:-}" "${2}" "${C_RST:-}"
  seg="$(_status_state_seg "${3:-}")"
  [ -n "${seg}" ] && printf ' %s·%s %s' "${C_DIM:-}" "${C_RST:-}" "${seg}"
  printf '\n'
  status_rule
}

status_row() { # $1=label (ASCII, ≤10 chars) $2=value (verbatim; may embed color spans)
  printf '  %s%-10s%s %s\n' "${C_DIM:-}" "${1}" "${C_RST:-}" "${2}"
}

status_module_row() { # $1=module_version $2=module_dir — sunk, whole row dim
  printf '  %s%-10s %s · %s%s\n' "${C_DIM:-}" "module" "${1:-?}" "${2:-}" "${C_RST:-}"
}

status_rule() { # the dim horizontal rule (width per the header comment)
  local w i=0 out=""
  if [ -t 1 ] 2>/dev/null; then
    w="$(_status_w 1)"
  else
    w=64
  fi
  while [ "${i}" -lt "${w}" ]; do
    out="${out}─"
    i=$(( i + 1 ))
  done
  printf '%s%s%s\n' "${C_DIM:-}" "${out}" "${C_RST:-}"
}

status_secheader() { # $1=title (ASCII) → "── title ───…" to the rule width
  local w n i=0 out=""
  if [ -t 1 ] 2>/dev/null; then
    w="$(_status_w 1)"
  else
    w=64
  fi
  n=$(( w - ${#1} - 6 ))
  [ "${n}" -lt 3 ] && n=3
  while [ "${i}" -lt "${n}" ]; do
    out="${out}─"
    i=$(( i + 1 ))
  done
  printf '%s%s── %s%s%s %s%s%s\n' \
    "${C_DIM:-}" "" "${C_BOLD:-}${C_CYA:-}" "${1}" "${C_RST:-}" \
    "${C_DIM:-}" "${out}" "${C_RST:-}"
}


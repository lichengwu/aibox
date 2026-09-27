# ---------- config store helpers (spec §Configuration) ----------
# The deploy's store is the single source of truth; env vars are install-time
# seeds only ("seed at install, store after"). One generic shape covers the
# KEY=value stores (.env for compose modules, /etc/<m>/<m>.conf for CLI
# modules); service-defined modules (pi-web) regenerate their whole service
# definition instead of piecemeal edits.

# Does this KEY hold a secret? (masked in `config` listings; get returns it)
cfg_secret_p() { # $1=KEY
  case "$1" in
  *PASSWORD* | *SECRET* | *TOKEN*) return 0 ;;
  *KEY) return 0 ;;
  *) return 1 ;;
  esac
}

cfg_mask() { printf '%s' "••••••••"; }

# KEY=value store reader. Accepts quoted and bare values; "" when unset.
cfg_kv_get() { # $1=file $2=KEY
  [ -n "${CFG_STORE:-}" ] || CFG_STORE="$1"
  [ -f "$1" ] || return 0
  sed -nE "s/^$2=\"?([^\"]*)\"?\$/\1/p" "$1" | head -1
}

# KEY=value store writer: replaces the FIRST matching line in place (comments,
# order and mode preserved), appends when the key is new. Idempotent.
cfg_kv_set() { # $1=file $2=KEY $3=value
  local f="$1" k="$2" v="$3" tmp mode
  [ -n "$k" ] || return 0
  tmp="${f}.cfgtmp.$$"
  if [ ! -f "$f" ]; then
    (
      umask 077
      printf '%s="%s"\n' "$k" "$v" >"$f"
    ) || {
      warn "cannot write $f"
      return 1
    }
    return 0
  fi
  # keys are [A-Z_0-9] (validator-enforced) — no awk-regex metachars
  awk -v k="$k" -v v="$v" '
    $0 ~ "^"k"=" && !done { print k "=\"" v "\""; done = 1; next }
    { print }
    END { if (!done) print k "=\"" v "\"" }
  ' "$f" >"$tmp" || {
    rm -f "$tmp"
    warn "cannot rewrite $f"
    return 1
  }
  mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo 600)"
  mv -f "$tmp" "$f"
  chmod "${mode}" "$f" 2>/dev/null || true
  return 0
}

# Remove every KEY= line (back to the declared default).
cfg_kv_unset() { # $1=file $2=KEY
  local f="$1" k="$2" tmp mode
  [ -f "$f" ] || return 0
  tmp="${f}.cfgtmp.$$"
  grep -vE "^${k}=" "$f" >"$tmp" || true
  mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo 600)"
  mv -f "$tmp" "$f"
  chmod "${mode}" "$f" 2>/dev/null || true
  return 0
}

# Parse the module.yaml env: declaration into lines of "KEY<TAB>default<TAB>desc<TAB>flags".
# $1 = the module.yaml path. Value shape: "default — description [flags]".
cfg_env_declare() { # $1=module.yaml → declaration lines on stdout
  [ -f "$1" ] || return 0
  # ONE awk pass extracts KEY<TAB>value pairs (the fork-elimination win — was
  # one sed per key). The value SPLITTING stays in bash: the " — " separator
  # is a 3-byte em-dash, and C-locale awk's index/substr counts BYTES while
  # UTF-8 awk counts CHARS — a portability divergence (measured: desc got cut
  # mid-character on the dev Mac). Bash string ops handle UTF-8 uniformly.
  awk '
    /^env:/ { inenv = 1; next }
    inenv && /^[a-zA-Z]/ { inenv = 0 }
    inenv && /^  [A-Z_][A-Z0-9_]*: *"/ {
      key = $0
      sub(/^  /, "", key); sub(/: *"/, "\t", key); sub(/"$/, "", key)
      print key
    }
  ' "$1" | while IFS="$(printf '\t')" read -r k v; do
    def="${v%% —*}"
    [ "${def}" = "${v}" ] && def="${v%%—*}"
    rest="${v#* —}"
    [ "${rest}" = "${v}" ] && rest="${v}"
    flags=""
    case "${v}" in
    *"["*"]"*) flags="$(printf '%s' "${v}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')" ;;
    esac
    desc="${rest%%\[*}"
    printf '%s\t%s\t%s\t%s\n' "${k}" "${def}" "$(printf '%s' "${desc}" | sed 's/^ *//; s/ *$//')" "${flags}"
  done
}

# Generic `config` action for KEY=value-store modules (spec §Configuration).
# Requires: CFG_YAML (module.yaml path), CFG_STORE (the .env/.conf file),
# CFG_APPLY (the apply command shown/offered, e.g. "aibox dify restart") or
# empty for apply-at-next-invocation modules.
# Sub-actions: (list) | get KEY | set KEY VALUE | unset KEY
cfg_action() { # $@ = config sub-args
  local mode="${1:-list}" k="${2:-}" v="${3:-}"
  case "${mode}" in
  list)
    local key def desc flags cur shown
    while IFS="$(printf '\t')" read -r key def desc flags; do
      [ -n "$key" ] || continue
      case " ${flags} " in *" knob "*) continue ;; esac
      cur="$(cfg_kv_get "${CFG_STORE}" "${key}")"
      if [ -n "${cur}" ]; then
        if cfg_secret_p "${key}" || case " ${flags} " in *" secret "*) true ;; *) false ;; esac then
          shown="$(cfg_mask)"
        else
          shown="${cur}"
        fi
        printf '  %-26s %-14s %s\n' "${key}" "${shown}" "${desc}"
      else
        printf '  %-26s %-14s %s\n' "${key}" "(default: ${def})" "${desc}"
      fi
    done < <(cfg_env_declare "${CFG_YAML}")
    if [ -n "${CFG_APPLY}" ]; then
      log "apply changes: ${CFG_APPLY}"
    else
      log "changes apply at the next invocation (no restart needed)"
    fi
    ;;
  get)
    [ -n "$k" ] || die "usage: config get <KEY> (keys: aibox ${AIBOX_MODULE:-module} --help)"
    cfg_kv_get "${CFG_STORE}" "$k" || true
    [ -n "$(cfg_kv_get "${CFG_STORE}" "$k")" ] || warn "(unset — default: $(cfg_env_declare "${CFG_YAML}" | awk -F'\t' -v k="$k" '$1==k{print $2}'))"
    ;;
  set)
    [ -n "$k" ] && [ -n "$v" ] || die "usage: config set <KEY> <VALUE>"
    cfg_kv_set "${CFG_STORE}" "$k" "$v" || return 1
    ok "set ${k} in ${CFG_STORE}"
    if [ -n "${CFG_APPLY}" ]; then
      if [ -t 0 ] && cfg_confirm_apply; then
        # shellcheck disable=SC2086
        ${CFG_APPLY}
      else
        log "apply when ready: ${CFG_APPLY}"
      fi
    else
      log "applies at the next invocation"
    fi
    ;;
  unset)
    [ -n "$k" ] || die "usage: config unset <KEY>"
    cfg_kv_unset "${CFG_STORE}" "$k"
    local def
    def="$(cfg_env_declare "${CFG_YAML}" | awk -F'\t' -v k="$k" '$1==k{print $2}')"
    ok "unset ${k} (back to default: ${def:-<builtin>})"
    [ -n "${CFG_APPLY}" ] && log "apply when ready: ${CFG_APPLY}"
    ;;
  *)
    die "usage: aibox ${AIBOX_MODULE:-module} config [get|set|unset] [KEY] [VALUE]"
    ;;
  esac
}

# The apply confirm for `config set` (default Y — writing config implies
# wanting it live); non-interactive takes the no-apply path with the hint.
cfg_confirm_apply() {
  local ans
  printf '%s⚠%s  apply now? [Y/n] ' "${C_YEL:-}" "${C_RST:-}"
  read -r ans || return 1
  case "$ans" in n | N | no | NO) return 1 ;; *) return 0 ;; esac
}

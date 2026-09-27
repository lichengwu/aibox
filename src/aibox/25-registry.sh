# ---------- registry ----------
# load_registry populates AIBOX_MODULES and AIBOX_MODULE_<name>_* in the current process.
# Local (file://) source: scan tools/*/module.yaml directly (spec §2.1, no registry.sh).
# Remote (GitHub raw) source: GitHub API lists tools/ dirs, fetches each module.yaml.
#   Result is cached to $AIBOX_REGISTRY_CACHE with a TTL to dodge the unauthenticated
#   GitHub API rate limit (60 req/hour/IP). Cache holds only AIBOX_MODULE_* assignments
#   (the same content that would be eval'd anyway), mode 600.
load_registry() {
  local m mu yaml f

  # Local source: no cache (always fresh, reads the working tree).
  if [ "${AIBOX_RAW#file://}" != "$AIBOX_RAW" ]; then
    local repo_dir="${AIBOX_RAW#file://}"
    AIBOX_MODULES=""
    for f in "$repo_dir"/tools/*/module.yaml; do
      [ -f "$f" ] || continue
      m="$(awk -F': *' '/^name:/{gsub(/"/,"",$2); print $2; exit}' "$f")"
      [ -n "$m" ] || continue
      AIBOX_MODULES="${AIBOX_MODULES:+$AIBOX_MODULES }$m"
      mu="${m//-/_}"
      eval "$(parse_yaml_module_stdin "$mu" < "$f")"
    done
    return
  fi

  # Remote source: serve from cache when fresh.
  if _cache_fresh "$AIBOX_REGISTRY_CACHE"; then
    # shellcheck disable=SC1090
    . "$AIBOX_REGISTRY_CACHE" 2>/dev/null || { rm -f "$AIBOX_REGISTRY_CACHE"; _load_registry_remote; return; }
    # Verify the cache actually produced a module list; otherwise refresh.
    [ -n "${AIBOX_MODULES:-}" ] && return
  fi

  _load_registry_remote
}

# Remote fetch + cache write. Extracted so the cache-hit-fallback path can call it.
_load_registry_remote() {
  local m mu yaml d api_json
  AIBOX_MODULES=""
  api_json="$(gh_pool_fetch "https://api.github.com/repos/${AIBOX_REPO}/contents/tools")" \
    || die "Failed to fetch module list (GitHub API: ${AIBOX_REPO}/tools; the source pool was tried — network? or use a file:// local source)"
  local _body_tmp="$AIBOX_REGISTRY_CACHE.body.tmp"
  local _out_tmp="$AIBOX_REGISTRY_CACHE.out.tmp"
  # mkdir BEFORE the temp-file writes — a fresh AIBOX_HOME (remote source, manager
  # not bootstrapped yet) would die on `: >` otherwise (pre-existing latent bug,
  # exposed by the pool's live test).
  mkdir -p "$(dirname "$AIBOX_REGISTRY_CACHE")"
  local _old_umask; _old_umask=$(umask); umask 077
  : > "$_body_tmp"
  for d in $(printf '%s\n' "$api_json" | awk -F'"' '/"name":/{print $4}'); do
    # _-prefixed dirs are the shared include home (tools/_shared) — NOT
    # modules; no module.yaml there. Fetching it cost a 4-candidate pool
    # miss + a noisy warn on every registry refresh (live-caught).
    case "${d}" in _*) continue ;; esac
    yaml="$(gh_pool_fetch "$AIBOX_RAW/tools/$d/module.yaml")" || continue
    m="$(printf '%s\n' "$yaml" | awk -F': *' '/^name:/{gsub(/"/,"",$2); print $2; exit}')"
    [ -n "$m" ] || continue
    AIBOX_MODULES="${AIBOX_MODULES:+$AIBOX_MODULES }$m"
    mu="${m//-/_}"
    printf '%s\n' "$(printf '%s\n' "$yaml" | parse_yaml_module_stdin "$mu")" >> "$_body_tmp"
  done
  # Persist cache atomically (write to temp, then mv). umask 077 + explicit chmod 600;
  # contains only module metadata, no secrets.
  mkdir -p "$(dirname "$AIBOX_REGISTRY_CACHE")"
  {
    printf 'AIBOX_MODULES="%s"\n' "$AIBOX_MODULES"
    cat "$_body_tmp"
  } > "$_out_tmp"
  mv "$_out_tmp" "$AIBOX_REGISTRY_CACHE"
  chmod 600 "$AIBOX_REGISTRY_CACHE" 2>/dev/null || true
  umask "$_old_umask"
  rm -f "$_body_tmp" "$_out_tmp"
  # Eval the same assignments into this process.
  # shellcheck disable=SC1090
  . "$AIBOX_REGISTRY_CACHE" 2>/dev/null || true
}

# Read a module field: module_field <name> <field> — requires load_registry already done.
module_field() {
  local key="AIBOX_MODULE_${1//-/_}_${2}"
  eval "printf '%s' \"\${${key}:-}\""
}

module_exists() {
  local m
  for m in ${AIBOX_MODULES:-}; do [ "$m" = "$1" ] && return 0; done
  return 1
}

# Normalize a module name to the installed-state key (pi-web -> pi_web), SCOPED to the
# active profile: base → AIBOX_INSTALLED_<mod>; named → AIBOX_INSTALLED_<mod>__<profile>.
# Per-profile state keeps multi-profile installs/uninstalls from clobbering each other.
_ikey() {
  local k="AIBOX_INSTALLED_${1//-/_}" p="${AIBOX_PROFILE:-base}"
  if [ "$p" != "base" ]; then k="${k}__${p//-/_}"; fi
  printf '%s' "$k"
}

# Is this module installed under ANY profile? (guards the shared script-cache deletion)
_installed_any_profile() {
  [ -f "$AIBOX_INSTALLED" ] || return 1
  grep -q "^AIBOX_INSTALLED_${1//-/_}\(__[A-Za-z0-9_]*\)\?=" "$AIBOX_INSTALLED"
}

# ---------- installed state (file-backed, plain vars, no source needed) ----------
is_installed() {
  [ -f "$AIBOX_INSTALLED" ] || return 1
  grep -q "^$(_ikey "$1")=" "$AIBOX_INSTALLED"
}

mark_installed() {
  local key; key="$(_ikey "$1")"
  touch "$AIBOX_INSTALLED"
  { grep -v "^${key}=" "$AIBOX_INSTALLED" 2>/dev/null || true; echo "${key}=\"${2:-unknown}\""; } > "$AIBOX_INSTALLED.tmp"
  mv "$AIBOX_INSTALLED.tmp" "$AIBOX_INSTALLED"
}

unmark_installed() {
  [ -f "$AIBOX_INSTALLED" ] || return 0
  local key; key="$(_ikey "$1")"
  grep -v "^${key}=" "$AIBOX_INSTALLED" > "$AIBOX_INSTALLED.tmp" 2>/dev/null || true
  mv "$AIBOX_INSTALLED.tmp" "$AIBOX_INSTALLED"
}

installed_names() {
  [ -f "$AIBOX_INSTALLED" ] || return 0
  local p="${AIBOX_PROFILE:-base}"
  if [ "$p" = "base" ]; then
    # base profile: keys WITHOUT the __<profile> suffix
    grep -oE "^AIBOX_INSTALLED_[a-z0-9_]+=" "$AIBOX_INSTALLED" 2>/dev/null | grep -v '__' \
      | sed -E 's/^AIBOX_INSTALLED_//; s/=$//' | tr '_' '-'
  else
    local suf="__${p//-/_}"
    grep -oE "^AIBOX_INSTALLED_[a-z0-9_]+${suf}=" "$AIBOX_INSTALLED" 2>/dev/null \
      | sed -E "s/^AIBOX_INSTALLED_//; s/${suf}=\$//" | tr '_' '-'
  fi
}

# Download module scripts to the local cache (result path in AIBOX_LAST_DEST).
download_module() {
  local name="$1" dir files f extra dl inc incs
  load_registry
  module_exists "$name" || die_unknown_module "$name"
  dir="$(module_field "$name" dir)"
  files="$(module_field "$name" files)"
  incs="$(module_field "$name" includes)"
  [ -n "$dir" ] || die "Module $name is missing the dir field"
  AIBOX_LAST_DEST="$AIBOX_MOD_DIR/$name"
  mkdir -p "$AIBOX_LAST_DEST"
  # Shared includes FIRST (repo-level tools/_shared/<inc>.sh → cache _<inc>.sh):
  # single source in the repo, per-module copy in the cache (self-containment
  # preserved). Fetched before the standard set so a failed include download
  # never leaves the module cache half-updated.
  for inc in $incs; do
    info "fetch tools/_shared/${inc}.sh (include)"
    if ! gh_pool_fetch "${AIBOX_RAW%/}/tools/_shared/${inc}.sh" >"$AIBOX_LAST_DEST/_${inc}.sh"; then
      rm -f "$AIBOX_LAST_DEST/_${inc}.sh"
      die "Download tools/_shared/${inc}.sh failed (module ${name} declares includes: [${inc}])"
    fi
  done
  # Standard set (module.yaml + lib.sh/install.sh/uninstall.sh/update.sh/svc.sh)
  # is implicitly downloaded — module.yaml rides along so the LOCAL cache carries
  # the module's own metadata (per-module help / dashboard / ports work offline).
  dl="module.yaml lib.sh install.sh uninstall.sh update.sh svc.sh"
  for extra in $files; do
    case " $dl " in *" $extra "*) ;; *) dl="${dl:+$dl }$extra" ;; esac
  done
  for f in $dl; do
    info "fetch $dir/$f"
    mkdir -p "$(dirname "$AIBOX_LAST_DEST/$f")"   # nested entries (e.g. cli/openmaic) need their dir
    if ! gh_pool_fetch "$AIBOX_RAW/$dir/$f" >"$AIBOX_LAST_DEST/$f"; then
      rm -f "$AIBOX_LAST_DEST/$f"
      die "Download $dir/$f failed (check branch/path; the source pool was tried)"
    fi
    chmod +x "$AIBOX_LAST_DEST/$f" 2>/dev/null || true
  done
  # capture the residue declaration while module.yaml is on disk: `aibox purge`
  # must work after the cache is gone and offline (rescue case)
  _residue_record "$name"
}


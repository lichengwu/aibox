# ---------- component upgrades (upstream-driven; independent of aibox releases) ----------
# Design (docs/module-spec.md §Component upgrades): the repo pins the install FLOOR
# (module.yaml + compose `${VAR:-pinned}`); the deploy .env image keys hold the LIVE
# version. `aibox upgrade <module>` floats the live version to a newer upstream release
# WITHOUT an aibox release: it resolves the target (GitHub releases / DockerHub tags,
# proxy-aware with mirror fallback), extracts the image-tag pairing from the upstream
# compose at that tag (mapping_url — no guessing), pre-pulls, rewrites ONLY the declared
# image keys in the deploy .env, recreates via the module's own svc.sh start (health
# wait), and auto-rolls-back on failure. Modules opt in via the module.yaml `upgrade:`
# stanza (flat shape — parser-compatible, same as `checks:`):
#   upgrade:
#     source: github-release        # or dockerhub-tags
#     repo: langgenius/dify
#     mapping_url: https://raw.githubusercontent.com/langgenius/dify/<VER>/docker/docker-compose.yaml
#     tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$'   # dockerhub-tags only
#     images:
#       - DIFY_API_IMAGE=langgenius/dify-api:      # .env key = upstream image prefix
# Compare dotted versions (suffix after the first '-' ignored): prints -1 / 0 / 1.
upgrade_ver_cmp() { # $1 $2
  local a="${1%%-*}" b="${2%%-*}" i n va vb
  local IFS='.'
  # shellcheck disable=SC2206
  local aa=($a) bb=($b)
  n="${#aa[@]}"
  [ "${#bb[@]}" -gt "$n" ] && n="${#bb[@]}"
  for ((i = 0; i < n; i++)); do
    va="${aa[$i]:-0}"; vb="${bb[$i]:-0}"
    va="${va//[!0-9]/}"; vb="${vb//[!0-9]/}"
    if [ "${va:-0}" -lt "${vb:-0}" ]; then printf -- '-1'; return 0; fi
    if [ "${va:-0}" -gt "${vb:-0}" ]; then printf -- '1'; return 0; fi
  done
  printf -- '0'
}

# Compare two major.minor pairs numerically ($1 $2 like "17.3"). Prints -1/0/1.
_upgrade_mm_cmp() {
  local a="${1}" b="${2}" a1 a2 b1 b2
  a1="${a%%.*}"; a2="${a#*.}"; [ "${a2}" = "${a}" ] && a2=0
  b1="${b%%.*}"; b2="${b#*.}"; [ "${b2}" = "${b}" ] && b2=0
  a1="${a1//[!0-9]/}"; a2="${a2//[!0-9]/}"; b1="${b1//[!0-9]/}"; b2="${b2//[!0-9]/}"
  if [ "${a1:-0}" -lt "${b1:-0}" ] || { [ "${a1:-0}" = "${b1:-0}" ] && [ "${a2:-0}" -lt "${b2:-0}" ]; }; then
    printf -- '-1'; return 0
  fi
  if [ "${a1:-0}" -gt "${b1:-0}" ] || { [ "${a1:-0}" = "${b1:-0}" ] && [ "${a2:-0}" -gt "${b2:-0}" ]; }; then
    printf -- '1'; return 0
  fi
  printf -- '0'
}

# Compute the upgrade hop path between two versions (multi-hop modules).
# stdin: the module's upgrade_stops() output (one major.minor per line).
# $1 = current version (may carry a tag suffix like "19.2.6-ce.0"),
# $2 = target version. Prints one hop version per line, IN ORDER:
#   every required stop strictly AFTER the current major.minor and AT/BEFORE the
#   target major.minor — deduped, sorted; the LAST hop is the target itself.
# Each intermediate stop prints as "major.minor" (the caller resolves its latest
# patch from the tag list); same-minor/patch-only upgrades print NOTHING (single hop).
_upgrade_path_compute() {
  local cur="${1}" tgt="${2}" stop cm tm hop out=""
  cm="$(printf '%s' "${cur%%-*}" | cut -d. -f1,2)"
  tm="$(printf '%s' "${tgt%%-*}" | cut -d. -f1,2)"
  while IFS= read -r stop; do
    stop="$(printf '%s' "${stop}" | tr -d '[:space:]')"
    [ -n "${stop}" ] || continue
    # strictly after current, at/before target
    [ "$(_upgrade_mm_cmp "${stop}" "${cm}")" = "1" ] || continue
    [ "$(_upgrade_mm_cmp "${stop}" "${tm}")" = "-1" ] || continue
    case " ${out} " in *" ${stop} "*) continue ;; esac
    out="${out}${out:+ }${stop}"
  done
  # sort the collected stops ascending (major.minor numeric), one per line
  [ -n "${out}" ] && printf '%s\n' ${out} | sort -t. -k1,1n -k2,2n
  return 0
}

# Highest version tag among the stdin lines (optional ERE filter in $1). Prints the tag.
upgrade_pick_tag() {
  local pat="${1:-}" line best=""
  while IFS= read -r line; do
    line="$(printf '%s' "${line}" | tr -d '[:space:]')"
    [ -n "${line}" ] || continue
    if [ -n "${pat}" ] && ! printf '%s\n' "${line}" | grep -qE "${pat}"; then continue; fi
    if [ -z "${best}" ] || [ "$(upgrade_ver_cmp "${line}" "${best}")" = "1" ]; then best="${line}"; fi
  done
  [ -n "${best}" ] || return 1
  printf '%s' "${best}"
}

# Extract the image tag for an upstream image prefix (stdin = upstream compose text).
# $1 = prefix ENDING with ':' (e.g. langgenius/dify-api:). Prints the tag (e.g. 1.17.1).
upgrade_extract_tag() {
  local prefix="$1" hit
  hit="$(grep -m1 -oE "image:[[:space:]]*${prefix}[^[:space:]'\"]+" || true)"
  [ -n "${hit}" ] || return 1
  printf '%s' "${hit##*"${prefix}"}"
}

# Default image for an env key from a compose file (the `image: ${KEY:-prefix:tag}` floor).
upgrade_floor_image() { # $1=compose file, $2=env key
  [ -f "$1" ] || return 1
  grep -m1 -oE "image:[[:space:]]*[$][{]${2}:-[^}]+" "$1" 2>/dev/null | sed -e 's/^.*:-//'
}

# Rewrite KEY=VALUE lines in an env file in place (appends missing keys; atomic; mode kept).
upgrade_env_rewrite() { # $1=envfile, rest=KEY=VALUE pairs
  local envf="$1"; shift
  local tmp mode kv k
  # GNU syntax FIRST (fails cleanly on BSD, no stdout garbage); BSD as fallback —
  # the reverse order breaks on GNU: stat -f prints multi-line filesystem info to
  # stdout even when it exits 1, and the || fallback output concatenates (CI-caught).
  mode="$(stat -c %a "$envf" 2>/dev/null || stat -f %Lp "$envf" 2>/dev/null || echo 600)"
  tmp="$(mktemp "${envf}.upgrade.XXXXXX")" || return 1
  local exprs=()
  for kv in "$@"; do exprs+=(-e "s|^${kv%%=*}=.*|${kv}|"); done
  # shellcheck disable=SC2068
  sed ${exprs[@]+"${exprs[@]}"} "$envf" > "$tmp" || { rm -f "$tmp"; return 1; }
  for kv in "$@"; do
    k="${kv%%=*}"
    grep -q "^${k}=" "$tmp" 2>/dev/null || printf '%s\n' "${kv}" >> "$tmp"
  done
  mv "$tmp" "$envf"
  chmod "${mode}" "$envf" 2>/dev/null || true
}

# Fetch a URL honoring the run's proxy env; then, for GitHub-hosted files, the
# api.github.com contents API (raw.githubusercontent.com is often blocked on
# networks where the api host is reachable — same family, different blocking;
# measured live); then the configured gh-proxy mirror as last resort.
# Portability: base64 -d (GNU) / -D (BSD/mac), no jq/python (repo rule).
_gh_api_fetch() { # $1 = https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>
  local owner repo ref path api_json b
  owner="$(printf '%s' "${1#https://raw.githubusercontent.com/}" | cut -d/ -f1)"
  repo="$(printf '%s' "${1#https://raw.githubusercontent.com/}" | cut -d/ -f2)"
  ref="$(printf '%s' "${1#https://raw.githubusercontent.com/}" | cut -d/ -f3)"
  path="$(printf '%s' "${1#https://raw.githubusercontent.com/}" | cut -d/ -f4-)"
  [ -n "${owner}" ] && [ -n "${repo}" ] && [ -n "${ref}" ] && [ -n "${path}" ] || return 1
  api_json="$(curl -fsSL --max-time "${AIBOX_UPGRADE_TIMEOUT:-20}" \
    "https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${ref}" 2>/dev/null)" || return 1
  b="$(printf '%s' "${api_json}" | grep -oE '"content": *"[^"]*"' | cut -d'"' -f4 | sed 's/\\n//g')"
  [ -n "${b}" ] || return 1
  printf '%s' "${b}" | base64 -d 2>/dev/null || printf '%s' "${b}" | base64 -D 2>/dev/null
}


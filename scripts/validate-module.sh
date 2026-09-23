#!/usr/bin/env bash
# validate-module.sh — aibox module conformance validator.
#
# The single local source of truth for the module rules that CI enforces
# (docs/module-spec.md §Onboarding). Zero runtime dependencies; bash 3.2
# compatible; optional enhancers are auto-detected:
#   yq         → real YAML well-formedness parse
#   ShellCheck → error-level script lint
#   bash 3.2   → parse check for mac dispatch compatibility
#
# Usage:
#   scripts/validate-module.sh <module>        # validate one module
#   scripts/validate-module.sh --all           # validate every tools/*/module.yaml
#   VALIDATE_ROOT=/path scripts/validate-module.sh ...   # validate another checkout
#
# Exit: 0 = no ERROR (WARN allowed), 1 = at least one ERROR, 2 = usage error.
set -uo pipefail

REPO_ROOT="${VALIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOLS_DIR="${VALIDATE_TOOLS_DIR:-$REPO_ROOT/tools}"

QUIET=0
MODE=""
TARGET=""
for a in "$@"; do
  case "$a" in
  --all) MODE="all" ;;
  --quiet) QUIET=1 ;;
  -h | --help)
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*)
    printf 'unknown flag: %s\n' "$a" >&2
    exit 2
    ;;
  *) [ -z "$TARGET" ] && {
    TARGET="$a"
    MODE="one"
  } ;;
  esac
done
[ -n "$MODE" ] || {
  printf 'usage: validate-module.sh <module>|--all\n' >&2
  exit 2
}

# ---------- parser reuse (single source of truth: bin/aibox) ----------
# Source in a sandboxed AIBOX_HOME so apply_proxy/config touch nothing real;
# then restore validator-friendly shell options (the CLI sets -e).
_VHOME="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-validate.$$")"
mkdir -p "$_VHOME"
export AIBOX_HOME="$_VHOME" AIBOX_CONFIG="$_VHOME/config"
# shellcheck disable=SC1091
. "$REPO_ROOT/bin/aibox" || {
  printf 'cannot source bin/aibox (parser)\n' >&2
  exit 2
}
set +e +u
set -o pipefail 2>/dev/null || true

# ---------- output (v-prefixed: bin/aibox defines warn/ok/info/note too — never collide) ----------
ERRORS=0
WARNS=0
MOD="?"
verr() {
  printf 'ERROR [%s] %s\n' "$MOD" "$*"
  ERRORS=$((ERRORS + 1))
}
vwarn() {
  printf 'WARN  [%s] %s\n' "$MOD" "$*"
  WARNS=$((WARNS + 1))
}
vok() { [ "$QUIET" = 1 ] || printf 'ok    [%s] %s\n' "$MOD" "$*"; }
vnote() { [ "$QUIET" = 1 ] || printf '  ·   %s\n' "$*"; }
# keep short aliases for readability inside rules (defined AFTER the source above)
err() { verr "$@"; }
warn() { vwarn "$@"; }

# ---------- optional enhancers (detect once) ----------
HAVE_YQ=0
command -v yq >/dev/null 2>&1 && HAVE_YQ=1
HAVE_SC=0
command -v shellcheck >/dev/null 2>&1 && HAVE_SC=1
BASH32=""
if [ -x /bin/bash ] && /bin/bash -c 'test "${BASH_VERSINFO[0]}" -eq 3' 2>/dev/null; then
  BASH32=/bin/bash
fi

# Full-width punctuation set for gotcha #1 (kept as a literal string, never sliced).
FW_PUNCT='，。、；：！？（）「」'

# Precise, portable gotcha #8 detector (AGENTS.md): a `local a="x" b="${a}..."`
# same-line forward reference. grep -P backrefs are GNU-only; this awk walk works
# on BWK awk (mac) and gawk (CI) alike. Only segments of a line that START a
# `local` statement count — sequential assignments (`local a=1; b="$a"`) are safe
# because each statement completes before the next expands. Prints "NR:line".
gotcha8_lines() {
  awk '
    /^[ \t]*#/ { next }
    /;/ { }
    {
      line = $0
      nseg = split(line, segs, ";")
      for (si = 1; si <= nseg; si++) {
        seg = segs[si]
        if (seg !~ /^[ \t]*local[ \t]/) continue
        work = seg
        sub(/^[ \t]*local[ \t]+/, "", work)
        nn = 0
        while (1) {
          if (!match(work, /[A-Za-z_][A-Za-z0-9_]*=/)) break
          nm = substr(work, RSTART, RLENGTH - 1)
          rest = substr(work, RSTART + RLENGTH)
          if (match(rest, /[ \t][A-Za-z_][A-Za-z0-9_]*=/)) {
            val = substr(rest, 1, RSTART - 1)
            work = substr(rest, RSTART + 1)
          } else {
            val = rest
            work = ""
          }
          sub(/[ \t]#.*$/, "", val)
          nn++
          names[nn] = nm
          vals[nn] = val
          if (work == "") break
        }
        for (i = 2; i <= nn; i++) {
          hit = 0
          for (j = 1; j < i; j++) {
            if (index(vals[i], "${" names[j]) > 0) { hit = 1; break }
            if (vals[i] ~ ("\\$" names[j] "[^A-Za-z0-9_{]")) { hit = 1; break }
            if (vals[i] ~ ("\\$" names[j] "$")) { hit = 1; break }
          }
          if (hit) { printf "%d:%s\n", NR, line; next }
        }
      }
    }' "$1"
}

# Does the file contain a strict-mode set line? $2=1 requires -e in the flags;
# $2=0 requires only u+o pipefail (large aggregation CLIs may deliberately drop
# -e — measured: openmaic uses `set -uo pipefail` with explicit EXIT_* handling).
has_strict_set() {
  awk -v reqe="${2:-1}" '
    /^set .*pipefail/ {
      f = $2
      sub(/^-/, "", f)
      if (f ~ /u/ && (reqe != 1 || f ~ /e/)) { found = 1; exit }
    }
    END { exit !found }' "$1"
}

# ---------- helpers ----------
mu_of() { printf '%s' "$1" | tr '-' '_'; }

# All module yaml files (sorted, stable order).
all_module_files() {
  local f
  for f in "$TOOLS_DIR"/*/module.yaml; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

parse_one() { # $1 = yaml file → eval-able assignments (namespaced by mu)
  local f="$1" m mu
  m="$(awk -F': *' '/^name:/{gsub(/"/,"",$2); gsub(/[ \t\r]/,"",$2); print $2; exit}' "$f")"
  [ -n "$m" ] || return 1
  mu="$(mu_of "$m")"
  parse_yaml_module_stdin "$mu" <"$f"
}

# ---------- load every module into AIBOX_MODULE_* vars (cross-module rules need all) ----------
LOAD_LIST=""
for f in $(all_module_files); do
  d="$(basename "$(dirname "$f")")"
  m="$(awk -F': *' '/^name:/{gsub(/"/,"",$2); gsub(/[ \t\r]/,"",$2); print $2; exit}' "$f")"
  if [ -z "$m" ]; then
    MOD="$d"
    err "module.yaml has no parseable name: field"
    continue
  fi
  if [ "$m" != "$d" ]; then
    MOD="$d"
    err "name '$m' does not match directory '$d'"
  fi
  eval "$(parse_one "$f")" || {
    MOD="$d"
    err "module.yaml failed to parse"
    continue
  }
  LOAD_LIST="$LOAD_LIST $m"
done

# Cross-module tables (plain temp files — bash 3.2 has no associative arrays).
_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-validate-tbl.$$")"
mkdir -p "$_TMP"
PORTS_TBL="$_TMP/ports"
: >"$PORTS_TBL" # "<port/proto> <module>"
PROVIDES_TBL="$_TMP/provides"
: >"$PROVIDES_TBL" # "<provider>:<component>"
for m in $LOAD_LIST; do
  mu="$(mu_of "$m")"
  p="$(module_field "$m" ports)"
  for tok in $p; do printf '%s %s\n' "$tok" "$m" >>"$PORTS_TBL"; done
  pv="$(module_field "$m" provides)"
  for c in $pv; do printf '%s:%s\n' "$m" "$c" >>"$PROVIDES_TBL"; done
done

# ---------- per-module rule checks ----------
validate_module() {
  local m="$1"
  local d="$TOOLS_DIR/$m"
  local f="$d/module.yaml"
  local mu tok line
  MOD="$m"
  if [ ! -d "$d" ]; then
    err "no such module directory: tools/$m"
    return
  fi
  if [ ! -f "$f" ]; then
    err "missing module.yaml"
    return
  fi
  mu="$(mu_of "$m")"

  # --- S3: YAML well-formed (yq, optional) ---
  if [ "$HAVE_YQ" = 1 ]; then
    yq eval '.' "$f" >/dev/null 2>&1 || err "module.yaml is not valid YAML (yq)"
  fi

  # --- S4: §2.2 awk-parser subset (no anchors/aliases/block scalars/flow) ---
  if grep -nE '[&*][A-Za-z_]|:[[:space:]]*[|>]|:[[:space:]]*[[{]|^[[:space:]]*-[[:space:]]*[[{]' "$f" |
    grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
    err "module.yaml uses §2.2-forbidden YAML (anchors/block scalars/flow); awk parser unsupported"
  fi

  # --- S5/S6: required fields + formats ---
  local name version desc dirv platform
  name="$(module_field "$m" name)"
  version="$(module_field "$m" version)"
  desc="$(module_field "$m" description)"
  dirv="$(module_field "$m" dir)"
  platform="$(module_field "$m" platform)"
  [ -n "$name" ] || err "missing required field: name"
  [ -n "$version" ] || err "missing required field: version"
  [ -n "$desc" ] || err "missing required field: description"
  [ -n "$dirv" ] || err "missing required field: dir"
  [ "$dirv" = "tools/$m" ] || err "dir '$dirv' must be 'tools/$m'"
  printf '%s' "$name" | grep -qE '^[a-z][a-z0-9-]*$' || err "name '$name': only lowercase letters, digits, hyphens; must start with a letter"
  if [ "$name" = self ]; then err "module name 'self' is reserved (the manager module: aibox uninstall self / update self / check self)"; fi
  printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+.][A-Za-z0-9.+-]+)?$' || err "version '$version' is not semver (x.y.z)"
  case "$platform" in "" | linux | darwin) ;; *) err "platform '$platform' must be empty, linux, or darwin" ;; esac

  # --- S8: hooks contract ---
  local h
  h="$(module_field "$m" install)"
  if [ -z "$h" ]; then
    err "missing hooks.install"
  elif [ ! -f "$d/$h" ]; then err "hooks.install '$h' not found in module dir"; fi
  for hk in uninstall update svc; do
    local hv
    hv="$(module_field "$m" "$hk")"
    if [ -n "$hv" ]; then
      [ -f "$d/$hv" ] || err "hooks.$hk '$hv' not found in module dir"
    else
      warn "hooks.$hk not declared (standard modules ship install/uninstall/update/svc)"
    fi
  done

  # --- S9: script quality (hooks, lib, cli/*) ---
  local s base_s in_cli
  for s in "$d"/*.sh "$d"/cli/*; do
    [ -f "$s" ] || continue
    base_s="$(basename "$s")"
    in_cli=0
    [ -d "$d/cli" ] && [ "${s#$d/cli/}" != "$s" ] && in_cli=1
    if [ "$in_cli" = 1 ]; then
      if ! head -1 "$s" | grep -qE '^#!'; then
        vwarn "cli/$base_s: no shebang (non-script file? skipping)"
        continue
      fi
    elif [ "$base_s" != "lib.sh" ]; then
      head -1 "$s" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash' || err "$base_s: line 1 must be a bash shebang"
    fi
    # lib.sh is a sourced library: no shebang and no strict-mode line required
    if [ "$base_s" != "lib.sh" ]; then
      if [ "$in_cli" = 1 ]; then
        has_strict_set "$s" 0 || err "$base_s: missing strict mode (set -[E]euo pipefail / set -uo pipefail)"
        has_strict_set "$s" 1 || vwarn "$base_s: runs without -e (acceptable for aggregation CLIs with explicit exit-code handling; verify deliberate)"
      else
        has_strict_set "$s" 1 || err "$base_s: missing strict mode (set -euo pipefail)"
      fi
    fi
    bash -n "$s" 2>/dev/null || err "$base_s: bash -n syntax error"
    if [ -n "$BASH32" ]; then
      "$BASH32" -n "$s" 2>/dev/null || err "$base_s: bash 3.2 parse error (mac dispatch compatibility; AGENTS.md pitfall #2)"
    fi
    if [ "$HAVE_SC" = 1 ]; then
      shellcheck --severity=error --external-sources --shell=bash "$s" >/dev/null 2>&1 ||
        err "$base_s: shellcheck --severity=error findings"
    fi
    # gotcha #1: bare $VAR followed directly by full-width punctuation
    line="$(grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[$FW_PUNCT]" "$s" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    [ -n "$line" ] && err "$base_s: gotcha #1 (bare \$VAR + full-width punctuation; use \${VAR}): $(printf '%s' "$line" | head -1)"
    # gotcha #8: local same-line forward reference (precise awk detector)
    line="$(gotcha8_lines "$s" || true)"
    [ -n "$line" ] && err "$base_s: gotcha #8 (local same-line self-reference; split lines): $(printf '%s' "$line" | head -1)"
    # bash4-only constructs (runtime landmines when dispatched on mac bash 3.2)
    line="$(grep -nE 'exec \{[a-z_]+\}|[^_a-z]mapfile |[^_a-z]readarray |declare -A|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' "$s" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    [ -n "$line" ] && vwarn "$base_s: bash4-only construct (mapfile/declare -A/exec {fd}/case-mods): $(printf '%s' "$line" | head -1)"
  done

  # --- S10: ports format + cross-module uniqueness ---
  for tok in $(module_field "$m" ports); do
    printf '%s' "$tok" | grep -qE '^[0-9]+/(tcp|udp):[A-Za-z0-9_-]+$' || err "ports entry malformed (want NNN/tcp|udp:usage): $tok"
    local others
    others="$(awk -v p="$tok" -v m="$m" '$1==p && $2!=m {print $2}' "$PORTS_TBL" | sort -u | tr '\n' ' ')"
    [ -n "$others" ] && err "port $tok conflicts with module(s): $others"
  done

  # --- S11: files: entries exist ---
  for tok in $(module_field "$m" files); do
    [ -e "$d/$tok" ] || err "files entry not present in module dir: $tok"
  done

  # --- S12: deps token format ---
  for tok in $(module_field "$m" deps); do
    printf '%s' "$tok" | grep -qE '^[A-Za-z0-9_.+-]+(@[a-z]+)?(:[0-9]+([.][0-9]+)*)?$' || err "deps entry malformed (want cmd[@platform][:version]): $tok"
  done

  # --- S13/S14: services (+ services_optional) + provides cross-refs ---
  for tok in $(module_field "$m" provides); do
    printf '%s' "$tok" | grep -qE '^[a-z0-9_-]+$' || err "provides entry malformed: $tok"
  done
  # services_optional: same entry grammar as services; semantically a deploy-time
  # USER TOGGLE (e.g. dify DIFY_SHARED_BASE=1) — install/update do NOT hard-gate
  # on it. Declaring it keeps the optional consumption machine-visible.
  for tok in $(module_field "$m" services_optional); do
    printf '%s' "$tok" | grep -qE '^[a-z0-9_-]+:[a-z0-9_-]+(#[a-z0-9_]+)?$' || {
      err "services_optional entry must use the provider form provider:component[#dbname]: $tok"
      continue
    }
  done
  for tok in $(module_field "$m" services); do
    printf '%s' "$tok" | grep -qE '^[a-z0-9_-]+:[a-z0-9_-]+(#[a-z0-9_]+)?$' || {
      err "services entry must use the full provider form provider:component[#dbname]: $tok"
      continue
    }
    local prov comp db
    prov="${tok%%:*}"
    comp="${tok#*:}"
    case "$comp" in *'#'*)
      db="${comp#*#}"
      comp="${comp%%#*}"
      ;;
    *) db="" ;; esac
    [ "$prov" != "$m" ] || err "services must not reference own module: $tok"
    printf '%s\n' "$LOAD_LIST" | tr ' ' '\n' | grep -qx "$prov" || {
      err "services provider '$prov' is not a module: $tok"
      continue
    }
    grep -qx "${prov}:${comp}" "$PROVIDES_TBL" || err "services component not in ${prov}'s provides: $tok"
    if [ -n "$db" ]; then
      local mu_name
      mu_name="$(printf '%s' "$m" | tr '-' '_')"
      case "$db" in
      "$m" | "$mu_name" | "${m}_"* | "${mu_name}_"*) ;;
      *) err "services dbname must be <module> or <module>_<usage>: $tok" ;;
      esac
    fi
  done

  # --- S15: checks section (mandatory preflight contract) ---
  grep -qE '^checks:' "$f" || err "missing checks: section (mandatory preflight contract — docs/module-spec.md)"
  local cg doms cmds imgs dpl
  cg="$(module_field "$m" checks_disk_gb)"
  doms="$(module_field "$m" checks_domains)"
  cmds="$(module_field "$m" checks_commands)"
  imgs="$(module_field "$m" checks_docker_images)"
  dpl="$(module_field "$m" checks_docker_pull)"
  if [ -z "$cg$doms$cmds$imgs$dpl" ]; then
    err "checks: declares no probe (need at least one of disk_gb/domains/docker_pull/docker_images/commands)"
  fi
  [ -n "$cg" ] && { printf '%s' "$cg" | grep -qE '^[0-9]+$' || err "checks.disk_gb must be an integer (GB): $cg"; }
  for tok in $doms; do
    printf '%s' "$tok" | grep -qE '^(https?://)?[A-Za-z0-9._:-]+(/.*)?$' || err "checks.domains entry malformed: $tok"
  done
  for tok in $cmds; do
    printf '%s' "$tok" | grep -qE '^[A-Za-z0-9_.+-]+(@[a-z]+)?$' || err "checks.commands entry malformed: $tok"
  done
  for tok in $imgs; do
    printf '%s' "$tok" | grep -qE '^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$' || err "checks.docker_images entry malformed: $tok"
  done
  [ -n "$dpl" ] && { printf '%s' "$dpl" | grep -qE '^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$' || err "checks.docker_pull must be an image reference: $dpl"; }

  # --- S15.5: upgrade stanza (optional; shape-checked when present) ---
  if grep -qE '^upgrade:' "$f"; then
    local usrc urepo uimgs umap upat tok
    usrc="$(module_field "$m" upgrade_source)"
    urepo="$(module_field "$m" upgrade_repo)"
    uimgs="$(module_field "$m" upgrade_images)"
    umap="$(module_field "$m" upgrade_mapping_url)"
    upat="$(module_field "$m" upgrade_tag_pattern)"
    [ -n "$usrc" ] || err "upgrade: present but missing source (github-release | dockerhub-tags)"
    printf '%s' "$usrc" | grep -qE '^(github-release|dockerhub-tags)$' || err "upgrade.source must be github-release or dockerhub-tags: $usrc"
    printf '%s' "$urepo" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || err "upgrade.repo must be <owner>/<repo>: $urepo"
    [ -n "$uimgs" ] || err "upgrade: present but the images list is empty"
    for tok in $uimgs; do
      # ENV_KEY=image[:tag_prefix] — the engine APPENDS the resolved version to
      # the whole value: classic form ends with ':' (gitlab/gitlab-ce: →
      # :19.2.7-ce.0); upstreams that prefix their tags (xiaozhi ghcr: server_0.9.6)
      # use a tag prefix (ghcr.io/...:server_ → ...:server_0.9.7).
      printf '%s' "$tok" | grep -qE '^[A-Z][A-Z0-9_]*=[A-Za-z0-9._/-]+:[A-Za-z0-9._-]*$' || err "upgrade.images entry malformed (want ENV_KEY=image[:tag_prefix], engine appends the version): $tok"
    done
    if [ -n "$umap" ]; then
      printf '%s' "$umap" | grep -qE '^https?://' || err "upgrade.mapping_url must be an http(s) URL: $umap"
      printf '%s' "$umap" | grep -q '<VER>' || err "upgrade.mapping_url must contain the <VER> placeholder: $umap"
    fi
    if [ "$usrc" = dockerhub-tags ]; then
      [ -n "$upat" ] || err "upgrade: dockerhub-tags needs tag_pattern (unfiltered tags pick 'latest'/rc junk)"
    fi
  fi

  # --- S16: actions lifecycle completeness ---
  local acts
  acts="$(module_field "$m" actions)"
  if printf '%s\n' $acts | grep -qx start; then
    for need in stop restart status logs; do
      printf '%s\n' $acts | grep -qx "$need" || err "service-type module (actions has start) missing lifecycle action: $need"
    done
  fi

  # --- S17: dashboard subfields (endpoints/hint only) ---
  if grep -qE '^dashboard:' "$f"; then
    local bad_sub
    bad_sub="$(awk '/^dashboard:/{inb=1;next} /^[A-Za-z0-9_]/{inb=0} inb && /^  [a-z_-]+:/{gsub(/:.*/,"");gsub(/ /,"");print}' "$f" |
      grep -vE '^(endpoints|hint)$' | tr '\n' ' ')"
    [ -n "$bad_sub" ] && err "dashboard allows only endpoints/hint; got: $bad_sub"
  fi

  # --- S17b: per-action usage entries (help framework; WARN for un-covered actions) ---
  if [ -n "$acts" ]; then
    local a missing=""
    for a in $acts; do
      grep -qE "^  ${a}:" "$f" || missing="${missing}${missing:+ }${a}"
    done
    [ -n "$missing" ] && warn "actions without usage: entries (aibox <module> --help renders bare action names): ${missing}"
  fi

  # --- S17c: shared-library includes — entry resolves to tools/_shared/<inc>.sh;
  # docker_images consumers MUST include common (the pool code lives there) ---
  local inc incs
  incs="$(module_field "$m" includes)"
  for inc in $incs; do
    [ -f "$REPO_ROOT/tools/_shared/${inc}.sh" ] || err "includes entry '${inc}' has no tools/_shared/${inc}.sh"
  done
  if [ -n "$(module_field "$m" checks_docker_images)" ]; then
    case " ${incs} " in
    *" common "*) ;;
    *) warn "declares checks.docker_images but not includes: [common] — the docker.io pool functions live in the shared _common.sh" ;;
    esac
  fi

  # --- S17d: env: declaration (config system; spec §Configuration) ---
  # format: KEY: "default — description [flags]"; flags ∈ {secret, knob}
  if grep -qE '^env:' "$f"; then
    local envline ekey eval flags
    while IFS= read -r envline; do
      envline="$(printf '%s' "${envline}" | sed 's/^ *//; s/ *$//')"
      [ -n "${envline}" ] || continue
      case "${envline}" in
      '#'*) continue ;; # TODO skeletons / commented examples
      esac
      if ! printf '%s' "${envline}" | grep -qE '^[A-Z_][A-Z0-9_]*: ".*"$'; then
        err "env entry malformed (KEY: \"default — description [flags]\"): ${envline}"
        continue
      fi
      ekey="${envline%%:*}"
      eval="$(printf '%s' "${envline}" | sed 's/^[^:]*: *"//; s/"$//')"
      case "${eval}" in
      *" — "*) ;;
      *) warn "env entry '${ekey}': value should carry a ' — ' separator (default — description)" ;;
      esac
      flags="$(printf '%s' "${eval}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"
      # " ${flags} " pads: empty flags → "  " (two spaces); flags may combine
      case " ${flags} " in
      "  " | *" secret "* | *" knob "*) ;;
      *) warn "env entry '${ekey}': unknown flag(s) [${flags}] (valid: secret, knob)" ;;
      esac
      # every declared key must be referenced somewhere in the module (dead
      # declarations drift from reality)
      grep -rq "${ekey}" "$d" || warn "env key ${ekey} is never referenced in the module code"
    done <<ENVLIST
$(sed -n '/^env:/,/^[a-zA-Z]/p' "$f" | sed -n 's/^  //p' | grep -vE '^(env:)?$')
ENVLIST
    # README cross-check (bidirectional, exact names): the declaration is the
    # CLI-discoverable surface; the README table is the documented one —
    # they must not drift apart (the gap the config system closed)
    if [ -f "$d/README.md" ]; then
      local rdkey
      while IFS= read -r ekey; do
        [ -n "${ekey}" ] || continue
        grep -qE "\`+${ekey}\`+" "$d/README.md" || warn "env key ${ekey} is declared but not documented in README.md"
      done <<DECL
$(sed -n '/^env:/,/^[a-zA-Z]/p' "$f" | grep -oE '^  [A-Z_][A-Z0-9_]*' | sed 's/^  //')
DECL
      while IFS= read -r rdkey; do
        [ -n "${rdkey}" ] || continue
        grep -qE "^  ${rdkey}:" "$f" || warn "README documents \`${rdkey}\` but module.yaml env: does not declare it (not CLI-discoverable: aibox ${m} --help)"
      done <<READM
$(grep -oE '^\| \`+[A-Z_][A-Z0-9_]+\`+' "$d/README.md" | sed -E 's/^\| \`+//; s/\`+$//' | sort -u)
READM
    fi
  fi

  # --- S18: upstream links ---
  [ -n "$(module_field "$m" upstream_homepage)" ] || warn "upstream.homepage missing (dev-guide link)"
  [ -n "$(module_field "$m" upstream_docs)" ] || warn "upstream.docs missing (dev-guide link)"

  # --- S19/S20/S22: docs + lib ---
  [ -f "$d/README.md" ] || err "missing README.md (module docs are part of the contract)"
  [ -f "$d/docs/DEVELOPMENT.md" ] || warn "missing docs/DEVELOPMENT.md (upstream links + design notes)"
  [ -f "$d/lib.sh" ] || warn "missing lib.sh (shared hook library convention)"

  # --- S21: no hardcoded shared-PG credentials in compose (base excepted) ---
  if [ "$m" != "base" ]; then
    local cf hit
    for cf in "$d"/docker-compose*.yml; do
      [ -f "$cf" ] || continue
      hit="$(grep -nE 'aibox:aibox@|postgres://aibox:' "$cf" || true)"
      [ -n "$hit" ] && err "$(basename "$cf"): hardcoded shared-PG credentials (use \${AIBOX_POSTGRES_*} via base.env): $(printf '%s' "$hit" | head -1)"
    done
  fi

  # --- S23: residue-map entry in bin/aibox (post-manager cleanup) ---
  # `aibox purge` must be able to clean this module's leftovers AFTER the module
  # (or aibox itself) is gone — the embedded residue map is the only knowledge
  # left then. Repo-own tools/ only: the map lives in THIS repo's bin/aibox, so
  # an external scaffold (VALIDATE_TOOLS_DIR override — used by new-module.sh and
  # tests) cannot be in it yet; the author adds the entry when the module lands.
  if [ -z "${VALIDATE_TOOLS_DIR:-}" ] && [ -f "$REPO_ROOT/bin/aibox" ]; then
    awk '/^residue_paths\(\)/,/^\}/' "$REPO_ROOT/bin/aibox" | grep -qE "^[[:space:]]*${m}\)" ||
      warn "no residue-map entry in bin/aibox (residue_paths) — 'aibox purge' cannot clean this module's leftovers"
  fi
}

# ---------- run ----------
[ "$HAVE_SC" = 1 ] || vnote "shellcheck not installed — script lint skipped (CI runs it)"
[ "$HAVE_YQ" = 1 ] || vnote "yq not installed — YAML well-formedness check skipped (CI runs it)"
[ -n "$BASH32" ] || vnote "bash 3.2 not found — mac parse-compat check skipped"

if [ "$MODE" = "all" ]; then
  for m in $LOAD_LIST; do
    validate_module "$m"
  done
else
  printf '%s\n' $LOAD_LIST | grep -qx "$TARGET" || {
    printf 'unknown module: %s (available:%s)\n' "$TARGET" " $LOAD_LIST" >&2
    exit 2
  }
  validate_module "$TARGET"
fi

rm -rf "$_TMP" "$_VHOME" 2>/dev/null
printf '\n%s: %d error(s), %d warning(s)\n' "$([ "$ERRORS" = 0 ] && printf 'PASS' || printf 'FAIL')" "$ERRORS" "$WARNS"
[ "$ERRORS" = 0 ]

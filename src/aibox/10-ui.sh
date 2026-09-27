# ---------- unknown-argument UX (suggestions + one consistent hint) ----------
# Verbs the dispatcher understands (typo suggestions for the first arg).
AIBOX_VERBS="install uninstall update upgrade check dashboard purge proxy clash help version"

# "Close enough to be a typo" for short ASCII words: prefix either way, one
# substitution, or one transposition. Cheaper than a full Levenshtein and
# covers the real typos (instal→install, upgrad→upgrade, chekc→check).
_word_close() { # $1=typed $2=candidate
  local a="$1" b="$2" i=0 d=0 la lb n maxd
  [ "$a" = "$b" ] && return 0
  [ "${#a}" -ge 3 ] || return 1
  case "$b" in "$a"*) return 0 ;; esac
  case "$a" in "$b"*) return 0 ;; esac
  la="${#a}"; lb="${#b}"
  [ $(( la > lb ? la - lb : lb - la )) -le 1 ] || return 1
  n=$(( la < lb ? la : lb ))
  # Scaled tolerance: 1 edit for short words, 2 from 5 chars up. Without the
  # scale, a 3-letter typo matched a 4-letter verb at 2 differences ("bas" →
  # "list") and shadowed the real module suggestion ("base").
  maxd=1; [ "$n" -ge 5 ] && maxd=2
  while [ "$i" -lt "$n" ]; do
    [ "${a:$i:1}" != "${b:$i:1}" ] && d=$(( d + 1 ))
    i=$(( i + 1 ))
  done
  [ "$d" -le "$maxd" ]
}

_suggest_word() { # $1=typed; rest=candidates → prints the first close match
  local w="$1"; shift
  local c
  for c in "$@"; do
    _word_close "$w" "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ONE death for every unknown-module path: consistent hint + a typo suggestion
# when one exists. A typo'd VERB used to die as "Unknown module: instal" with
# no suggestion (live-caught), and the catalog hint appeared on some verbs only.
die_unknown_module() { # $1=typed name
  local n="$1" sug
  sug="$(_suggest_word "$n" ${AIBOX_VERBS} || true)"
  if [ -n "$sug" ]; then
    usage_die "Unknown command or module: ${n} — did you mean: aibox ${sug}?  (verbs: aibox help · modules: aibox dashboard --available)"
  fi
  sug="$(_suggest_word "$n" ${AIBOX_MODULES:-} || true)"
  if [ -n "$sug" ]; then
    usage_die "Unknown module: ${n} — did you mean: aibox ${sug}?  (catalog: aibox dashboard --available)"
  fi
  usage_die "Unknown module: ${n} (aibox dashboard --available shows available modules)"
}

# Installed-module version ("" when absent) — for the re-install note.
_installed_version() { # $1=module
  [ -f "$AIBOX_INSTALLED" ] || return 0
  grep "^$(_ikey "$1")=" "$AIBOX_INSTALLED" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"'
}

# curl is the single download primitive — say so plainly instead of letting a
# fetch fail with a misleading "Download … failed (check branch/path)" when
# the tool simply isn't installed (live-caught on a bare host).
require_curl() {
  command -v curl >/dev/null 2>&1 ||
    die "curl is required for downloads but was not found — install it (apt install curl / dnf install curl / brew install curl)"
}

# " (needed by a, b)" derived from the INSTALLED module caches' deps — local
# metadata only. The old hardcoded list said docker was needed by
# base/openmaic/windmill and never mentioned node at all (stale + incomplete).
_needed_note() { # $1=dep command
  local cmd="$1" f m deps out=""
  for f in "$AIBOX_MOD_DIR"/*/module.yaml; do
    [ -f "$f" ] || continue
    m="$(awk -F': *' '/^name:/{gsub(/"/,"",$2); print $2; exit}' "$f" 2>/dev/null)"
    [ -n "$m" ] || continue
    deps="$(awk '/^deps:/{d=1;next} /^[a-z_]+:/{d=0} d&&/^  - /{sub(/^  - /,""); sub(/@.*/,""); sub(/:.*/,""); printf "%s ", $0}' "$f" 2>/dev/null)"
    case " ${deps} " in *" ${cmd} "*) out="${out}${out:+, }${m}" ;; esac
  done
  [ -n "$out" ] && printf ' (needed by %s)' "$out"
  return 0
}

# TUI helpers — formal, clean, consistent (design ref: gh CLI / kubectl).
# Three visual levels: action (plain), success/warning/error (symbol prefix),
# sub-detail (dim, indented). No bracket prefixes; symbols carry the semantics.
# log/warn/ok/info/die/usage_die/die_code live in the shared library
# (tools/_shared/lib/00-out.sh, injected into this bundle by scripts/bundle.sh):
# ONE definition for the manager and for module hooks (the bundler injects the
# same fragment; the old hand-maintained copies used to drift).
bad() { printf '%s✗%s  %s\n' "$C_RED" "$C_RST" "$*"; }

# Per-verb help — the manager-side counterpart of `aibox <module> --help`, reachable as
# `aibox <verb> --help|-h` (any argument position) and `aibox help <verb>`.
# ONE block per verb, always exit 0 (help is not an error), so the verb surface
# cannot drift into "purge answers, install fetches the registry".
_verb_help() { # $1=verb → usage block on stdout (0) / 1 when unknown (caller prints usage)
  case "$1" in
  install)
    cat <<'EOF'
usage: aibox install <module> [--skip-checks]

Fetch the module scripts (+ declared includes), run its preflight, then the
install hook. Declared service deps are installed FIRST (recursive, cycle-guarded).

  --skip-checks           bypass the preflight (soft checks only — missing hard
                          deps/services are not bypassable)
  AIBOX_NO_AUTO_DEPS=1    never auto-install (service deps and packages)
  AIBOX_PM_TIMEOUT=<secs> bound package-manager auto-install (default 600; 0 = off)
  AIBOX_STRICT_SERVICES=1 exit non-zero when a service dep did not start

related: aibox check <module> (preflight dry-run) · aibox dashboard <module>
EOF
    ;;
  uninstall)
    cat <<'EOF'
usage: aibox uninstall <module>|self [--purge] [--yes]

Run the module's uninstall hook, then remove its marker. Data is KEPT unless
--purge is given (two gates: confirm, then confirm DATA). Residue afterwards:
aibox purge <module>.

  --purge      also delete the module's DATA (volumes, deploy root)
  --yes, -y    answer both gates yes (scripts/non-interactive)

related: aibox purge [--apply] · aibox uninstall self [--purge]
EOF
    ;;
  update)
    cat <<'EOF'
usage: aibox update <module>|self|--all [--restart|--no-restart] [--skip-checks]

Refresh MODULE SCRIPTS (the repo-pinned floor) and run the update hook. This is
NOT the upstream app version — that is `aibox upgrade <module>`. Reports the
version transition, and says so when already current.

  --all             every installed module + the manager itself
  --restart         restart services after the update
  --no-restart      never restart (deploy hosts that batch restarts)
  --skip-checks     bypass the preflight

related: aibox upgrade <module> [--check]
EOF
    ;;
  upgrade)
    cat <<'EOF'
usage: aibox upgrade <module> [--check|--rollback|--history] [--to <ver>] [--no-backup] [--yes]

Upgrade the DEPLOYED upstream app version (dockerhub / github-release resolver)
without an aibox release. Snapshots the data when the module's DB is knowable,
rewrites the deploy .env image pins, recreates via the module's own health gate,
and records a rollback point. Multi-hop modules (gitlab) walk the required stops.

  --check         plan only: current/target/path + the recorded rollback point
  --rollback      go back to the recorded rollback point (swaps the point)
  --history       list recorded transitions
  --to <version>  pin a target (works offline; enables downgrades)
  --no-backup     skip the pre-upgrade data snapshot
  --yes, -y       skip the confirmation

exit codes: 10 = upgrade failed but rolled back · 20 = manual intervention needed
related: aibox dashboard <module> (shows the recorded state)
EOF
    ;;
  check)
    cat <<'EOF'
usage: aibox check <module>|self

  --json          machine-readable verdict on stdout:
                  {"module","ok","exit","details":[...]} — exit codes unchanged

Run the module's preflight without installing (deps, commands, disk, domains,
docker pull, services), or the environment check for `self` (egress route,
docker, node/npm, disk). Exit: 3 = hard requirement missing · 4 = precheck failed.

related: aibox install <module> (which runs the same preflight)
EOF
    ;;
  dashboard)
    cat <<'EOF'
usage: aibox dashboard [--available|--json] [<module>]

No argument: every installed module per profile — app version, state, endpoint,
credentials, ports + listeners, residue, and the async "updates available" list.

  --available     the registry catalog (module version + status)
  --json          the same overview as ONE JSON object on stdout (machine-readable:
                  aibox_version/profile/modules[] with name, module_version,
                  app_version, state, endpoint, ports[], upgrade{}); local-first,
                  no network, exit codes unchanged
  <module>        detail + health: app version, endpoint probe, auth, log path,
                  port listeners, config-key count, upgrade/rollback state

The dashboard is the authoritative view for DERIVED values (profile ports,
container names, env paths) — docs deliberately point here instead of hardcoding.
EOF
    ;;
  purge)
    cat <<'EOF'
usage: aibox purge [<module>...|self] [--apply] [--stop] [--yes]

Scan for residue (containers, volumes, deploy dirs, /etc configs, units, CLI
binaries, npm packages) and remove it. Dry-run by DEFAULT: nothing is deleted
without --apply. Works after the module — or aibox itself — is gone.

  --apply    actually delete (default: report only)
  --stop     stop RUNNING containers among the findings first
  --yes, -y  skip the confirmation gate
EOF
    ;;
  proxy)
    cat <<'EOF'
usage: aibox proxy show|set <url>|unset|on|off|check [url]|env [--remote]

Static proxy config (global; covers module hooks and dispatched CLIs). The clash
pool takes priority while it is on. Modules that network LATER (on a deploy host)
get the value persisted into their own config files .

  show                 current config (URL masked)
  set <url>            set the proxy (asks before accepting a dead one)
  unset                clear the URL (config file survives as a template)
  on | off             enable/disable without losing the URL
  check [url]          connectivity test; verdict uses %{proxy_used} (1 = went
                       through the proxy) + a direct-connection control
  env [--remote]       the export lines for your own shell

related: aibox clash on|off|status · `aibox --no-proxy <cmd>` for a one-shot bypass
EOF
    ;;
  clash)
    cat <<'EOF'
usage: aibox clash set <sub-url>|on|off|status|refresh|select|test|logs|doctor|use-external

Clash subscription pool (mihomo kernel). While it is on it takes priority over
the static proxy for the whole toolkit.

  set <sub-url>       store the subscription + generate the config
  on | off            start/stop the kernel (start/stop/restart also work)
  status              state + nodes + latency (dashboard view)
  refresh             re-fetch the subscription
  select <node>       switch the active node
  test [url]          connectivity through the pool
  logs                kernel log
  doctor              deep diagnostics
  use-external <port>  reuse a local clash client (Verge etc.) as the egress
EOF
    ;;
  version)
    cat <<'EOF'
usage: aibox version   (also: -v, --version)

Print the manager version. Module versions: aibox dashboard --available.
EOF
    ;;
  help)
    cat <<'EOF'
usage: aibox help [<verb>|--all]

  aibox help             this overview
  aibox help <verb>      one verb's usage/options (also: aibox <verb> --help)
  aibox <module> --help  a module's actions (usage: stanza in module.yaml)
  aibox <module> <action> --help   one action's args hint
EOF
    ;;
  *) return 1 ;;
  esac
  return 0
}
# BSD awk compatible (index/substr/sub, no capture groups; runs on bash 3.2's nawk).
# $1=module name. Scalars -> AIBOX_MODULE_<name>_<key>; lists -> space-joined; nested -> <parent>_<subkey>.

# Is the given cache file fresh (mtime within TTL)? Returns 0 if fresh, 1 if stale/missing.
# Extracted so tests can exercise the staleness logic directly. Optional $2 overrides
# the TTL (defaults to the registry TTL — the gh source pool passes its own).
_cache_fresh() {
  local f="$1" now mtime age
  local ttl="${2:-${AIBOX_REGISTRY_TTL:-3600}}"
  [ -f "$f" ] || return 1
  now="$(date +%s)"
  mtime="$(date -r "$f" +%s 2>/dev/null || stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
  age=$((now - ${mtime:-0}))
  [ "$age" -lt "${ttl}" ]
}


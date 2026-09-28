# ---------- global options / dispatch (only when executed, not sourced) ----------
# Guarded so `bin/aibox` can be sourced by tests (bats) without dispatching.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # --no-proxy: bypass the proxy for this invocation (must precede the command)
  BYPASS_PROXY=0
  ASSUME_YES=0
  AIBOX_PROFILE="${AIBOX_PROFILE:-base}"
  PREFLIGHT_SKIP="${AIBOX_SKIP_CHECKS:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-proxy) BYPASS_PROXY=1; shift ;;
      --profile)  AIBOX_PROFILE="${2:-base}"; shift 2 ;;
      --profile=*) AIBOX_PROFILE="${1#--profile=}"; shift ;;
      --yes | -y) ASSUME_YES=1; shift ;;
      --)         shift; break ;;
      *)          break ;;
    esac
  done
  export AIBOX_PROFILE

  # ONE config: load the provider contract into this process and export it, so every
  # module hook / dispatched CLI / compose call inherits the SAME connection facts
  # (spec §Dependency contract). Silent when there is no contract (standalone).
  base_contract_export 2>/dev/null || true

  # Load config and apply the proxy (covers layer 1: this process; layer 2: spawned module hooks)
  load_config
  if [ "$BYPASS_PROXY" = "1" ]; then
    bypass_proxy
  else
    apply_proxy
  fi

  # ---------- dispatch ----------
  # Help first, uniformly: `aibox <verb> --help|-h` (any position) and
  # `aibox help <verb>` render that verb's block and exit 0. Before this, only
  # purge answered --help; install/check/status treated it as a MODULE name
  # (fetching the registry) and the rest as an unknown option.
  case "${1:-}" in
    help|-h|--help)
      if [ -n "${2:-}" ]; then
        _verb_help "${2}" || { usage; exit 2; }
        exit 0
      fi ;;
    install|uninstall|update|upgrade|check|status|autoclean|proxy|version)
      case "${2:-}" in -h|--help) _verb_help "$1"; exit 0 ;; esac ;;
  esac

  case "${1:-help}" in
    install)          shift; cmd_install "$@" ;;
    uninstall)        shift; cmd_uninstall "$@" ;;
    update)           shift; cmd_update "$@" ;;
    upgrade)          shift; cmd_upgrade "$@" ;;
    check)            shift; cmd_check "$@" ;;
    autoclean)        shift; cmd_autoclean "$@" ;;
    status)        shift; cmd_status "$@" ;;
    dashboard)
      # removed in 0.26.0 — merged into `status` (its module-level rich views too)
      usage_die "the 'dashboard' verb was merged into 'status' — use: aibox status [<module>]" ;;
    proxy)            shift; cmd_proxy "$@" ;;
    # hidden internal verb: the status's async latest-version probe runs as
    # a SEPARATE process (bash $0 __status-probe …) — gh_pool_fetch's race
    # semantics misbehave inside nested background subshells (measured: silent
    # instant failure); a fresh process runs the pool exactly like any CLI
    # invocation. Not in help; harmless if invoked directly.
    __status-probe)     shift; _status_probe_cmd "$@" ;;
    version|-v|--version) echo "aibox $AIBOX_VERSION" ;;
    help|-h|--help)   usage ;;
    *)
      # A typo'd VERB lands here (the dispatcher falls through to module
      # actions) — suggest the verb instead of a bare "Unknown module".
      # The `|| true` matters: _suggest_word returns 1 with no match and a bare
      # assignment would trip set -e into a SILENT exit (caught by the suite:
      # `aibox base --help` produced no output at all). An EXACT verb match is
      # a module that happens to share a verb's name (clash) — pass through.
      _sv="$(_suggest_word "${1:-}" ${AIBOX_VERBS} || true)"
      if [ -n "${_sv}" ] && [ "${_sv}" != "${1:-}" ] && ! is_installed "${1:-}" 2>/dev/null; then
        die "Unknown command or module: ${1:-} — did you mean: aibox ${_sv}?  (verbs: aibox help)"
      fi
      cmd_module_action "$@" ;;
  esac
fi

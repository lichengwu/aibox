# ---------- first-run preparation (the contract that `start` must make it run) ----------
# A module whose app must be PREPARED before it can run declares that in module.yaml:
#   first_run: install                     # the action `start` invokes when the app is absent
#   first_run_note: "clone + build (~1h)"  # printed before the (possibly long) step
# `aibox install <module>` stays LIGHT (fast, repeatable — it puts the CLI/compose/.env in
# place and ensures the shared base); deploying the APP is the app's own lifecycle, so it is
# triggered by the verb whose contract is "make it run": `start`. Without this, "install then
# start" produced a raw `cd: …/app: No such file or directory` (live-reported on 50.55) —
# reasonable expectations, unstated contract.
module_ensure_deployed() { # $1=module $2=module.yaml $3=artifact path $4=prepare-cmd(optional)
  local m="$1" yaml="$2" artifact="$3" prep="${4:-}" action="" note=""
  [ -e "${artifact}" ] && return 0
  action="$(meta_field "${yaml}" first_run 2>/dev/null || true)"
  note="$(meta_field "${yaml}" first_run_note 2>/dev/null || true)"
  [ -n "${prep}" ] || prep="${AIBOX_FIRST_RUN_CMD:-aibox ${m} ${action:-install}}"
  if [ "${AIBOX_NO_PREPARE:-0}" = 1 ]; then
    warn "${m} is not deployed yet (${artifact} missing) — first-run step skipped (--no-prepare)"
    log "  deploy it when ready: ${prep}"
    return 30
  fi
  log "first run: ${m} is not deployed yet — running: ${prep}"
  [ -n "${note}" ] && log "           ${note}"
  if ! sh -c "${prep}"; then
    warn "the first-run step failed — retry it directly: ${prep}"
    return 30
  fi
  [ -e "${artifact}" ] || { warn "still missing after the first-run step: ${artifact}"; return 30; }
  return 0
}

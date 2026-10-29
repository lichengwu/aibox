#!/usr/bin/env bats
# pi-web svc.sh launchd error surfacing — regression tests for the live-caught
# 2026-10-29 case: `aibox pi-web restart` printed launchctl's misleading
# "Bootstrap failed: 5: Input/output error" (internally errno 37 "Operation
# already in progress" — the label was still loaded, because the preceding
# bootout failed silently under `2>/dev/null || true`). The Darwin branch is
# exercised on Linux/CI via a fake `uname` + a scripted fake `launchctl` on
# PATH. Contract pinned here:
#   - a failed bootout is LOUD (warn carrying launchctl's stderr), never swallowed
#   - "not loaded" (No such process / Could not find service) stays silent
#   - bootstrap EIO-5 dies with the translation (still-registered label, or an
#     SSH session with no console login), with exactly one bounded retry
#     (bootout teardown is asynchronous — a racing bootstrap also sees EIO-5)
#   - stop no longer claims "stopped" over a failed bootout

setup() {
  SANDBOX="$(mktemp -d 2>/dev/null || echo "/tmp/aibox-piweb-svc.$$")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/Library/LaunchAgents"
  unset AIBOX_PROFILE PI_WEB_BIND PI_WEB_PORT PI_WEB_PASSWORD || true
  export PI_WEB_PASSWORD=testpw
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FAKEBIN="$SANDBOX/bin"
  mkdir -p "$FAKEBIN"
  export FAKE_LAUNCHCTL_CALLS="$SANDBOX/launchctl.calls"
  : > "$FAKE_LAUNCHCTL_CALLS"

  # fake uname: the Darwin branch must be exercisable on Linux CI
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$FAKEBIN/uname"
  chmod +x "$FAKEBIN/uname"

  # fake launchctl: per-subcommand rc + stderr scripted via env vars; every
  # invocation is recorded (call-count assertions, e.g. the EIO retry)
  cat > "$FAKEBIN/launchctl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_CALLS:-/dev/null}"
case "$1" in
bootout)
  echo "${FAKE_LAUNCHCTL_BOOTOUT_MSG:-}" >&2
  exit "${FAKE_LAUNCHCTL_BOOTOUT_RC:-0}"
  ;;
bootstrap)
  echo "${FAKE_LAUNCHCTL_BOOTSTRAP_MSG:-}" >&2
  exit "${FAKE_LAUNCHCTL_BOOTSTRAP_RC:-0}"
  ;;
kickstart)
  echo "${FAKE_LAUNCHCTL_KICKSTART_MSG:-}" >&2
  exit "${FAKE_LAUNCHCTL_KICKSTART_RC:-0}"
  ;;
print)
  if [ -n "${FAKE_LAUNCHCTL_PRINT_RUNNING:-}" ]; then
    printf 'state = running\nlast exit code = 0\n'
    exit 0
  fi
  echo "Could not find service in domain for user gui: ${UID}" >&2
  exit 3
  ;;
*)
  exit 0
  ;;
esac
SHIM
  chmod +x "$FAKEBIN/launchctl"
  export PATH="$FAKEBIN:$PATH"

  # restart only checks the plist EXISTS (the real one is written by
  # write_service; this path never parses it)
  touch "$HOME/Library/LaunchAgents/pi-web.plist"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

@test "restart: EIO-5 both ways — raw text kept, translation added, one retry" {
  export FAKE_LAUNCHCTL_BOOTOUT_RC=5
  export FAKE_LAUNCHCTL_BOOTOUT_MSG="Boot-out failed: 5: Input/output error"
  export FAKE_LAUNCHCTL_BOOTSTRAP_RC=5
  export FAKE_LAUNCHCTL_BOOTSTRAP_MSG="Bootstrap failed: 5: Input/output error
Try re-running the command as root for richer errors."
  run bash "$REPO_ROOT/tools/pi-web/svc.sh" restart
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # the bootout failure is loud, carrying launchctl's stderr...
  [[ "$output" == *"launchctl bootout failed (rc=5): Boot-out failed: 5"* ]] || false
  # ...the raw bootstrap text is kept as evidence...
  [[ "$output" == *"Bootstrap failed: 5: Input/output error"* ]] || false
  # ...and EIO is translated into its two real meanings
  [[ "$output" == *"still registered in launchd"* ]] || false
  [[ "$output" == *"SSH session"* ]] || false
  [[ "$output" == *"aibox pi-web status"* ]] || false
  # exactly one bounded retry (async-teardown-race absorption)
  [ "$(grep -c '^bootstrap ' "$FAKE_LAUNCHCTL_CALLS")" -eq 2 ] || false
}

@test "restart: not-loaded bootout is silent, bootstrap succeeds" {
  export FAKE_LAUNCHCTL_BOOTOUT_RC=3
  export FAKE_LAUNCHCTL_BOOTOUT_MSG="Boot-out failed: 3: No such process"
  export FAKE_LAUNCHCTL_PRINT_RUNNING=1
  run bash "$REPO_ROOT/tools/pi-web/svc.sh" restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"restarted (service definition re-read"* ]] || false
  [[ "$output" != *"bootout failed"* ]] || false
}

@test "stop: failed bootout is NOT 'stopped'" {
  export FAKE_LAUNCHCTL_BOOTOUT_RC=5
  export FAKE_LAUNCHCTL_BOOTOUT_MSG="Boot-out failed: 5: Input/output error"
  run bash "$REPO_ROOT/tools/pi-web/svc.sh" stop
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"stop failed"* ]] || false
  [[ "$output" == *"still registered in launchd"* ]] || false
  [[ "$output" == *"launchctl bootout failed (rc=5)"* ]] || false
}

@test "stop: not-loaded is a clean idempotent stop" {
  export FAKE_LAUNCHCTL_BOOTOUT_RC=3
  export FAKE_LAUNCHCTL_BOOTOUT_MSG="Boot-out failed: 3: No such process"
  run bash "$REPO_ROOT/tools/pi-web/svc.sh" stop
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "stopped" ]] || false
}

@test "start: bootstrap AND kickstart both failing gets the translation" {
  export FAKE_LAUNCHCTL_BOOTSTRAP_RC=5
  export FAKE_LAUNCHCTL_BOOTSTRAP_MSG="Bootstrap failed: 5: Input/output error"
  export FAKE_LAUNCHCTL_KICKSTART_RC=5
  export FAKE_LAUNCHCTL_KICKSTART_MSG="Could not find service \"pi-web\" in domain for user gui: 501"
  run bash "$REPO_ROOT/tools/pi-web/svc.sh" start
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"start failed (bootstrap and kickstart both failed)"* ]] || false
  [[ "$output" == *"still registered in launchd"* ]] || false
}

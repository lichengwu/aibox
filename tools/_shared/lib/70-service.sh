# ---------- platform service units (one implementation of the shapes) ----------
# Two modules (pi-web, windmill) generate launchd plists and systemd units. The
# CONTENT differs per module (user-level UI vs system-level oneshot/timer), but
# the SHAPES — plist keys, systemd section order, the quoting of Environment= —
# are the same knowledge written twice, which is exactly what drifts. These
# renderers own the shapes; callers supply the content.

# launchd plist for a user agent.
#   $1=label $2=workdir $3=log dir $4=log name $5=throttle seconds
#   $6=run-at-load (0|1) $7=keep-alive (0|1) $8=program path, $9...=program args
#   env pairs come through the ENV_PAIRS variable ("K=V K=V"; values are quoted
#   for the plist — keep them shell-safe, the caller builds them from conf).
svc_render_launchd_plist() {
  local label="$1" workdir="$2" logdir="$3" logname="$4" throttle="$5"
  local run_at_load="$6" keep_alive="$7" program="$8"
  shift 8
  local arg pair k v
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>'
  printf '    <key>Label</key><string>%s</string>\n' "${label}"
  printf '%s\n' '    <key>ProgramArguments</key>' '    <array>'
  printf '        <string>%s</string>\n' "${program}"
  for arg in "$@"; do
    printf '        <string>%s</string>\n' "${arg}"
  done
  printf '%s\n' '    </array>'
  if [ -n "${ENV_PAIRS:-}" ]; then
    printf '%s\n' '    <key>EnvironmentVariables</key>' '    <dict>'
    for pair in ${ENV_PAIRS}; do
      k="${pair%%=*}"
      v="${pair#*=}"
      printf '        <key>%s</key><string>%s</string>\n' "${k}" "${v}"
    done
    printf '%s\n' '    </dict>'
  fi
  printf '    <key>WorkingDirectory</key><string>%s</string>\n' "${workdir}"
  [ "${run_at_load}" = "1" ] && printf '%s\n' '    <key>RunAtLoad</key><true/>'
  [ "${keep_alive}" = "1" ] && printf '%s\n' '    <key>KeepAlive</key><true/>'
  [ -n "${throttle}" ] && [ "${throttle}" != "0" ] &&
    printf '    <key>ThrottleInterval</key><integer>%s</integer>\n' "${throttle}"
  printf '    <key>StandardOutPath</key><string>%s/%s.log</string>\n' "${logdir}" "${logname}"
  printf '    <key>StandardErrorPath</key><string>%s/%s.err.log</string>\n' "${logdir}" "${logname}"
  printf '%s\n' '</dict>' '</plist>'
}

# systemd unit.
#   $1=scope (user|system) $2=description $3=exec line $4=workdir $5=log dir
#   $6=log name $7=type (simple|oneshot) $8=restart secs ("" = none)
#   $9=extra [Service] lines ("" = none; may contain newlines)
#   $10=extra [Unit] lines ("" = none) $11=install target ("" = scope default)
#   $12... argv to append to the exec line (one per argument)
#   env pairs come through the ENV_PAIRS variable ("K=V K=V").
svc_render_systemd_unit() {
  local scope="$1" desc="$2" exec_line="$3" workdir="$4" logdir="$5" logname="$6"
  local type="$7" restart="$8" extra_service="$9" extra_unit="${10}" install_target="${11}"
  shift 11 2>/dev/null || shift $#
  local arg pair k v target
  # the install target follows the SCOPE unless the caller overrides it
  if [ -n "${install_target}" ]; then
    target="${install_target}"
  elif [ "${scope}" = "user" ]; then
    target="default.target"
  else
    target="multi-user.target"
  fi
  printf '%s\n' '[Unit]'
  printf 'Description=%s\n' "${desc}"
  [ -n "${extra_unit}" ] && printf '%s\n' "${extra_unit}"
  printf '\n%s\n' '[Service]'
  printf 'Type=%s\n' "${type}"
  if [ "${scope}" = "system" ]; then printf '%s\n' 'User=root'; fi
  if [ -n "${ENV_PAIRS:-}" ]; then
    for pair in ${ENV_PAIRS}; do
      k="${pair%%=*}"
      v="${pair#*=}"
      printf 'Environment="%s=%s"\n' "${k}" "${v}"
    done
  fi
  printf 'ExecStart=%s' "${exec_line}"
  for arg in "$@"; do
    printf ' %s' "${arg}"
  done
  printf '\n'
  [ -n "${workdir}" ] && printf 'WorkingDirectory=%s\n' "${workdir}"
  if [ -n "${restart}" ]; then
    printf 'Restart=always\nRestartSec=%s\n' "${restart}"
  fi
  if [ -n "${logdir}" ]; then
    printf 'StandardOutput=append:%s/%s.log\n' "${logdir}" "${logname}"
    printf 'StandardError=append:%s/%s.err.log\n' "${logdir}" "${logname}"
  fi
  [ -n "${extra_service}" ] && printf '%s\n' "${extra_service}"
  printf '\n%s\n' '[Install]'
  printf 'WantedBy=%s\n' "${target}"
}

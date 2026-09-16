# pi-web module

Deploys [`@agegr/pi-web`](https://www.npmjs.com/package/@agegr/pi-web) as a macOS user-level launchd persistent service (HTTP Basic Auth + crash auto-restart). This module was split out from the original `pi-web-ctl` single script and is functionally equivalent.

## Install / Uninstall / Update (via aibox)

```bash
aibox install pi-web              # install and start the service
aibox update pi-web               # if an update exists, asks whether to restart (no restart when already up to date)
aibox update pi-web --restart     # if an update exists, restart directly without prompting
aibox update pi-web --no-restart  # even if an update exists, do not restart
aibox update --all                # update all installed modules + aibox itself
aibox update pi-web --all         # update pi-web + aibox itself
aibox uninstall pi-web            # stop service + clean up plist
```

`update` first compares the installed version of `@agegr/pi-web` with the npm latest: **if there is no update, it never restarts** (regardless of flags); if an update exists, it upgrades the npm package and rewrites the plist, then decides whether to restart the service based on `--restart` (restart directly) / `--no-restart` (do not restart) / no flag (interactive `[Y/n]` prompt, non-interactive defaults to no restart).

## Service operations

```bash
aibox pi-web start
aibox pi-web stop
aibox pi-web restart
aibox pi-web status
aibox pi-web logs
aibox pi-web diagnose
```

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `PI_WEB_PASSWORD` | randomly generated | HTTP Basic Auth password (username is fixed to `pi`); randomly generated on first install and written into the plist, read back from the plist on reinstall/update (idempotent, not rotated); setting this variable overrides it |
| `PI_WEB_BIND` | `0.0.0.0` | listen address; `127.0.0.1` for localhost only |
| `PI_WEB_PORT` | `30141` | listen port |

Just export them before `aibox install pi-web`, for example:

```bash
PI_WEB_PASSWORD=secret PI_WEB_BIND=127.0.0.1 aibox install pi-web
```

## Comparison with the original pi-web-ctl

| Original `pi-web-ctl` | Now |
| --- | --- |
| `pi-web-ctl install` | `aibox install pi-web` |
| `pi-web-ctl start` | `aibox pi-web start` |
| `pi-web-ctl status` | `aibox pi-web status` |
| `pi-web-ctl uninstall` | `aibox uninstall pi-web` |
| `pi-web-ctl install-cli` | (removed, replaced by the `aibox` main CLI) |

## Platform

Cross-platform: macOS uses launchd (`~/Library/LaunchAgents` plist + `KeepAlive`), Linux uses systemd --user (`~/.config/systemd/user/pi-web.service` + `Restart=always` + `loginctl enable-linger` for keep-alive). Neither requires root. Windows is not supported.

## Hook structure

| File | Purpose |
| --- | --- |
| `lib.sh` | shared: config variables, `resolve_node` / `cleanup_old` / `write_plist` / `show_status` |
| `install.sh` | install |
| `uninstall.sh` | uninstall |
| `update.sh` | update |
| `svc.sh` | `start/stop/restart/status/logs/diagnose` |

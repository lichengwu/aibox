# windmill

A **single-file ops CLI** distribution module for a Windmill self-hosted instance (isomorphic to `openmaic`).
The CLI itself is `windmill` (a self-contained bash script with all compose/Caddyfile/systemd templates embedded);
this module is responsible for installing it onto the target machine and seeding host-level configuration.

## Applicable scenarios

- Linux deployment host (recommended: `WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill`)
- macOS local install is also supported (the CLI has platform adaptations: lock/port/IP/memory/backup rescue all have fallback implementations);
  the only unadapted item is the **launchd scheduled task** (daily backup/version check is currently unavailable on macOS; the `systemd` subcommand will explicitly error out)

## Landing points (module-spec "Deployment directory and config landing point convention")

| Item | Path | Description |
| --- | --- | --- |
| CLI itself | `${WINDMILL_BIN_DIR:-${AIBOX_BIN_DIR:-~/.local/bin}}/windmill` | install landing point |
| Deployment root | `$AIBOX_HOME/apps/windmill` | `.env`, compose, `backups/`, `logs/`, credentials; the deletion boundary of `destroy` |
| Host-level config | `/etc/windmill/windmill.conf` | key whitelist `PROXY_URL` / `WM_GHCR_MIRROR` / `WM_HUB_MIRROR` / `HTTP_PORT`; seeded on install, only fills in without overwriting, read-only to the CLI; **no credentials stored here** |

The deployment root is the same expression on both platforms (Linux `/root/.aibox/apps/windmill`, macOS `~/.aibox/apps/windmill`).

## Quick start (on the deployment host)

```bash
aibox install windmill                 # or WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill
windmill doctor                        # environment self-check
windmill init --version 1.811.1        # deploy from scratch (for domestic networks, configuring a proxy for the docker daemon first is recommended)
windmill systemd install               # daily backup + weekly version check + boot alignment
```

Day-to-day: `windmill status / doctor / backup --full / drill`; upgrades: `windmill check` → `windmill upgrade <ver>`.

## Networking notes (empirically tested)

- ghcr.io direct connection from China is about 0.5 MB/s; **configuring an HTTP proxy for the docker daemon is the preferred approach** (systemd drop-in, measured 66 MB/s); `--ghcr-mirror` / `--hub-mirror` are fallback alternatives
- If the daemon's `registry-mirrors` contains a black-hole source, `docker pull` will silently hang — the CLI's pull has built-in stall detection and retry, and you can also bypass it with `--hub-mirror`

## Uninstall semantics

`aibox uninstall windmill` only deletes the CLI itself; `/etc/windmill/windmill.conf` and
`$AIBOX_HOME/apps/windmill` (database volumes, backups) are **preserved** — they belong to "this deployment".
For a complete teardown use `windmill --yes destroy --all` (it first relocates backups to `$AIBOX_HOME/backups/`).

## Relationship with aibox

- Proxy: the aibox global proxy (`aibox proxy set`) is seeded into the `PROXY_URL` of `/etc/windmill/windmill.conf` during install/update, for running `windmill check` offline on the deployment host
- `aibox windmill <action>` is passed through to the local `windmill` CLI
- `aibox self uninstall` has fail-closed protection over `apps/` and will not accidentally delete deployment instances

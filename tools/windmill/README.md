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
| Host-level config | `/etc/windmill/windmill.conf` | key whitelist (seeded on install, only fills in without overwriting, read-only to the CLI; **no credentials stored here**): `PROXY_URL` · `WM_GHCR_MIRROR` · `WM_HUB_MIRROR` · `HTTP_PORT` (default **8080**) · `BASE_URL` · `WM_WORKER_REPLICAS` / `WM_WORKER_MEMORY` / `WM_NATIVE_REPLICAS` / `WM_NATIVE_MEMORY` / `WM_INDEXER_REPLICAS` · `LOG_MAX_SIZE` / `LOG_MAX_FILE` · `KEEP` · `ENABLE_LSP` / `ENABLE_MULTIPLAYER` / `ENABLE_DEBUGGER` |

The deployment root is the same expression on both platforms (Linux `/root/.aibox/apps/windmill`, macOS `~/.aibox/apps/windmill`).

## Configuration knobs

Host-level (`/etc/windmill/windmill.conf`, written by `aibox windmill config set <KEY> <value>`);
precedence is **CLI flag > environment variable > deploy `.env` > this conf > built-in default**:

| Key | Default | What it does | When it applies |
| --- | --- | --- | --- |
| `HTTP_PORT` | `8080` | entry HTTP port | next `up`/`deploy` (was `80` before 0.16) |
| `BASE_URL` | (unset) | the external URL the instance advertises, **scheme+host only** (`https://wm.example.com`); no port, no path | next `deploy --recreate` (it changes the published ports) |
| `WM_WORKER_REPLICAS` | `3` | default-worker-group replica count | next `up`/`deploy` |
| `WM_WORKER_MEMORY` | `1536M` | default worker memory cap | next `up`/`deploy` |
| `WM_NATIVE_REPLICAS` | `1` | native worker replicas | next `up`/`deploy` |
| `WM_NATIVE_MEMORY` | `1024M` | native worker memory cap | next `up`/`deploy` |
| `WM_INDEXER_REPLICAS` | `0` | `1` enables full-text job/log search (EE) | next `up`/`deploy` |
| `LOG_MAX_SIZE` | `20m` | docker `json-file` rotate size | next `up`/`deploy` |
| `LOG_MAX_FILE` | `10` | docker `json-file` files kept | next `up`/`deploy` |
| `KEEP` | `7` | daily backups kept by the scheduled timer | after `windmill systemd install` (baked into the unit) |
| `ENABLE_LSP` / `ENABLE_MULTIPLAYER` / `ENABLE_DEBUGGER` | `true` / `false` / `true` | windmill_extra feature switches (LSP, collaboration, debugger) | next `up`/`deploy` |
| `PROXY_URL` | (unset) | egress proxy (seeded from `aibox proxy`) | immediately |
| `WM_GHCR_MIRROR` / `WM_HUB_MIRROR` | (unset) | registry mirrors for the image pulls | immediately |

**HTTPS / domain** — `BASE_URL` drives the generated Caddyfile's site address:

```bash
# real domain: Caddy obtains the certificate automatically (needs 80/443 reachable); 443 gets published
aibox windmill config set BASE_URL https://wm.example.com && windmill deploy --recreate
# bare IP or *.local: self-signed via `tls internal` (ACME cannot certify an IP)
aibox windmill config set BASE_URL https://10.0.0.5 && windmill deploy --recreate
# behind your own reverse proxy: leave BASE_URL unset (plain HTTP on HTTP_PORT)
aibox windmill config set BASE_URL ""; windmill deploy --recreate
```

A port or path inside `BASE_URL` is rejected on purpose — the port is conveyed by `HTTP_PORT`
(http) or by the automatic 443 publish (https), so a port in the URL would make Caddy listen
on a container port the published mapping does not cover.

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
- `aibox uninstall self` keeps module services/data by default (apps/ preserved); `--purge` cascades the full teardown

## Standard actions

`aibox windmill start|stop|restart|status|logs` — the shared lifecycle; `dashboard` is the
rich view (alias of `status`), and `doctor` is the standard diagnostic (deps, docker,
state, declared ports; see below).

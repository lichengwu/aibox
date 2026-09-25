# openmaic module

Distributes the unified ops CLI for [OpenMAIC](../..) (`openmaic`) to target hosts via aibox.

The CLI itself is `tools/openmaic/cli/openmaic` in the repo (a single-file bash script), and **this repo is its sole source of truth**: change it here, run `aibox update openmaic`, and everything stays in sync.

## What it manages

OpenMAIC is a Docker Compose deployment (app + PostgreSQL + video rendering service). This CLI collapses its day-to-day ops into a single entry point: install, upgrade/rollback, backup/restore, configuration management, environment self-check.

## Where it runs

The CLI requires **docker + compose** (any OS: a Linux deployment host or macOS Docker Desktop both work); the default deployment directory is `$AIBOX_HOME/apps/openmaic`.

- With docker: service commands such as `up/install/upgrade/backup` are all available
- Without docker: only read-only commands like `help / version / doctor` are available; service commands explicitly refuse (exit code `3`) rather than throwing a docker error

`aibox install openmaic` auto-checks the docker dependency (and prompts to install it if missing).

```bash
OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic
```

## Install / Update / Uninstall

```bash
aibox install openmaic      # install (idempotent)
aibox update openmaic       # overwrites only if content changed; skips if identical
aibox uninstall openmaic    # deletes only the CLI itself
```

`aibox uninstall openmaic` does **not** delete `/etc/openmaic` (secrets, access passwords) or the deployment root `$AIBOX_HOME/apps/openmaic` (deployment directory) — those belong to "this deployment" rather than "this command". To clean the deployment use `openmaic clean`.

## Action pass-through

The module has no resident service of its own; `aibox openmaic <action>` passes straight through to the local `openmaic`:

```bash
aibox openmaic status           # equivalent to openmaic status
aibox openmaic doctor
aibox openmaic upgrade --check
aibox openmaic backup list
```

> ⚠️ Naming collision: `aibox install openmaic` means **install this module**; `aibox openmaic install` means **deploy OpenMAIC itself** (clone from source + build + start containers). One word order apart, completely different semantics.

## Environment variables

Install location:

| Variable | Default | Description |
| --- | --- | --- |
| `OPENMAIC_BIN_DIR` | `$AIBOX_BIN_DIR` or `~/.local/bin` | CLI install directory; commonly `/usr/local/bin` on deployment hosts |

CLI runtime (also writable into `/etc/openmaic/openmaic.conf`; environment variables take higher priority):

| Variable | Default | Description |
| --- | --- | --- |
| `OPENMAIC_CONF_DIR` | `/etc/openmaic` | config and secrets directory |
| `OPENMAIC_BASE_DIR` | `$AIBOX_HOME/apps/openmaic` | deployment root directory (see "Layout" below) |
| `OPENMAIC_PROXY_URL` | empty | proxy for pulling source code; accepts a full URL (`http://host:port` / `socks5://host:port`). **Takes precedence over the legacy key below** |
| `OPENMAIC_PROXY_HOST` | empty | same as above (legacy key, kept for compatibility). The value may be a bare `host:port`; `http://` is auto-prepended |
| `OPENMAIC_HEALTH_URL` | `http://127.0.0.1:3000/api/health` | health check URL |
| `OPENMAIC_HEALTH_TIMEOUT` | `300` | health check wait limit (seconds) |
| `OPENMAIC_BACKUP_KEEP` | `14` | number of backups to retain |
| `OPENMAIC_RENDER_ENABLED` | `1` | whether to enable the video rendering container profile |
| `OPENMAIC_SHARED_PG` | `0` | connect to the shared aibox base PG (`1` enables: the CLI auto-writes an override + creates the openmaic database; see docs/DEVELOPMENT.md) |
| `OPENMAIC_BUILD_TIMEOUT_MAIN` | `3600` | main image build timeout (seconds) |
| `OPENMAIC_BUILD_TIMEOUT_RENDER` | `2400` | render image build timeout (seconds) |

The repo contains no site addresses; any host-specific values must be passed in explicitly this way.

## Layout

| Platform | Identity | Deployment root |
| --- | --- | --- |
| Linux | root | `/root/.aibox/apps/openmaic` |
| macOS | normal user | `~/.aibox/apps/openmaic` |

Both platforms share the expression `${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}/openmaic`,
**with no platform branching** — the convention is defined in the repo's `docs/module-spec.md` under "Deployment directory and config layout conventions".

- The config directory `/etc/openmaic` (written once, read daily) is deliberately separated from the deployment root (**written on every command**):
  the latter must live on a path that is "writable by the daily identity" and "shared by the container runtime by default" — otherwise even read-only commands like `status` would require privilege escalation, and compose's relative mounts would hit `Mounts denied`.
- **The deployment root is not placed under `/opt`**: on macOS, Docker Desktop does not share `/opt` by default (this is unrelated to sudo).
- When `HOME` cannot be resolved and no explicit value is given, the CLI **errors out and exits (`3`)** rather than producing a `/.aibox/...` path.

## Proxy

Deployment hosts often cannot reach GitHub directly, yet the "pull source code" step (`openmaic install` / `upgrade`) must go over the network. This proxy **usually needs no manual configuration**:

```bash
# On the deployment host (aibox already installed)
aibox proxy set http://10.0.0.2:7897           # configure once; aibox itself and module hooks both go through it
OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic
#   └─ the module hook automatically writes the proxy into OPENMAIC_PROXY_URL in /etc/openmaic/openmaic.conf
```

**Why it must be persisted to conf**: `openmaic upgrade` runs on the deployment host **without aibox present** — environment variables do not cross that boundary (across hosts, across time). Once written to conf, every subsequent source pull during upgrade uses it automatically.

You can also bypass aibox and edit `/etc/openmaic/openmaic.conf` directly:

```ini
OPENMAIC_PROXY_URL="http://10.0.0.2:7897"
```

Pulling source code is **multi-channel**; the proxy is only the first one:

1. Direct to GitHub via the proxy (attempted only when a proxy is configured)
2. Direct connection with no proxy
3. `ghproxy.net`
4. `gh-proxy.com`

So an unreachable proxy, or the proxy host being powered off, will **not stall an upgrade** — the public mirrors still back it up. The currently active proxy is visible in `openmaic doctor` (masked).

## Common commands

```bash
openmaic status / health / doctor       # overview, health check, environment self-check
openmaic up / down / restart / logs     # lifecycle
openmaic upgrade [--check] / rollback   # upgrade and rollback
openmaic backup [list|verify] / restore # backup and restore
openmaic config show|get|set|diff       # configuration management
openmaic models                         # model connectivity probing
openmaic powerlog                       # abnormal power-loss detection (journalctl)
openmaic install [--tag <tag>] / clean  # deploy from scratch / clean the deployment
openmaic completion bash                # completion script
```

Global options: `--json` / `--yes` / `--dry-run` / `--quiet` / `--no-color`.
Exit code tiers: `0` success, `1` runtime error, `2` usage error, `3` missing dependency, `4` pre-check failed, `10` failed-and-rolled-back, `20` needs human intervention, `30` not ready, `40` concurrency conflict, `50` user cancelled.

## Hook structure

| File | Purpose |
| --- | --- |
| `openmaic` | CLI itself (single-file bash, ~1500 lines) |
| `lib.sh` | shared: layout resolution, version reading, syntax check, `host_notice`, proxy dispatch (`sync_proxy_to_conf`) |
| `install.sh` | install |
| `uninstall.sh` | uninstall (deletes only the CLI itself) |
| `update.sh` | update (content comparison, idempotent) |
| `svc.sh` | action pass-through |
| `docker-compose.shared.yml` | compose override for connecting to the shared aibox base PG (reference copy; when `OPENMAIC_SHARED_PG=1`, the CLI auto-writes it to `$APP_DIR`) |

## Platform

Cross-platform: installation is copying a single file; the CLI is bash 3.2 compatible (uses fixed fds instead of bash 4's `exec {fd}>`). Service commands require docker (Docker Desktop on macOS / docker on Linux), with no OS restriction — read-only commands still work without docker.

## Standard actions

`aibox openmaic start|stop|restart|status|logs` — the shared lifecycle; `dashboard` is the
rich view (alias of `status`), and `doctor` is the standard diagnostic (deps, docker,
state, declared ports; see below).

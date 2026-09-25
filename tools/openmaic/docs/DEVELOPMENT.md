# openmaic Development Guide

> AI uses this guide to upgrade this module.

## upstream

- Homepage: <https://github.com/THU-MAIC/OpenMAIC>
- Docs: <https://github.com/THU-MAIC/OpenMAIC#readme>

## Installation

- aibox module: `aibox install openmaic` (installs the CLI to `~/.local/bin`, copies files cross-platform)
- upstream deployment: `openmaic install` (on the Linux deployment host, brings up OpenMAIC itself via docker compose)

## Testing

- Self-check: `openmaic doctor`
- Status: `openmaic status`
- Health: `openmaic health`

## Module Configuration

- Port: 3000/tcp:app (OpenMAIC http) — the postgres service has NO host port
  (internal to the compose network; shared mode uses the base PG), so it is not declared
- Credentials: `.env.local` (API Key, access password)
- Deployment target: app root `$AIBOX_HOME/apps/openmaic`; config `/etc/openmaic/openmaic.conf` (delivers `OPENMAIC_PROXY_URL` via proxy)
- Autostart: none resident (svc passes through to the CLI)
- Dependencies: docker + docker-compose + git (OS-agnostic, checked by `require_docker`; macOS Docker Desktop / Linux docker)
- Customization points: the CLI is the in-repo `tools/openmaic/cli/openmaic` (single-file bash, 3.2-compatible using fixed fd 9 instead of bash4 `exec {fd}>`)

## Upgrade Procedure

1. Check upstream latest version: `openmaic upgrade --check`
2. `aibox update openmaic` (updates the CLI copy) + `openmaic upgrade` (upgrades OpenMAIC itself on the deployment host)
3. Verify: `openmaic status` + `openmaic health`

## Connecting to the shared base PG (resource-saving, shared across modules)

openmaic's DB connection lives in `.env.local` (`DATABASE_URL=postgres://openmaic:...`). Connecting to the shared base PG
is **CLI-driven** (enabled by `OPENMAIC_SHARED_PG=1`); no manual edits to the upstream compose are needed anymore:

1. Start the shared base: `aibox base start` — the live PG port + container name come from
   **`aibox dashboard base`** (default profile: 35432 / `aibox-base-postgres`; named profiles
   derive both)
2. Enable shared mode: write `OPENMAIC_SHARED_PG=1` to `/etc/openmaic/openmaic.conf`
   (or temporarily `OPENMAIC_SHARED_PG=1 openmaic install`)
3. `openmaic install` — the CLI automatically:
   - Writes `docker-compose.shared.yml` to `$APP_DIR` (generated idempotently inside `apply_local_patches`)
   - `compose()` calls automatically append this override via `-f` (applies to up/install/upgrade/backup, etc.)
   - If `aibox-base-postgres` is running, runs `CREATE DATABASE openmaic` (idempotent; if not running, prompts but does not block)
   - The override uses `environment: DATABASE_URL=postgres://aibox:aibox@aibox-base-postgres:5432/openmaic`
     to override `DATABASE_URL` from `.env.local` (environment takes precedence over env_file), and adds the `aibox-base`
     network to the `openmaic` service; the `postgres` service sets `replicas: 0` so the local PG does not start
4. `.env.local` still must exist (holds `PERSISTENCE_DEV_TOKEN`, `QWEN_API_KEY`, `ACCESS_CODE`, etc.); its `DATABASE_URL`
   is simply overridden by the override — no need to change it.

**Manual activation** (without conf): copy `tools/openmaic/docker-compose.shared.yml` to
`$APP_DIR/docker-compose.shared.yml`; the CLI detects the file and activates it (`shared_pg_active` is determined by the file's presence).

**Downgrade** (back to a standalone PG): set `OPENMAIC_SHARED_PG=0` then `openmaic up` (the CLI deletes the override),
or manually delete `$APP_DIR/docker-compose.shared.yml`.

`openmaic doctor` checks, under shared mode, that the `aibox-base-postgres` container is running + the override is in place;
`openmaic backup/restore/db`, under shared mode, go through `docker exec aibox-base-postgres pg_dump/psql` (no longer looks up the local postgres).

### Existing Data Migration (standalone PG → shared PG)

1. `openmaic backup` (pg_dump the standalone PG)
2. `aibox base start` + `aibox base create postgres openmaic` (or `OPENMAIC_SHARED_PG=1 openmaic install` creates it automatically)
3. Restore: `gunzip -c <backup> | docker exec -i aibox-base-postgres psql -U aibox -d openmaic`
   (equivalent to `openmaic restore <backup>` after switching to shared mode)
4. `OPENMAIC_SHARED_PG=1 openmaic up` + verify data

**Downgrade**: `OPENMAIC_SHARED_PG=0` + delete the override + `openmaic up` to bring up the standalone PG.

> Note: the upstream compose is bundled with the OpenMAIC source (git clone); this module **does not modify upstream files** — the shared PG
> relies entirely on the CLI-generated override layered on top (`docker compose -f docker-compose.yml -f docker-compose.shared.yml`);
> downgrading is as simple as deleting the override, clean and reversible. The override file `tools/openmaic/docker-compose.shared.yml` is
> an in-repo reference copy whose content matches the CLI `_shared_override_write` heredoc (change one and sync the other).

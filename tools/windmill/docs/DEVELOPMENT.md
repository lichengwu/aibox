# windmill Development Guide

> AI uses this guide to upgrade this module.

## upstream

- Homepage: <https://github.com/windmill-labs/windmill>
- Docs: <https://www.windmill.dev/docs/>

## Installation

- aibox module: `aibox install windmill` (installs the CLI)
- upstream deployment: `windmill init --version <ver>` (brings up Windmill itself via docker compose)

## Testing

- Self-check: `windmill doctor`
- Status: `windmill status`
- Credentials: `windmill credentials`

## Module Configuration

- Port: 8080/tcp:http (overridable via `WM_HTTP_PORT` / `init --port`)
- Credentials: `CREDENTIALS.txt` + `.env` (POSTGRES_PASSWORD, admin password)
- Deployment target: app root `$AIBOX_HOME/apps/windmill`; config `/etc/windmill/windmill.conf`
- Autostart: mac launchd (backup/update-check timer, `cmd_launchd`) / linux systemd (`cmd_systemd`)
- Dependencies: docker + docker-compose + python3
- Customization points: the CLI is the in-repo `tools/windmill/cli/windmill` (single-file bash, 3.2-compatible); has a Darwin platform branch (hostname/flock fallback)

## Upgrade Procedure

1. Check upstream latest version: `windmill check` (exit code 10 = a new version is available)
2. `aibox update windmill` (updates the CLI copy) + `windmill upgrade <ver>` (upgrades the deployment)
3. Verify: `windmill status` + `windmill doctor`

## Connecting to the shared base PG (resource-saving, shared across modules)

The windmill compose db service has been changed to `replicas: 0 (hardcoded, connects to the shared PG, db does not start)` (controlled by .env).
Configuration flow for connecting to the shared aibox base PG (avoiding a standalone PG per module):

1. Start the shared base: `aibox base start` (PG 35432)
2. Create the database: `aibox base createdb windmill`
3. Configure windmill `.env`:
   - `DB_REPLICAS=0` (do not start the local db)
   - `DATABASE_URL=postgres://aibox:aibox@aibox-base-postgres:5432/windmill` (container connects to the shared PG service name via the aibox-base network)
4. Add network to compose: add `networks: [default, aibox-base]` to services, and add a `networks:` block at the bottom containing `aibox-base: external: true`
5. depends_on db: when `DB_REPLICAS=0` the db does not start; change the `depends_on` condition to `service_started` or remove it via a compose override

### Existing Data Migration (standalone PG → shared PG)

1. `windmill backup` (pg_dumpall the standalone cluster)
2. `aibox base start` + `aibox base createdb windmill`
3. Restore: `cat cluster.sql | docker exec -i aibox-base-postgres psql -U aibox`
4. Edit `.env` (DB_REPLICAS=0 + shared DATABASE_URL) + `windmill up`
5. Verify: `windmill status` + data is readable/writable

**Downgrade**: set `.env` DB_REPLICAS=1 + DATABASE_URL back to local, `windmill up` to bring up the standalone PG.

> Note: the network + depends_on changes in the compose heredoc (services networks field + 4 depends_on spots + network block) are a sizable change; spec §5.6 recommends iterating existing-data migration separately. The db replicas change is already in place (minimal and controllable); see above for the rest of the configuration.

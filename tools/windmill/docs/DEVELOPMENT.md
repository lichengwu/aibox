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

- Port: **8080/tcp:http** — built-in default and the `module.yaml` declaration agree (it was `80` in code but documented as `8080` before 0.16; existing deploys keep the port pinned in their `.env`). Overridable via the host conf `HTTP_PORT`, the env var, or `init --port`.
- Credentials: `CREDENTIALS.txt` + `.env` (POSTGRES_PASSWORD, admin password)
- Deployment target: app root `$AIBOX_HOME/apps/windmill`; config `/etc/windmill/windmill.conf`
- Autostart: mac launchd (backup/update-check timer, `cmd_launchd`) / linux systemd (`cmd_systemd`)
- Dependencies: docker + docker-compose + python3
- Customization points: the CLI is the in-repo `tools/windmill/cli/windmill` (single-file bash, 3.2-compatible); has a Darwin platform branch (hostname/flock fallback)

### Knob plumbing (how a conf change reaches the running stack)

The conf is host-level and read-only to the CLI; the generated `docker-compose.yml`/
`Caddyfile`/`.env` are render artifacts and any hand edit is lost at the next render.
So the flow is deliberate:

1. `wm_conf_load` whitelists the key (unknown keys are ignored on purpose).
2. `render_env` (init) writes the resolved value into `.env` — the file compose
   interpolates from (`_compose ... --env-file`).
3. `sync_env_knobs` (called by `up` and `deploy`) refreshes **only the knob lines**,
   never `WM_IMAGE`/`WM_EXTRA_IMAGE`/`POSTGRES_PASSWORD` (re-rendering `.env` would
   rotate the DB password).
4. The compose heredoc stays a QUOTED heredoc so `${...:-default}` reaches compose
   verbatim — turning it into an expanding heredoc would freeze the values and break
   the “edit `.env` then `up`” workflow.
5. Things compose cannot express conditionally (the `443:443` publish, `tls internal`)
   are decided at render time via a marker line (`##__TLS_PORTS__` / `##__TLS_INTERNAL__`)
   replaced or dropped by `awk` — hence `sync_env_knobs` warns when only the scheme
   changed and a `deploy --recreate` is needed.
6. `KEEP` is baked into `windmill-backup.service` at `systemd install` time (systemd
   has no HOME-derived config, so the value must be literal); re-run
   `windmill systemd install` after changing it.

## Upgrade Procedure

1. Check upstream latest version: `windmill check` (exit code 10 = a new version is available)
2. `aibox update windmill` (updates the CLI copy) + `windmill upgrade <ver>` (upgrades the deployment)
3. Verify: `windmill status` + `windmill doctor`

## Connecting to the shared base PG (resource-saving, shared across modules)

The windmill compose db service has been changed to `replicas: 0 (hardcoded, connects to the shared PG, db does not start)` (controlled by .env).
Configuration flow for connecting to the shared aibox base PG (avoiding a standalone PG per module):

1. Start the shared base: `aibox base start` (PG 35432)
2. Create the database: `aibox base create postgres windmill`
3. Configure windmill `.env`:
   - `DB_REPLICAS=0` (do not start the local db)
   - `DATABASE_URL=postgres://aibox:aibox@aibox-base-postgres:5432/windmill` (container connects to the shared PG service name via the aibox-base network)
4. Add network to compose: add `networks: [default, aibox-base]` to services, and add a `networks:` block at the bottom containing `aibox-base: external: true`
5. depends_on db: when `DB_REPLICAS=0` the db does not start; change the `depends_on` condition to `service_started` or remove it via a compose override

### Existing Data Migration (standalone PG → shared PG)

1. `windmill backup` (pg_dumpall the standalone cluster)
2. `aibox base start` + `aibox base create postgres windmill`
3. Restore: `cat cluster.sql | docker exec -i aibox-base-postgres psql -U aibox`
4. Edit `.env` (DB_REPLICAS=0 + shared DATABASE_URL) + `windmill up`
5. Verify: `windmill status` + data is readable/writable

**Downgrade**: set `.env` DB_REPLICAS=1 + DATABASE_URL back to local, `windmill up` to bring up the standalone PG.

> Note: the network + depends_on changes in the compose heredoc (services networks field + 4 depends_on spots + network block) are a sizable change; spec §5.6 recommends iterating existing-data migration separately. The db replicas change is already in place (minimal and controllable); see above for the rest of the configuration.

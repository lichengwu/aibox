# base

> Shared base components (PostgreSQL 18 + Redis 7) — deploy-type modules connect to a single shared instance and get their own database, instead of each running its own PG/Redis.

`base` is a **provider** module: it brings up one shared PostgreSQL + Redis stack (docker compose) and publishes the connection info to `$AIBOX_HOME/base.env`, which consuming modules inject via compose `--env-file`. Other modules declare `services: [base:postgres#<db>]` in their `module.yaml`, and `aibox install` auto-starts base + creates the `<db>` for them.

## Commands

```text
aibox install base              place docker-compose.yml at the deploy root
aibox base start                bring up shared PG/Redis (writes base.env)
aibox base stop                 stop (data volumes retained)
aibox base restart              stop + start (re-writes base.env)
aibox base status               compose ps + PG/Redis endpoints
aibox base create postgres <module> [usage]   create the <module>[_<usage>] database (idempotent)
```

## How it works

```
aibox base start
  ├─ docker compose up -d   →  aibox-base-postgres (PG 18) + aibox-base-redis (Redis 7)
  │                            network: aibox-base   (consuming modules join it by service name)
  └─ write $AIBOX_HOME/base.env   (instance-level connection info, container-perspective)

consuming module's compose (--env-file base.env)
  └─ DATABASE_URL / REDIS_URL  built from AIBOX_POSTGRES_* / AIBOX_REDIS_* → connects to the shared instance
```

- **`base.env` is the single source of connection info** — host (container service name `aibox-base-postgres`/`aibox-base-redis`), internal ports (5432/6379), user, password. Consuming modules read it via compose `--env-file`; they never hardcode `aibox:aibox@`.
- **DB naming**: `<module>` (single DB) or `<module>_<usage>` (multiple). The prefix avoids cross-module clashes. `aibox base create postgres windmill` / `aibox base create postgres openmaic backup` (→ `openmaic_backup`).
- **Data volumes** are retained on `stop`/`uninstall` — they outlast the manager. They carry **explicit names** (`aibox_pg_data`, `aibox_redis_data`) so they're deterministic regardless of the deploy dir / compose project name. To clear: `docker volume rm aibox_pg_data aibox_redis_data`.
  > **Migrating from a pre-explicit-naming deploy?** Your data lives in `base_pg_data` / `base_redis_data` (named after the deploy dir by compose's implicit project prefix). Copy it over before `aibox base restart`:
  > `docker run --rm -v base_pg_data:/from -v aibox_pg_data:/to alpine cp -a /from/. /to/` (same for the redis pair). The old volumes are left untouched — remove them once verified.

## Configuration (env overrides)

| Variable | Default | Notes |
| --- | --- | --- |
| `AIBOX_BASE_POSTGRES_PORT` | `35432` | host-side PG port (container uses 5432 internally) |
| `AIBOX_BASE_POSTGRES_USER` | `aibox` | PG superuser |
| `AIBOX_BASE_POSTGRES_PASSWORD` | `aibox` | loopback-default; override before binding to a non-loopback interface |
| `AIBOX_BASE_REDIS_PORT` | `36379` | host-side Redis port |

## Files & state

| Path | What |
| --- | --- |
| `$AIBOX_HOME/apps/base/docker-compose.yml` | the compose file (copied from the module) |
| `$AIBOX_HOME/base.env` | connection info for consuming modules (written by `base start`) |

## For module authors (consuming base)

In your `module.yaml`:

```yaml
services:
  - base:postgres#<your-module>        # aibox install auto-starts base + creates <your-module> DB
  - base:redis                          # (if you need Redis)
```

In your compose, read the connection info from the injected env (do **not** hardcode `aibox:aibox@`):

```yaml
environment:
  - DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@aibox-base-postgres:${AIBOX_POSTGRES_PORT}/<your-module>
networks:
  - default
  - aibox-base          # external: true (the base network)
```

See `docs/module-spec.md` (the `services` / shared-component contract) and the [`windmill`](../windmill/) / [`openmaic`](../openmaic/) modules for working examples.

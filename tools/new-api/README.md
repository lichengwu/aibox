# new-api

New API self-hosted (docker compose): LLM API gateway (OpenAI-compatible relay, key/quota management, usage analytics)

Upstream: [QuantumNous/new-api](https://github.com/QuantumNous/new-api) · docs: <https://docs.newapi.dev/>

## Commands

```text
aibox install new-api
aibox new-api start|stop|restart|status|logs|credentials
aibox new-api dashboard          # endpoint + health
aibox update new-api [--restart|--no-restart]
aibox upgrade new-api [--check]  # float to a newer upstream image tag
aibox uninstall new-api [--purge]
```

First login: **root / 123456** — change it immediately (top-right user → personal settings).

## How it works

Single docker container (`aibox-new-api`, image `calciumion/new-api`, pinned to the
latest stable tag `v0.13.2`) publishing `http://127.0.0.1:30300` (upstream's
default 3000 collides with the openmaic module — this repo's port registry uses
30300). Data lives in two named volumes: `aibox_new_api_data` (app data),
`aibox_new_api_logs` (via upstream's `--log-dir /app/logs`).

**Requires the shared base** (`module.yaml services:`): `aibox install new-api`
auto-starts base and creates the `new_api` database; the container joins the
external `aibox-base` network and connects PG/Redis from `base.env`
(`SQL_DSN=postgresql://…/new_api`, `REDIS_CONN_STRING=redis://…` — the base's
redis has no password). Deploy root: `$AIBOX_HOME/apps/new-api` (compose + `.env`).

Image pulls go through the docker.io **source pool** (concurrent mirror
speed-ranking + failover when the daemon's direct route is dead — see
`docs/module-spec.md` §Download source pools).

## Configuration (env overrides)

Deploy `.env` (`$AIBOX_HOME/apps/new-api/.env`, written once by install, mode 600):

| Var | Default | Meaning |
| --- | --- | --- |
| `NEW_API_PORT` | `30300` | host port (container listens on 3000 internally) |
| `NEW_API_IMAGE` | `calciumion/new-api:v0.13.2` | image tag; `aibox upgrade new-api` floats it |
| `NODE_NAME` | `aibox-new-api` | audit-log node identity |
| `SESSION_SECRET` | generated | session signing (pinned once; multi-node requires a shared value) |
| `TZ` | `Asia/Shanghai` | timezone |
| `NEW_API_START_TIMEOUT` | `120` | seconds svc waits for `/api/status` |
| `NEW_API_LOG_TAIL` | `200` | `logs` tail lines |

Pool knobs (docker.io mirror failover): `AIBOX_DOCKER_POOL` / `AIBOX_DOCKER_MIRROR` /
`AIBOX_DOCKER_FORCE_POOL` — see `docs/module-spec.md` §Download source pools.

## Preflight

Declared in `module.yaml` `checks:` — enforced by `aibox install/update`
(see `docs/module-spec.md` §Preflight checks). Re-run manually:

```text
aibox check new-api
```

- `disk_gb: 2` — image + volumes floor
- `docker_images: calciumion/new-api:v0.13.2` — all-cached short-circuit (no
  network probes when the image is already local; pulls are daemon-routed,
  mirrored by the pool when direct is dead)

## Upgrade

`aibox upgrade new-api --check` resolves the newest tag matching
`^v\d+\.\d+\.\d+(-rc\.\d+)?$` from docker hub (includes the active `v1.0.0-rc`
line — visible to `--check`, pinnable via `--to`; the cross-major guardrail
refuses auto-jumping 0.13.x → 1.0.0-rc). Auto-rollback on failed health check.

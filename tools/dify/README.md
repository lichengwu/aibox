# dify

[Dify](https://github.com/langgenius/dify) self-hosted (docker compose): LLM app
builder — api / worker / web / nginx, with the default weaviate vector store.
Pinned to dify **v1.17.1**.

## Commands

```text
aibox install dify                # place compose + templates, write deploy .env (generates secrets)
aibox dify start                  # docker compose up -d + boot-wait (first boot 1-2 min)
aibox dify stop|restart|status|logs
aibox dify credentials            # show the admin first-visit password (INIT_PASSWORD) + SECRET_KEY
aibox update dify [--restart]     # refresh module scripts (compose/templates) — version stays on the floor
aibox upgrade dify [--check] [--to <ver>] [--yes]
                                  # bump the deployed dify VERSION without an aibox release (see below)
aibox uninstall dify [--purge]    # default: stop + remove program files (data kept); --purge: also wipe volumes
aibox check dify                  # run the preflight (docker pull, disk, images)
aibox dashboard dify              # version + endpoint + health
```

## How it works

A curated single-file `docker-compose.yml` (NOT dify's auto-generated one) is
placed into `$AIBOX_HOME/apps/dify` by the install hook. It runs the **core**
services dify needs out of the box:

| service | image | role |
| --- | --- | --- |
| `init_permissions` | busybox | one-shot chown of the storage volume |
| `db_postgres` | postgres:15-alpine | bundled metadata DB (dify) |
| `redis` | redis:6-alpine | bundled cache + celery broker |
| `sandbox` | langgenius/dify-sandbox:0.2.15 | code execution (egress via ssrf_proxy) |
| `ssrf_proxy` | ubuntu/squid | SSRF forward proxy (vendored squid templates) |
| `plugin_daemon` | langgenius/dify-plugin-daemon:0.6.10-local | dify 1.x plugin system |
| `agent_backend` | langgenius/dify-agent-backend:1.17.1 | agent runtime backend |
| `api` / `api_websocket` / `worker` / `worker_beat` | langgenius/dify-api:1.17.1 | API + celery worker + beat |
| `web` | langgenius/dify-web:1.17.1 | Next.js frontend |
| `nginx` | nginx:latest | entry reverse proxy (vendored envsubst templates) |
| `weaviate` | cr.weaviate.io/semitechnologies/weaviate:1.39.2 | default vector store |

The `nginx/` and `ssrf_proxy/` config templates are **vendored verbatim** from
dify v1.17.1's `docker/` tree — their entrypoint scripts run `envsubst`/`awk`
*inside the containers* (aibox never sources them). Data uses **named volumes**
(`dify_storage`, `dify_db`, `dify_redis`, `dify_sandbox_deps`,
`dify_sandbox_conf`, `dify_plugin_daemon`, `dify_weaviate`).

**Default port**: `8088` (dify upstream defaults to `80`, which collides with
the `windmill` module in this repo). Override with `DIFY_WEB_PORT` (NOT `DIFY_PORT` — upstream's DIFY_PORT is the api listen port).

## Upgrades (version floats, independent of aibox releases)

`aibox update dify` refreshes the module's own files and keeps the **install floor**
(repo-pinned 1.17.1). `aibox upgrade dify` bumps the **live version** in the deploy
`.env` without waiting for an aibox release:

```text
aibox upgrade dify --check        # dry run: current vs latest upstream release
aibox upgrade dify                # same-major auto-latest: pull → rewrite .env → recreate → health-wait
aibox upgrade dify --to 1.18.0    # pin explicitly (also the cross-major escape hatch)
```

The engine resolves the target from dify's GitHub releases, then fetches dify's own
`docker-compose.yaml` **at the target tag** and extracts the paired image tags for
api / web / sandbox / plugin-daemon / agent-backend — the pairing always matches what
the target release ships (never guessed). DB/Redis/weaviate stay on the floor (data
compatibility — bump them manually in `.env` only if you know what you're doing).
Auto-latest refuses to cross a major; `--to` is required for e.g. 1.x → 2.x.

Failed health check → automatic rollback to the previous `.env` backup (exit 20).
Old images remain on disk — reclaim with `docker image prune`.

## Configuration (env overrides)

All tunables live in the deploy `.env` at `$AIBOX_HOME/apps/dify/.env` (mode
600, written once by `aibox install dify`, never clobbered on update). Edit it,
then `aibox dify restart`. Highlights:

| var | default | meaning |
| --- | --- | --- |
| `DIFY_PORT` / `EXPOSE_NGINX_PORT` | 8088 | host web port |
| `SECRET_KEY` | auto-generated (hex 32) | session-cookie signing |
| `INIT_PASSWORD` | auto-generated (24 chars) | admin first-visit password (see `aibox dify credentials`) |
| `DIFY_API_IMAGE` (and `_WEB`/`_SANDBOX`/`_PLUGIN_DAEMON`/`_AGENT_BACKEND`/`DB_IMAGE`/`REDIS_IMAGE`/`WEAVIATE_IMAGE`) | pinned 1.17.1 tags | image tags (bump on update) |
| `DB_*` / `REDIS_*` | bundled creds `difyai123456` | standalone-mode DB/Redis connection |
| `MIGRATION_ENABLED` | true | api runs alembic migrations on boot |
| `VECTOR_STORE` | weaviate | vector store selection |
| `DIFY_SHARED_BASE` | 0 | 1 = use the aibox shared base PG18/Redis7 (see below) |
| `NGINX_HTTPS_ENABLED` | false | enable HTTPS (needs manual cert setup) |
| `SSRF_PROXY_ALLOW_PRIVATE_IPS` | (empty) | CIDRs the SSRF proxy may reach despite deny-private |

## Shared base (optional — saves resources)

Instead of the bundled PG/Redis, point dify at the aibox shared base:

```text
aibox base start
aibox base create postgres dify           # dify api/worker DB
aibox base create postgres dify_plugin     # plugin_daemon DB
# then set DIFY_SHARED_BASE=1 in $AIBOX_HOME/apps/dify/.env
aibox dify restart
```

`svc.sh` detects `DIFY_SHARED_BASE=1` and invokes compose with both
`-f docker-compose.yml -f docker-compose.shared.yml --env-file base.env`. The
override sets the bundled `db_postgres`/`redis` to `replicas: 0` and remaps
`DB_*`/`REDIS_*` at the base containers.

> **Caveat**: dify upstream ships `postgres:15-alpine` / `redis:6-alpine`; the
> shared base provides `postgres:18` / `redis:7`. This opt-in mode is NOT in
> dify's official test matrix — fall back to standalone (`DIFY_SHARED_BASE=0`)
> if migrations/redis semantics misbehave. The base redis has **no password**,
> so the override forces `REDIS_PASSWORD` empty (dify's client sends AUTH by
> default, which a no-auth redis rejects).

## Docker image source pool

The compose images are pulled through the docker.io **source pool** (main
README → "Download source pools"): at start a bounded direct daemon-route
probe runs — healthy networks pull directly with zero overhead; when the
direct route is dead, mirrors (docker.1ms.run, docker.m.daocloud.io,
dockerproxy.net, hub.rat.dev — live-verified) are ranked by concurrent probe
pulls and the images are pre-pulled via `docker pull <mirror>/<image>` +
`docker tag` (mirrors proxy identical digests), so `compose up` finds them
cached.

| Variable | Default | Description |
| --- | --- | --- |
| `AIBOX_DOCKER_POOL` | shipped pool | mirror list override (`direct` = no pool) |
| `AIBOX_DOCKER_MIRROR` | (unset) | your mirror — joins the race first |
| `AIBOX_DOCKER_FORCE_POOL` | `0` | `1` = skip the direct probe, always engage |

Images on OTHER registries (the `cr.weaviate.io` vector store) stay
direct-only — no mainstream mirror proxies them.

## Preflight

Declared in `module.yaml` `checks:` — enforced by `aibox install/update`. All
images are pulled by the docker **daemon** (its egress differs from the host's),
so connectivity is probed daemon-routed via `docker_pull: hello-world`; when
every `docker_images` entry is already cached, the probe is skipped (offline
restarts pass). There are no host-curl consumers, so no `domains:`. Disk floor:
10 GB.

```text
aibox check dify
```

## What's intentionally NOT included

The curated compose omits dify's optional components to keep the default stack
manageable — extend manually if needed (see `docs/DEVELOPMENT.md`):

- the 20+ alternative vector stores (qdrant/milvus/pgvector/…) — only weaviate ships by default
- the agent `local_sandbox` shell workspace + `agent_ssrf_proxy`
- `certbot` (HTTPS is an opt-in manual cert setup)
- `db_mysql`, `tidb`, `elasticsearch`, `opensearch`, `oracle`, …

To switch vector store: drop the `weaviate` service, set `VECTOR_STORE`, and add
the matching service + env (model the block on dify's upstream compose).

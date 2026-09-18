# dify — development notes

- Upstream: <https://github.com/langgenius/dify>
- Docs: <https://docs.dify.ai/>
- Version pinned: **1.17.1** (api/web/agent-backend images share the tag;
  sandbox `0.2.15` and plugin-daemon `0.6.10-local` have independent tags —
  match them to the upstream v1.17.1 release's `docker/docker-compose.yaml`).

## Design decisions

### Curated compose, not the auto-generated one

dify's `docker/docker-compose.yaml` is **auto-generated** by
`generate_docker_compose` from `docker-compose-template.yaml` + `.env.example`,
and it depends on the `docker/envs/**/*.env.example` tree (≈30 files) synced to
`.env` files at runtime (`required: false` in compose → skipped if absent). It
also `env_file:`-includes those; running it without the `envs/` tree means
≈50 operational defaults (e.g. `CELERY_BROKER_URL`, `MIGRATION_ENABLED`,
locale, `SSRF_PROXY_*`, `DEPLOY_ENV`) come only from code defaults — fragile.

This module ships a **curated single-file** `docker-compose.yml` (core services
- weaviate, named volumes) that instead puts all operational defaults directly
into the deploy `.env` (ported verbatim from the upstream `envs/*.env.example`
at v1.17.1). The compose references them via `${VAR:-default}`. This matches
the aibox idiom (`gitlab`/`base`/`openmaic`/`windmill` all ship curated
composes, not upstream's verbatim) and keeps the module self-contained.

### Vendored config templates (verbatim)

The `nginx/` (5 files) and `ssrf_proxy/` (3 files) directories are copied
**byte-identical** from dify v1.17.1's `docker/` tree. They carry real config
logic: the nginx `docker-entrypoint.sh` does `envsubst` on the templates
(`NGINX_*` → `nginx.conf`/`proxy.conf`/`default.conf`, with HTTPS/certbot
conditional assembly); the squid `docker-entrypoint.sh` builds `squid.conf` via
`awk` and generates the private-IP/domain allowlists from
`SSRF_PROXY_ALLOW_PRIVATE_*`. Re-authoring these is high-risk; vendoring them
verbatim preserves upstream behavior. **aibox never sources these files** —
they are bind-mounted into the containers and run there.

### Named volumes, not `./volumes/` binds

dify upstream bind-mounts `./volumes/app/storage`, `./volumes/db/data`, etc.
(relative to the compose dir). This module uses **named volumes** with explicit
`name:` (`dify_storage`, `dify_db`, …) — matching the `base` module convention
and giving clean, deterministic names for the residue map. The deploy root
(`$AIBOX_HOME/apps/dify`, under `~/.aibox` → `/Users` on macOS) is in Docker
Desktop's default share list, so the `nginx/`+`ssrf_proxy/` config-template
**binds** work fine; only data uses named volumes.

### Port 8088

dify upstream defaults to `:80`; the `windmill` module already owns `:80` in
this repo (CI detects cross-module port conflicts). Default to **8088**,
overridable via `DIFY_PORT` (writes both `EXPOSE_NGINX_PORT` and `DIFY_PORT`
in the deploy `.env`; nginx still listens internally on `NGINX_PORT=80`).

### Shared-base mode (opt-in)

`docker-compose.shared.yml` (modeled on `tools/openmaic/docker-compose.shared.yml`)
switches the bundled PG/Redis to the aibox shared base: sets `db_postgres` +
`redis` to `deploy.replicas: 0`, joins the dify services to the external
`aiboxbasenet`, and remaps `DB_*`/`REDIS_*` from the `base.env` vars (injected
via compose `--env-file`). The `svc.sh` `compose()` wrapper detects
`DIFY_SHARED_BASE=1` and adds the override + `base.env` automatically.

**Two empirical constraints baked into the override:**

1. **base redis has no password** — `tools/base/docker-compose.yml`'s redis:7
   does not run `--requirepass`. dify's redis client sends `AUTH` by default,
   which a no-auth redis rejects (`ERR Client sent AUTH, but no password is
   set`). The override forces `REDIS_PASSWORD=` empty and builds
   `CELERY_BROKER_URL`/`DIFY_AGENT_REDIS_URL` **without** the `:pw@` segment.
2. **DB pre-creation** — dify does not `CREATE DATABASE`; it expects `dify` and
   `dify_plugin` to pre-exist. Shared-mode onboarding must run
   `aibox base create postgres dify` + `aibox base create postgres dify_plugin`.

### Version skew (PG15→18, Redis6→7)

dify upstream ships `postgres:15-alpine` / `redis:6-alpine`. The shared base
provides `postgres:18` / `redis:7`. Standalone mode (default) is faithful to
upstream; shared-base mode trades per-module resources for sharing but is NOT
in dify's official test matrix. The override documents this; users fall back to
standalone if migrations or redis semantics misbehave.

## Upgrade / rollback

**Two verbs, two concerns** (`docs/module-spec.md` §Component upgrades):

- `aibox update dify` — refreshes module files; version stays on the **install floor**
  (repo-pinned, tested, reproducible fresh installs).
- `aibox upgrade dify` — floats the **live version** in the deploy `.env`, independent
  of aibox releases. The manager engine is data-driven from the module.yaml `upgrade:`
  stanza (github-release resolver + `mapping_url` = upstream compose at `<VER>`); the
  engine locates the deploy `.env` via this module's `lib.sh deploy_root()`, rewrites
  ONLY the 5 declared image keys, and recreates via `svc.sh start` (health-wait +
  auto-rollback). Compose consumes the keys via `image: ${DIFY_*_IMAGE:-floor}` —
  the same interpolation gitlab uses for `GITLAB_IMAGE`.

**Repo changes for a floor bump** (aibox release): update the image tags in `lib.sh`
`DEFAULT_*_IMAGE` constants AND `docker-compose.yml` `${VAR:-tag}` defaults AND
`module.yaml` `checks.docker_images` AND this file's "Version pinned" line. Re-vendor
`nginx/`+`ssrf_proxy/` from the new dify tag if upstream changed them
(`diff` against the previous copies first). — `aibox update dify --restart` refreshes
the deployed files and recreates containers. dify api runs alembic migrations on boot
(`MIGRATION_ENABLED=true`); a major dify upgrade may need a manual migration step —
see upstream release notes.
Rollback: `aibox upgrade dify --to <old>` (the engine keeps `.env.bak.<ts>` backups),
or revert the floor tags and `aibox update dify --restart`. Data volumes are
preserved across recreate.

## Known quirks

- **First boot**: api runs migrations + the plugin daemon initializes its
  python env; the web UI is not answering for 1–2 min. `start`/`restart` poll
  `http_up` (nginx `/` → 200/302/307) with `DIFY_START_TIMEOUT` (default 300s).
- **`agent_backend` is core**: upstream gives it no `profile`, and
  `api`/`worker` `depends_on` it — so it's always started. The
  `local_sandbox`+`agent_ssrf_proxy` shell-workspace feature is omitted (opt-in
  advanced); `agent_backend` still runs with `DIFY_AGENT_RUNTIME_BACKEND=local`.
- **`api_websocket` kept by default**: the vendored nginx routes `/socket.io/`
  to `NGINX_SOCKET_IO_UPSTREAM=api_websocket:5001`; dropping the websocket
  service requires also setting that var to `api:5001` (collaboration off).
- **HTTPS**: `NGINX_HTTPS_ENABLED=false` by default. Enabling HTTPS needs
  manual cert placement under `nginx/ssl/` (+ certbot binds if using Let's
  Encrypt) — not automated by this module.
- **shellcheck on vendored files**: the validator's shellcheck scan is scoped to
  top-level `*.sh` (`"$d"/*.sh`); the vendored `nginx/docker-entrypoint.sh` and
  `ssrf_proxy/docker-entrypoint.sh` live in subdirs and are not scanned. They
  run inside containers anyway. (An SC2016 info on the awk `${...}` regex in
  `ssrf_proxy/docker-entrypoint.sh` is a known false positive — the `${}` is an
  awk/envsubst pattern literal, not a shell expansion.)

## Local testing

```bash
scripts/validate-module.sh dify      # conformance (same rules as CI)
bats tests/*.bats                    # port-conflict / residue / parse suite
# integration (docker + network): aibox check dify && aibox install dify &&
#   aibox dify start → status → logs → credentials → stop → uninstall
```

# jumpserver — development notes

## Upstream references

- App: https://github.com/jumpserver/jumpserver (v4.10.19-lts tag consulted)
- Installer (the compose source of truth): https://github.com/jumpserver/installer
  — the v4.10.19 release tarball (`jumpserver-installer-v4.10.19.tar.gz`) carries
  `compose/{core,celery,web,koko,lion,chen}.yml` + `config-example.txt` +
  `static.env` (`VERSION=v4.10.19-ce`). This module's compose is a faithful
  port of exactly those files.
- Docs: https://docs.jumpserver.org/ (参数说明 documents the env vars)

## Version-pin policy

- Pinned floor: **v4.10.19-ce** — the newest tag whose images are VERIFIED
  published on Docker Hub (checked via the Hub API on 2026-10-01: core/web/
  koko/lion/chen all have `v4.10.19-ce`, amd64+arm64). JumpServer v5.0.0 was
  released on GitHub (2026-09-17) but its core/web/koko/chen images were NOT
  on Docker Hub at onboarding time (only `jumpserver/kael:v5.0.0-ce` — kael is
  the new v5 component). When the v5 images land, `aibox upgrade jumpserver
  --to 5.0.0` floats the pin; note v5's community service set CHANGES (kael
  in; lion+magnus→xpack: razor) — the compose will need a module update then.
- All five images share one tag scheme (`v<x.y.z>-ce`), so `upgrade.images`
  lists all five with the `jumpserver/<svc>:v` prefix.
- Image sizes (compressed, amd64): core 296M, koko 229M, lion 141M, chen
  ~150M, web ~100M → ~1.4G total.

## Design decisions

- **Shared base instead of bundled PG/Redis.** Upstream's installer bundles
  `postgres:16.15` / `redis:7.4` (v5 default engine = postgresql, matching
  config-example `DB_ENGINE=postgresql`). This module consumes the aibox
  shared base (PG 18 / Redis 7) — the standard aibox tradeoff dify's
  shared-base mode makes. VERSION SKEW (upstream 16 vs base 18): Django
  4.2-era psycopg speaks the same wire protocol; verified live (migrations +
  boot + login on PG 18). If a future JumpServer hard-requires PG 16, bundling
  is the fallback (xiaozhi/MySQL precedent).
- **Redis: 4-wide slot range, allocated hook-side.** JumpServer uses four
  Redis logical DBs (`REDIS_DB_CELERY/CACHE/SESSION/WS`, upstream defaults
  3/4/5/6). The declarative `services: base:redis#jumpserver` would make the
  manager's ensure_services pre-allocate ONE slot (no slot-count syntax
  exists); the first allocation wins, so the module declares BARE
  `base:redis` (provider start gate only) and allocates the 4-wide range
  itself (`ensure_shared_redis_db jumpserver 4` — the dify 3-slot pattern).
  `svc start` then remaps the four DBs onto the range (`_redis_db_remap`
  exports `JUMPSERVER_REDIS_DB_*` for compose interpolation).
- **Ports.** Upstream publishes web:80 and koko ssh:2222. aibox reserved band:
  31200 (web), 31202 (ssh). lion/chen/koko-http stay container-internal
  (reached through the web nginx, like upstream). RDP via lion is proxied
  through the web console (websocket), so no extra host port.
- **restart: unless-stopped** (upstream `always` would resurrect
  `aibox jumpserver stop` after a docker daemon restart).
- **Bind mounts → named volumes** (spec §Deploy conventions); the `certs/`
  dir stays a bind mount under the deploy root (state_files: operator-owned
  TLS material).
- **docker.sock mount on core+celery** kept verbatim from upstream (some
  terminal/asset features exec through the host daemon; documented upstream
  behavior).
- **SECRET_KEY/BOOTSTRAP_TOKEN** generated at install (hex — no quote/URL
  metacharacters; JumpServer's own config warns passwords must not contain
  quotes) and NEVER rotated by aibox: data encrypted with a rotated
  SECRET_KEY is unreadable (upstream's migration note).
- **koko/lion/chen env**: upstream passes them a sanitized config
  (`config_safe.txt`) — the components need `CORE_HOST` + `BOOTSTRAP_TOKEN`
  (they register with core); DB/SECRET_KEY are core-only. This module inlines
  exactly those two.
- **celery privileged: true** and koko `privileged: true` kept verbatim
  (upstream ships both; terminal features need the wider syscall surface).

## Known quirks

- **First boot is slow** (measured ≈ 11 min on a 4-core arm64 host): Django
  migrations run inside core's healthcheck start_period (90s) — the module's
  health-wait (`JUMPSERVER_START_TIMEOUT`, default 900s) covers it.
- **Partial recreate ⇒ web 502s (nginx upstream DNS cache, measured live)**:
  `docker compose up -d` recreating only core/celery (e.g. a rotated
  SECRET_KEY) leaves the web nginx proxying to core's dead old IP — nginx
  resolves `proxy_pass http://core:8080` once at config load. The module's
  `restart` therefore does a FULL cycle (`down` WITHOUT `-v` — named data
  volumes survive a plain down — then `up`), matching upstream jmsctl's
  restart semantics (upstream can afford `down -v` because it uses bind
  mounts; this module's named volumes make `-v` a data-killer).
- **Default login `admin` / `ChangeMe`** is JumpServer's built-in: this module
  does NOT seed a custom admin password (upstream has no env for it; the
  installer leaves the default too). First login through the web UI hits
  JumpServer's `PasswordTooSimple` challenge (the SPA prompts the change);
  a RAW api login with the default password returns a confusing 500 — that is
  upstream's own error-handler bug (`PasswordTooSimple` has no `.detail`),
  not a deployment problem (measured live; verified: after `changepassword`
  the api login returns 201 + Bearer token). The reset recipe in
  `credentials` uses the v4 image path `/opt/jumpserver/.venv/bin/python`
  (v3 images used `/opt/jumpserver/py3/bin/python`).
- **`/api/health/` through the web nginx** is the module's health probe (it
  proves the full chain nginx→core); the web container's own healthcheck uses
  `/web/health/` (nginx-local) and core's uses `:8080/api/health/` directly.
- **DOMAINS/`JUMPSERVER_DOMAINS`**: JumpServer's trusted-host list; empty by
  default (no restriction). If you expose the console through a domain,
  set it (`config set JUMPSERVER_DOMAINS demo.example.com:31200`).
- **Web console behind a proxy**: `USE_LB=1` default (upstream) makes nginx
  trust `X-Forwarded-For $remote_addr`; flip `JUMPSERVER_USE_LB=0` in the
  deploy `.env` if real client IPs look wrong behind your LB.

## Test coverage

`tests/jumpserver.bats` — fully OFFLINE (fake-docker shim pattern from
tests/xiaozhi.bats): install idempotency (.env once, secrets hex + 600),
redis DB remap onto the allocated slot range, effective ports,
status_info/render_status fields, uninstall retention vs purge, the compose
contract (base network/env-file injection, no hardcoded credentials, upstream
healthchecks, named volumes). Live smoke: install → start → status → logs →
credentials → restart → stop → uninstall (docker host).

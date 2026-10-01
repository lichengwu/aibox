# jumpserver

JumpServer — the open-source bastion host / PAM (堡垒机): web console, SSH/web
terminal, RDP, database access + full session audit, deployed as upstream's
6-service community docker stack (core + celery + web + koko + lion + chen).

Upstream: [jumpserver/jumpserver](https://github.com/jumpserver/jumpserver) ·
docs: <https://docs.jumpserver.org/> ·
installer reference: [jumpserver/installer](https://github.com/jumpserver/installer) (v4.10.19)

## Commands

```text
aibox install jumpserver            # place compose + write .env + ensure shared base (does NOT start)
aibox jumpserver start              # pull + up + wait for api health (first boot runs migrations, 2-6 min)
aibox jumpserver stop|restart|status|logs
aibox jumpserver logs core          # per-service logs (core|celery|web|koko|lion|chen)
aibox jumpserver credentials        # default login + where the secrets live
aibox jumpserver config list        # env knobs (store: apps/jumpserver/.env)
aibox jumpserver doctor             # deps + docker + state + port listeners
aibox update jumpserver             # refresh compose; .env/certs never clobbered
aibox upgrade jumpserver [--check]  # float all five images to a newer v<ver>-ce tag
aibox uninstall jumpserver [--purge]
```

## First-run flow

1. `aibox install jumpserver` — places the compose, generates
   `SECRET_KEY` / `BOOTSTRAP_TOKEN` into the deploy `.env` (mode 600), and
   starts the shared base (PG database `jumpserver` + a 4-wide Redis logical-DB
   range are allocated).
2. `aibox jumpserver start` — pulls the five images (docker.io source pool),
   brings up all 6 containers, then health-waits
   (`http://127.0.0.1:<port>/api/health/` — core through the web nginx; the
   first boot runs Django migrations, measured ≈ 11 min).
3. Open **http://127.0.0.1:31200** — login `admin` / `ChangeMe`
   (JumpServer's built-in default; change it at first login).
4. SSH terminal access: `ssh -p 31202 admin@<host>` (koko).

## The stack (default profile)

Deploy root `$AIBOX_HOME/apps/jumpserver` (compose + `.env` + `certs/`);
`aibox status jumpserver` is the authoritative view of ports/versions.

| container | image | what |
| --- | --- | --- |
| `aibox-jumpserver-core` | `jumpserver/core:v4.10.19-ce` | Django web+api (**:8080** container-internal) |
| `aibox-jumpserver-celery` | same image | task workers (`start task`) |
| `aibox-jumpserver-web` | `jumpserver/web:v4.10.19-ce` | nginx frontend (**host :31200**) |
| `aibox-jumpserver-koko` | `jumpserver/koko:v4.10.19-ce` | ssh/web terminal (**host :31202** ssh) |
| `aibox-jumpserver-lion` | `jumpserver/lion:v4.10.19-ce` | RDP/guacamole (through the web nginx) |
| `aibox-jumpserver-chen` | `jumpserver/chen:v4.10.19-ce` | database audit (through the web nginx) |

**PostgreSQL + Redis come from the shared aibox base**: core/celery join the
external `aibox-base` network and read `AIBOX_POSTGRES_*` / `AIBOX_REDIS_*`
from `base.env` (compose `--env-file`). Upstream bundles `postgres:16` /
`redis:7`; the shared base provides PG 18 / Redis 7 (skew documented in
`docs/DEVELOPMENT.md`). JumpServer's four Redis logical DBs
(celery/cache/session/ws) are remapped onto the module's 4-wide slot range at
start.

Data lives in named volumes
`aibox_jumpserver_{core,koko,lion,chen,nginx_logs}`; `certs/` (state) is
bind-mounted into the containers that want TLS material.

## Configuration (env overrides)

Deploy `.env` (`$AIBOX_HOME/apps/jumpserver/.env`, written once by install,
mode 600 — it holds the generated secrets):

| Var | Default | Meaning |
| --- | --- | --- |
| `JUMPSERVER_WEB_PORT` | `31200` | host web console port (container 80) |
| `JUMPSERVER_SSH_PORT` | `31202` | host SSH/SFTP terminal port (container 2222) |
| `JUMPSERVER_*_IMAGE` (5) | `jumpserver/<svc>:v4.10.19-ce` | image pins; `aibox upgrade` floats them |
| `JUMPSERVER_SECRET_KEY` | generated | Django SECRET_KEY — **keep when migrating data** |
| `JUMPSERVER_BOOTSTRAP_TOKEN` | generated | core↔component registration token |
| `JUMPSERVER_DOMAINS` | (empty) | trusted domains (`demo.example.com:31200`; JumpServer 安全设置) |
| `JUMPSERVER_START_TIMEOUT` | `900` | seconds svc waits for api health (first boot runs migrations, measured ≈ 11 min) |
| `JUMPSERVER_LOG_TAIL` | `200` | `logs` tail lines |

Pool knobs: `AIBOX_DOCKER_POOL` / `AIBOX_DOCKER_MIRROR` / `AIBOX_DOCKER_FORCE_POOL`
(docker.io family — the five jumpserver images).

## Resource floors

- **RAM ≥ 4 GB free** (Django + celery + 3 sidecars; upstream recommends 4C8G
  for production use).
- **Disk ≥ 12 GB free** (images ≈ 1.4 G compressed + recordings/audit growth —
  sessions/replay data grows with usage; move the audit storage to object
  storage in the console for large deployments) — enforced by `checks.disk_gb`.

## TLS

Upstream serves plain HTTP by default and expects a real reverse proxy for
TLS (see JumpServer's "安全设置 / HTTPS" docs). This module keeps that shape:
put your certificates in `apps/jumpserver/certs/` (never touched by aibox) if
a component needs them, and terminate TLS on your front proxy — set
`JUMPSERVER_DOMAINS` to the public address so the console renders it.

## Upgrades

- `aibox update jumpserver` — refreshes the module's own scripts; image pins
  in `.env` are never clobbered.
- `aibox upgrade jumpserver [--check]` — floats all five images to a newer
  stable `v<x.y.z>-ce` tag (Docker Hub resolver on `jumpserver/core`; rc/lts
  tag variants excluded). Cross-major (4→5) needs an explicit `--to`.
  Auto-rollback on failed health check; the shared-base `jumpserver` database
  is dumped first (`--no-backup` skips).

## Preflight

Declared in `module.yaml` `checks:` — enforced by `aibox install/update`
(see `docs/module-spec.md` §Preflight checks). Re-run manually:

```text
aibox check jumpserver
```

- `disk_gb: 12`
- `docker_images:` all-cached short-circuit (offline restart works without
  network probes)

## Diagnostics

`aibox jumpserver doctor` — declared deps, docker daemon reachability, the
module's own reported state (`status_info`) and its declared port listeners.
Shared implementation (`module_doctor`, `tools/_shared/common.sh`),
local-only: exit `0` healthy · `3` a dependency is missing · `30` the service
is not ready.

<!-- BEGIN GENERATED: actions (scripts/gen-docs.sh) -->
| action | what it does |
| --- | --- |
| `start` | Start the 6-service stack (source pool pulls; first boot runs migrations, ≈ 11 min) |
| `stop` | Stop the containers |
| `restart` | Recreate the containers (applies .env changes) |
| `status` | Containers + web health + rich view |
| `doctor` | Deep diagnostics: deps, docker, state, declared ports |
| `logs` | Container logs (per-service: aibox jumpserver logs core) |
| `credentials` | Default admin login + where SECRET_KEY/BOOTSTRAP_TOKEN live |
| `config` | Show/set config keys (store: apps/jumpserver/.env) |
<!-- END GENERATED: actions -->
<!-- BEGIN GENERATED: config (scripts/gen-docs.sh) -->
| key | default | notes |
| --- | --- | --- |
| `JUMPSERVER_WEB_PORT` | `31200` | host web console port (container 80; upstream default 80 is privileged) |
| `JUMPSERVER_SSH_PORT` | `31202` | host SSH/SFTP terminal port (container 2222; `ssh -p 31202 admin@<host>`) |
| `JUMPSERVER_CORE_IMAGE` | `jumpserver/core:v4.10.19-ce` | core image (aibox upgrade floats all five) |
| `JUMPSERVER_WEB_IMAGE` | `jumpserver/web:v4.10.19-ce` | web (nginx) image |
| `JUMPSERVER_KOKO_IMAGE` | `jumpserver/koko:v4.10.19-ce` | ssh/web terminal image |
| `JUMPSERVER_LION_IMAGE` | `jumpserver/lion:v4.10.19-ce` | RDP (guacamole) image |
| `JUMPSERVER_CHEN_IMAGE` | `jumpserver/chen:v4.10.19-ce` | database audit image |
| `JUMPSERVER_SECRET_KEY` | `random` | Django SECRET_KEY (generated at install; session/crypto. MUST be kept when migrating data) (secret) |
| `JUMPSERVER_BOOTSTRAP_TOKEN` | `random` | core↔component registration token (generated at install) (secret) |
| `JUMPSERVER_DOMAINS` | `—` | trusted DOMAINS (e.g. 'demo.example.com:31200'; empty = no restriction, see JumpServer 安全设置) |
| `JUMPSERVER_START_TIMEOUT` | `900` | start health-wait seconds (first boot runs Django migrations; measured ≈ 11 min) |
| `JUMPSERVER_LOG_TAIL` | `200` | log tail lines |
| `AIBOX_DOCKER_POOL` | `shipped pool` | docker.io mirror list override (knob) |
| `AIBOX_DOCKER_MIRROR` | `(unset)` | user mirror, tried first (knob) |
| `AIBOX_DOCKER_FORCE_POOL` | `0` | 1 = skip the direct probe, always engage the pool (knob) |
<!-- END GENERATED: config -->

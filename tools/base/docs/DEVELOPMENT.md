# base — development notes

- Upstream: [PostgreSQL](https://www.postgresql.org/) (image `postgres:18`) and
  [Redis](https://redis.io/) (image `redis:7`) — pinned by major tag; bumps are
  deliberate operations (PG major upgrades need `pg_upgrade`/dump-restore planning).
- Spec: [`../../docs/module-spec.md`](../../../docs/module-spec.md) §base module /
  shared components; the module is the PROVIDER side of the `services:` contract.

## Design decisions

- **One compose stack, profile-derived identity**: each aibox profile gets its
  own stack — containers `aibox-base[-<profile>]-{postgres,redis}`, hash-derived
  host ports (PG `35100+h%332`, Redis `36100+h%279`; the `prod` profile hash is
  pinned at `1073` → PG 35177), network `aibox-base[-<profile>]`, volumes
  `aibox_pg_data[_<profile>]`. Derivation is deterministic from the profile NAME
  (same name → same ports/names on every host — a cross-machine contract;
  changing the hash algorithm or port ranges is a BREAKING change).
- **Shared-PG consumer contract**: consumers declare `services:
  base:postgres#<db>`; aibox's `ensure_services` auto-starts base and calls
  `svc.sh create postgres <db>`; connection info is injected via
  `$AIBOX_HOME/base[-<profile>].env` (`AIBOX_POSTGRES_*`) that consumers pass to
  compose with `--env-file`. Consumers must NOT hardcode `aibox:aibox@` (the
  validator scans compose files for this).
- **`create` waits for `pg_isready`** (≤30s) before `CREATE DATABASE` — measured
  fix: cold-stack createdb raced the server boot (live bug, 2026-09).
- **Named volumes only** (`pg_data:/var/lib/postgresql` covers PG's versioned
  subdir layout across major bumps) — Docker Desktop doesn't share `/opt`.
- **Credentials**: generated once into the env file (chmod 600); `PGPASSWORD`
  never appears in process args (`docker exec` uses in-container psql).
- **Uninstall preserves volumes** — the shared DBs belong to "this deployment";
  deletion is an explicit manual act (hint prints the exact volume names).

## Known quirks

- CN networks: `registry-1.docker.io` is commonly blocked for the docker DAEMON
  even when host curl works (and vice versa) — see README §Mainland-China
  network deployment (registry mirror / daemon proxy drop-in / AL4 docker group).
- Preflight `docker_images` short-circuit: when `postgres:18` + `redis:7` are
  cached, the daemon pull probe is skipped — offline restarts pass preflight.

## Local testing

```bash
scripts/validate-module.sh base        # conformance (same rules as CI)
bats tests/base-env.bats tests/base-svc.bats
bats tests/integration/base-profiles.bats   # needs docker: dual-profile E2E
```

## Design decisions (2026-09 dependency review)

- **One link resolver per profile.** `base_env_file` / `base_pg_container` / `base_network_name`
  live in `tools/_shared/common.sh`; base's own `_profile_load` derives through the same
  helpers. Before that, three consumers hardcoded `$AIBOX_HOME/base.env` while base wrote
  `base-<profile>.env` for named profiles — a named-profile consumer either attached to the
  DEFAULT instance (silently writing to the wrong database) or joined the wrong network.
- **The connection file is a versioned contract.** Keys are additive; a rename bumps
  `AIBOX_BASE_ENV_VERSION` on both sides and consumers fail with `aibox update base` guidance
  instead of interpolating empty strings.
- **Secrets are generated once, never rotated silently.** Resolution order: explicit
  env/config → the value already in the contract file (so existing deployments keep
  working) → `$AIBOX_HOME/.base-secret` (mode 600) → a fresh random value. `cmd_start` also
  ALTERs the role so the DB and the contract can never disagree.
- **Redis auth + one logical DB per module.** Keyspace separation by index is not security;
  the password is published in the contract file and every consumer reads its slot from its
  own `redis-env-file`. `dify` reserves three consecutive slots for its DB/broker/agent roles.
- **Image pins in the deploy root's `.env`.** Compose reads `${AIBOX_BASE_PG_IMAGE:-postgres:18}`
  so `aibox base upgrade` can float/roll back versions without editing a file that
  `aibox update base` overwrites. `--project-directory` makes the project name independent
  of the caller's CWD.
- **Readiness before the contract.** `base start` waits for `pg_isready` + an authenticated
  `PING` before writing `AIBOX_BASE_READY=1`; the multi-profile integration suite used to
  catch a race where a consumer created its DB while PG was still initializing.
- **State file shared with the manager.** `upgrades/base.state` uses the manager's keys
  (`from`/`to`/`ts`/`envbak`/`databak`/`status`) so `aibox dashboard base` renders it and
  `aibox upgrade base --rollback` restores the same pin file.
- **Reverse-dependency awareness.** The manager lists installed dependents
  (`_base_dependents`) and gates `base stop` / `uninstall base` / `purge base`; purge also
  scans every profile's deploy root (`apps/<name>-<profile>`).

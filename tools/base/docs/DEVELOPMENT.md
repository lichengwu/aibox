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

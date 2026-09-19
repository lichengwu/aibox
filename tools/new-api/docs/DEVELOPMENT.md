# new-api — development notes

- Upstream: <https://github.com/QuantumNous/new-api> (one-api lineage)
- Docs: <https://docs.newapi.dev/>
- Image: `calciumion/new-api` (docker.io) — floor pinned to **v0.13.2** (the
  latest STABLE release, 2026-04-27). The `v1.0.0-rc` line is explicitly
  pre-release (38 RCs, very active) — reachable via
  `aibox upgrade new-api --to v1.0.0-rc.38` but NOT the auto floor.
- Bump policy: floor changes via `module.yaml checks.docker_images` + the
  compose `${NEW_API_IMAGE:-…}` default, shipped in an aibox release;
  live bumps via `aibox upgrade new-api` (dockerhub-tags resolver rewrites
  `NEW_API_IMAGE` in the deploy `.env` only).

## Design decisions

- **Single-service compose on the shared base** (module.yaml `services:
  base:postgres#new_api + base:redis`): aibox `ensure_services` starts base +
  creates the `new_api` database BEFORE install.sh runs; the container joins
  the external `aibox-base` network and reads `SQL_DSN` /
  `REDIS_CONN_STRING` from `base.env` via `compose --env-file`. Upstream's
  bundled postgres/redis services are dropped — the base owns them (same
  contract as dify's shared-base mode, but always-on: new-api has no
  standalone mode, keeping one compose file and one code path).
- **PG DSN URL-safety**: `SQL_DSN` is a `postgresql://user:pass@host:port/db`
  URL — the base PG password must avoid `@` `:` `#` chars
  (`AIBOX_BASE_POSTGRES_PASSWORD`; the default `aibox` is URL-safe).
  Postgres + `postgresql://` DSN support verified at tag v0.13.2 (upstream
  compose at that tag already ships a postgres service).
- **Port 30300** (host) → container 3000: upstream's default 3000 collides
  with the openmaic module (CI port-conflict gate). `NEW_API_PORT` overridable.
- **Named volumes with explicit names** (`aibox_new_api_data` /
  `aibox_new_api_logs`): deterministic for `aibox purge new-api` regardless
  of deploy dir / compose project; `--purge` removes them, plain uninstall
  retains them.
- **SESSION_SECRET generated once at install** (mode-600 `.env`): upstream
  auto-generates when unset, but a pinned secret keeps sessions stable across
  restarts and is REQUIRED for multi-node — harmless single-node.
- **Health contract**: `/api/status` must answer `"success": true` —
  upstream's own container healthcheck, probed from the host (`api_up`) for
  the svc start/status gates and the upgrade rollback gate.
- **No static `docker_pull:` gate** (module.yaml): the svc-start hook probes
  the daemon's direct route itself (docker.io source pool) and pre-pulls via
  ranked mirrors when direct is dead — a static gate would false-fail exactly
  the mirror-saved networks. `checks.docker_images` provides the all-cached
  short-circuit; `deps` still hard-gates the docker daemon.

## Known quirks

- First login `root / 123456` (one-api heritage) — change immediately;
  surface via `aibox new-api credentials`.
- Upstream image tags carry `-amd64`/`-arm64` variants next to the plain
  multi-arch tag — always pin the PLAIN tag (the daemon picks its arch).
- The v1.0.0-rc line is the de-facto mainline (RCs ship features weekly);
  `tag_pattern` includes `-rc` so `--check` sees it, and the cross-major
  guardrail keeps auto-upgrade on the 0.13.x stable line until 1.x is
  explicitly pinned with `--to`.

## Local testing

```bash
scripts/validate-module.sh new-api      # conformance (same rules as CI)
bats tests/new-api.bats                 # module suite (offline-safe)
bats tests/*.bats                       # full fast suite
# live smoke: aibox install new-api → start → status → logs → stop → uninstall
```

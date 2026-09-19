# xiaozhi — development notes

- Upstream: <https://github.com/xinnan-tech/xiaozhi-esp32-server> (one-api style lineage; 3 parts: manager-web Vue / manager-api Java Spring Boot / xiaozhi-server Python)
- Docs: <https://github.com/xinnan-tech/xiaozhi-esp32-server/tree/main/docs>
- Images (ghcr.io, built by upstream's docker-image.yml on tag push):
  `ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_<ver>` + `:web_<ver>` — NOTE
  the tags have NO leading `v` (the workflow strips it: tag v0.9.6 →
  `server_0.9.6`); plus `server_latest` / `web_latest`. Floor pinned to
  **v0.9.6** (latest release, verified live via the NJU mirror's tag list).
- Bump policy: floor changes via `module.yaml checks.docker_images` + the
  compose `${XIAOZHI_*_IMAGE:-…}` defaults, shipped in an aibox release; live
  bumps via `aibox upgrade xiaozhi` (github-release resolver rewrites the
  `XIAOZHI_*_IMAGE` keys in the deploy `.env` only — the v-stripping resolver
  - `images:` prefixes reproduce upstream's exact tag format).

## Design decisions

- **3-service compose from upstream's docker-compose_all.yml**: server
  (Python ws 8000 + vision/OTA http 8003) + web (nginx + Java manager-api
  console 8002) + bundled MySQL. The 4th upstream service (redis:8.0) is
  REPLACED by the shared aibox base — the web service joins the external
  aibox-base network and reads `SPRING_DATA_REDIS_*` from `base.env`
  (`compose --env-file`). Base redis runs without a password →
  `SPRING_DATA_REDIS_PASSWORD` empty. Version skew (upstream redis:8.0 vs
  base 7): the cache/session usage is protocol-compatible; same documented
  tradeoff as dify's shared-base mode.
- **MySQL is bundled** (mysql:8.0, not upstream's `mysql:latest`): the shared
  base deliberately ships no MySQL (PG only), and xiaozhi's manager-api is
  MySQL-only (Spring druid + `jdbc:mysql://` DSN; no PG support upstream).
  8.0 pinned over latest for druid/Connector-J compatibility. Root password
  is generated at install (hex — no URL/shell metacharacters) and shared by
  the mysql container init and the Java DSN env. utf8mb4 forced BOTH via
  `MYSQL_INITDB_ARGS` (first init) and the server `command` (re-inits).
- **Ports 8000/8002/8003** = upstream's own defaults, all free in this repo's
  port registry. Container-internal ports unchanged; `XIAOZHI_*_PORT` env
  overrides remap the host side only.
- **Console-managed config contract** (upstream's `config_from_api.yaml`):
  the server's providers (LLM/TTS/ASR) live in the console/DB, not in
  config files. aibox renders `data/.config.yaml` ONCE at install with:
  server endpoints (ws/vision URLs built from the DETECTED LAN IP — devices
  connect from outside), `manager-api.url` → the web container, and an EMPTY
  `secret`. The secret flow is upstream's own: register the first console
  user (becomes super admin) → 参数管理 → copy `server.secret` →
  `aibox xiaozhi secret <value>` (writes the yaml + restarts the server
  container — the config is bind-mounted, the app re-reads it at boot).
- **`./data` bind mount** (upstream-faithful): the config must exist BEFORE
  first start, so the install hook renders it on the host; the deploy root is
  under `$HOME` (Docker Desktop shares it — only `/opt` has the Mounts-denied
  issue, pitfall #8). Models get a NAMED volume instead (docker copies the
  image's content in on first use; drop model.pt without recreating).
- **seccomp:unconfined** on the server container: ported from upstream
  (their audio/model syscall surface requires it).
- **ghcr source pool** (NEW family — the docker.io mirrors do NOT proxy
  ghcr.io): uncached ghcr images get a bounded DIRECT pull attempt first
  (`AIBOX_GHCR_DIRECT_TIMEOUT`, 120s: fast links finish with zero overhead;
  slow links get cut harmlessly — mirrors serve identical digests), then
  ordered mirror failover (`ghcr.nju.edu.cn` — upstream's own compose ships
  it, measured 62 MB/s by the windmill module — then `ghcr.dockerproxy.net`):
  pull `<mirror>/<path>` + `docker tag` back to the official ref (the
  windmill WM_GHCR_MIRROR technique). Sequential, not concurrent-rank: the
  images are 0.7–1.5 GB — racing duplicate pulls through every mirror would
  multiply the traffic; mirror #1 is measured-fast. MySQL goes through the
  docker.io pool (hello-world probe → ranked mirrors) as usual.
- **No static `docker_pull:` gate** (module.yaml): the svc-start hook probes
  the daemon's routes itself; `checks.docker_images` provides the all-cached
  short-circuit; `deps` still hard-gates the docker daemon.

## Known quirks

- First boot runs MySQL init + Java Liquibase migrations — 1–3 min before the
  console answers (the start gate waits, `XIAOZHI_START_TIMEOUT` default 300s).
- The Python server REFUSES to boot with an empty manager-api.secret
  (measured: "manager-api的url或secret配置错误" crash-loop). svc start therefore
  runs STAGED: mysql + web first (the Java manager-api GENERATES server.secret
  into MySQL sys_params at first boot), auto-fetch + apply via
  `_fetch_secret`/`_write_secret`, THEN the server container — no crash-loop
  window. `aibox xiaozhi secret <value>` remains the manual override/rotation.
- Device-facing URLs (`websocket:`, `vision_explain:`) are LAN-IP-rendered at
  install; wrong-interface detection is fixed by editing `data/.config.yaml`.
- Upstream image tags carry no leading `v` (git tag v0.9.6 ↔ docker
  `server_0.9.6`) — the upgrade stanza relies on the engine's `target#v`
  strip + `images:` prefixes; do NOT add `v` to those prefixes.

## Local testing

```bash
scripts/validate-module.sh xiaozhi      # conformance (same rules as CI)
bats tests/xiaozhi.bats                 # module suite (offline-safe)
bats tests/*.bats                       # full fast suite
# live smoke: aibox install xiaozhi → start → console+ws health →
#             secret → restart/stop → purge dry-run
```

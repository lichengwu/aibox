# xiaozhi

Xiaozhi ESP32 server (docker compose): backend for xiaozhi-esp32 AI voice devices (manager console + websocket relay + bundled MySQL)

Upstream: [xinnan-tech/xiaozhi-esp32-server](https://github.com/xinnan-tech/xiaozhi-esp32-server) · docs: <https://github.com/xinnan-tech/xiaozhi-esp32-server/tree/main/docs>

## Commands

```text
aibox install xiaozhi
aibox xiaozhi start|stop|restart|status|logs
aibox xiaozhi secret <value>       # manual override of the auto-applied server.secret
aibox xiaozhi credentials
aibox xiaozhi dashboard            # endpoint + health
aibox update xiaozhi [--restart|--no-restart]
aibox upgrade xiaozhi [--check]    # float to a newer upstream release
aibox uninstall xiaozhi [--purge]
```

## First-run flow (secret auto-applied)

1. `aibox xiaozhi start` — pulls (source pools), then a STAGED start: MySQL +
   console first, `server.secret` auto-applied from the console's DB, then the
   ws server (it refuses to boot with an empty secret — upstream contract)
2. Open **http://127.0.0.1:8002**, register the FIRST user → it becomes the **super admin**
3. Configure LLM/TTS/ASR providers in the console (they are stored in MySQL, the
   server pulls them from manager-api); bind devices via the console (OTA URL
   `http://<host>:8002/xiaozhi/ota/`, websocket `ws://<host>:8000/xiaozhi/v1/`)
4. Manual override/rotation of the secret: `aibox xiaozhi secret <value>`

## How it works

3 containers from upstream v0.9.6's `docker-compose_all.yml` (deploy root
`$AIBOX_HOME/apps/xiaozhi`):

| container | image | what |
| --- | --- | --- |
| `aibox-xiaozhi-server` | `ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_0.9.6` | Python websocket relay (**:8000** ws for devices) + http (**:8003** vision/OTA) |
| `aibox-xiaozhi-web` | `ghcr.io/xinnan-tech/xiaozhi-esp32-server:web_0.9.6` | nginx + Java manager-api 智控台 (**:8002**) |
| `aibox-xiaozhi-mysql` | `mysql:8.0` | bundled MySQL (upstream is MySQL-only — the shared aibox base ships no MySQL) |

**Redis comes from the shared base** (`module.yaml services: base:redis`): the
web service joins the external `aibox-base` network and reads
`SPRING_DATA_REDIS_*` from `base.env`. Volumes: `./data` bind (config +
runtime — `data/.config.yaml` is rendered at install), named volumes
`aibox_xiaozhi_models` / `_uploadfile` / `_mysql`.

Image pulls go through **source pools** (spec §Download source pools): ghcr
images → bounded direct attempt, then ghcr mirrors (`ghcr.nju.edu.cn`,
`ghcr.dockerproxy.net` — pull-via-mirror + `docker tag`, identical digests);
mysql → the docker.io pool (direct hello-world probe, ranked mirrors).

## Configuration (env overrides)

Deploy `.env` (`$AIBOX_HOME/apps/xiaozhi/.env`, written once by install, mode 600):

| Var | Default | Meaning |
| --- | --- | --- |
| `XIAOZHI_WS_PORT` | `8000` | host websocket port (devices) |
| `XIAOZHI_CONSOLE_PORT` | `8002` | host console port (nginx → Java) |
| `XIAOZHI_HTTP_PORT` | `8003` | host http port (vision/OTA) |
| `XIAOZHI_SERVER_IMAGE` / `XIAOZHI_WEB_IMAGE` / `XIAOZHI_MYSQL_IMAGE` | `…:server_0.9.6` / `…:web_0.9.6` / `mysql:8.0` | image tags; `aibox upgrade xiaozhi` floats them |
| `XIAOZHI_MYSQL_PASSWORD` | generated | bundled MySQL root password |
| `XIAOZHI_START_TIMEOUT` | `300` | seconds svc waits for console + ws |
| `XIAOZHI_LOG_TAIL` | `200` | `logs` tail lines |

Device-facing addresses (`websocket:` / `vision_explain:` in
`data/.config.yaml`) are rendered with the **detected LAN IP** — edit that file
if auto-detection picks the wrong interface, then `aibox xiaozhi restart`.

Pool knobs: `AIBOX_GHCR_POOL` / `AIBOX_GHCR_MIRROR` / `AIBOX_GHCR_DIRECT_TIMEOUT` (ghcr family);
`AIBOX_DOCKER_POOL` / `AIBOX_DOCKER_MIRROR` / `AIBOX_DOCKER_FORCE_POOL` (docker.io family).

## Preflight

Declared in `module.yaml` `checks:` — enforced by `aibox install/update`
(see `docs/module-spec.md` §Preflight checks). Re-run manually:

```text
aibox check xiaozhi
```

- `disk_gb: 10` — server ~1.5G + web ~0.7G + mysql + optional SenseVoice model
- `docker_images:` all-cached short-circuit (no network probes when local)

## Upgrade

`aibox upgrade xiaozhi --check` resolves the latest release (github-release);
the engine strips the leading `v` and the `images:` prefixes rebuild the exact
upstream ghcr tags (`server_0.9.7` / `web_0.9.7`). Cross-major guardrail
refuses auto-jumps; `--to` pins. Auto-rollback on failed health check.

## Diagnostics

`aibox xiaozhi doctor` — declared deps, docker daemon reachability, the module's own
reported state (`dashboard_info`) and its declared port listeners. Shared
implementation (`module_doctor`, `tools/_shared/common.sh`), local-only:
exit `0` healthy · `3` a dependency is missing · `30` the service is not ready.

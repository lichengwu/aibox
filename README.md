# aibox

> AI coding toolkit — a lightweight module manager plus a set of independent tools. One-line `curl|bash` install; install / update / uninstall each module on demand.

`aibox` is a pure-bash module manager (zero runtime dependencies, compatible with the bash 3.2 that ships with macOS). Each "module" is a directory under `tools/<name>/` in the repo, shipping its own `install / uninstall / update / svc` hooks and dispatched uniformly by `aibox`.

> **Scope note:** the `windmill` and `openmaic` modules bundle full self-host ops CLIs (a few thousand lines each) inside this repo — they are the source of truth for those ops tools, not vendored copies. The core manager itself is `bin/aibox` (~1.3k lines). See [Bundled ops CLIs](#bundled-ops-clis).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

On networks where raw.githubusercontent.com is blocked (CN common), prefix a
mirror — the bootstrap itself races direct + mirrors for everything it
downloads (see [Download source pools](#download-source-pools-mirror-acceleration)):

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

This installs the `aibox` main CLI to `~/.local/bin/aibox` (PATH is handled automatically). Then install your first module:

```bash
aibox install pi-web
```

Optional checksum verification (defense in depth for the `curl|bash` bootstrap):

```bash
# Pin a specific SHA256 of bin/aibox:
AIBOX_SHA256=<hex> curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash

# Or verify against the release SHA256SUMS sidecar (graceful if absent):
AIBOX_VERIFY=1 curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

## Commands

```
aibox install <module> [--skip-checks]   install a module (preflight-gated)
aibox uninstall <module>|self [--purge] [--yes]
                                  uninstall a module; --purge also deletes its DATA.
                                  'self' = the manager: default removes ONLY aibox
                                  (services/data KEPT, apps/ preserved); --purge =
                                  cascade full teardown (every module's uninstall
                                  --purge, then manager + rc block)
aibox update <module>|self|--all [--restart|--no-restart] [--skip-checks]
                                  update modules; self = aibox itself; --all = modules + self
aibox upgrade <module> [--check] [--to <version>] [--yes]
                                  upgrade the deployed COMPONENT to a newer upstream release
                                  WITHOUT an aibox release: the repo pins the install floor,
                                  the deploy .env floats (auto-rollback on failed health)
                                  — `update` refreshes module scripts; `upgrade` bumps versions
aibox check <module>|self         module preflight; 'self' = environment check
                                  (egress, core domains, docker, disk)
aibox dashboard [--available] [<module>]
                                  overview (modules + versions + endpoints + credentials +
                                  port table) / registry catalog / single-module detail + health
aibox purge [<module>...|self] [--apply] [--stop] [--yes]
                                  residue scan/cleanup (dry-run by default): volumes, apps/,
                                  /etc dirs, units, binaries left after uninstalls
aibox <module> <action> [args]    invoke a module action (e.g. aibox pi-web start)

Every install/update is gated by a **preflight check** (domains reachable / disk / deps / base
services ready — declared per module in `module.yaml` `checks:`; see `docs/module-spec.md`).
On network failure it tries the configured alternatives (direct / clash pool / gh mirror /
static proxy) and adopts a working route for that run. `aibox check self` checks the
environment, `aibox check <module>` runs a module preflight proactively;
`--skip-checks` (or `AIBOX_SKIP_CHECKS=1`) bypasses it.

aibox proxy                       show proxy config and state
aibox proxy set <url> [--no-test|--no-check]
                                  set proxy: test -> save -> verify site connectivity
aibox proxy check [url]           no url: dev-site connectivity matrix; with url:
                                  single-target reachability + direct-connection control
aibox proxy on | off              enable / disable (config retained)
aibox proxy unset                 clear the config
aibox proxy env [--remote]        print export statements / remote-ship format
aibox --no-proxy <command>        bypass the proxy for this invocation

aibox clash set <sub-url>          store the subscription + generate config (mihomo kernel, auto speed-test/switch)
aibox clash on | off               start/stop (on switches aibox egress to local mihomo)
aibox clash status | refresh       status/current node | force-refresh the subscription (auto after 1 week)
aibox clash select <node>          switch node manually
aibox clash test | logs | doctor   probe / logs / self-check
```

## Proxy

aibox has two proxy egress paths:

- **Static proxy** (`aibox proxy set`): manually specify an http/https/socks5 proxy (below).
- **clash subscription pool** (`aibox install clash` + `aibox clash set <sub-url>`): orchestrates the local mihomo kernel; subscription nodes are auto speed-tested (pick fastest) and failed over. See the [clash module](tools/clash/README.md). Clash takes priority over the static proxy when on.

In some environments (e.g. direct-to-GitHub from CN) `aibox` can't pull modules, or git/npm inside module hooks can't reach out. Configure a static proxy once and both `aibox` itself and the module hooks it spawns use it:

```bash
aibox proxy set http://10.0.0.2:7897           # set -> test -> save -> verify sites
aibox proxy check                              # recheck site connectivity anytime
aibox --no-proxy list --available                # bypass once
```

The config lives at `~/.aibox/config` (mode 600) and **does not touch your shell config** — to make terminal git/brew use the proxy too, decide for yourself with `eval "$(aibox proxy env)"`.

### Site connectivity is verified right after `set`

A single-point probe only proves "this url can reach out"; it doesn't prove "the sites you need are reachable" — proxies are often **partially available** (reach GitHub but not Docker Hub). So `set` automatically runs the site list after saving:

```
  Connectivity check (via proxy http://10.0.0.2:7897)
  Any HTTP answer counts as reachable — 401/404/405 just mean the link reached the peer
  Dev deps
  ✓ github.com                   200   0.65s
  ✓ docker hub                   401   1.45s
  ✓ ghcr.io                      405   0.86s
  ✗ google                       000   8.00s  connection failed or timed out
  CN mirrors
  ✓ npmmirror                    200   0.09s
  ✓ tuna                         200   0.18s

  14 items: 13 ok · 1 failed
  All traffic confirmed via proxy (curl %{proxy_used})
  unreachable:
    google
       Troubleshoot: `aibox proxy check <url>` for the direct-connection control; or try another proxy
```

**If any fail it asks whether to revert**, restoring the pre-set state exactly (back to unconfigured if there was none, or back to the previous proxy if there was one). To skip the prompt:

```bash
aibox proxy set <url> --no-check    # single-point test only, no site verification
aibox proxy set <url> --no-test     # test nothing, just save
```

Verdict rule: **any HTTP response counts as reachable** — `401` (private registry needs auth), `404` (no content at root), `405` (no HEAD) all just mean the peer answered normally. Only connection-layer failure (`000`) counts as unreachable; `5xx` is recorded as suspicious.

The default list has 14 entries: GitHub (home / API / raw), Docker Hub, GHCR, npm, PyPI, Go proxy, Google, Hugging Face, Maven Central, plus npmmirror / TUNA / dashscope as CN mirror controls. Override with your own:

```bash
export AIBOX_PROBE_SITES='my source|https://example.com|custom group
another|https://example.org|custom group'
aibox proxy check
```

Prefer ASCII labels — alignment is byte-based, so multibyte labels misalign. Default timeout is 8s, adjustable via `AIBOX_PROBE_TIMEOUT`.

Effect is layered; the first two layers are automatic:

| Layer | What it covers | How it takes effect |
| --- | --- | --- |
| 1. Main process | `aibox`'s own registry / module / self-update fetches | env vars exported at startup |
| 2. Child process | curl / git / npm inside module hooks (`install.sh` etc.) | env vars inherited by children |
| 3. Persistent | networking when a module runs on **another machine, another time** | the module writes the proxy into its own config file; needs module cooperation |

Why layer 3 is necessary: the `openmaic` module's dispatched CLI runs `openmaic upgrade` on the deploy host when `aibox` isn't present at all, and env vars don't cross that boundary. So `aibox install openmaic` also writes the proxy into `/etc/openmaic/openmaic.conf`.

### What happens when the proxy is down

**Configured is enforced**: if the proxy is down, it errors; it does not silently fall back to direct (otherwise it'd表现为 wait-for-timeout-then-fallback every time — slow and untraceable). Four escape hatches:

```bash
aibox proxy check     # site-level connectivity (14 by default)
aibox proxy check <url>   # single-target reachability + direct-connection control
aibox proxy off       # disable globally (config retained)
aibox --no-proxy ...  # bypass once
```

If `set` finds failures it asks whether to revert — you don't have to remember what you had before.

`proxy check <url>` additionally runs a "direct-connection control" and tells you plainly whether the proxy is required on the current network — because **"can I reach it" is misleading**; see [AGENTS.md](AGENTS.md) pitfall #3.

### What is NOT overridden

The proxy is **process-level env vars**, affecting only tools that honor `*_proxy` (curl / git / wget / npm / pip / apt). **Docker daemon pulls go through `/etc/docker/daemon.json` and are unaffected**; already-running daemons can't be changed either — restart them.

## Download source pools (mirror acceleration)

Every download aibox performs goes through a **source pool**: mainstream
accelerated mirrors race the direct route with a REAL download, the fastest
measured source serves, and a stalled/failed source fails over to the next —
every reachable source is tried before giving up. On healthy networks the
direct route wins the race and nothing changes.

| family | where | shipped pool (live-verified, content-checked) |
| --- | --- | --- |
| npm (pi-web) | module install/update | npmjs + npmmirror + Tencent + Huawei Cloud mirrors |
| GitHub raw/api (scripts, registry, bootstrap, self-update, upgrades) | every manager download | direct + gh-proxy.com + ghproxy.net (+ a raw→api rewrite fallback) |
| GitHub releases ~20MB (clash mihomo) | clash install | same mirrors — rate-probed on the real asset, resumable, per-source failover |
| docker.io images (dify / gitlab / base; openmaic via its CLI) | module start / `up` (pre-pull + `docker tag`) | direct (daemon-routed probe) + docker.1ms.run + daocloud + dockerproxy + rat.dev |
| node dist (nvm `node:22` dep) | dependency auto-install | nodejs.org + npmmirror + Aliyun (exports NVM_NODEJS_ORG_MIRROR) |
| ghcr (windmill) | windmill's own CLI | ghcr.nju.edu.cn + ghcr.dockerproxy.net (auto-probed, persisted to .env) |

Mirrors that served divergent content were measured and EXCLUDED (ghproxy.link,
ghproxy.cn — truncated/wrong-size; tencent node-dist — stale index). Per-family
knobs (see [docs/module-spec.md](docs/module-spec.md) §Download source pools for
the full contract):

```text
AIBOX_GH_POOL=<urls|direct>                    GitHub family mirror list ("direct" = no pool)
AIBOX_GH_MIRROR / CLASH_MIRROR                 your mirror — joins the race as a candidate
AIBOX_NPM_REGISTRY / AIBOX_NPM_REGISTRIES / AIBOX_NPM_TIMEOUT      npm family
AIBOX_DOCKER_POOL / AIBOX_DOCKER_MIRROR / AIBOX_DOCKER_FORCE_POOL  docker.io family
AIBOX_NODE_POOL / AIBOX_NODE_MIRROR             node-dist family
CLASH_PROBE_TIME / CLASH_TAG_TIMEOUT / CLASH_DOWNLOAD_ATTEMPTS     clash binary download
```

Note the docker.io pool composes with the proxy note above: the proxy env vars
still do not affect the daemon — the pool instead pre-pulls mirror-prefixed
refs and `docker tag`s them to the official names, so `compose up` finds the
images locally.

## Modules

| Module | Description |
| --- | --- |
| [`pi-web`](tools/pi-web/README.md) | Deploys `@agegr/pi-web` as a macOS launchd service (HTTP Basic Auth + auto-restart) |
| [`openmaic`](tools/openmaic/README.md) | [OpenMAIC](https://github.com/THU-MAIC/OpenMAIC) ops CLI, dispatched to Linux deploy hosts (install / upgrade / backup / doctor) |
| [`windmill`](tools/windmill/README.md) | [Windmill](https://www.windmill.dev) self-host ops CLI, docker compose deploy (init / upgrade / backup / drill / doctor) |
| [`clash`](tools/clash/README.md) | Clash subscription proxy pool, orchestrates local mihomo (auto speed-test / failover / auto-refresh after 1 week) |
| [`base`](tools/base/README.md) | Shared base components (PostgreSQL 18 + Redis 7); each module gets its own DB |
| [`gitlab`](tools/gitlab/README.md) | [GitLab CE](https://about.gitlab.com/) self-hosted (omnibus docker): web UI + git over SSH, embedded PG/Redis |
| [`dify`](tools/dify/README.md) | [Dify](https://github.com/langgenius/dify) self-hosted (docker compose): LLM app builder, api/worker/web/nginx + weaviate (v1.17.1) |
| [`new-api`](tools/new-api/README.md) | [New API](https://github.com/QuantumNous/new-api) self-hosted (docker compose): LLM API gateway — OpenAI-compatible relay, key/quota management, usage analytics (v0.13.2) |

### Bundled ops CLIs

The `tools/windmill/cli/windmill` and `tools/openmaic/cli/openmaic` files are full single-file ops CLIs (3.6k and 1.7k lines respectively) authored for this repo — they are the source of truth for operating Windmill/OpenMAIC deployments, not vendored third-party copies. They're large because they own the entire lifecycle (init/upgrade/rollback/backup/restore/migrate/drill/doctor, incl. Docker image-source blackhole detection and pull-stall handling). The core `aibox` manager is unaffected by their size.

## Developing a new module

A module = a `tools/<name>/` directory + a `module.yaml` declaration (the source of truth; the registry is discovered from `tools/*/module.yaml`). The hook contract is in [`docs/module-spec.md`](docs/module-spec.md). A minimal module needs only an `install.sh`.

```bash
# local trial against your working tree, no network:
AIBOX_RAW=file:///path/to/aibox aibox dashboard --available
AIBOX_RAW=file:///path/to/aibox aibox install <your-module>
```

## Design tradeoffs

- **Registry uses a shell-sourceable format, not JSON**: zero runtime dependencies, compatible with macOS bash 3.2; the main CLI sources it directly, no `jq` / `python`.
- **Module scripts are cached on disk**: `aibox` downloads module scripts to `~/.aibox/modules/<name>/` before executing; hooks can reuse `lib.sh`, and `svc.sh` pass-through doesn't re-fetch every time.
- **Self-update = idempotent re-bootstrap**: `aibox update self` re-runs `curl|bash install.sh` to overwrite the main CLI, with no git / Releases dependency. Optional `AIBOX_SHA256` / `AIBOX_VERIFY=1` add checksum defense in depth.
- **Platform is self-reported by the module**: a `platform=darwin` module only warns on non-macOS; the real constraint is reported by the module hook at runtime.
- **`AIBOX_RAW` is overridable**: supports local sources / mirrors (e.g. `AIBOX_RAW=file:///path/to/aibox aibox dashboard --available`). Remote registry results are cached with a TTL to dodge the unauthenticated GitHub API rate limit.
- **A module need not ship a daemon**: `pi-web` manages a launchd service, while `openmaic` only dispatches a CLI and passes `aibox openmaic <action>` through to it — in the contract, `svc.sh` is an "action entry point", not "must be a daemon".
- **Module runtime environment is self-reported**: cross-platform install modules (like `openmaic`) don't set `platform`; the CLI refuses unsupported platforms at execution with a clear message, which is less false-positive-prone than hard-blocking at install time (install itself is side-effect-free on any OS).
- **Proxy config is separated from runtime**: config is written to `~/.aibox/config` (600) and exported as env vars at startup. So it covers both `aibox` itself and the module hooks it spawns (child inheritance), with no changes to existing module code. The cross-machine / cross-time layer (a module networking elsewhere on its own) must be handled by the module writing the value into its own config file — env vars don't cross that boundary by nature; this isn't a trick, it's the boundary.
- **Proxy failure is deterministic, no silent fallback**: if the proxy is down, it errors. Silent fallback would make "proxy broken" look like "a bit slow every time", which is harder to diagnose. `test` / `off` / `--no-proxy` are three escape hatches so you're never stuck.
- **Doesn't touch your shell config**: `aibox proxy set` only writes its own config, never injects into `~/.zshrc` — a global proxy would affect services that shouldn't go through it, out of scope for aibox. For global effect use `eval "$(aibox proxy env)"`.
- **clash pool doesn't parse the subscription yaml itself**: `aibox clash` writes the subscription URL into mihomo's `proxy-providers`; fetch/parse/speed-test/switch are all delegated to the kernel — pure bash shouldn't write a yaml parser (fragile), and subscription format changes are adapted by mihomo.

## License

[MIT](LICENSE)

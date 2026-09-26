<div align="center">

# aibox

**A zero-dependency, pure-bash module manager for AI coding toolkits.**

[![Latest Release](https://img.shields.io/github/v/release/lichengwu/aibox?color=blue&label=release)](https://github.com/lichengwu/aibox/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/lichengwu/aibox/lint.yml?label=CI)](https://github.com/lichengwu/aibox/actions/workflows/lint.yml)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)](#requirements)

[Install](#install) · [Quick Start](#quick-start) · [CLI Grammar](#cli-grammar) · [Modules](#modules) · [中文文档](README.zh.md)

</div>

`aibox` treats every self-hosted tool you deploy — a GitLab, a Dify, a Clash
proxy pool — as a **module**: a directory with `install / uninstall / update /
svc` hooks, dispatched uniformly by one ~3.4k-line single-file CLI. No runtime
dependencies, no package manager, works on the bash 3.2 that ships with macOS.

## Features

- **One grammar** — `aibox <verb> <module>` for everything: `install`, `update`,
  `uninstall`, `check`, `upgrade`, `dashboard`, `purge`. One mental model, no sub-family verbs.
- **Preflight-gated installs** — deps, disk, domains, docker daemon reachability and
  shared-service readiness are probed *before* anything is touched; a bad network tries the
  configured alternative routes (direct / clash / mirror) automatically.
- **Download source pools** — every download family (GitHub raw/releases/API, docker.io,
  npm, ghcr, node-dist) races candidates concurrently, ranks by measured throughput,
  and fails over per source. On a healthy network this costs nothing.
- **Docker source selector** — docker.io / ghcr.io traffic (image pulls AND upgrade version
  resolution) follows one strict priority: the official/default route first, then the
  local addresses you already have (the daemon's own registry-mirrors + your knobs), and
  only on timeout/failure a live-verified acceleration pool (10 docker.io + 2 ghcr
  mirrors) ranked by measured speed. Rankings are cached with TTL and self-heal — dead
  mirrors are skipped, revived ones re-join, `dockerpool.cache` is shared across runs.
- **Mirror acceleration built in** — GitHub / docker.io / npm mirrors are pre-ranked by
  real downloads on your machine, not guessed. Verification-gated: a mirror serving a
  corrupt body is discarded and the next source is tried.
- **Staged upgrades with a rollback point** — `aibox upgrade <module>` bumps the deployed
  upstream version without an aibox release: pin the target, per-hop health gates, a VERIFIED
  auto-rollback (exit 10 = failed but rolled back, 20 = needs a human), a recorded rollback
  point (`--rollback` goes back, `--history` lists transitions) and a pre-upgrade data snapshot
  for shared-PG consumers (`--no-backup` skips). GitLab's official required-upgrade-stops rule
  is automated (multi-hop path computed, each hop on the latest patch, readiness-gated between
  hops).
- **Local-first dashboards** — `aibox dashboard` renders state (✓ ok / ⚠ starting /
  ○ stopped), endpoints, credentials, port listeners from local metadata; async probes
  never block the view. Every block leads with the deployed **app version** (npm
  package / image tag / kernel tag; the aibox module packaging version is the dim
  footer row) — one keyline template across overview, detail and module rich views.
- **Per-module help, offline** — `aibox <module> --help` renders an action table from
  the module's own `usage:` map; `aibox <module> <action> --help` renders the single action.
- **Safe by default** — every destructive verb confirms interactively (uninstall asks,
  then asks about data; purge asks, then asks about running containers); scripts decline
  with exit 2 unless `--yes`.
- **Residue cleanup** — `aibox purge` scans and removes what uninstall hooks leave behind
  (volumes, `/etc` dirs, units, binaries), even after aibox itself is uninstalled.

## Requirements

- **macOS or Linux** with bash 3.2+ (the version that ships with macOS works).
- `curl`. Docker is required only by container-deploying modules (the preflight will tell you).
- Zero runtime dependencies otherwise; no jq/python needed.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

On networks where raw.githubusercontent.com is blocked (common in CN), prefix a
mirror — the bootstrap itself races direct + mirrors for everything it downloads:

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

Installs to `~/.local/bin/aibox` (PATH handled automatically).

Optional checksum verification for the `curl | bash` bootstrap:

```bash
AIBOX_SHA256=<hex>     curl -fsSL …/install.sh | bash   # pin an exact binary
AIBOX_VERIFY=1         curl -fsSL …/install.sh | bash   # check the release SHA256SUMS
```

Knobs for the install itself (all optional, all per-run):

```bash
AIBOX_PM_TIMEOUT=1200         aibox install pi-web    # bound package-manager auto-install (default 600s; 0 = unlimited)
AIBOX_NO_AUTO_DEPS=1          aibox install new-api   # never auto-install (service deps AND packages)
AIBOX_STRICT_SERVICES=1       aibox install new-api   # non-zero exit when a service dependency didn't start
AIBOX_SYSTEM_BIN_DIRS=/usr/local/bin  aibox …         # candidate in-PATH system dirs for the bin-dir pick
```

The bin dir is chosen with a fixed precedence (the manager and the bootstrap use the
same rule): explicit `AIBOX_BIN_DIR` → `~/.local/bin` when it is already in `PATH`
(no churn) → an in-PATH writable system dir (deploy hosts: `/usr/local/bin` — the
command works immediately) → `~/.local/bin`.

`aibox check self` reports the environment (egress route, docker, node/npm, disk)
before you install anything.

## Quick Start

```bash
aibox install pi-web        # preflight-gated module install
aibox pi-web start          # service lifecycle: start / stop / restart / status / logs
aibox dashboard             # all modules: app versions, state, endpoints, credentials, ports
```

Deploy a shared PostgreSQL + Redis base, then a module that uses it:

```bash
aibox install base          # shared PG18 + Redis7 (each module gets its own DB)
aibox base create postgres dify
aibox install dify
aibox dify start
```

The shared base is versioned, backed up and floatable on its own:

```bash
aibox base dump                # whole-cluster pg_dumpall + Redis snapshot (safety net)
aibox base upgrade --check     # current image pins + the recorded rollback point
aibox base upgrade --pg postgres:19   # dump → pin → readiness gate → pin rollback on failure
aibox base upgrade --rollback  # back to the recorded pins
aibox base create redis <module>      # allocate the module's own Redis logical DB (auth is on)
```

## CLI Grammar

One grammar: **`aibox <verb> <module>`** — "self" is a module too (the manager itself).

### Manager verbs (module lifecycle)

```text
aibox install <module> [flags]    preflight-gated install (--skip-checks to bypass)
aibox uninstall <module>|self     asks first, then asks about DATA (--purge answers
                                  yes upfront; --yes skips prompts for scripts)
aibox update <module>|self|--all  refresh module SCRIPTS (the repo-pinned floor)
aibox upgrade <module> [flags]    bump the deployed UPSTREAM version (dockerhub /
                                  github-release resolver, health gate, verified
                                  auto-rollback, staged multi-hop for gitlab).
                                  --check plan · --rollback to the recorded pin ·
                                  --history transitions · --no-backup skips the
                                  shared-PG snapshot. update ≠ upgrade:
                                  scripts vs upstream app version
aibox check <module>|self         preflight dry-run; self = environment check
aibox dashboard [--available]     overview (installed modules) / catalog
aibox dashboard <module>          single-module detail + health probe (app version in the header)
aibox purge [<module>...|self]    residue scan/cleanup (dry-run by default; --apply
                                  confirms, then asks about RUNNING containers)
aibox proxy {show|set|on|off|…}   static egress proxy config (global)
aibox <verb> --help               that verb's usage + options · also: aibox help <verb>
aibox --no-proxy <command>        bypass the proxy for one command
```

Exit codes are stable for automation: `1` runtime · `2` usage / declined ·
`3` dependency missing · `4` precheck failed · `10` upgrade rolled back ·
`20` manual intervention (module hooks add `30` not ready, `40` lock conflict,
`50` cancelled — [module-spec §Exit codes](docs/module-spec.md)).

### Module verbs (pass-through to the module's svc.sh)

```text
aibox <module> <action> [args]    e.g. aibox pi-web start · aibox clash select <node>
aibox <module> --help             action table (offline, from the module's usage: map)
aibox <module> <action> --help    the single action's usage (args + description)
```

Every service module implements the same standard set —
`start / stop / restart / status / logs`, `dashboard` (the rich view: containers,
health, endpoints, credentials, port listeners) and `doctor` (deps + docker daemon
+ reported state + declared port listeners; exit `0` healthy / `3` dep missing /
`30` not ready) — plus its own domain actions (`base create postgres <db>`,
`gitlab credentials`, `clash select <node>`, …). Dispatch-type modules (openmaic,
windmill) alias the lifecycle verbs onto their own CLI's spelling, so
`aibox <module> start` works everywhere.

### Ports & endpoints

> **Heads-up: aibox-deployed services don't always use upstream's default ports.**
> Port collisions across modules are prevented by an internal port registry —
> e.g. new-api serves on **30300** (upstream default 3000), GitLab on **8929**,
> dify on **8088**. Profiles derive further ports (`--profile prod` shifts base
> to 35177/36336).

Find the actual ports and endpoints at any time:

```bash
aibox dashboard            # versions + the port table + listeners for every installed module
aibox dashboard <module>   # the single module's app version + endpoint + health
aibox <module> status      # same, from the module itself
```

## Modules

| Module | What it deploys | Docs |
| --- | --- | --- |
| [`base`](tools/base/) | Shared PostgreSQL 18 + Redis 7; each module gets its own DB | [README](tools/base/README.md) |
| [`clash`](tools/clash/) | Clash subscription proxy pool (mihomo kernel, auto speed-test/failover) | [README](tools/clash/README.md) |
| [`dify`](tools/dify/) | [Dify](https://github.com/langgenius/dify) LLM app builder (docker compose) | [README](tools/dify/README.md) |
| [`gitlab`](tools/gitlab/) | [GitLab CE](https://gitlab.com/gitlab-org/gitlab) omnibus (staged upgrades) | [README](tools/gitlab/README.md) |
| [`new-api`](tools/new-api/) | [New API](https://github.com/QuantumNous/new-api) LLM gateway | [README](tools/new-api/README.md) |
| [`pi-web`](tools/pi-web/) | [@agegr/pi-web](https://github.com/agegr/pi-web) as a launchd/systemd service | [README](tools/pi-web/README.md) |
| [`openmaic`](tools/openmaic/) | [OpenMAIC](https://github.com/THU-MAIC/OpenMAIC) deploy-host ops CLI | [README](tools/openmaic/README.md) |
| [`windmill`](tools/windmill/) | [Windmill](https://github.com/windmill-labs/windmill) self-host ops CLI | [README](tools/windmill/README.md) |
| [`xiaozhi`](tools/xiaozhi/) | [Xiaozhi ESP32 server](https://github.com/xinnan-tech/xiaozhi-esp32-server) (voice assistant backend) | [README](tools/xiaozhi/README.md) |

> **Scope note:** `windmill` and `openmaic` bundle full self-host ops CLIs (a few
> thousand lines each) in this repo — they are the source of truth for those ops
> tools, not vendored copies. The core manager itself is `bin/aibox` (single file —
> the curl|bash deployment constraint).

## Advanced

<details>
<summary><b>Egress proxy</b> (aibox proxy on/off/set, clash-managed)</summary>

`aibox proxy set <url>` stores a static proxy used by every aibox download;
`aibox clash on` routes egress through the locally-managed mihomo instead.
Site connectivity is verified right after `set`, with a direct-connection
control so the verdict can't be a false positive. See the
[Proxy](README.md#proxy) section history / [clash README](tools/clash/README.md).
</details>

<details>
<summary><b>Download source pools</b> (how mirror acceleration works)</summary>

Every download family — GitHub raw / releases / API, docker.io images, npm
packages, ghcr, node-dist — maintains a candidate pool. Installs race the
candidates with bounded partial downloads of the REAL asset, rank by measured
bytes/sec, and fail over on failure. Completed bodies are verified before
acceptance (gzip integrity + execution + version pin where applicable); a bad
mirror is discarded, not fatal. See
[tools/clash/README](tools/clash/README.md#download-source-pool-the-mihomo-binary)
for a worked example.

**Docker source selector** (spec §Docker source selector) is the docker-specific
instance, covering image pulls AND dockerhub version resolution with the same
state (`$AIBOX_HOME/dockerpool.cache`, TTL 600s): priority is strict — the
official route → local addresses (the daemon's own registry-mirrors,
auto-discovered; your `AIBOX_DOCKER_MIRROR` knob) → the live-verified pool
(`docker.1ms.run hub.rat.dev docker.1panel.live hub.1panel.dev proxy.vvvv.ee
docker.m.daocloud.io hub3.nat.tf hub4.nat.tf docker.367231.xyz docker.apiba.cn`;
ghcr: `ghcr.nju.edu.cn ghcr.1ms.run`). A known-dead official route is
death-cached within the TTL (no repeated timeout tax); everything failing
invalidates and re-resolves. Override with `AIBOX_DOCKER_POOL="m1 m2"`
(`direct` disables). This is what makes `aibox upgrade <dockerhub module>` work
on networks where hub.docker.com is blocked.
</details>

<details>
<summary><b>Developing a new module</b> (scaffold + validator + spec)</summary>

```bash
scripts/new-module.sh mytool            # scaffold a conformant skeleton
scripts/validate-module.sh mytool       # conformance gate (CI runs --all)
```

The contract is [`docs/module-spec.md`](docs/module-spec.md) (normative):
module.yaml schema (ports/checks/usage/includes/upgrade), hook rules,
preflight contract, residue map, exit codes, interaction gates. Reference
implementation: [`tools/gitlab/`](tools/gitlab/).
</details>

<details>
<summary><b>Design tradeoffs</b></summary>

- **Single-file main CLI** (~3.4k lines): the curl|bash one-line install constraint. Internally sectioned.
- **Pure bash, zero deps**: runs on stock macOS bash 3.2; the repo's pitfall log (AGENTS.md) turns every platform gotcha into a CI assertion.
- **Registry = `tools/*/module.yaml`**: adding a module is creating a directory; no central registry to edit.
- **Local-first dashboards**: the default view needs no network; version probes are async.

</details>

## Contributing

PRs welcome. Read [`AGENTS.md`](AGENTS.md) first — it carries the bash coding
conventions, the pitfall log (platform traps with minimal repros), and the
module spec pointers. Conventional Commits; every release follows the
[changelog standard](CHANGELOG.md).

### Testing

```bash
bats tests/*.bats                 # fast suite: no docker, no network, ~seconds
tests/docker/run.sh               # reproducible: gates + the fast suite as root AND non-root
tests/docker/run.sh --integration # + the docker-backed E2E suites (host daemon)
```

[`tests/CASES.md`](tests/CASES.md) maps every logged bug (pitfall log, changelog
fixes, live catches) to the test that locks it — add a row with every fix.

## License

[MIT](LICENSE)

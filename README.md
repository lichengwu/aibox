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
- **Mirror acceleration built in** — GitHub / docker.io / npm mirrors are pre-ranked by
  real downloads on your machine, not guessed. Verification-gated: a mirror serving a
  corrupt body is discarded and the next source is tried.
- **Staged upgrades** — `aibox upgrade <module>` bumps the deployed upstream version
  without an aibox release: pin the target, per-hop health gates, auto-rollback.
  GitLab's official required-upgrade-stops rule is automated (multi-hop path computed,
  each hop on the latest patch, readiness-gated between hops).
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

## CLI Grammar

One grammar: **`aibox <verb> <module>`** — "self" is a module too (the manager itself).

### Manager verbs (module lifecycle)

```text
aibox install <module> [flags]    preflight-gated install (--skip-checks to bypass)
aibox uninstall <module>|self     asks first, then asks about DATA (--purge answers
                                  yes upfront; --yes skips prompts for scripts)
aibox update <module>|self|--all  refresh module SCRIPTS (the repo-pinned floor)
aibox upgrade <module> [flags]    bump the deployed UPSTREAM version (dockerhub /
                                  github-release resolver, health gate, auto-rollback,
                                  staged multi-hop for gitlab). update ≠ upgrade:
                                  scripts vs upstream app version
aibox check <module>|self         preflight dry-run; self = environment check
aibox dashboard [--available]     overview (installed modules) / catalog
aibox dashboard <module>          single-module detail + health probe (app version in the header)
aibox purge [<module>...|self]    residue scan/cleanup (dry-run by default; --apply
                                  confirms, then asks about RUNNING containers)
aibox proxy {show|set|on|off|…}   static egress proxy config (global)
aibox --no-proxy <command>        bypass the proxy for one command
```

### Module verbs (pass-through to the module's svc.sh)

```text
aibox <module> <action> [args]    e.g. aibox pi-web start · aibox clash select <node>
aibox <module> --help             action table (offline, from the module's usage: map)
aibox <module> <action> --help    the single action's usage (args + description)
```

Every service module implements the standard lifecycle
(`start / stop / restart / status / logs`) plus its own domain actions
(`base create postgres <db>`, `gitlab credentials`, `clash select <node>`, …).
`status` shows the module's operational facts **and its rich view**
(containers, health, endpoints, credentials, port listeners) — `dashboard` is
an alias of `status` at the module level.

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

## License

[MIT](LICENSE)

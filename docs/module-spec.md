# aibox module spec

Each aibox "module" is an independent tool, living under `tools/<name>/` in the repo, installed / updated / uninstalled / dispatched uniformly by the main CLI `aibox`.

## Onboarding a new module (normative)

Adding a module = **scaffold + fill the contract + prove conformance**. Two repo tools own the
mechanics; this spec owns the rules. `tools/gitlab/` is the reference implementation onboarded
with exactly this flow.

### Tooling

| Tool | Purpose |
|------|---------|
| `scripts/new-module.sh <name> [--desc "..."] [--no-compose] [--out <dir>]` | Generates a conformant skeleton: `module.yaml` (incl. the mandatory `checks:`), `lib.sh`, the four hooks, `svc.sh`, `README.md`, `docs/DEVELOPMENT.md`, optional `docker-compose.yml` — then runs the validator on it, so a fresh scaffold PASSes out of the box |
| `scripts/validate-module.sh <name> \| --all` | The conformance gate — same rules CI enforces (this file is the rulebook, the validator is the executable form). Zero dependencies; auto-uses `yq` / `shellcheck` / bash 3.2 when present. Exit 0 ⇔ 0 ERRORs (WARNs tolerated) |

### Checklist (definition of done)

1. **Scaffold**: `scripts/new-module.sh <name>` → `tools/<name>/` skeleton (validator PASSes immediately).
2. **`module.yaml`**: real `version`/`description`/`upstream` links; `ports` declared (unique across modules — the validator detects conflicts); `deps` (strict-checked at preflight); `services: base:<component>#<name>[_usage]` when consuming the shared base; **`checks:` is MANDATORY** (§Preflight checks below); `usage:` entries for every declared action (§Per-action help).
3. **Hooks**: `install/uninstall/update/svc.sh` per §Hook contract — bash shebang, `set -euo pipefail`, idempotent, `${VAR}` braces (AGENTS.md pitfalls #1/#8), no bash-4-only syntax (pitfall #2); shared code in `lib.sh` (sourced library: no shebang/strict line).
4. **Deploy conventions**: root `$AIBOX_HOME/apps/<name>`, config under `/etc/<name>/`, named volumes only, no hardcoded credentials (§Deploy directory & config path conventions).
5. **Service modules**: `actions` containing `start` MUST provide the full lifecycle `start/stop/restart/status/logs` (+ module-specific actions like `credentials`); a `dashboard` action with a module-owned rich view (`render_dashboard` in `lib.sh` — the manager prefers module-owned over its generic fallback); self-starting services use the platform-native init system (AGENTS.md rule 9).
6. **Docs**: `README.md` (commands / ports / env overrides / preflight — ERROR if missing) + `docs/DEVELOPMENT.md` (upstream links, version-pin policy, design decisions, known quirks — WARN if missing).
7. **Prove**: `scripts/validate-module.sh <name>` → 0 errors; `bats tests/*.bats` green; live smoke on a docker host: `aibox install <name>` → `<name> start` → `status` → `logs` → `stop` → `uninstall`.
8. **Residue map**: extend the residue map in `bin/aibox` (`residue_*` functions) with the module's leftover locations (volumes, containers, `/etc/<name>`, units, dispatched binaries) — `aibox purge` must be able to clean up AFTER the module (or aibox itself) is uninstalled (validator WARNs when the entry is missing).
9. **Register in docs**: add the module row to `README.md` / `README.zh.md`; `aibox dashboard --available` picks the module up automatically (`module.yaml` is the registry).

## Directory layout

```
tools/<name>/
├── lib.sh          # shared functions (optional; hooks source it to reuse)
├── install.sh      # required: install
├── uninstall.sh    # recommended: uninstall
├── update.sh       # optional: update
├── svc.sh          # optional: action entry point; $1=action (long-lived service; or just pass-through to a dispatched command)
└── README.md       # module docs
```

## Registering a module — via `module.yaml` (source of truth)

> As of v0.4.0, **`module.yaml` is the source of truth** for module metadata. The legacy `registry.sh` has been **removed**; `load_registry` auto-discovers `tools/*/module.yaml`:
>
> - **Local source (`file://`)**: the main CLI globs `tools/*/module.yaml` directly (no `registry.sh` needed — adding a module = create `tools/<name>/` + `module.yaml`, zero global changes).
> - **Remote source (`https://`)**: the GitHub API lists `tools/` dirs, then fetches each `module.yaml` over HTTPS. Results are cached to `~/.aibox/registry.cache` (1h TTL) to dodge the unauthenticated GitHub API rate limit (60 req/hour/IP).

Create `tools/<name>/module.yaml`:

```yaml
name: <name>                       # required. Hyphenated name.
version: x.y.z                     # required.
description: "one-line description"
platform: ""                       # optional; empty = cross-platform; darwin = macOS-only
dir: tools/<name>                  # required. repo dir
deps:                              # optional. runtime deps (command names)
  - "node:22"                      #   node:22 = major version >= 22
  - "docker@linux"                 #   @linux = check on Linux only
  - npm                            #   bare = no version/platform constraint
ports:                             # optional. ports occupied (port/proto:usage) — CI detects conflicts
  - 30141/tcp:http
files:                             # optional. extra files only; the standard 6 (module.yaml + lib.sh/install.sh/uninstall.sh/update.sh/svc.sh) are implicit — module.yaml rides in the cache so per-module help/metadata is local
  - docker-compose.yml
hooks:                             # required. hook filenames
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh
actions:                           # optional. actions svc supports (list all)
  - start
  - stop
usage:                             # per-action help text — `aibox <module> --help` renders one
  start: "Start the service"       # line per declared action; validator WARNs on gaps
  stop: "Stop the service"         # format: <action>: "<one-line description, args hint>"
upstream:                          # optional. dev-guide links (see the upstream stanza below)
  homepage: https://...
  docs: https://...
services:                          # optional. shared-component deps (CI validates provider/component)
  - base:postgres#<your-db>
checks:                            # REQUIRED. preflight contract (enforced by install/update; see below)
  disk_gb: 5                       #   min free disk (GB) at $AIBOX_HOME's filesystem
  domains:                         #   HOST-probed domains (git/npm/curl consumers); probed as https://<host>/
    - github.com
  docker_pull: hello-world         #   optional. DAEMON-routed pull probe (registry consumers; tiny image)
  docker_images:                   #   optional. when ALL are cached locally, domain+pull probes are skipped
    - postgres:18
  commands:                        #   optional. binaries that must exist (cmd@platform supported; no auto-install)
    - systemctl@linux
includes:                         # shared-library includes (§Shared library includes): repo-level
  - common                         #   tools/_shared/<name>.sh → cached per-module as _<name>.sh
```

Field reference: this document IS the normative schema (the historical design draft
`docs/module-system-spec.md` §2.3 is superseded).

> **History note (registry.sh):** before v0.4.0, modules were registered by appending `AIBOX_MODULE_<name>_*` shell variables to a root-level `registry.sh` (sourced directly by the CLI). That file no longer exists; the same fields now live in `module.yaml` and are parsed by a zero-dependency awk subset parser at runtime (`parse_yaml_module_stdin`), with yq validating the subset in CI. Module names with hyphens map to underscored variable keys internally (`pi-web` → `AIBOX_MODULE_pi_web_*`); that convention is unchanged.

## Hook contract

- aibox downloads the files listed in `files` (plus the standard 6 — module.yaml + the 5 hooks — implicitly) to `~/.aibox/modules/<name>/`, then invokes them as `bash <dest>/<hook>.sh [args]`.
- Hooks can `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"` to reuse shared functions.
- aibox injects these environment variables:

  | Variable | Description |
  | --- | --- |
  | `AIBOX_HOME` | aibox state dir |
  | `AIBOX_MODULE` | current module name |
  | `AIBOX_RAW` | repo raw base URL (may be a `file://` local source) |
  | `AIBOX_BIN_DIR` | main CLI install dir; module install paths start here |
  | `AIBOX_PROXY_URL` | effective proxy URL; empty when disabled. May come from aibox config or pre-existing env |
  | `AIBOX_NO_PROXY` | comma-separated addresses that bypass the proxy |
  | `AIBOX_PROXY_ENABLED` | `1` enabled / `0` disabled |

  Standard vars `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` are also exported, **lowercase and uppercase both** — curl only honors lowercase `http_proxy` (it ignores uppercase `HTTP_PROXY`), while apt-style tools only honor uppercase; the two sets differ in practice. See [Proxy](#proxy) below.

  The color vars `C_RST` / `C_DIM` / `C_BOLD` / `C_GRN` / `C_YEL` / `C_RED` / `C_CYA` are also exported (empty when piped or `NO_COLOR=1`). A module's `log`/`warn`/`ok`/`die` should use `${C_*:-}` fallbacks and match the manager's output system — plain `log` (no prefix), symbol-prefixed `warn`/`ok`/`die` (⚠/✓/✗, two-space gap) — no per-module color setup is needed (single source of truth in `bin/aibox`).
- `install.sh` installs the module itself (paths are self-determined, e.g. pi-web writes a launchd plist).
- `svc.sh`: `$1` = action, rest pass through.
  - **`svc.sh` is an "action entry point", NOT "must be a daemon".** Long-lived-service modules (e.g. pi-web) implement `start/stop/restart/status/logs/diagnose`. Dispatch-only modules (e.g. openmaic) can just pass through: `exec <dispatched-cmd> "$1" "$@"`, where the action set is that command's subcommands. The contract is "the file named by `hooks.svc` receives `(action, args...)`" — nothing more.
- Start install paths from `${AIBOX_BIN_DIR:-$HOME/.local/bin}` and expose a module-specific override (deploy hosts often want `/usr/local/bin`).
- Platform differences: warn, don't hard-block. Install is usually cross-platform; the real limit is reported by the script at execution time, which is less false-positive-prone than blocking at install.

### Data-purge contract (`AIBOX_PURGE_DATA`), self uninstall & residue purge

Data deletion is ONE flag across the CLI: **`--purge`**.

```text
aibox uninstall <module> [--purge]     tear down one module; --purge also deletes its DATA
aibox purge [<module>...|self] [--apply] [--stop] [--yes]
                                       after-the-fact residue scan/cleanup (see below)
aibox uninstall self [--purge] [--yes] remove the manager; --purge = cascade full teardown
```

- `aibox uninstall self` (default): removes ONLY the manager — `$AIBOX_BIN_DIR/aibox`,
  `$AIBOX_HOME` state and the marked `# aibox` rc PATH block. **`apps/` is preserved** so
  surviving deployments stay manageable; module services and data are KEPT and the summary
  prints the teardown paths. Confirm gate: TTY asks; non-interactive requires `--yes`.
- `aibox uninstall self --purge`: cascade — runs every installed (module, profile)'s
  `uninstall.sh` with `AIBOX_PURGE_DATA=1` (services + data via the hooks), drops `apps/`,
  then removes the manager + rc block. One command, composed from existing semantics.
- `aibox uninstall <m> --purge`: single-module equivalent (hook with `AIBOX_PURGE_DATA=1`
  - the manager sweeps `apps/<m>`).
- Hooks run from the module cache (`~/.aibox/modules/<m>/uninstall.sh`) — no registry
  fetch, so uninstall works offline.

**Hook obligations** (`uninstall.sh` receives `AIBOX_MODULE`, `AIBOX_PROFILE`,
`AIBOX_PURGE_DATA`):

- Default (`AIBOX_PURGE_DATA` unset/0): stop the service and remove the module's own
  *program* artifacts (compose files, binaries, units). **Data is preserved** — volumes,
  deploy roots, `/etc/<name>` — print the exact manual-removal commands.
- `AIBOX_PURGE_DATA=1`: ALSO delete the module's *data*: docker volumes, deploy-root
  contents, `/etc/<name>` config, scheduled units. The module knows its own volume
  names/paths — the manager never guesses them.
- Missing binaries must not short-circuit the hook (purge/retention of the deploy root
  still runs): no early `exit 0` before the data branch.

### Residue cleanup (`aibox purge`)

Hooks can only clean while they exist. `aibox purge` handles the after-the-fact case —
data/config left behind when modules (or aibox itself) are already gone. The residue MAP
is embedded in `bin/aibox` (`residue_*` functions — the single source of cleanup knowledge;
new modules MUST extend it, onboarding checklist item 8; the validator WARNs otherwise):

```bash
aibox purge                          # dry-run scan: categorized residue report (default)
aibox purge <module>... --apply      # clean specific modules' residue
aibox purge self --apply             # the manager's own residue (bin, state, rc block)
aibox purge --apply [--stop] [--yes] # everything; --stop authorizes stopping RUNNING
                                     # containers/processes (refused by default)
```

Rescue when aibox itself is already deleted (single file — offline, zero deps):

```bash
curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/bin/aibox -o /tmp/aibox
bash /tmp/aibox purge --apply
```

Safety: deletion targets come only from the embedded map + existence checks; RUNNING
containers (and their volumes) and live processes are refused without `--stop`; `--apply`
in a non-interactive shell requires `--yes`.

## Deploy directory & config path conventions

Modules fall into two classes, **judged by "is there runtime data that lives and dies with the deploy instance"**:

- **Install-type** (e.g. `pi-web`): only drops things into `${AIBOX_BIN_DIR}` and hands the service to the platform
  (the launchd plist must go in `~/Library/LaunchAgents`, logs in `~/Library/Logs`).
  **No deploy root** — stick to platform-conventional locations; forcing them under `apps/` breaks platform conventions.
- **Deploy-type** (e.g. `openmaic`, `windmill`): besides the CLI, drops runtime data on the target
  (compose files, `.env`, data volumes, backups, locks, logs). **Use the paths below — don't invent your own.**

### Deploy root: `$AIBOX_HOME/apps/<name>`

```sh
APPS_ROOT="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}"
BASE_DIR="${<MODULE>_BASE_DIR:-$APPS_ROOT/<name>}"
```

> ⚠️ When expanding, **don't drop the `.aibox` segment**. Writing `${AIBOX_HOME:-$HOME}` resolves to
> `$HOME/apps/<name>` instead of `$HOME/.aibox/apps/<name>` — the script doesn't error, but the path is wrong
> (this was hit in practice; caught only by a test asserting the exact path).
> A safer form is `${AIBOX_HOME:-${HOME:+$HOME/.aibox}}`: if `HOME` is empty, the whole thing is empty and a guard errors out.

**The same expression works on macOS and Linux — no platform branch.** Resolved values:

| Platform | User | Deploy dir |
| --- | --- | --- |
| macOS | normal user | `~/.aibox/apps/<name>` |
| Linux | root | `/root/.aibox/apps/<name>` |

Before switching roots, verify these three constraints in order (the first two are empirical findings, not style):

1. **Must be in the container-runtime default share list.** Docker Desktop (macOS) by default only shares `/Users`,
   `/Volumes`, `/private`, `/tmp`, `/var/folders` — putting the deploy dir under `/opt` makes compose **relative mounts**
   (e.g. `- ./Caddyfile:/etc/caddy/Caddyfile`) fail with `Mounts denied`. This is unrelated to privileges; `sudo` won't fix it.
2. **The identity running daily commands must be able to write.** Lock files, logs, backups all live in the deploy dir, and **every command writes** — putting it under a path that needs privilege escalation means even `status` (read-only) needs sudo, i.e. unusable.
   (By contrast, config is "write once, read daily", so it's allowed under `/etc`.)
3. **Centralized but not mixed namespaces.** Under `$AIBOX_HOME` lets aibox enumerate/audit/clean uniformly
   (`$AIBOX_HOME/apps/*`), but **you must use a sub-dir like `apps/`** to keep it separate from
   `$AIBOX_HOME/modules/<name>/` (the downloaded hook scripts) — otherwise the two share a name and differ by one level, making accidental deletion likely.

> ⚠️ `apps/` holds **deploy instances**, not "aibox state": their lifecycle outlasts aibox itself.

### Mandatory corollaries (skip any and you get an incident)

- **`aibox uninstall self` must be fail-safe.** The default removes ONLY the manager (binary +
  state + rc block) and KEEPS module services/data — `apps/` survives so running deployments stay
  manageable, and the summary prints the teardown paths (`aibox uninstall <m> --purge`,
  `aibox purge --apply`). `--purge` cascades: every installed (module, profile)'s hook with
  `AIBOX_PURGE_DATA=1`, then `apps/`, then the manager. Confirm gate: TTY asks; non-interactive
  without `--yes` exits non-zero and changes nothing ("dangerous ops never run silently").
- **systemd / launchd units must bake the resolved absolute paths in explicitly**, e.g.
  `Environment="AIBOX_HOME=/root/.aibox"`.
  **Empirically: there is no `HOME` variable in a systemd system service** (`systemd-run /usr/bin/env` only outputs `USER=root`).
  Any path derived from `$HOME` resolves to empty in the service context → points at the wrong dir.
- **Fail when unresolvable, don't construct paths.** If `HOME` is empty and no explicit value is set, fail and exit,
  rather than producing a path like `/.aibox/apps/<name>`.
- **Module uninstall deletes only the module's own body**; `apps/<name>` and config files are retained (they belong to "this deployment").

### Config path: `/etc/<name>/<name>.conf` (same name cross-platform)

| | Config dir | Deploy dir |
| --- | --- | --- |
| Write frequency | write once, read daily | **every command writes** |
| Location | `/etc/<name>/` | `$AIBOX_HOME/apps/<name>` |
| Allowed under privileged path | yes (privilege once at install) | no (daily commands would all need sudo) |

- Permissions: dir `755 root:root`, file **`644`** — **writes only happen at install** (can escalate),
  **reads happen on every command** (can't escalate). **So don't put credentials here.**
- **Seeded** by `install.sh` (from aibox global settings); policy is **supplement, don't overwrite**; the CLI **reads but never writes**.
- Don't use `/opt/<name>.conf`: `/opt`'s convention is "one package, one dir"; a lone config file has unclear ownership,
  and at uninstall you wouldn't know whether to delete it.
- When the config file doesn't exist, built-in defaults apply — behavior is identical to before its introduction.

> Current module status:
>
> - `openmaic` **aligned** (deploy root `$AIBOX_HOME/apps/openmaic`, config `/etc/openmaic`);
> - `windmill` **aligned** (deploy root `$AIBOX_HOME/apps/windmill`, config `/etc/windmill/windmill.conf`; CLI bash-3.2 compatible, scheduled tasks via systemd units);
> - `clash` **aligned** (deploy root `$AIBOX_HOME/apps/clash`; no `/etc` config — the subscription contains a token, so state/config/pool.yaml are all mode 600 under the deploy root; the mihomo binary is downloaded from GitHub by the install hook);
> - `pi-web` is install-type — no deploy root, paths stay platform-conventional.

## Proxy

Users can set a global proxy via `aibox proxy set <url>` (see the repo README). Modules consume it two ways:

**1. Via env vars (the common case — do nothing)**

Hooks are child processes of aibox; the proxy is already exported by the parent, so calling `curl` / `git` / `npm` just works.

**2. Persisted into the module's own config (required for cross-machine / cross-time)**

If the module's dispatched command will network on **another machine** or **when aibox isn't present** — e.g. the `openmaic`-dispatched CLI runs `openmaic upgrade` on the deploy host to pull source — env vars can't cross that boundary, so **the module must write the proxy into its own config file** in the install/update hook. See `sync_proxy_to_conf` in `tools/openmaic/lib.sh`.

Caveats:

- When no proxy is configured, `AIBOX_PROXY_URL` is empty and `AIBOX_PROXY_ENABLED=0`; the module should **skip gracefully** rather than erroring or writing an empty value.
- Don't assume the proxy is HTTP. The value may be `socks5://host:port`; **pass it through wholesale**, don't prepend `http://`.
- When writing the config file, remember to redact — the proxy URL may contain `user:pass@`; don't log it in cleartext (see `mask_url`).

## Download source pools (per-family acceleration)

**Pattern** (applies to EVERY download aibox performs): maintain a pool of
mainstream accelerated sources per family, **probe them concurrently with a
real download through the real channel**, rank by measured speed, serve from
the fastest, and **fail over down the ranking until every reachable source is
tried** — then (and only then) fail. DIRECT always races: healthy networks keep
zero-overhead defaults. User-configured mirrors join as candidates (raced, not
pinned). Mirrors that serve divergent/corrupt content are EXCLUDED from the
shipped pools (measured: ghproxy.link/ghproxy.cn truncated/wrong-size; tencent
node-dist index diverges).

### Family inventory

| family | consumer | mechanism (where) | shipped pool (live-verified) |
| --- | --- | --- | --- |
| npm | pi-web install/update | `npm_registry_pick` + `npm_install_global` (tools/pi-web/lib.sh) — concurrent tarball-throughput probe + wall-clock watchdog failover | registry.npmjs.org, registry.npmmirror.com, mirrors.cloud.tencent.com/npm, mirrors.huaweicloud.com/repository/npm |
| GitHub raw/api/releases | manager registry + module download + self-update + upgrade mappings | `gh_pool_fetch` (bin/aibox) — race + per-family file cache (TTL) + ghapi pseudo-candidate | direct, gh-proxy.com, ghproxy.net, CLASH_MIRROR/AIBOX_GH_MIRROR |
| GitHub (bootstrap) | install.sh (bin/aibox, SHA256SUMS) | `fetch_pool` (install.sh, bootstrap-local) — first-success race | direct + the same mirrors + AIBOX_GH_MIRROR |
| GitHub releases (~20MB) | clash mihomo download | `clash_gh_get` + `clash_rank_candidates` + resumable `download_mihomo` (tools/clash/lib.sh) — bounded rate probes of the actual asset, probe partial seeds the resume | direct + the same mirrors; CLASH_MIRROR joins |
| docker.io images | dify / gitlab / base compose pulls | `docker_pool_prepull` (each module's lib.sh) — direct daemon probe (healthy → zero overhead); dead → rank mirrors by concurrent hello-world pulls, pre-pull + `docker tag` (mirrors proxy identical digests) | docker.1ms.run, docker.m.daocloud.io, dockerproxy.net, hub.rat.dev (tencent-family excluded) |
| docker.io images (dispatched) | openmaic compose pulls (deploy host) | `docker_pool_prepull` hooked into its CLI's `compose()` on `up*` (tools/openmaic/cli/openmaic) — same mechanism | the same 4 mirrors |
| node dist | install_dep's nvm branch (node:22 deps) | `_node_dist_pick` (bin/aibox) — concurrent bounded probes of the REAL index nvm fetches; winner exported as NVM_NODEJS_ORG_MIRROR | nodejs.org, npmmirror.com/mirrors/node, mirrors.aliyun.com/nodejs-release (≥100KB size floor — a 404 page is small AND fast) |
| ghcr + docker.io (images) | windmill | `auto_ghcr_mirror` + `WM_HUB_MIRROR` (tools/windmill/cli/windmill) — throughput probe (layer growth), persist to .env, failure-driven re-probe | ghcr.nju.edu.cn, ghcr.dockerproxy.net — the in-repo PRECEDENT that seeded this pattern |
| npm (inside docker build) | openmaic render-service | baked `--registry=npmmirror` Dockerfile patch (tools/openmaic/cli) — predates this pattern | registry.npmmirror.com |

### Knobs (per family)

| family | env vars |
| --- | --- |
| npm | `AIBOX_NPM_REGISTRY` (pin), `AIBOX_NPM_REGISTRIES` (list), `AIBOX_NPM_TIMEOUT` (watchdog), `AIBOX_NPM_PROBE_TIMEOUT` |
| GitHub (manager) | `AIBOX_GH_POOL` (list; `direct` = off), `AIBOX_GH_MIRROR`/`CLASH_MIRROR` (user mirror), `AIBOX_GH_POOL_TIMEOUT`, `AIBOX_GH_POOL_TTL` (ranking cache) |
| GitHub (clash) | `CLASH_MIRROR`, `CLASH_TAG_TIMEOUT`, `CLASH_PROBE_TIME`, `CLASH_DOWNLOAD_TIMEOUT`, `CLASH_DOWNLOAD_ATTEMPTS` (per source) |
| docker.io | `AIBOX_DOCKER_POOL` (list; `direct` = off), `AIBOX_DOCKER_MIRROR` (user mirror), `AIBOX_DOCKER_FORCE_POOL` (skip the direct probe), `AIBOX_DOCKER_PROBE_TIMEOUT`, `AIBOX_DOCKER_MIRROR_PROBE_TIMEOUT`, `AIBOX_DOCKER_PULL_TIMEOUT` |
| node dist | `AIBOX_NODE_POOL` (list; `direct` = off), `AIBOX_NODE_MIRROR`, `AIBOX_NODE_PROBE_TIMEOUT` |
| ghcr (windmill) | `WM_GHCR_MIRROR`, `WM_GHCR_CANDIDATES`, `WM_GHCR_PROBE`, `WM_HUB_MIRROR` |

### Static preflight gates superseded by runtime pools

Where a module's runtime pool handles the family, the STATIC preflight gate
would false-fail exactly the mirror-saved networks, so it is removed (the deps
check still hard-gates the tool's existence):

- pi-web: no `domains: registry.npmjs.org` — `npm_registry_pick` probes at install time
- clash: no `domains: api.github.com/github.com` — `clash_gh_get`/`clash_rank_candidates` handle it
- dify / gitlab / base: no `docker_pull: hello-world` — `docker_pool_prepull` probes the daemon's direct route and falls back to the mirror pool; the upgrade engine's pre-pull no longer aborts on direct failure (warn + continue; health gate + auto-rollback remain the safety net)

### Boundaries (deliberately NOT pooled)

- the clash **subscription URL** — the user's own provider, fetched by mihomo (plain-curl probes 403 by design)
- `cr.weaviate.io` (dify's vector store) — no mainstream mirror proxies it; direct-only, documented
- openmaic's in-build npm — already accelerated via its Dockerfile patch

## Configuration (`env:` stanza + `config` action)

**Model — "seed at install, store after"**: the deploy's store is the single source of truth; environment variables are install-time seeds only. `PI_WEB_PASSWORD=x aibox update` takes effect ONCE and is written into the store; afterwards plain restarts use the stored value.

**Declaration (`module.yaml env:`)** — the CLI-discoverable config surface, same flat-map parser subset as `checks:`/`usage:`:

```yaml
env:
  PI_WEB_PASSWORD: "random — HTTP Basic Auth password (user pi) [secret]"
  PI_WEB_BIND: "0.0.0.0 — listen address"
  AIBOX_NPM_TIMEOUT: "240 — npm watchdog seconds [knob]"
```

Value shape: `default — description [flags]`. Flags: `secret` (masked in `config` listings; `config get` returns the plaintext) and `knob` (env-only runtime knob — declared for discovery, NOT persisted, excluded from the `config` view).

**Store (per module type)**:

| type | store | write | apply |
| --- | --- | --- | --- |
| compose | `apps/<m>/.env` | `cfg_kv_set` (shared helper) | `aibox <m> restart` (compose up -d recreates) |
| service-defined (pi-web) | plist `EnvironmentVariables` / unit `Environment=` | regenerate the whole definition (`write_service` — the single writer) | `restart` = bootout + bootstrap (RE-READS the definition; the old kickstart -k did not apply changes — live-caught) |
| CLI (windmill) | `/etc/<m>/<m>.conf` | `cfg_kv_set` | next invocation (immediate) |
| state (clash) | — | — | exempt: subscription/node state has its own action semantics |

**User surface**: `aibox <m> config` (list: value + masked secrets + defaults), `config get KEY` (plaintext single value, script-friendly), `config set KEY VALUE` (writes the store; interactively offers the apply, non-interactive prints the apply command), `config unset KEY` (back to the declared default). `aibox <m> --help` renders the declared keys (offline, local-first).

**Key mapping**: declared keys are the aibox-facing names; the store may carry the app's runtime names (pi-web: `PI_WEB_BIND` → plist `PI_WEB_HOSTNAME`, `PI_WEB_PORT` → `PORT`). The module maps them in its store read/write helpers — one user-facing name per knob.

**Shared helpers** (`tools/_shared/common.sh`): `cfg_kv_get/set/unset` (KEY=value stores: comments, order and mode preserved; idempotent), `cfg_env_declare` (module.yaml env: → tab-separated declaration lines), `cfg_secret_p`/`cfg_mask`, `cfg_action` (the generic `config` action implementation — a compose module's `config)` is one call), `cfg_confirm_apply` (default-Y, non-interactive declines to a hint).

**Validator (S17d)**: env entry format ERROR; every declared key documented in README (WARN); every README env-table key declared (WARN — the discoverability gap this closes); declared keys referenced in module code (WARN).

## Per-action help (`usage:` stanza)

Every module declares a `usage:` map in `module.yaml` — one entry per declared action. `aibox <module> --help` (and bare `aibox <module>`, `help`, `-h`) renders a fixed-column action table from this stanza; `aibox <module> <action> --help` renders the single action's usage block. Both are local-first (module cache → registry, no network when installed).

```yaml
actions:
  - start
  - credentials
usage:
  start: "Start the stack (docker compose up -d)"
  credentials: "Show admin + database credentials"
```

Format rules:

- One line per action: `<action>: "<description>"`. Args hints go FIRST, separated by ` — `: `"<node-name> — switch the active node"` — the action-level help splits on that separator to build `usage: aibox clash select <node-name>`.
- The **validator WARNs** when a declared action has no `usage:` entry (the table still renders, just without a description).
- The stanza is a flat two-space-indented map (same parser subset as `checks:`) — no nesting.
- Hyphenated action keys (`use-external`) are supported; the registry parser normalizes hyphens to underscores in variable names (`usage_use_external`), and the help renderer reads the cached `module.yaml` directly.
- An action with no usage entry (or a typo'd action name) + `--help` falls back to the module table — never a dead end.

## Shared library includes (`includes:` stanza)

Infrastructure code that every module needs (output helpers `log/warn/ok/info/die` + the docker.io download source pool) lives ONCE in the repo at `tools/_shared/common.sh`. A module declares it, and the downloader ships it into the module cache:

```yaml
includes:
  - common
```

- **Repo**: single source (`tools/_shared/common.sh`) — a pool fix or helper change lands once, not in N copies.
- **Cache**: each module dir gets its own copy (`~/.aibox/modules/<name>/_common.sh`) — modules stay **self-contained per-directory** (the dispatched-at-any-time constraint is unchanged; nothing depends on the aibox process).
- **lib.sh** resolves both layouts:

```bash
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_COMMON="${LIB_SELF}/_common.sh"                # cache layout (aibox install)
[ -f "${LIB_COMMON}" ] || LIB_COMMON="${LIB_SELF}/../_shared/common.sh"  # repo layout (direct exec / bats)
# shellcheck disable=SC1091
. "${LIB_COMMON}"
```

Rules:

- The include is fetched FIRST in `download_module` (before hooks) so a failed fetch never leaves the cache half-updated.
- Dispatched CLIs that run standalone on deploy hosts (openmaic/windmill `cli/<name>`) **cannot** use includes — they keep their own copies by design (pitfall #4: env vars and sources don't cross process/host boundaries).
- New shared libraries follow the same shape: `tools/_shared/<name>.sh` + `includes: [<name>]`; validator checks the entry resolves to an existing file.

## User command → hook mapping

| User command | Hook |
| --- | --- |
| `aibox install <name>` | `install.sh` |
| `aibox uninstall <name>` | `uninstall.sh` |
| `aibox update <name>` | `update.sh` (manager re-fetches module scripts first) |
| `aibox upgrade <name>` | manager engine — locates the deploy .env via the module's `lib.sh deploy_root`, rewrites image keys, then invokes `svc.sh start` (see §Component upgrades) |
| `aibox <name> <action>` | `svc.sh <action>` |

## Component upgrades (`aibox upgrade <module>` — upstream-driven, floor vs live)

**Problem**: the repo pins component versions (compose `${VAR:-pinned}`, `module.yaml`), so a
component release would otherwise wait for an aibox release. **Split the two concerns**:

- **Install floor** (repo-owned, tested, reproducible): `module.yaml` + compose `${VAR:-pinned}`
  defaults + `checks.docker_images`. Fresh installs always land on the floor.
- **Live version** (deployment-owned, floats independently of aibox): the deploy `.env`
  image keys (`DIFY_API_IMAGE`, `GITLAB_IMAGE`, …). Compose interpolation makes them authoritative
  for running containers; `aibox update` never clobbers the `.env`.

`aibox upgrade <module> [--check] [--to <version>] [--yes]` floats the live version to a newer
upstream release **without any aibox release**:

1. **Resolve** the target: `github-release` → `/releases/latest` of the declared repo;
   `dockerhub-tags` → the tags API filtered by `tag_pattern`, max by dotted-version compare.
   Fetches honor the run's proxy and fall back to the configured `CLASH_MIRROR`/`AIBOX_GH_MIRROR`.
2. **Guardrail**: auto-latest refuses to cross a **major** version (migration/data risk) —
   cross-major needs an explicit `--to`. EXCEPTION: modules providing a multi-hop path
   (see below) — the hop sequence IS the migration-safe path.
3. **Multi-hop path (optional, gitlab-style)**: when the module's cached `lib.sh` defines
   `upgrade_stops()` (same implicit-function contract as `render_dashboard`), the engine
   computes the required-upgrade-stops sequence between current and target
   (`_upgrade_path_compute`), resolves each intermediate stop's **latest patch** from the
   tags API, and executes one hop at a time — pull → per-hop `.env` backup → rewrite →
   `svc.sh start` (health gate) → next hop. Failure rolls back to the PREVIOUS hop
   (exit `20`). `--check` prints the whole hop table. Knob:
   `AIBOX_UPGRADE_HOP_SETTLE=<seconds>` (extra background-migrations wait).
4. **Pairing, not guessing**: when the app is multi-image, `mapping_url` points at the
   upstream compose **at the target tag** (the `<VER>` placeholder is substituted); each
   declared image key's tag is extracted from it. Dify's sandbox/plugin-daemon/agent-backend
   pairing thus always matches what the target release itself ships.
5. **Fail fast**: every new image is `docker pull`ed BEFORE anything is touched (daemon egress
   probed the same way preflight does; failure → exit `4`, nothing changed).
6. **Atomic-ish apply**: `.env` → `.env.bak.<ts>` backup; ONLY the declared image keys are
   rewritten (missing keys appended, mode preserved); containers recreated via the module's own
   `svc.sh start` (which health-waits per its normal contract).
7. **Auto-rollback**: failed health check → restore the backup, recreate, exit `20` with the
   retry hint.

The current live version is reported by `--check`, shown by `dashboard` (module's
`dashboard_info` may print `version=…` from its `.env`), and recorded in the installed-state
marker after a successful upgrade (note: a subsequent `aibox update <module>` re-marks the
floor — the `.env` keeps the live version; cosmetic only).

### `upgrade:` stanza (module.yaml, flat shape — parser-compatible like `checks:`)

```yaml
upgrade:
  source: github-release          # github-release | dockerhub-tags
  repo: langgenius/dify            # github repo, or dockerhub repository
  # Optional: upstream compose at the target tag — the image-tag pairing source.
  # <VER> is substituted with the target version.
  mapping_url: https://raw.githubusercontent.com/langgenius/dify/<VER>/docker/docker-compose.yaml
  tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$'   # dockerhub-tags: stable-tag filter
  images:                          # .env key = upstream image prefix — the engine APPENDS the
                                   # resolved version to the whole value. Classic form ends with
                                   # ':' (…dify-api: → :1.17.2); upstreams that prefix their
                                   # tags use a tag prefix (…xiaozhi-esp32-server:server_ →
                                   # :server_0.9.7 — upstream tags git v0.9.7 as server_0.9.7)
    - DIFY_API_IMAGE=langgenius/dify-api:
```

Rules:

- **Opt-in**: no stanza → `aibox upgrade <module>` declines cleanly. Modules whose images
  already float by design (base's `postgres:18`) or that own their own upgrade path
  (windmill/openmaic CLIs, npm-based pi-web) don't need one.
- **Infra images stay on the floor** (DB/Redis/vector-store): float them manually in the `.env`
  only when you accept the data-compat implications (PG major upgrades need migration steps).
- Declaring `upgrade:` opts into the standard deploy-root `.env` contract
  (§Deploy directory) — the engine locates it via the module's own `lib.sh deploy_root()`.
- `aibox upgrade dify --to 1.18.0` works WITHOUT any resolution network (direct pin) — the
  escape hatch when registries are unreachable from the host.

## Exit code convention

Hooks and dispatched CLIs should follow unified exit codes so automation (`aibox <module> <action>; echo $?`) can depend on them stably. `aibox` itself uses `die` → exit `1`.

| Code | Meaning | Example |
| --- | --- | --- |
| 0 | success | — |
| 1 | runtime error (general) | command execution failed |
| 2 | usage error / declined non-interactively | bad args; a dangerous op wasn't confirmed in a non-interactive env |
| 3 | dependency missing | platform/command not satisfied (e.g. deploy command on non-Linux) |
| 4 | precheck failed | config missing, image unpullable |
| 10 | upgrade failed, rolled back | — |
| 20 | manual intervention needed | health check failed; not ready after rollback |
| 30 | service not ready | container started but didn't pass health check |
| 40 | concurrency conflict | couldn't acquire the lock (another op is running) |
| 50 | user cancelled | interactive confirmation chose "no" |

Conventions:

- `aibox <module> <action>` returns the svc hook's exit code to the caller as-is (`AIBOX_MODULE=... bash "$svc"`).
- Dangerous ops **decline by default in non-interactive environments** and return `2`, never executing silently (see [Interactive confirmation](#interactive-confirmation) below).
- Dispatch-type modules' (openmaic/windmill) CLI bodies already implement this scheme; new modules should align.

## Interactive confirmation

Irreversible ops (uninstalling a deploy, wiping data volumes, teardown) must be interactively confirmed, following a unified pattern:

- **Dangerous ops use `confirm "<prompt>"`**: requires typing `yes` to proceed; honors `--yes`/`-y` (`ASSUME_YES=1`, skip confirmation) and `--dry-run` (show only, don't execute). openmaic/windmill's `confirm` already does this.
- **Soft choices use `ask_yn "<prompt>" [y|n]`**: default `n` (decline) or `y` (accept); **non-interactive environments (`[ -t 0 ]` false) always take the conservative default** with a warning.
- The main CLI's `ask_confirm` (`bin/aibox`) is the soft-choice, default-decline, non-interactive-returns-`1` variant. `aibox uninstall self` uses it for the confirm gate (non-interactive requires `--yes`).
- **Never silently execute a dangerous op**: non-interactive + no `--yes` returns `2` instead of `0`, so scripts and CI can notice.

### The two-gate uninstall model (`aibox uninstall <module>`)

Every destructive verb follows the same shape; module uninstall is the reference:

1. **Gate 1 — the operation itself**: `ask_confirm "Uninstall <m>? (what it does; what is kept)"` — `[y/N]`, default decline; `--yes` skips; non-interactive without `--yes` → exit `2`, nothing runs.
2. **Gate 2 — data cleanup, asked INLINE**: `ask_confirm "Also DELETE the data? …"` — the answer feeds `AIBOX_PURGE_DATA` into the SAME hook invocation (one run carries the whole decision). `--purge` = explicit intent (skips the question); non-interactive without `--purge` keeps data (the safe default) and prints the residue hint.

The data question being inline removes the dead round-trip the old flow forced: `aibox uninstall <m>` then `aibox uninstall <m> --purge` — the latter warns "not installed" (the hook contract needs the installed state); the correct post-uninstall cleanup is `aibox purge <m>`. Module hooks print that guidance.

Gate coverage: uninstall (2 gates) · uninstall self (confirm per teardown scope) · purge `--apply` (confirm + dry-run default + an inline "stop RUNNING containers?" question — `--stop` pre-answers yes; non-interactive skips them with a single hint, never a partial-stopping state) · upgrade (confirm) · proxy set (confirm) · dispatched CLIs' `confirm` (windmill destroy etc.).

## Preflight checks (mandatory for every module)

Install/update is **gated** by a preflight check (`preflight_module` in `bin/aibox`). Every module —
existing and future — MUST declare a `checks:` section in `module.yaml`; CI enforces both the
section's presence and its field formats.

### What gets checked (in order)

| Check | Source | Semantics |
| ------- | -------- | ----------- |
| deps | `deps:` field | strict: missing after an auto-install attempt → **FAIL** (the old warn-and-continue behavior is gone) |
| commands | `checks.commands` | binary must exist (`cmd@platform` supported; no auto-install — these are OS facilities like `systemctl@linux` / `launchctl@darwin`) |
| disk | `checks.disk_gb` | free space at `$AIBOX_HOME`'s filesystem ≥ N GB → else **FAIL** |
| domains | `checks.domains` | each probed as `https://<host>/` via the **host's** curl/egress; any HTTP response (even 401/404) = reachable, connection failure = not. All must pass |
| docker pull | `checks.docker_pull` | **daemon-routed** probe: `docker pull <tiny image>` proves the daemon's actual registry path (its mirrors/proxy differ from the host's). Skipped when docker is absent (deps reports that) |
| docker images | `checks.docker_images` | when **all** refs exist locally, the domain AND pull probes are skipped (offline restart/install works) |
| services | `services:` field | recursive: provider `base` must be installed (profile-scoped); if its stack isn't running, **base's own preflight** runs — passes → install proceeds (`ensure_services` auto-starts it); fails → **FAIL** |
| services_optional | `services_optional:` field | **NOT gated** — documentation of a deploy-time user toggle (e.g. dify `DIFY_SHARED_BASE=1`): the entry format is validated (provider form), but install/update never require the provider. Two consumption modes exist: hard (`services:` — the module cannot run without the shared component) and opt-in (`services_optional:` — standalone by default, joins the shared base only when the user flips the deploy env knob) |

### Host vs daemon probe semantics (pick the right channel)

`domains:` probes run through the **host's** curl with aibox's egress (and the route fallback
below applies). The **docker daemon has its own egress** — Docker Desktop's VM network,
`/etc/docker/daemon.json` `registry-mirrors`, daemon-level proxy settings — none of which aibox's
proxy/clash configuration touches. Measured reality: a macOS host where `curl https://registry-1.docker.io/v2/`
times out on every host route while `docker pull` succeeds in 8s. Therefore:

- Registries consumed by **host tools** (npm/git/curl downloads) → declare in `domains:`.
- Registries consumed by the **docker daemon** (image pulls/builds) → declare `docker_pull: <tiny image>`
  (e.g. `hello-world`, 5.8KB) instead; on failure the hint points at daemon-side config, not `aibox proxy`.
- Exception: `ghcr.io` stays a host-probed domain for windmill — no canonical tiny ghcr image exists
  for a pull probe, and on typical Linux deploy hosts daemon and host share egress.

### Network failure → automatic route fallback

When domains are unreachable via the current egress, the engine tries the **configured**
alternatives in order — `direct` (bypass proxies), `clash` (the clash pool's mixed port, if a
clash state exists), `mirror` (GitHub-family domains via a gh-proxy-style URL-prefix mirror when
`CLASH_MIRROR`/`AIBOX_GH_MIRROR` is set — this solves the bootstrap paradox: on CN networks
github.com may be unreachable while the clash module that would fix it downloads FROM GitHub),
`proxy` (the static `AIBOX_PROXY_URL`, even when disabled) — and **adopts the
first route that makes ALL failed domains reachable**, for this run only. The warning tells you how
to make it permanent (`aibox clash on` / `aibox proxy on` / `aibox proxy off`); the mirror route
adopts nothing (modules honoring `CLASH_MIRROR` just work). Nothing is tried
that isn't already configured; global config is never changed silently.

Bootstrap pattern on a blocked network (before clash exists):

```bash
CLASH_MIRROR=https://gh-proxy.com aibox install clash   # preflight passes via the mirror route
aibox clash set <subscription-url> && aibox clash on    # real egress from here on
```

### CLI surface

```bash
aibox check self               # environment: egress route, core domains (raw.githubusercontent/api.github), docker, disk
aibox check <module>           # that module's full preflight (usable before installing)
aibox install <module> [--skip-checks]
aibox update  <module> [--skip-checks] [--all]
AIBOX_SKIP_CHECKS=1 aibox install <module>   # script-friendly bypass
AIBOX_CHECK_TIMEOUT=3 aibox check <module>   # per-probe timeout (default 8s)
```

`--skip-checks` bypasses the WHOLE preflight (deps included) — for air-gapped installs with
pre-staged dependencies. A failed preflight aborts install/update **before** any hook runs.

### Per-module check matrix (current modules)

| module | disk_gb | domains (host-probed) | docker_pull (daemon-probed) | docker_images | commands | services |
| -------- | :---: | --------- | --------- | --------------- | ---------- | ---------- |
| base | 5 | — | — (docker.io pool at start) | postgres:18, redis:7 | — | — |
| clash | 1 | — (GitHub source pool) | — | — | — | — |
| dify | 10 | — | — (docker.io pool at start) | langgenius 1.17.1 set + postgres/redis/weaviate (offline-restart short-circuit) | — | — |
| gitlab | 15 | — | — (docker.io pool at start) | gitlab/gitlab-ce:19.2.6-ce.0 | — | — |
| openmaic | 20 | github.com | hello-world | — | — | base:postgres#openmaic |
| pi-web | 2 | — (npm registry pool) | — | — | launchctl@darwin, systemctl@linux | — |
| windmill | 12 | ghcr.io (its CLI auto-probes ghcr mirrors) | — | — | — | base:postgres#windmill, base:redis |

Notes: entries marked "pool" have their static gate REMOVED — the runtime download
source pool (see §Download source pools) probes the real channel and fails over,
so a static direct-egress gate would false-fail exactly the mirror-saved networks.
The clash **subscription URL** is user-supplied and fetched by mihomo with its own
UA — plain-curl probes return 403 by design, so it is deliberately not a checked
domain (same class: not poolable). Disk floors
match measured reality (windmill images ≈ 9.5G live; openmaic's render-service Chromium build is
heavy) and windmill's own `doctor` contract (≥ 12G).

## Dependency declaration & auto-check

Modules declare a `deps` field in `module.yaml` (command names, list); `aibox install` auto-checks and installs by platform if missing:

- **Format**: `command` / `command@platform` (check on that platform only) / `command:version` (major-version constraint)
- **Examples**: `docker@linux docker-compose git` (docker on Linux only), `node:22 npm` (node 22+), `python3`
- **When**: `aibox install/update <module>` runs deps as part of the **preflight** (strict — missing after an auto-install attempt aborts the operation; see §Preflight checks). `--skip-checks` bypasses.
- **Platform filter**: a `platform=darwin` module skips the check on non-darwin; `@platform`-tagged deps are skipped off-target (just a hint)
- **Auto-install** (`install_dep`):
  - Lightweight / has a package manager → install (macOS brew / Linux apt/yum/dnf)
  - Needs sudo (apt/yum) or GUI interaction (Docker Desktop) → **print the manual command**, never silently sudo
  - node reuses nvm (pi-web pattern)
- **Unknown deps**: print a manual-install hint

## Design tradeoffs

- **Registry uses a shell-sourceable format, not JSON**: zero runtime dependencies, compatible with macOS bash 3.2; the main CLI sources it directly, no `jq`/`python`. (Now via `module.yaml` + an awk subset parser; yq validates the subset in CI.)
- **Module scripts are cached on disk**: aibox downloads module scripts to `~/.aibox/modules/<name>/` before executing; hooks reuse `lib.sh`; `svc.sh` pass-through doesn't re-fetch.
- **Platform is self-reported by the module**: a `platform=darwin` module only warns on non-macOS (the module's own error at runtime is clearer).

## module.yaml (source of truth)

> **`registry.sh` is gone.** `load_registry` discovers modules from `tools/*/module.yaml` (local source globs directly; remote source uses the GitHub API + caches with TTL). **Adding a module = create `tools/<name>/` + `module.yaml`; local source needs zero global changes.**

### module.yaml fields (normative schema: docs/module-spec.md §Registering a module)

name/version/description/platform/dir/deps/ports/files/hooks/actions/upstream/dashboard.

### ports field (port/proto:usage)

CI `port-conflict` checks port+proto uniqueness (spec §3). The `aibox dashboard` overview lists the assignment table + does an lsof listen probe.

### dashboard_info() interface (spec §4.4)

Each module's `lib.sh` implements `dashboard_info()`, outputting key=value lines.
Called by `aibox dashboard` / `aibox <module> dashboard`.

| key | meaning | notes |
| --- | --- | --- |
| `endpoint` | the service URL | annotated `(stopped — aibox <module> start)` when the state is stopped |
| `credential` | auth hint | rendered as `auth:` |
| `version` | deployed app version | the keyline header segment (cyan); first token feeds the async updates comparison; `version=` is REQUIRED (validator S19) |
| `state` | **machine-readable service state** — one of `ok` / `starting` / `stopped` / `na` | the overview renders the composite icon: `✓` ok (green) · `⚠` starting (yellow) · `○` stopped (dim) · `na` = no marker (CLI-type modules — openmaic/windmill: their state is a remote deploy's, `aibox <module> status` is the real view). The probe is the module's own (pg_isready / http_up / docker health) — local-only, so the local-first rule holds. Stale caches without `state=` fall back to the declared-port listening heuristic. |
| `health` | human detail line | free text: probe verdict, starting hint, or the copy-paste probe command |
| `log` | log location | rendered as `log:` |

Example (new-api):

```bash
dashboard_info() {
  …
  if container_running; then
    if api_up "${port}"; then echo "state=ok"; echo "health=ok (api answers on :${port})"
    else echo "state=starting"; echo "health=starting (container up, api not ready yet)"; fi
  else
    echo "state=stopped"; echo "health=stopped"
  fi
}
```

### Dashboard template (keyline)

Spec source: `docs/superpowers/specs/2026-09-23-dashboard-app-version-keyline-design.md`.

Every dashboard surface (module rich view via `render_dashboard`, manager
overview, manager detail view) renders the SAME keyline template, from shared
helpers in `tools/_shared/common.sh` (`dash_header` / `dash_row` /
`dash_module_row` / `dash_rule` / `dash_secheader`; bin/aibox inlines twins):

```text
pi-web 0.9.3 · ✓ running
────────────────────────────────────────────
  service    launchd · pid 38243
  endpoint   http://127.0.0.1:30141 · HTTP 307 ✓
  auth       pi / ai-coding
  log        ~/Library/Logs/pi-web.log
  module     1.3.5 · ~/.aibox/modules/pi-web/
```

Rules:

- **Two versions, two places**: the **app version** (deployed software: npm
  package / image tag / kernel tag / dispatched CLI) is the cyan header
  segment, reported by `dashboard_info`'s `version=` and, in rich views, an
  `app_version()` helper; the **module version** (aibox packaging,
  module.yaml `version:`) is the SUNK last row — whole row dim. Never show
  the module version where the app version is expected.
- `dash_header <name> <appver> <state>`: appver `""` omits the segment;
  states `ok|running` → `✓`, `starting` → `⚠`, `stopped` → `○`,
  `na`/`""` → no segment. Manager overview headers show the icon only.
- `dash_row <label> <value>`: ASCII label ≤10 chars in a `%-10s` grid, NO
  colon; values verbatim — never byte-truncate (CJK stays ragged-right,
  pitfall #6).
- Rule width: TTY → `tput cols` clamped [40,72]; non-TTY → 64. `─` literals
  are complete characters, never sliced.
- `health=` merges into the endpoint row (`<url> · <health>`); `state=stopped`
  appends the dim `(stopped — aibox <module> start)` hint instead.
- `dashboard`/`status` actions render the keyline view only; raw
  launchctl/systemctl/lsof dumps belong to `diagnose`.
- New modules: the scaffolder emits the skeleton (app_version TODO +
  dashboard_info with `version=` + render_dashboard via dash_header);
  the validator WARNs on gaps (S18/S19).

### DB naming convention (shared base, spec §5.4)

Single DB: `<module>`; multiple DBs: `<module>_<usage>`. `aibox base create postgres <module> [usage]` creates the DB.

### base module (spec §5)

`tools/base/` ships shared PG18+Redis7 (compose + create). Deploy-type modules connect to the shared instance (.env DATABASE_URL + compose override network, see `tools/openmaic/docker-compose.shared.yml`).

### hooks field parsing

The awk parser strips the parent prefix for `hooks:` nesting (`hooks.install` → `AIBOX_MODULE_<name>_install`, compatible with `module_field`); upstream/dashboard keep the prefix (`_upstream_homepage`, `_dashboard_hint`).

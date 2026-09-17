# aibox module spec

Each aibox "module" is an independent tool, living under `tools/<name>/` in the repo, installed / updated / uninstalled / dispatched uniformly by the main CLI `aibox`.

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
files:                             # optional. extra files only; the standard 5 (lib.sh/install.sh/uninstall.sh/update.sh/svc.sh) are implicit
  - docker-compose.yml
hooks:                             # required. hook filenames
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh
actions:                           # optional. actions svc supports (list all)
  - start
  - stop
upstream:                          # optional. dev-guide links (see §6 of module-system-spec.md)
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
```

See `docs/module-system-spec.md` §2.3 for the full field reference.

> **History note (registry.sh):** before v0.4.0, modules were registered by appending `AIBOX_MODULE_<name>_*` shell variables to a root-level `registry.sh` (sourced directly by the CLI). That file no longer exists; the same fields now live in `module.yaml` and are parsed by a zero-dependency awk subset parser at runtime (`parse_yaml_module_stdin`), with yq validating the subset in CI. Module names with hyphens map to underscored variable keys internally (`pi-web` → `AIBOX_MODULE_pi_web_*`); that convention is unchanged.

## Hook contract

- aibox downloads the files listed in `files` (plus the standard 5 implicitly) to `~/.aibox/modules/<name>/`, then invokes them as `bash <dest>/<hook>.sh [args]`.
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

  The color vars `C_RST` / `C_DIM` / `C_BOLD` / `C_GRN` / `C_YEL` / `C_RED` / `C_CYA` are also exported (empty when piped or `NO_COLOR=1`). A module's `log`/`warn`/`die` should use `${C_CYA:-}` etc. and `${AIBOX_MODULE:-<name>}` as the prefix — no per-module color setup is needed (single source of truth in `bin/aibox`).
- `install.sh` installs the module itself (paths are self-determined, e.g. pi-web writes a launchd plist).
- `svc.sh`: `$1` = action, rest pass through.
  - **`svc.sh` is an "action entry point", NOT "must be a daemon".** Long-lived-service modules (e.g. pi-web) implement `start/stop/restart/status/logs/diagnose`. Dispatch-only modules (e.g. openmaic) can just pass through: `exec <dispatched-cmd> "$1" "$@"`, where the action set is that command's subcommands. The contract is "the file named by `hooks.svc` receives `(action, args...)`" — nothing more.
- Start install paths from `${AIBOX_BIN_DIR:-$HOME/.local/bin}` and expose a module-specific override (deploy hosts often want `/usr/local/bin`).
- Platform differences: warn, don't hard-block. Install is usually cross-platform; the real limit is reported by the script at execution time, which is less false-positive-prone than blocking at install.

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

- **`aibox self uninstall` must be fail-closed.** When `apps/` is non-empty it **refuses by default** and lists the deploys
  (databases, backups) that would be deleted; an explicit `--yes` is required to proceed. A bare `rm -rf "$AIBOX_HOME"`
  with a one-line prompt is not protection. (Consistent with "dangerous ops return 2 non-interactively".)
  **Implemented**: `aibox self uninstall [--yes]` — when `apps/` is non-empty it lists deploys and requires interactive
  confirmation; non-interactive without `--yes` returns `2` and changes nothing; `--yes` is accepted before or after the subcommand.
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

## User command → hook mapping

| User command | Hook |
| --- | --- |
| `aibox install <name>` | `install.sh` |
| `aibox uninstall <name>` | `uninstall.sh` |
| `aibox update <name>` | `update.sh` |
| `aibox <name> <action>` | `svc.sh <action>` |

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
- The main CLI's `ask_confirm` (`bin/aibox`) is the soft-choice, default-decline, non-interactive-returns-`1` variant. `aibox self uninstall` uses it for fail-closed behavior when `apps/` is non-empty.
- **Never silently execute a dangerous op**: non-interactive + no `--yes` returns `2` instead of `0`, so scripts and CI can notice.

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
clash state exists), `proxy` (the static `AIBOX_PROXY_URL`, even when disabled) — and **adopts the
first route that makes ALL failed domains reachable**, for this run only. The warning tells you how
to make it permanent (`aibox clash on` / `aibox proxy on` / `aibox proxy off`). Nothing is tried
that isn't already configured; global config is never changed silently.

### CLI surface

```bash
aibox check                    # environment: egress route, core domains (raw.githubusercontent/api.github), docker, disk
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
| base | 5 | — | hello-world | postgres:18, redis:7 (cached → skip probes) | — | — |
| clash | 1 | api.github.com, github.com (mihomo release; `CLASH_MIRROR` overrides the download base) | — | — | — | — |
| pi-web | 2 | registry.npmjs.org | — | — | launchctl@darwin, systemctl@linux | — |
| openmaic | 20 | github.com | hello-world | — | — | base:postgres#openmaic |
| windmill | 12 | ghcr.io (shared-PG mode pulls nothing from docker.io) | — | — | — | base:postgres#windmill, base:redis |

Notes: the clash **subscription URL** is user-supplied and fetched by mihomo with its own UA —
plain-curl probes return 403 by design, so it is deliberately not a checked domain. Disk floors
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

### module.yaml fields (see docs/module-system-spec.md §2.3)

name/version/description/platform/dir/deps/ports/files/hooks/actions/upstream/dashboard.

### ports field (port/proto:usage)

CI `port-conflict` checks port+proto uniqueness (spec §3). The `aibox ports` command lists the assignment table + does an lsof listen probe.

### dashboard_info() interface (spec §4.4)

Each module's `lib.sh` implements `dashboard_info()`, outputting key=value: endpoint/credential/log/health. Called by `aibox dashboard` / `aibox <module> dashboard`.

### DB naming convention (shared base, spec §5.4)

Single DB: `<module>`; multiple DBs: `<module>_<usage>`. `aibox base create postgres <module> [usage]` creates the DB.

### base module (spec §5)

`tools/base/` ships shared PG18+Redis7 (compose + create). Deploy-type modules connect to the shared instance (.env DATABASE_URL + compose override network, see `tools/openmaic/docker-compose.shared.yml`).

### hooks field parsing

The awk parser strips the parent prefix for `hooks:` nesting (`hooks.install` → `AIBOX_MODULE_<name>_install`, compatible with `module_field`); upstream/dashboard keep the prefix (`_upstream_homepage`, `_dashboard_hint`).

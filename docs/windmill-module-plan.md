# Adapting the windmill Ops CLI as an aibox Module — Plan

> Status: **Implemented** (windmill v1.1.0, see registry.sh; deploy-root/config placement aligned with the docs/module-spec.md conventions. This document is a historical design record.)
> Goal: Add a `tools/windmill/` module to the aibox repo to bring the Windmill self-hosted ops CLI under management.

## Revision Notes

### v1 → v2

Revised three premises based on feedback:

| Item | v1 assumption | v2 revision |
| --- | --- | --- |
| Where it runs | aibox on Mac remotely manages a Linux host | **All local**; the module only does "install to this machine", no scp / ssh involved |
| Platform | Linux deploy host only | **Must adapt to both macOS and Linux** (reserved for future work; this round gets Linux working first) |
| Proxy | Add a new `windmill proxy` subcommand to manage the daemon proxy | **Not added**; proxy uniformly goes through aibox's global config (rationale in §4.4) |

### v2 → v3

| Item | v2 plan | v3 revision |
| --- | --- | --- |
| Config placement | Two locations split by platform (Linux `/etc/`, macOS XDG `~/.config/`) | **Unified to `/etc/windmill/windmill.conf`**; macOS allows one-time privilege escalation during install → the platform branch is eliminated (see §3.3) |
| Deploy directory | Only said "macOS needs to move away", without enough reason | Added hard reasons: **must be under `/Users`** (`~/windmill`) — Docker Desktop does not share `/opt` by default, and the relative mount in `./Caddyfile` would hit `Mounts denied` (see §3.3) |

### v3 → v4

| Item | v3 plan | v4 revision |
| --- | --- | --- |
| Deploy directory | Linux `/opt/windmill`, macOS `~/windmill` — still leaves **one platform branch** | **Both platforms unified to `$AIBOX_HOME/apps/windmill`** (= Linux `/root/.aibox/apps/windmill`, macOS `~/.aibox/apps/windmill`); the platform branch is gone entirely; the backup evacuation directory is likewise unified to `$AIBOX_HOME/backups/` |
| Premise | Not mentioned | Added two **prerequisites** (skipping them is an incident): ① `aibox self uninstall` changed to fail-closed (currently a bare `rm -rf "$AIBOX_HOME"`, which would take the databases down with it); ② the systemd unit must explicitly set `Environment=` (**verified: there is no `HOME` in the system service**) |
| Spec scope | Only this module | The deploy root is written into `docs/module-spec.md` as a **cross-module convention** |

### v4 → v5

| Item | v4 plan | v5 revision |
| --- | --- | --- |
| Existing instance | Phase 7 does an explicit **migration** (`/opt/windmill` → new location) | **No migration, just reinstall** — the existing footprint is still small; the cost of wiping and reinstalling is lower than long-term maintenance of a one-time migration path (see §6 Phase 7) |
| Existing module alignment | openmaic's `/opt/openmaic` listed as "to be aligned later" | **Already aligned**: openmaic's deploy root changed to `$AIBOX_HOME/apps/openmaic`; `pi-web` confirmed as install-type, **does not introduce a deploy root** |
| Prerequisites | Only listed in the risk table | The fail-closed `cmd_self_uninstall` **is implemented and tested** (Phase 0 complete) |

## 1. Conclusion

There is an existing template: **`tools/openmaic/` is isomorphic to windmill** (single-file bash ops CLI, Docker Compose deployment, command-domain separation, exit-code tiers, existing concurrency lock). Copy the module skeleton directly.

The real workload is in the CLI itself:

| # | Refactor item | Necessity |
| --- | --- | --- |
| 1 | Strip the intranet-proxy binding (also lands in the generated compose file) | **Required** |
| 2 | Prefix the version variable (`CLI_VERSION` → `WINDMILL_CLI_VERSION`) | **Required** |
| 3 | Placement convention: config unified to `/etc/windmill/windmill.conf`, deploy unified to `$AIBOX_HOME/apps/windmill` | Recommended |
| 4 | Platform abstraction layer (foundation for macOS adaptation, 8 spots total) | Foundation this round; fill in later |
| 5 | `aibox self uninstall` changed to fail-closed (**prerequisite**, see §3.3) | **Required** |

## 2. Isomorphism

### 2.1 Parts directly reusable from openmaic

Target platform (Linux + docker compose), CLI form (single-file bash), command-domain separation, exit-code tiers, concurrency lock, and the entire hook contract and `lib.sh` structure.

### 2.2 Differences

| # | Dimension | openmaic | windmill current | Handling |
| --- | --- | --- | --- | --- |
| 1 | Placement | Config `/etc/openmaic`, deploy `/opt/openmaic` (separated) | All in `/opt/windmill` (config and runtime not separated) | Config → `/etc/windmill/windmill.conf`; deploy → `$AIBOX_HOME/apps/windmill`, see §3.3 |
| 2 | Intranet binding | None | Hardcoded intranet proxy, and **written into the generated compose** | Must strip |
| 3 | Version variable | `OPENMAIC_CLI_VERSION` | `CLI_VERSION` (generic name) | Add prefix |
| 4 | Platform guard | Yes (exit code 3) | None | Add |
| 5 | `--json` | Yes | None | Optional, not done this round |
| 6 | macOS parsing | Needs to avoid bash 4 syntax | **Verified `bash -n` passes** | No handling needed |

> **Item 6 is good news**: the windmill CLI parses cleanly under macOS's built-in bash 3.2, meaning the runtime guard can give a clear message instead of hitting a syntax error first like openmaic.

## 3. Four CLI Items to Refactor

### 3.1 Strip the intranet binding (required)

```bash
# Line 23
DEFAULT_PROXY="http://<intranet-IP>:7897"
# Line 1146 — more severe
WM_PROXY=${DEFAULT_PROXY}      # lands in the docker-compose.yml generated by windmill init
```

Line 1146 means **every generated compose carries the intranet address**, and it stays on the target machine with the deployment.

Fix:

- Remove `DEFAULT_PROXY`; `PROXY_URL` changes to a three-tier read "command line > env var > conf", **default empty**.
- At render time, leave `WM_PROXY=` empty, and **branches depending on it must skip gracefully** (when empty, do not run `curl -x http://`).
- Self-check: `grep -rn '192\.168\.' tools/windmill/` must be 0.

### 3.2 Prefix the version variable

`CLI_VERSION` → `WINDMILL_CLI_VERSION` (including references at lines 2801, 2819).
The module's `lib.sh` reads it with `sed -nE 's/^WINDMILL_CLI_VERSION="([^"]+)".*/\1/p'`, keeping the same convention as `OPENMAIC_CLI_VERSION`.

### 3.3 Placement convention — config `/etc/windmill/`, deploy `$AIBOX_HOME/apps/windmill`

**Conclusion: both have the same shape on both platforms; no platform branch.** Writing config to `/etc/windmill/windmill.conf` requires `sudo`, but **only once during install** (the module's `install.sh` hook) — after install, daily commands like `status` / `up` / `logs` / `backup` need no privilege escalation; the deploy directory lives under `$AIBOX_HOME/apps/`, and daily commands need no privilege escalation either.

**Why `/etc/windmill/` and not `/opt`**

First, separate the three meanings of "put it under `/opt`":

| Placement | Result |
| --- | --- |
| Inside `/opt/windmill/` (current: `.env`, `backups/`) | **Invalid** — `destroy` is just `rm -rf "$WM_DIR"`; moving to a deeper subdirectory still deletes it |
| Under `/opt/` root (e.g. `/opt/windmill.conf`) | Survives (not inside `WM_DIR`), but ownership is unclear: the `/opt` convention is "one directory per package" (`/opt/<package>/`). A lone config file leaves no one knowing who it belongs to or whether to delete it on uninstall |
| **`/etc/windmill/` (recommended)** | See below |

`/etc` is correct on four dimensions:

| Dimension | Basis |
| --- | --- |
| Semantics | FHS (`man 5 hier`): `/etc` = *host-specific system configuration*. Proxy, image mirrors, ports are exactly **host-specific settings invariant across deploy instances** |
| Precedent | `/etc/docker/daemon.json`, `/etc/caddy/`, `/etc/nginx/` — similar "single-machine daemon-service deployments" all do this |
| Cross-platform | On macOS, `/etc` is a symlink to `/private/etc`, writable with `sudo`; on Linux, deployment itself is done as root. **The same path works, no branch needed** |
| Does not vanish with the deployment | Outside `$WM_DIR`; `destroy --all` cannot reach it |

`/opt/windmill.conf` has another hard flaw: on a Linux server, `/opt` is also `root:root 755`, and **you can write to it only because you operate as root**. Once you target two platforms, that "writable" feeling immediately breaks; whereas `/etc` does not rely on this assumption — it is explicitly "put files here that require privilege to change", semantically self-consistent.

**Permissions: directory `755 root:root`, file `644 root:root`**

The key is read/write separation: **writes happen only during install (need sudo); reads happen on every command (must not need sudo)**, so the file must be `644`, letting ordinary users read it.

> Direct consequence: **do not put credentials in this file** (644 means whole-machine readable). If you ever need to store proxy credentials, the only option is `600`, at the cost of escalating on every run on macOS — not worth it; credentials stay in aibox's own config. Currently the proxy has no credentials, so it's safe.

**Key distinction: config can be unified to `/etc`, the deploy directory cannot**

The two have completely different requirements for "who writes, how often":

| | Config directory | Deploy directory `WM_DIR` |
| --- | --- | --- |
| What the CLI does to it | **Write once, read daily** | **Writes on every command** |
| Contents | Proxy / image mirror / port | `.env`, `docker-compose.yml`, `Caddyfile`, `CREDENTIALS.txt`, `backups/`, `logs/`, `.lock` (L66–72 verified all inside `$WM_DIR`) |
| Put in `/etc`, `/opt` | Works (one-time sudo acceptable) | **Does not work** — even a read-only command like `status` would need privilege escalation |

**Deploy directory: both platforms unified to `$AIBOX_HOME/apps/windmill`** (cross-module convention written into `docs/module-spec.md`)

```bash
APPS_ROOT="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}"
WM_DIR="${WM_DIR:-$APPS_ROOT/windmill}"
WM_CONF_FILE="${WM_CONF_FILE:-/etc/windmill/windmill.conf}"   # no platform branch
```

| Platform | Identity | Deploy directory |
| --- | --- | --- |
| macOS | Ordinary user | `~/.aibox/apps/windmill` |
| Linux | root | `/root/.aibox/apps/windmill` |

One expression, no platform branch. The first two of the three hard constraints come from real testing (see module-spec):

1. **macOS is locked by Docker Desktop's shared list** — by default it only shares `/Users`, `/Volumes`, `/private`, `/tmp`, `/var/folders` (official docs). And compose has relative mounts like `- ./Caddyfile:/etc/caddy/Caddyfile` (L1047), whose source is `$WM_DIR` → putting it under `/opt` hits `Mounts denied` directly. This has nothing to do with sudo; privilege escalation cannot fix it.
2. **Daily commands must not require sudo** — locks / logs / backups are all inside `$WM_DIR`; putting them in `root:wheel` `/opt` means `windmill status` would also need privilege escalation.
3. **Must be in a separate namespace from `$AIBOX_HOME/modules/`** — that holds downloaded hook scripts; if the deploy directory were `$AIBOX_HOME/windmill`, it would share a name with `$AIBOX_HOME/modules/windmill/`, differing by only one level, creating a high risk of accidental deletion.

**Two prerequisites (not optional optimizations)**

⚠️ **① `aibox self uninstall` must be changed to fail-closed.** `apps/` holds **deploy instances** (databases, backups) whose lifecycle outlasts aibox itself; currently it's a bare `rm -rf "$AIBOX_HOME"` (`bin/aibox:851`) — uninstalling the manager deletes all deployments along with their data. It must: **default to refuse** when `apps/` is non-empty, list the deployments that would be lost, and require an explicit `--yes` to proceed. (Consistent with the existing rule "dangerous operations under non-interactive mode return 2".)

⚠️ **② The systemd unit must explicitly carry `Environment=`.** Verified (`systemd-run /usr/bin/env`):

```
USER=root          ← the system service has only this; no HOME, no SHELL
```

**The `HOME` variable does not exist in a systemd system service** → any `$HOME`-derived path resolves to empty in the service context. The existing unit only works because `WM_DIR` is the constant `/opt/windmill`. After changing it to a derived value, the resolved result must be baked into the unit:

```ini
Environment="AIBOX_HOME=/root/.aibox"
```

CLI-side accompaniment: if resolution fails, **error and exit**; never assemble a path like `/.aibox/apps/windmill`.

**Also unifies the backup evacuation directory**: `evacuate_backups()` currently lands in `/var/backups/` (a Linux-specific directory, needs root, absent on macOS); using the same root works on both — `${AIBOX_HOME}/backups/`, and the platform branch disappears.

**What goes in conf, what doesn't**

| Goes in | Does not go in |
| --- | --- |
| `WM_PROXY`, `WM_GHCR_MIRROR`, `WM_HUB_MIRROR`, `HTTP_PORT` — **human-configured, invariant across deploy instances** | DB password, admin password — these are **deploy-instance state**; `init` regenerating them is by design, so putting them in conf creates a contradiction |

When the config file is absent, everything falls back to built-in defaults → the behavior of existing deployments on the server **is completely unchanged**.

> Corroborating evidence: this CLI is already patching "not separated" — `BACKUP_DIR="$WM_DIR/backups"` is inside the deploy directory, so `destroy` must first use `evacuate_backups()` to rescue backups to `/var/backups/windmill-pre-destroy-*`. The judgment "some things shouldn't vanish with the deployment" **already exists** in the code, just via "rescue after the fact" rather than "separate from the start". This patch itself has two platform issues: `/var/backups` is a Linux-specific directory (absent on macOS), and creating it requires root.
>
> Also a small redundancy: `--keep-backups` is identical to the default behavior (the two branches of the ternary at L1674 produce the same output).

### 3.4 Platform abstraction layer (foundation for macOS adaptation)

Verified on your local machine (Darwin arm64): `flock` ✗, `ss` ✗, `free` ✗, `lsof` ✓, `launchctl` ✓, docker CLI ✓ (compose v5.5.1), but **daemon not running**.

There are **8 spots** in the CLI needing adaptation:

| # | Location | Current (Linux) | macOS difference | Handling |
| --- | --- | --- | --- | --- |
| 1 | L639 concurrency lock | `flock -n 9` | macOS has no `flock` | Abstract `with_lock()`: use flock if available, otherwise `mkdir` atomic lock |
| 2 | L299 stall detection | `du -sm /var/lib/docker` | Docker Desktop's image layers are inside the VM; the host cannot see that directory | Switch to a progress signal: parse timestamps from `docker pull` output lines |
| 3 | L166 writing .env | `sed -i "s\|…\|"` | BSD sed needs `sed -i ''` | Switch to `awk + mv` (no platform difference, more robust than adapting sed) |
| 4 | L541 / L1920 port probe | `ss -ltn` | No `ss` | Abstract `port_listening()`: `ss` → `lsof -iTCP -sTCP:LISTEN` → `netstat -an` |
| 5 | L722 / L1436 get local IP | `hostname -I` | No `-I` | Abstract `primary_ip()`: `hostname -I` → `ipconfig getifaddr en0` |
| 6 | L1870 memory display | `free -h` | No `free` | Abstract `mem_used()`: `/proc/meminfo` → `vm_stat` |
| 7 | L821 backup evacuation | `/var/backups/` | macOS has no such directory, and creating it needs root | Unify to `${AIBOX_HOME}/backups/` — **same expression on both platforms, branch disappears** (see §3.3) |
| 8 | systemd 17 spots | `systemctl` + timer | macOS uses launchd | `windmill systemd` translates to launchd on macOS (**reference the plist writing in `tools/pi-web/lib.sh`**) |

Item 7 is the heaviest — the three existing units map one-to-one:

| Linux | macOS |
| --- | --- |
| `windmill-stack.service` (boot alignment) | LaunchAgent + `RunAtLoad` |
| `windmill-backup.timer` | LaunchAgent + `StartCalendarInterval` |
| `windmill-update-check.timer` | LaunchAgent + `StartCalendarInterval` |

`WM_DIR` becomes a derived value (`$AIBOX_HOME/apps/windmill`), **one expression on both platforms, no branch**.
Rationale and the three hard constraints are in §3.3; the cross-module convention is in `docs/module-spec.md`.

```bash
APPS_ROOT="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}"
WM_DIR="${WM_DIR:-$APPS_ROOT/windmill}"
```

⚠️ But the derived value introduces a new **service-context risk** that must be handled: verified via `systemd-run /usr/bin/env` showing **no `HOME` in the system service** (only `USER=root`). Therefore:

- The unit template must explicitly write `Environment="AIBOX_HOME=…"` (bake the resolved result in at install time)
- The CLI, when it cannot resolve `HOME`/`AIBOX_HOME`, **errors and exits**; do not assemble `/.aibox/apps/windmill`
- `windmill doctor` adds a check: assert "the path declared in the unit" matches "the currently resolved path"

**Recommendation**: this round only **extract the abstraction-layer functions** (`with_lock` / `port_listening` / `primary_ip` / `mem_used` / `sed_inplace` / `backup_evac_dir`); the Linux branch keeps its current implementation unchanged; the macOS branch is left as `TODO`. This keeps this round zero-risk; later rounds just fill in the branch without touching the main trunk again.

## 4. Module Design

### 4.1 Directory and files

```
tools/windmill/
├── windmill         # CLI body (single-file bash, 129 KB)
├── lib.sh           # placement resolution, version reading, syntax check, host_notice
├── install.sh
├── uninstall.sh
├── update.sh
├── svc.sh
└── README.md
```

> ⚠️ The repo becomes **the single source of the CLI** (same as openmaic): from now on, editing `tools/windmill/windmill` syncs to each machine via `aibox update windmill`. The copy in the session directory is no longer the source.

### 4.2 registry.sh registration

```sh
AIBOX_MODULES="${AIBOX_MODULES} windmill"

AIBOX_MODULE_windmill_version="1.0.0"
AIBOX_MODULE_windmill_description="Windmill self-host ops CLI (init/upgrade/backup/restore/doctor) — Docker Compose"
AIBOX_MODULE_windmill_platform=""          # empty = cross-platform (macOS branch to be added later)
AIBOX_MODULE_windmill_dir="tools/windmill"
AIBOX_MODULE_windmill_files="windmill lib.sh install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_windmill_install="install.sh"
AIBOX_MODULE_windmill_uninstall="uninstall.sh"
AIBOX_MODULE_windmill_update="update.sh"
AIBOX_MODULE_windmill_svc="svc.sh"
AIBOX_MODULE_windmill_actions="init deploy destroy up down status doctor check upgrade rollback backup snapshots restore drill logs shell exec psql credentials systemd version"
```

### 4.3 Hook responsibilities

| File | Responsibility | Difference from openmaic |
| --- | --- | --- |
| `install.sh` | `do_install` + `ensure_path` + `host_notice` + **seed `/etc/windmill/windmill.conf`** | Difference: openmaic has no system-level config placement (on macOS, one-time privilege escalation needed) |
| `update.sh` | `cmp -s` content comparison, skip if identical | None |
| `uninstall.sh` | Only deletes the CLI body | Preserves `$AIBOX_HOME/apps/windmill`, `/etc/windmill/windmill.conf`, `$AIBOX_HOME/backups/` |
| `svc.sh` | Passes through to the local `windmill` | Collision reminder: `aibox install windmill` vs `aibox windmill init / destroy` |
| `lib.sh` | Placement resolution (`APPS_ROOT` / `WM_DIR` / `WM_CONF_FILE`) + version reading + `check_syntax` + `host_notice` | Variable prefix `WINDMILL_*`; placement uses a unified expression, **no platform branch**; `host_notice` changed to a **dual-platform** notice |

**Placement**: `WINDMILL_BIN_DIR` → `AIBOX_BIN_DIR` → `~/.local/bin` three-tier fallback.
Install to a system directory: `WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill`.

**Who writes the config file**: `install.sh` does the **initial seeding** — drops aibox's global settings (proxy / image mirror / port) into `/etc/windmill/windmill.conf`. The strategy is **append-only, never overwrite**: if the file already exists, skip, to avoid clobbering hand-edited values. The CLI itself **only reads, never writes** this file, so `644` is sufficient and daily commands need no privilege escalation.

### 4.4 How the proxy connects (no new subcommand; rationale)

You mentioned "aibox's proxy is global" — following that line of thinking, windmill **does not need its own proxy command**; the link is already connected:

| Scenario | Who handles it | Automatic? |
| --- | --- | --- |
| The hook's own network requests (downloading module files) | aibox-exported `http_proxy` etc. | ✓ inherited automatically |
| `windmill check` querying the upstream release | Same (the CLI is a child process of the hook, inheriting env vars) | ✓ inherited automatically |
| **`docker pull` pulling images** | **Env vars are entirely ineffective** | ✗ must be specified explicitly |

The third row is the only gap, but **it is already covered by the existing mechanism**: the CLI's `--ghcr-mirror` / `--hub-mirror` do "pre-pull + re-tag", taking over the pull itself without relying on the daemon config. So the loop is closed:

```
aibox global proxy  →  covers all of the CLI's HTTP requests
image-mirror args   →  cover docker pull (bypassing the daemon)
```

**Uninstall boundary**: `aibox proxy unset` does not affect windmill's deployment state; conversely `windmill destroy` does not touch aibox's proxy config — the two do not intrude on each other, consistent with the "delete only your own stuff" principle.

**Optional acceleration (write into README, not a feature)**: under restricted networks, configure an HTTP proxy for the docker daemon; verified to boost ghcr.io pulls from 2.4 KB/s to 66 MB/s. On Linux the placement is `/etc/systemd/system/docker.service.d/http-proxy.conf`; on macOS it goes through Docker Desktop settings (**not** systemd). This is a performance optimization, not a functional dependency.

## 5. Risks

| Risk | Mitigation |
| --- | --- |
| Intranet address residue (including generated compose files) | After refactor, `grep -rn '192\.168\.' tools/windmill/` must be 0 |
| Dual-source drift | Establish the repo as the single source; abandon the copy in the session directory |
| macOS cannot be fully verified | Foundation phase only extracts the abstraction layer and does not change Linux-branch behavior; real-machine verification deferred |
| 129 KB single file checked in | Same pattern as openmaic; the project already accepts it |
| Behavior change after introducing the config file | When conf is absent, everything falls back to built-in defaults → existing deployment behavior unchanged |
| macOS install writes to `/etc`, needs privilege escalation | Escalate only once in `install.sh`; conf set to `644`; daily commands neither read nor write it, so no sudo needed |
| **Deployments in `apps/` taken down by an aibox uninstall** | **Prerequisite**: change `cmd_self_uninstall` to fail-closed (`apps/` non-empty → default refuse + list items to be lost; `--yes` required to proceed) |
| **`HOME` cannot be resolved (service context)** | Unit explicitly sets `Environment="AIBOX_HOME=…"`; CLI errors and exits on resolution failure; `doctor` asserts "unit path == currently resolved path" |
| Existing instance at `/opt/windmill`, inconsistent with the new default | **No migration, just reinstall**: first `windmill --yes destroy --all`, then `init` at the new location. No one-time migration path — when the existing footprint is small, reinstall costs less and removes one long-term maintenance surface |
| macOS deploy root if it lands back under `/opt` | Hard constraints written into §3.3 / §3.4 and `module-spec`; `lib.sh` adds an assertion (on `Darwin`, `WM_DIR` must be under `/Users`) |
| New module-spec convention inconsistent with openmaic's `/opt/openmaic` | **Already aligned**: openmaic deploy root changed to `$AIBOX_HOME/apps/openmaic` (`OPENMAIC_BASE_DIR` default value + comment + README + uninstall hint); placement resolution adds a missing-`HOME` guard |

## 6. Execution Phases

| Phase | Content | Acceptance |
| --- | --- | --- |
| 0 | **Prerequisite**: change `bin/aibox`'s `cmd_self_uninstall` to fail-closed | ✅ **Done**: returns `2` and lists items to be lost when `apps/` is non-empty; `--yes` accepted both before and after the subcommand |
| 0b | **Prerequisite**: existing-module placement alignment (openmaic → `$AIBOX_HOME/apps/openmaic`) | ✅ **Done**: all 8 placement-resolution assertions pass; `pi-web` confirmed to need no changes |
| 1 | Move the CLI to `tools/windmill/`; strip the intranet binding; prefix the version variable | `bash -n` passes; no intranet residue |
| 2 | Abstraction-layer foundation (6 functions) + externalize config to `/etc/windmill/windmill.conf` + unify deploy root to `$AIBOX_HOME/apps/windmill` + unit explicit `Environment=` | Linux behavior unchanged; works when conf is absent; errors (instead of assembling a path) when `HOME` is missing; unit path == resolved path |
| 3 | Write the 6 module files + registry registration + README + check in the `module-spec` convention | — |
| 4 | Sandbox verification: isolate `HOME`/`BIN_DIR` + `file://` local source; run install → pass-through → idempotent update → uninstall | End-to-end pass |
| 5 | Real-machine verification: install to `/usr/local/bin`; run read-only commands + one `--dry-run` | Zero side effects |
| 6 | **(Later)** Fill in macOS branches: lock, progress signal, port/IP/memory, launchd | A full set runs locally on macOS |
| 7 | **Real-machine reinstall** (no migration): existing `/opt/windmill` directly `destroy --all` → re-`init` at the new location `$AIBOX_HOME/apps/windmill` | After reinstall, `doctor` all green, `drill` passes, 8 containers Up, UI 200 |

## 7. Confirmed Decisions

| # | Decision | Conclusion |
| --- | --- | --- |
| 1 | Cross-machine architecture | **Local run**, no remote; the module only does local install |
| 2 | Config directory | **Externalized, both platforms unified to `/etc/windmill/windmill.conf`** (`755 root:root` + file `644`), with `WM_CONF_FILE` override retained; on macOS, `install.sh` escalates once to write it. **Not in `/opt`** (`destroy` would take it down / ownership unclear, see §3.3) |
| 3 | Deploy directory | **Both platforms unified to `$AIBOX_HOME/apps/windmill`** (Linux `/root/.aibox/apps/windmill`, macOS `~/.aibox/apps/windmill`), **no platform branch**; backup evacuation directory same root `${AIBOX_HOME}/backups/`. Three constraints in §3.3 |
| 4 | Whether the deploy root enters the spec | **Written into `docs/module-spec.md`** — a cross-module convention, including the three hard constraints and two accompanying mandatory items |
| 5 | `aibox self uninstall` | **Changed to fail-closed** (currently a bare `rm -rf "$AIBOX_HOME"`) — a prerequisite of this plan |
| 6 | `windmill proxy` subcommand | **Not added**; proxy goes through aibox global + the CLI's image-mirror args |
| 7 | Platform | This round gets Linux working + lays the macOS abstraction-layer foundation; full macOS adaptation comes later |

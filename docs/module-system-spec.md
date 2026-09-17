# aibox Module System Enhancement Spec

> Status: Design draft. This document collects enhancement requirements including port declaration, Dashboard, shared base components, module development guide, and the module.yaml declaration spec, as the basis for subsequent implementation.
>
> **Incremental revision (2026-09-16)**: module.yaml field de-duplication (implicit standard files set / common lifecycle contract for actions / slimmed-down dashboard) + shared-component dependency declaration and connection-info propagation (provider model + base.env + compose `--env-file` live injection, no generator). See [`docs/design/module-yaml-refactor-design.md`](design/module-yaml-refactor-design.md). §1 / §2.3 / §4 / §5 / Appendix B/C have been annotated accordingly.
>
> Positioning: aibox is a lightweight module manager for local development + single-machine deployment and ops (pure bash, zero runtime dependencies, compatible with macOS bash 3.2). The terminal-state design as modules grow from the current 4 to dozens.

---

## 1. Background and Goals

Historically, aibox module declarations were centralized in `registry.sh` (shell-sourced variables), suitable for 4-5 modules; this has been migrated to a per-module `tools/<name>/module.yaml` (autonomous, discovered by scanning `tools/*/module.yaml`, registry.sh has been deleted, see §9). As modules grow to dozens, we still need: no port conflicts, visible module status, shared components to save resources, and a development guide to help AI upgrades.

This spec defines:

1. **module.yaml spec** —— one YAML declaration file per module, structured and autonomous
2. **Port declaration and conflict detection** —— statically declared at design time, CI gates conflicts
3. **Dashboard TUI** —— module status + endpoint + credential visualization
4. **Shared base components** —— single PG/Redis instance with multiple databases, saving resources
5. **Module development guide** —— AI upgrades modules based on this
6. Dependency management, auto-start conventions (already implemented, documenting current state)

---

## 2. module.yaml Spec (Module Declaration)

### 2.1 Location and Discovery

- **Location**: `tools/<name>/module.yaml` (same directory as the module code, autonomous)
- **Discovery**: the main CLI scans `tools/*/module.yaml` to auto-discover modules (**no longer needs registry.sh to list module names**). Adding a module = create `tools/<name>/` + `module.yaml`, zero changes to global code.

### 2.2 YAML Subset (awk-parseable)

To keep the main CLI zero-dependency (pure bash + awk), module.yaml is restricted to a subset that awk can reliably parse:

- `key: value` (scalar, quotes optional)
- `- item` under `key:` (list)
- `subkey: value` under `key:` (shallow nesting, at most 2 levels)
- `#` comments
- **Forbidden**: anchors/aliases (`&`/`*`), multi-line strings (`|`/`>`), flow style (`{}`/`[]`), complex types

This subset covers all module declaration fields.

### 2.3 Field Spec

```yaml
# tools/<name>/module.yaml —— module declaration source of truth
name: pi-web                      # Required. Module name (hyphenated)
version: 1.0.0                    # Required. Module version
description: "..."                # Required. One-line description
platform: ""                      # Optional. Empty = cross-platform; darwin = macOS-specific
dir: tools/pi-web                 # Required. Directory within the repo

deps:                             # Optional. Runtime dependencies (command@platform:version)
  - "node:22"                     #   node:22 = major version >=22
  - npm                           #   @linux = Linux-only check
  - "docker@linux"                #   empty = no dependencies (e.g. clash, mihomo download)

ports:                            # Optional. Ports used (port/protocol:purpose) —— CI detects conflicts
  - 30141/tcp:http
  - 9090/tcp:api

files:                            # Optional. List only "extra" files; the standard 5 files (lib.sh/install.sh/uninstall.sh/update.sh/svc.sh) are implicit by default (awk union, old yaml listing all still works)
  - lib.sh
  - install.sh
  - uninstall.sh
  - update.sh
  - svc.sh

hooks:                            # Required. Hook file names
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                          # Optional. Actions supported by svc (list all); the lifecycle subset of service-type modules (start/stop/restart/status/logs) must satisfy the "Common Action Contract", see §4 and design doc §4
  - start
  - stop
  - restart
  - status
  - logs
  - diagnose

upstream:                         # Optional. Development guide links (see §6)
  homepage: https://github.com/agegr/pi-web
  docs: https://github.com/agegr/pi-web#readme
  install: https://github.com/agegr/pi-web#installation
  test: https://github.com/agegr/pi-web#development

dashboard:                        # Optional. Only a static fallback when not installed; only endpoints[] + hint subfields allowed; at runtime always goes through lib.sh's dashboard_info() (see §4)
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "Username pi / password: see aibox pi-web status"
```

### 2.3.1 Incremental Fields (2026-09-16, see [design doc](design/module-yaml-refactor-design.md))

| Field | Required | Description |
| --- | --- | --- |
| `files` | No | List only **extra** files; the standard 5 files are implicit (awk union, old yaml listing all still works). CI verifies that listed items exist. |
| `actions` | No | List all actions. **Containing `start` means service-type** and must satisfy the lifecycle contract (start/stop/restart/status/logs); without `start` means distribution-type, not enforced. The CLI lists actions as help when running `aibox <module>` (no action), and does not validate on every invocation. |
| `services` | No | Shared-component dependencies, compact string `provider:component[#dbname]`. component is the **full name** (`postgres`/`redis`, `pg` forbidden). `postgres` should provide `#dbname`; `redis` is usually omitted. Declaration drives: CI validation, `install` auto-runs `base create postgres`, compose scheduling auto-injects `--env-file base.env`. Multiple DBs: `base:postgres#windmill_jobs`. |
| `provides` | No | Only filled by provider modules (e.g. base). Declares the full names of components exposed to others. A consuming module's `services` reference must match a provider's `provides`. |
| `dashboard` | No | Only `endpoints[]` + `hint`, as static fallback when not installed; at runtime goes through `dashboard_info()`. |

**Full-name consistency**: component names always use the full name —— module.yaml `services`/`provides`, env variables (`AIBOX_POSTGRES_*`), compose service/container (`postgres:` / `aibox-base-postgres`), and port purpose labels (`35432/tcp:postgres`).

### 2.4 Parsing Approach (Approach A: built-in awk, zero dependency)

The main CLI's `load_registry` is changed to scan `tools/*/module.yaml` + parse with awk:

```bash
load_registry() {
  AIBOX_MODULES=""
  local f name
  for f in "$AIBOX_REPO_DIR"/tools/*/module.yaml; do
    [ -f "$f" ] || continue
    name="$(parse_yaml_field "$f" name)"
    [ -n "$name" ] || continue
    AIBOX_MODULES="${AIBOX_MODULES:+$AIBOX_MODULES }$name"
    parse_yaml_module "$f" "$name"   # awk parse → eval-injected AIBOX_MODULE_<name>_* variables
  done
}
```

`parse_yaml_module` (awk implementation, ~80 lines):

- Iterates YAML lines, recognizing hierarchy by indentation + `-`
- Scalar → `AIBOX_MODULE_<name>_<key>="value"`
- List → `AIBOX_MODULE_<name>_<key>="item1 item2 ..."` (space-separated, compatible with module_field reads)
- Shallow nesting (hooks/upstream/dashboard) → `AIBOX_MODULE_<name>_<parent>_<subkey>="value"`
- Outputs `eval`-able variable assignments; the main CLI eval-injects them

The awk parser only supports the §2.2 subset; CI guarantees YAML compliance (see §2.5).

### 2.5 CI Validation (module-lint)

```yaml
  module-lint:
    name: module.yaml lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install yq
        run: sudo wget -qO/usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
      - name: validate module.yaml
        run: |
          set -e
          fail=0
          for f in tools/*/module.yaml; do
            [ -f "$f" ] || continue
            # 1. Required fields: name/version/dir/hooks.install non-empty (files is now optional, only lists extras)
            # 2. YAML subset compliance: no anchors (&/*), no multi-line (|/>), no flow ({}/[])
            # 3. ports format: port/protocol:purpose
            # 4. files listed items must exist under tools/<name>/
            # 5. Modules containing start must contain the lifecycle set and svc.sh implements it (without start, not enforced)
            # 6. dashboard only allows endpoints + hint subfields
            # 7. services/provides component names are full names (whitelist postgres/redis/...)
            yq -e '.name' "$f" >/dev/null || { echo "::error file=$f::missing name"; fail=1; }
            ...
          done
          exit $fail
```

CI uses yq (authoritative parser) to validate; the main CLI uses awk (zero dependency) for runtime parsing. CI guarantees the YAML is within the awk subset.

---

## 3. Port Declaration and Conflict Detection

### 3.1 Goal

Modules statically declare used ports at design time; aibox registers them so that multiple modules on a single machine do not conflict. **This is not a runtime error; CI gates submissions with tests.**

### 3.2 Declaration (module.yaml ports field)

```yaml
ports:
  - 30141/tcp:http      # port/protocol:purpose
  - 9090/tcp:api
```

Format: `port/protocol:purpose`. CI detects uniqueness by **port + protocol**.

### 3.3 Allocation Strategy: Static Declaration + First-Declared-First-Served (No Randomization)

- **Static declaration**: ports are hard-coded in module.yaml (fixed at design time), stable and predictable
- **First-declared-first-served**: whoever declares first wins; a new module declaring an already-occupied port → CI fail, and the developer changes the new module's port
- **No randomization**: random ports suit multi-tenant/container scenarios, not local development (endpoints unstable, users can't remember them, dashboard must query dynamically)
- **Port range**: aibox modules use 30000-49999 (avoiding common system ports <1024, 80, 443, 3000, 5432, 6379, 8080, 9000, etc.)

### 3.4 CI Conflict Detection (port-conflict job)

```yaml
  port-conflict:
    name: port conflict
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install yq
        run: sudo wget -qO/usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
      - name: detect cross-module port conflicts
        run: |
          set -e
          declare -A owner
          dup=0
          for f in tools/*/module.yaml; do
            [ -f "$f" ] || continue
            m=$(yq '.name' "$f")
            for p in $(yq -o=ts '.ports[]' "$f" 2>/dev/null || true); do
              pp="${p%%/*}"
              if [ -n "${owner[$pp]:-}" ]; then
                echo "::error::port $pp conflict: ${owner[$pp]} and $m"
                dup=1
              else owner[$pp]="$m"; fi
            done
          done
          [ $dup -eq 0 ] && echo "✅ no port conflicts"
          exit $dup
```

Conflict → `::error` + exit 1 → PR check fails, code cannot merge.

### 3.5 `aibox ports` Command (View Allocation Table)

```bash
$ aibox ports
Module       Port/Proto    Usage     Overridable (example)
pi-web       30141/tcp     http      PI_WEB_PORT
clash        7890/tcp      mixed     CLASH_PORT
clash        9090/tcp      api       CLASH_API_PORT
windmill     8080/tcp      http      WM_HTTP_PORT
openmaic     3000/tcp      app       —
openmaic     5432/tcp      postgres  — (migration-era local pg; shared base takes over after)
```

Developers run `aibox ports` before adding a module to see what's allocated and pick a free port. The main CLI collects this live from module.yaml's ports field (dynamic, no need to maintain docs/ports.md).

### 3.6 Runtime Probing (at install, optional)

`aibox install <module>` reads the module's ports and probes actual usage via `lsof -iTCP:port` → if occupied by a non-aibox service, it warns ("port X is occupied externally; you can override with PI_WEB_PORT"). This layer does not gate submissions; it only notifies. Users can override the actual port via environment variables (`PI_WEB_PORT`, etc.).

### 3.7 Shared-Component Ports

The ports of shared PG/Redis (§5) are also declared in the base module's module.yaml + checked by CI. Recommended to use non-default ports (PG 35432, Redis 36379) to avoid collisions with system services.

---

## 4. Dashboard TUI

### 4.1 Goal

Each module has a Dashboard showing: whether it is deployed, endpoint (browser URL/port), and initial password/key, for easy login and use.

### 4.2 Commands

- `aibox dashboard` —— global overview table (module / deployed? / endpoint / status)
- `aibox <module> dashboard` —— single-module detail (port/URL/credentials/log path/health)

### 4.3 TUI Implementation

Pure bash (colors + tables, zero dependency). **Does not use dialog/whiptail** (not on macOS). Output like:

```
┌─ aibox dashboard ────────────────────────────────┐
│ Module     Status   endpoint                Creds │
├──────────────────────────────────────────────────┤
│ pi-web     ✓ run    http://127.0.0.1:30141  pi/** │
│ clash      ✓ run    socks5://127.0.0.1:7890  —     │
│ windmill   ✗ off    —                        —     │
│ openmaic   ✓ on     http://127.0.0.1:3000   .env  │
└──────────────────────────────────────────────────┘
```

### 4.4 Module Interface: `dashboard_info()`

Each module's `lib.sh` implements `dashboard_info()`, outputting key=value (parsed by the aibox caller):

```bash
# tools/<name>/lib.sh
dashboard_info() {
  # output key=value, collected by aibox dashboard
  echo "endpoint=http://127.0.0.1:${PORT}"
  echo "credential=Username pi / password ${PASSWORD}"   # password read from plist (resolve_password)
  echo "log=${LOG_DIR}/pi-web.log"
  echo "health=curl -s -u pi:${PASSWORD} http://127.0.0.1:${PORT}/"
}
```

The convention is written into module-spec. **The module.yaml `dashboard` section is only a static fallback when not installed, and only the `endpoints[]` + `hint` subfields are allowed; once a module is installed, runtime info (endpoint/credentials/log/health) always follows `dashboard_info()` output, overriding the yaml.**

### 4.5 Credential Sources (per module)

| Module | Credential source |
| --- | --- |
| pi-web | plist `PI_WEB_PASSWORD` (read by resolve_password) |
| clash | state `CLASH_SECRET` (API auth) |
| windmill | `$WM_DIR/CREDENTIALS.txt` + `.env` (POSTGRES_PASSWORD, etc.) |
| openmaic | `.env.local` (API Key, access password) |

### 4.6 Health Check

`aibox <module> dashboard` does a lightweight probe of the endpoint (curl health endpoint, 2s timeout) and shows ✓/✗. Depends on port declaration (§3) + the module's dashboard_info health.

### 4.7 Dependencies

- Port declaration (§3) —— endpoint ports come from module.yaml ports
- Module `dashboard_info()` interface

---

## 5. Shared Base Components (PG/Redis)

### 5.1 Goal

When modules depend on the same component, start only one instance; each module uses an independent database (named `<module>` or `<module>_<purpose>`) to save resources.

### 5.2 Current State

- openmaic compose starts app + PG + render (its own PG)
- windmill compose starts windmill + PG + caddy (its own PG)
- Duplicate PG instances, wasting resources

### 5.3 Design

**Add a `tools/base/` module**: manages shared PG 18 + Redis 7 (one docker compose).

```yaml
# tools/base/module.yaml
name: base
provides:                # declares components exposed to others (full names)
  - postgres
  - redis
ports:
  - 35432/tcp:postgres   # non-default port + full-name purpose label, avoids colliding with system PG
  - 36379/tcp:redis
deps:
  - docker
  - docker-compose
actions:
  - start
  - stop
  - restart
  - status
  - create
```

**Refactor each deployment-type module's compose**:

- Remove its own PG/Redis service
- Connect to the shared instance (join the `aibox-base` network + env points to shared PG via `${AIBOX_POSTGRES_*}`, values injected from `$AIBOX_HOME/base.env`)
- At `init`, create its own DB in the shared PG: `<module>` or `<module>_<purpose>`

### 5.4 DB Naming Convention

- Single DB: `<module>` (e.g. `windmill`, `openmaic`)
- Multiple DBs: `<module>_<purpose>` (e.g. `moduleA_jobs`, `moduleA_cache`)
- Prefix = module name, avoids cross-module collisions

The convention is written into module-spec.

### 5.5 Implementation Notes (provider model + base.env injection, see [design doc](design/module-yaml-refactor-design.md) §5–§6)

- `base` acts as a **provider**; the single source of truth = `tools/base/lib.sh` holds connection constants → `base start`/`restart` writes `$AIBOX_HOME/base.env` (`AIBOX_POSTGRES_*` / `AIBOX_REDIS_*`, full names). base.env is consistent with `base/docker-compose.yml` defaults, guarded by CI deps-lint.
- Consuming modules declare dependencies in module.yaml `services: [base:postgres#<db>]` (full names).
- When aibox schedules compose, for modules declaring `services` it automatically appends `--env-file "$AIBOX_HOME/base.env"` (compose v2.24+ merges multiple `--env-file`s) → `${AIBOX_POSTGRES_*}` can be interpolated inside the module compose.
- Modules **hand-write one stable** `docker-compose.shared.yml` (network join + `replicas:0` + `environment: DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@aibox-base-postgres:${AIBOX_POSTGRES_PORT}/${AIBOX_POSTGRES_DB}`), **zero hard-coded credentials**; the module's `.env` sets `AIBOX_POSTGRES_DB=<module>` (the DB name belongs to the module).
- Changing base credentials/ports → `base restart` rewrites base.env → each module `aibox <module> restart` (compose up) interpolates the new values and reconnects automatically. **No generator, no extra files, no sync-deps command.**
- `tools/base/lib.sh` still manages the shared compose lifecycle (start/stop/status) + DB creation tool (`base create postgres <module> [purpose]`); `aibox <module> install` sees `services` → ensures base is up + `base create postgres <module>` creates the DB.
- Version compatibility: module.yaml can declare `deps` containing `postgres:16` (base manages versions, modules declare compatible versions; **full name**)
- Network: the shared compose creates the docker network `aibox-base`; each module hand-writes an override to join

### 5.6 Phased Rollout (Avoid Big-Bang)

1. **Phase 1**: build the `tools/base/` shared PG/Redis module + DB creation tool
2. **Phase 2**: new modules use shared (compose connects to shared, no longer starts its own PG)
3. **Phase 3**: migrate existing modules (openmaic/windmill compose refactor + data migration `pg_dump` to shared PG)

Migrating existing modules carries data risk; iterate separately. New modules use shared directly.

### 5.7 Fallback

When a module needs an exclusive PG version (incompatible with shared 18), it can fall back to an independent instance (compose starts its own PG). module.yaml **does not** declare that `services` (aibox then does not add `--env-file`; the module's bundled compose starts a local instance); if you need to pin a version, use the existing `deps` mechanism to declare `postgres:14` (full name), without introducing `@standalone` syntax.

### 5.8 Dependencies

- Port declaration (§3) —— shared PG/Redis ports registered + CI detection
- module.yaml (§2) —— base module declaration

---

## 6. Module Development Guide

### 6.1 Goal

Each module has a development guide; AI upgrades modules based on it (project homepage, docs, install/test manual, configuration status).

### 6.2 module.yaml upstream Field

```yaml
upstream:
  homepage: https://github.com/agegr/pi-web
  docs: https://github.com/agegr/pi-web#readme
  install: https://github.com/agegr/pi-web#installation
  test: https://github.com/agegr/pi-web#development
```

aibox `aibox <module> dev-guide` outputs these links (AI checks upstream docs first when upgrading).

### 6.3 `docs/DEVELOPMENT.md` (per module)

`tools/<name>/docs/DEVELOPMENT.md`, containing:

- **upstream**: homepage + official docs (same as module.yaml upstream, may elaborate)
- **Install manual**: upstream native install + aibox module install (`aibox install <name>`)
- **Test manual**: how to run tests (upstream tests + aibox module tests)
- **This module's configuration**: ports (§3), password/credentials (§4), file locations (deploy root/config), customization points (aibox's changes to upstream)
- **Upgrade flow**: steps for AI to upgrade this module (check upstream new version → modify module.yaml version → run tests → `aibox update`)

### 6.4 AI Upgrade Flow

```
1. Read module.yaml upstream.docs → check upstream new version + changes
2. Read docs/DEVELOPMENT.md → understand this module's customization points + test methods
3. Modify module.yaml version + sync code
4. Run tests (DEVELOPMENT.md test manual)
5. aibox update <module> verify
6. commit (CI port/spec validation)
```

### 6.5 Dependencies

- module.yaml (§2) —— upstream field
- Independent (pure docs)

---

## 7. Dependency Management (Already Implemented, Documenting Current State)

### 7.1 Current State

- registry `deps` field → migrated to module.yaml `deps` (format unchanged: `command@platform:version`)
- `bin/aibox`'s `check_deps` + `dep_satisfied` + `install_dep` are implemented
- `cmd_install` calls `check_deps` (before the install hook)
- Platform filtering: non-empty `platform` that doesn't match is skipped; `@platform` is skipped + notified
- Auto-install: lightweight install (brew/apt/yum/dnf); sudo/GUI-requiring ones (Docker Desktop) prompt for manual install; node reuses nvm

### 7.2 Migration to module.yaml

```yaml
deps:
  - "node:22"
  - npm
```

awk parses it as `AIBOX_MODULE_<name>_deps="node:22 npm"`; check_deps logic is unchanged.

---

## 8. Auto-Start Platform Conventions (Already Implemented, Documented)

### 8.1 Convention (AGENTS.md Item 10)

Auto-start for persistent services follows the platform; **do not mix**:

- **macOS → launchd**: user-level `~/Library/LaunchAgents/<label>.plist`, `launchctl bootstrap gui/$(id -u)`, no root needed. `KeepAlive` = auto-restart, `StartCalendarInterval` = scheduled.
- **Linux → systemd**: user-level `~/.config/systemd/user/<name>.{service,timer}`, `systemctl --user` + `loginctl enable-linger` for persistence, no root needed. `Restart=always` = auto-restart, `OnCalendar` = scheduled.
- The same service writes one unit per platform, branched via `case "$(uname -s)"`. System-level (needs root/start-at-boot) only then uses `/etc/systemd/system` + `systemctl` (without `--user`).

### 8.2 Current State

- pi-web: mac launchd + linux systemd --user (`write_plist`/`write_systemd_unit` OS branches)
- windmill: mac launchd + linux systemd (`cmd_launchd`/`cmd_systemd`)
- clash: nohup+pid (not an init system, cross-platform simple persistence)
- openmaic: no persistence (svc passes through to CLI)

---

## 9. Migration Path (registry.sh → module.yaml)

The existing 4 modules migrate from centralized registry.sh declarations to `tools/<name>/module.yaml`:

1. Create `tools/<name>/module.yaml` for each module, moving that module's fields from registry.sh over (version/platform/deps/ports/files/hooks/actions + new upstream/dashboard)
2. Each module declares `ports` (pi-web 30141, clash 7890/9090, windmill 8080, openmaic 3000/5432)
3. The main CLI's `load_registry` changes to scan `tools/*/module.yaml` + parse with awk (delete the registry.sh source logic)
4. Delete `registry.sh` (or keep as a compatibility shim that scans module.yaml when sourced)
5. CI adds module-lint (yq validation) + port-conflict (port conflicts)
6. module-spec updated (module.yaml spec + ports + dashboard_info interface + DB naming + auto-start reference)

Migration cost is low (4 modules, mechanical field move). After migration, adding a new module requires zero global changes.

---

## 10. Priority and Dependencies

```
§2 module.yaml spec (foundation) ──┬──> §3 port declaration (ports field + CI)
                              ├──> §4 Dashboard (endpoint from ports + dashboard_info)
                              ├──> §5 shared components (base module declaration + ports)
                              └──> §6 dev guide (upstream field)

§7 dependency management (implemented, migrate to module.yaml deps)
§8 auto-start (implemented)
```

| Order | Requirement | Difficulty | Dependencies | Notes |
| --- | --- | --- | --- | --- |
| 1 | **module.yaml spec + migration** | Medium | None | Foundation; all requirements depend on it; awk parser + CI |
| 2 | **Port declaration + CI conflict detection** | Medium | §2 | ports field + port-conflict job + `aibox ports` command |
| 3 | **Module development guide** | Low | §2 | Independent, pure docs; can parallelize with 2 |
| 4 | **Dashboard TUI** | Medium | §2 + §3 | dashboard_info interface + aibox dashboard command |
| 5 | **Shared base components** | High | §2 + §3 | Architectural-level, phased; base module + compose refactor + existing migration |

Suggested order: **1 → 2 + 3 (parallel) → 4 → 5**. Requirement 5 (shared components) is the largest; iterate separately/phased.

---

## Appendix A: Complete module.yaml Example (pi-web)

```yaml
name: pi-web
version: 1.0.0
description: "Deploy @agegr/pi-web as a launchd/systemd service (HTTP Basic auth, auto-restart)"
platform: ""                      # cross-platform: mac launchd / linux systemd --user
dir: tools/pi-web

deps:
  - "node:22"
  - npm

ports:
  - 30141/tcp:http

files:
  - lib.sh
  - install.sh
  - uninstall.sh
  - update.sh
  - svc.sh

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:
  - start
  - stop
  - restart
  - status
  - logs
  - diagnose

upstream:
  homepage: https://github.com/agegr/pi-web
  docs: https://github.com/agegr/pi-web#readme
  install: https://github.com/agegr/pi-web#installation
  test: https://github.com/agegr/pi-web#development

dashboard:
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "Username pi / password: see aibox pi-web status (plist PI_WEB_PASSWORD, resolve_password generates)"
```

## Appendix B: awk parse_yaml Parser Notes

`parse_yaml_module <file> <name>` (awk implementation):

1. Iterate lines, recognize hierarchy by indentation (0 = top level, 2 = list item, 2/4 = nested)
2. Top-level `key: value` → `AIBOX_MODULE_<name>_<key>="<value>"`
3. `key:` with no value + `- item` below → list, collected into `AIBOX_MODULE_<name>_<key>="item1 item2 ..."`
4. `key:` with no value + `subkey: value` below → nested, `AIBOX_MODULE_<name>_<key>_<subkey>="<value>"`
5. dashboard.endpoints (list) → `AIBOX_MODULE_<name>_dashboard_endpoints="url1 url2"`
6. Skip `#` comments and blank lines
7. Output `eval`-able assignments; the main CLI runs `eval "$(parse_yaml_module "$f" "$name")"`
8. **files union (incremental)**: after parsing, union with the standard 5 files and dedupe (standard set first), backward-compatible with old yaml listing all
9. **services/provides (incremental)**: parsed as new list fields as usual (space-separated scalars), for CI validation, `install` to decide `create, and the compose wrapper to decide whether to add `--env-file base.env`

awk only handles the §2.2 subset; CI (yq) guarantees YAML compliance.

## Appendix C: CI Workflows Summary

`.github/workflows/lint.yml` adds jobs:

- `module-lint`: yq validates module.yaml (required fields + subset compliance + ports format + files items exist + lifecycle implemented + dashboard only two subfields + component full-name whitelist)
- `port-conflict`: yq collects all ports, detects port+protocol duplicates
- `deps-lint` (new): ① a consuming module's `services` provider/component must match some provider's `provides`; ② hard-coded credential literals like `aibox:aibox@` / `postgres://aibox:` are forbidden in `tools/*/docker-compose*.yml` (except base) (the service name `aibox-base-postgres` as host is allowed); ③ the constants `base/lib.sh` writes to `base.env` are consistent with `base/docker-compose.yml` ports/default credentials + base.env contains full-name keys

Existing `bash -n` + `shellcheck` + `bash32-gotchas` are retained.

---

## License

MIT.

# module.yaml Refactor and Shared-Component Dependency Propagation Design

> Status: Design draft (spec-only; this round does not modify any actual `.sh` / `module.yaml` / `docker-compose*.yml` content)
> Date: 2026-09-16
> Scope: ① Remove redundancy from module.yaml fields (actions / files / dashboard); ② Shared-component (PG/Redis) dependency declaration + connection-info propagation spec
> Related: This design is an incremental revision of [`docs/module-system-spec.md`](../module-system-spec.md); after landing, the corresponding spec sections will be updated accordingly
> Principle: **Keep it simple and extensible.** Shared-component propagation introduces no codegen — one shared env file + compose `--env-file` live read + module-referenced variables.

---

## 0. TL;DR

- **files**: The standard 5 files (`lib.sh install.sh uninstall.sh update.sh svc.sh`) are implicit defaults; module.yaml lists only **extra** files. The awk parser takes the union of "standard set ∪ files".
- **actions**: Keep the full list; add a new "Common Action Contract" defining the semantics of the lifecycle set; service-type = derived from `actions` containing `start` (no extra field); when the CLI runs `aibox <module>` (no action), it lists the declared actions as help, without validating on every invocation.
- **dashboard**: yaml keeps only `endpoints[]` + `hint` (pre-install fallback); at runtime everything goes through `lib.sh`'s `dashboard_info()` (installed overrides yaml).
- **Shared components**: `base` acts as the **provider**; `base start` writes a `$AIBOX_HOME/base.env` (`AIBOX_POSTGRES_*` / `AIBOX_REDIS_*`, single source). Consumer modules declare `services: [base:postgres#windmill]` in module.yaml.
- **Propagation (no generator)**: When aibox schedules compose, for modules that declare `services` it automatically appends `--env-file $AIBOX_HOME/base.env`; the module **hand-writes one stable** `docker-compose.shared.yml` (network join + `replicas:0` + constructs `DATABASE_URL` in `environment` using `${AIBOX_POSTGRES_*}`, **zero hardcoded credentials**); the module's own `.env` sets `AIBOX_POSTGRES_DB=<module>`. Changing base credentials/port → `base restart` rewrites base.env → the next `aibox <module> restart` (compose up) interpolates the new values. **Change once, zero module-file edits.**
- **Component names are always full names**: `postgres`, `redis`; no abbreviations like `pg` (env variables, component keys, and compose service/container naming stay consistent throughout).

---

## 1. Background: Current Redundancy and Fragility

### 1.1 actions is purely declarative, never read

`bin/aibox`'s `cmd_module_action` forwards actions directly to `svc.sh` and **never reads the `actions` field of module.yaml** (grep for `_actions` / `module_field … action` yields zero hits in the CLI). Consequences:

- Every module repeats a near-identical action list, but the list itself has no binding force;
- `start/stop/restart/status/logs` have inconsistent semantics across 5 modules (each `status` is implemented ad hoc);
- A misspelled action name is not caught anywhere;
- `aibox <module>` (no action) only prints "usage" and doesn't tell the user which actions the module supports.

Action distribution across the 5 modules (status as of 2026-09-16):

| Module | Common core | Module-specific |
| --- | --- | --- |
| base | start/stop/restart/status | createdb |
| clash | start/stop/restart/status/logs | refresh/set/select/test/doctor |
| pi-web | start/stop/restart/status/logs | diagnose |
| openmaic | status/logs | up/down/restart/upgrade/rollback/backup/restore/db/config/models/install/clean/health/doctor/version/render/powerlog/url (pass-through CLI, **does not include start**) |
| windmill | status/logs | up/down/restart/shell/credentials/systemd/destroy/backup/upgrade/rollback/check/deploy/restore/drill/snapshots/init/version/doctor |

**Conclusion**: `start/stop/restart/status/logs` are nearly universal lifecycle core; the rest are truly module-specific. So the object of "common-layer definition" is **this lifecycle contract**, not hoisting the action list to global scope (the list remains module-autonomous and mutable).

### 1.2 files duplicates the standard set

All 5 modules' `files:` contain the same `lib.sh install.sh uninstall.sh update.sh svc.sh`, plus a few extra items (`openmaic`/`windmill` own CLIs, `base/docker-compose.yml`, `openmaic|windmill/docker-compose.shared.yml`). The standard set is the established default in spec §2.3, yet it is copy-pasted.

### 1.3 dashboard's hint and runtime overlap

spec §4.4 already specifies that runtime info comes from `lib.sh`'s `dashboard_info()`. The `dashboard` section of module.yaml was originally positioned as a "static fallback when not installed", but the `hint` string often re-copies the credentials/port that `dashboard_info()` would compute. Two sources of truth → drift.

### 1.4 Shared-component connection info is scattered and hardcoded (most severe)

`tools/base/docker-compose.yml` is the real definition of the PG/Redis instance (`aibox:aibox@…:35432`), but `openmaic/docker-compose.shared.yml` and `windmill/docker-compose.shared.yml` **copy the connection string verbatim**:

```yaml
# tools/openmaic/docker-compose.shared.yml (current, hardcoded)
- DATABASE_URL=postgres://aibox:aibox@aibox-base-pg:5432/openmaic
```

Changing base's port (35432→35000), user, password, or image version → dependent modules silently break, with no warning anywhere. And **there is no module.yaml field** declaring "I depend on base's postgres, with database name X" — spec §5 only describes the intent, leaving propagation to manually maintained compose overrides.

> **This design's solution is not to build yet another generator to replace hand-written overrides**, but rather: keep the module's existing hand-written `docker-compose.shared.yml` (stable structure: network join + `replicas:0`), **only replace the hardcoded credentials inside with `${AIBOX_POSTGRES_*}` variables**, whose values are written by base into a shared env file and injected live by aibox when invoking compose. Zero generation, zero extra files.

---

## 2. Trade-offs: Why These Approaches

| Decision point | Chosen | Why not the alternative |
| --- | --- | --- |
| **actions** | Spec defines a common lifecycle contract; modules still list all actions; service-type derived from containing `start` | ❌ "List only extra actions, inject the standard set implicitly": actions are no longer self-describing; you can't see the full picture from the yaml; both help and CI need injection logic. ❌ Add a `lifecycle: passthrough` field: duplicates "whether actions contains start", adding another drift point. |
| **actions reading** | CLI lists actions as help only when no action is given; no per-invocation validation | ❌ "Validate declared ∈ actions before forwarding, warn if not blocked": if it doesn't block it has no binding force, and it adds noise on every call — the worst of both worlds. |
| **files** | Standard set implicit; list only extras | ❌ "Explicitly list all + lint to enforce the standard set exists": still duplicates 5 lines; adding a new standard file requires editing all modules. Implicit union is backward-compatible (old yaml that lists everything still works). |
| **dashboard** | yaml keeps only endpoints+hint (pre-install) | ❌ "Remove the yaml field entirely": when not installed, the main CLI has no endpoint hint, degrading UX. |
| **Shared-component propagation** | base writes a `base.env` + compose `--env-file` live injection + module hand-writes a stable override using variables | ❌ "sync-deps generator templating overrides + `.env.aibox` + `base_conn_info`": the generator must understand each module's service topology (which joins the network, which has `replicas:0`) — this is inherently module-specific and clearest when hand-written; the generator amounts to reinventing a template engine, its output needs .gitignore, regeneration triggers, and conflicts with hand-written files. The module already has a hand-written shared.yml; only the credentials need to become variables. ❌ "Only write a spec without building a mechanism": relies on manual sync, treating symptoms not causes. |
| **Component naming** | Full names `postgres`/`redis` | ❌ Abbreviation `pg`: poor readability, decoupled from env-variable/compose-service naming. |

---

## 3. module.yaml New Field Table (schema increment)

### 3.1 Field overview (★ = changed/new this round)

```yaml
# tools/<name>/module.yaml — module declaration source of truth
name: windmill
version: 1.1.0
description: "..."
platform: ""                      # empty = cross-platform
dir: tools/windmill

deps:                             # runtime dependencies (command@platform:version), unchanged
  - docker
  - docker-compose
  - python3

ports:                            # port/protocol:purpose, unchanged
  - 8080/tcp:http

files:                            # ★ changed: list only "extra" files; the standard 5 files are implicit
  - windmill                      #   module's own CLI

services:                         # ★ new: shared-component dependencies (provider:component#dbname, full names)
  - base:postgres#windmill        #   declaration → CI validation + auto-createdb + compose auto --env-file base.env
  - base:redis

hooks:                            # unchanged (install/uninstall/update/svc)
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                          # ★ changed: still lists all; containing start → service-type, must satisfy the lifecycle contract (see §4)
  - start
  - stop
  - restart
  - status
  - logs
  - ...module-specific actions

upstream:                         # unchanged
  homepage: ...
  docs: ...

dashboard:                        # ★ changed: slimmed down, only two subfields
  endpoints:
    - "http://127.0.0.1:${PORT}"  #   static template (may use ${PORT} placeholder)
  hint: "credentials in CREDENTIALS.txt + .env"  #   one-line pre-install fallback
```

### 3.2 `provides` (provider modules only, e.g. base)

```yaml
# tools/base/module.yaml
provides:                         # ★ new: declares components exposed externally (full names)
  - postgres
  - redis
ports:
  - 35432/tcp:postgres
  - 36379/tcp:redis
```

### 3.3 Field semantics

| Field | Required | Description |
| --- | --- | --- |
| `name` `version` `description` `dir` `hooks` | Yes | Unchanged |
| `deps` `ports` `platform` | No | Unchanged |
| `files` | No | **List only extra files.** The standard set (`lib.sh install.sh uninstall.sh update.sh svc.sh`) is auto-filled by the parser. Listed items must exist in the repo directory. |
| `actions` | No | **List all actions.** A module containing `start` is service-type and must satisfy the lifecycle contract (§4); one without `start` (e.g. a pass-through downstream CLI) is distribution-type and is not enforced. The CLI lists actions as help when running `aibox <module>` (no action). |
| `services` | No | **Shared-component dependencies**, compact string `provider:component[#dbname]`. `component` uses full names (`postgres`/`redis`). `postgres` should provide `#dbname` (creates an independent database for the module); `redis` usually omits `#dbname`. Multi-DB use: `base:postgres#windmill_jobs`. Declaration drives: CI validation of provider/component, `install` auto-runs `base createdb`, compose scheduling auto-adds `--env-file base.env`. |
| `provides` | No | Provider modules only. Lists exposed component full names. A consumer module's `services` references must match some provider's `provides`. |
| `upstream` | No | Unchanged |
| `dashboard` | No | **Only `endpoints[]` + `hint`.** Other subfields are deprecated. `endpoints` may use placeholders like `${PORT}` (expanded against the module's env at parse time). |

### 3.4 Compact string format `provider:component[#dbname]`

- Three segments separated by colon/hash, **all scalars**, falling within the awk-parseable subset (spec §2.2).
- `dbname` may be omitted (`redis` usually has no separate DB, so omitted); `postgres` should provide `#dbname` (creates an independent database `<module>` for the module); omission falls back to the provider's default DB (shared across modules, not recommended). When provided, name it `<module>` or `<module>_<purpose>` (the spec §5.4 convention is preserved).
- Examples: `base:postgres#windmill`, `base:redis`, `base:postgres#windmill_jobs`.

---

## 4. Common Action Contract (lifecycle set)

The spec adds a new section "Common Action Contract". It defines the **unified semantics** of the following actions, which service-type modules (whose `actions` contain `start`) must implement:

| Action | Contract semantics (must be satisfied) |
| --- | --- |
| `start` | Start the instance (idempotent: no-op + notice if already running). Returns 0 on success. |
| `stop` | Gracefully stop the instance (idempotent: no-op if already stopped). Does not delete data. |
| `restart` | Equivalent to `stop` + `start`, or a native restart. |
| `status` | Output: running/not-running + key identifiers (PID/container name/port). Exit code 0 = running. |
| `logs` | Output recent logs, supporting `-f` follow. |

### 4.1 Service-type vs distribution-type (derived, no extra field)

- **Service-type** = `actions` contains `start` (base/clash/pi-web/windmill): must implement the lifecycle set. CI validates that `actions` contains the full lifecycle set and that `svc.sh` implements it.
- **Distribution-type** = `actions` does not contain `start` (openmaic pass-through downstream CLI): lifecycle not enforced; CI only validates that `actions` is self-consistent (declared actions have corresponding cases in `svc.sh`).
- **No `lifecycle: passthrough` field needed** — whether `start` is present is already self-describing; an extra field is an extra drift point.

### 4.2 CLI consuming actions (read in one place, no per-call validation)

`cmd_module_action`:

- **No action** (`aibox <module>`) → prints "usage: aibox $name <action>" + lists the declared `actions` (so the user knows what they can do). This is the only truly useful consumption point of the `actions` field.
- **With action** → forwards directly to `svc.sh`, **without validating** that the declaration ∈ actions (pass-through modules have variable actions; hard-blocking or warning is just friction).

This turns `actions` from a dead field into a live one, with zero runtime validation logic.

---

## 5. Shared-Component Provider Model (base + base.env)

### 5.1 Roles and the Single Source of Truth

```
provider = base
   ├─ tools/base/docker-compose.yml   ← real instance definition (image/port mapping/default credentials/volumes/network)
   └─ tools/base/lib.sh               ← holds connection constants; writes $AIBOX_HOME/base.env on base start
                                          base.env = the shared connection-info outlet (single source)
```

**Single-source-of-truth principle**: consumer modules **never** read base's compose directly, and **never** hardcode `aibox:aibox@`. The only legitimate path = `$AIBOX_HOME/base.env` (written by base, injected via `--env-file` when aibox schedules compose).

The contents of `base.env` must be consistent with `docker-compose.yml`'s port mapping + default env — base/lib.sh holds the constants and feeds both compose's `${...:-default}` and base.env; CI deps-lint guards consistency (see §7.3).

### 5.2 `base.env` content spec

`base start` (and `base restart`) writes `$AIBOX_HOME/base.env`, with contents like:

```dotenv
# Generated by aibox base start — do not edit by hand; after changing base, run base restart to rewrite
AIBOX_POSTGRES_HOST=aibox-base-postgres
AIBOX_POSTGRES_PORT=35432
AIBOX_POSTGRES_USER=aibox
AIBOX_POSTGRES_PASSWORD=aibox
AIBOX_REDIS_HOST=aibox-base-redis
AIBOX_REDIS_PORT=36379
```

- Only **instance-level shared** info (host/port/user/password) — not the database name (the DB name `<module>` is each module's own, provided by the module's `.env` `AIBOX_POSTGRES_DB`).
- Env variables, container names, service names, and port purpose labels use **full names** throughout (see §5.3).
- base/lib.sh uses the same constants to construct compose's `${AIBOX_BASE_POSTGRES_USER:-aibox}` default, ensuring base.env and compose are consistent.

> No `base_conn_info()` function is introduced — it was an interface designed for the generator; with no generator now, the base.env file itself is the outlet, and `aibox base status` can simply `cat` or display it.

### 5.3 Full-name consistency convention (throughout)

| Location | Old (abbreviation) | New (full name) |
| --- | --- | --- |
| module.yaml `services`/`provides` component | `pg` | `postgres` |
| env variable | `AIBOX_PG_*` | `AIBOX_POSTGRES_*` |
| compose service name | `pg:` | `postgres:` |
| container name | `aibox-base-pg` | `aibox-base-postgres` |
| port purpose label | `35432/tcp:pg` | `35432/tcp:postgres` |

`redis` is already a full name, unchanged. `aibox-base-postgres` (docker service name / container name) is base's **stable contract** to the outside; module overrides use it as the host — it is not a credential, and renaming it breaks the contract (rare, guarded by lint).

---

## 6. Connection-Info Propagation: base.env + compose `--env-file` (no generator)

### 6.1 Mechanism

1. **base writes** `$AIBOX_HOME/base.env` (§5.2), rewritten on `base start`/`restart`.
2. **When aibox schedules compose**, for modules that declare `services`, it automatically appends `--env-file "$AIBOX_HOME/base.env"` (alongside the module project's `.env`; compose v2 merges multiple `--env-file`). Thus `${AIBOX_POSTGRES_*}` can be interpolated in the compose file.
3. **The module hand-writes a stable** `docker-compose.shared.yml` (in-repo, travels with the module):
   - `db: replicas: 0` (does not start a local PG)
   - app service `networks: [default, aibox-base]` (joins the shared network, connecting via the service name `aibox-base-postgres`)
   - `environment: DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@aibox-base-postgres:${AIBOX_POSTGRES_PORT}/${AIBOX_POSTGRES_DB}` — **zero hardcoded credentials**; host uses the stable service name, the rest are interpolated variables.
4. **The module's own `.env`** sets `AIBOX_POSTGRES_DB=windmill` (the DB name belongs to the module) + the module's own variables.
5. **install**: `aibox <module> install` sees `services` → ensures `base` is running (otherwise prompts to run `aibox base start` first) + `base createdb <module>` creates the DB. **No sync-deps command** — not needed.

### 6.2 Change once → auto-propagate everywhere (core)

Changing base credentials/port/image:

1. Edit `tools/base/docker-compose.yml` + `base/lib.sh` constants;
2. `aibox base restart` → rewrites `base.env`;
3. Each consumer module's `aibox <module> restart` (compose up) → compose reads `--env-file base.env` and re-interpolates → the app reconnects with the new connection string.

**No more manual transcription, no more generated files, no more silent breakage.** The only thing the module side maintains is that stable shared.yml (network join + structure); credentials/port are always read live from base.env.

### 6.3 Degradation (back to standalone instance)

If a module needs an exclusive version/config incompatible with the shared one → module.yaml does **not** declare that component in `services` (aibox then does not add `--env-file`; the module's own compose starts a local instance); if a version pin is needed, use the existing `deps` mechanism to declare `postgres:14` (full name). The spec §5.7 degradation convention is preserved; no extra `@standalone` syntax is introduced.

---

## 7. CI lint Rules

### 7.1 module-lint (expanded)

- Every item listed in `files` must exist in `tools/<name>/`.
- **Service-type judgment is derived**: a module whose `actions` contains `start` must contain the full lifecycle set (start/stop/restart/status/logs) and `svc.sh` must implement them (grep the action-name case branches). Modules without `start` are not enforced.
- `dashboard` allows only the `endpoints` + `hint` subfields (extras error out).
- Component names in `services`/`provides` must be full names (whitelist `{postgres, redis, ...}`).

### 7.2 port-conflict (existing, retained)

Includes base's 35432/36379. Purpose labels synced to full names (`35432/tcp:postgres`).

### 7.3 deps-lint (new)

- For each `provider:component[#db]` in a consumer module's `services`:
  - `provider` must be a registered module;
  - that provider's `provides` must contain the `component`;
  - if `dbname` is given, it must follow the `<module>` / `<module>_<purpose>` naming.
- **Hardcoded credentials/hosts are forbidden**: `tools/*/docker-compose*.yml` (except `tools/base/`) must not match regexes like `aibox:aibox@`, `postgres://aibox:`, `:5432/aibox`. Modules must reference via `${AIBOX_POSTGRES_*}`. (The service name `aibox-base-postgres` as a stable host is allowed and does not count as a credential.)
- **base.env consistency**: the constants (host/port/user/password) used by `base/lib.sh` to write `base.env` must be consistent with `base/docker-compose.yml`'s port mapping + default env (`${AIBOX_BASE_POSTGRES_*:-...}`), preventing internal drift within the provider.

### 7.4 awk subset compliance (existing, retained)

`services`/`provides` are scalar lists, falling within the §2.2 subset; no relaxation needed.

---

## 8. awk Parser Changes

`parse_yaml_module_stdin` (`bin/aibox`):

1. The `files` union is done in `download_module` (standard set ∪ files deduplicated, standard set first), not in the parser — local, minimal intrusion. Backward-compatible with old yaml (listing all → after union still the full set, no duplicate downloads).
2. `services` / `provides` are parsed as new list fields as usual (`AIBOX_MODULE_<name>_services` / `_provides`, space-separated scalars), for CI validation, `install` createdb decisions, and the compose wrapper's decision to add `--env-file`.
3. `dashboard.endpoints` (existing list) retained; `dashboard.hint` (existing scalar) retained; other subfields deprecated (CI error is enough).
4. **`esc()` escapes `$` / `"` / `` ` `` / `\` in `printvar` values**, so that `${...}` in values (e.g. `${PORT}`, `${AIBOX_POSTGRES_*}`) stays literal and is not expanded by `eval` — fixing the original parser's bug where `$VAR`/`${VAR}` in values were expanded during `eval` injection (which under `set -u` would blow up as unbound). The `${PORT}` placeholder in dashboard endpoints is therefore usable.
5. `module_field` still returns space-separated strings for `services`/`provides`; the caller splits them further.

Zero structural breakage, minimal changes.

---

## 9. Migration Path (phased; executed during implementation; this round only plans)

### Phase A: Remove module.yaml field redundancy (low risk)

1. awk parser adds files union + parses services/provides.
2. Each module.yaml: remove `files` standard lines, slim down `dashboard`, change `ports` purpose labels to full names.
3. CI module-lint adds new validations (including service-type derived judgment).
4. Existing hand-written `docker-compose.shared.yml` stays for now (refactored to use variables in the next phase).

### Phase B: Shared-component base.env + compose injection

1. base: `lib.sh` holds connection constants + `base start`/`restart` writes `$AIBOX_HOME/base.env`; `docker-compose.yml` service/container/env renamed to full names; `module.yaml` adds `provides`.
2. aibox compose wrapper: modules declaring `services` auto-append `--env-file "$AIBOX_HOME/base.env"` (detect compose v2.24+ multiple `--env-file` support; if too old, error and prompt to upgrade).
3. `aibox <module> install`: sees `services` → ensures base is running + `base createdb <module>`.
4. CI deps-lint goes live (warn first, then fail).
5. One new module uses the shared setup first (no legacy baggage).

### Phase C: Migrate existing modules (data risk; separate iteration)

1. openmaic/windmill: replace **hardcoded credentials in existing hand-written `docker-compose.shared.yml` with `${AIBOX_POSTGRES_*}` variables** (structure unchanged); `.env` adds `AIBOX_POSTGRES_DB=<module>`; module.yaml adds `services`.
2. Data migration: `pg_dump` the old standalone PG → import into the shared PG's `<module>` database.
3. Throughout, lint fail → fallback.

---

## 10. Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| compose does not support multiple `--env-file` | Require compose v2.24+ (Docker Desktop ships ≥2.29); the aibox wrapper detects the version and errors with an upgrade prompt if too old, without silently degrading. |
| `base.env` missing/stale → module interpolates empty values, can't connect | The aibox compose wrapper checks that `$AIBOX_HOME/base.env` exists before adding `--env-file`; if missing, it prompts "run `aibox base start` first" and aborts. `aibox <module> status` detects when base.env is inconsistent with base's current running state and prompts to rerun `base restart`. |
| Module forgets to set `AIBOX_POSTGRES_DB` in `.env` | CI deps-lint: a module declaring `base:postgres#<db>` must have `AIBOX_POSTGRES_DB` in its `.env` (or compose env) with value = `<db>`. |
| Drift between base.env and compose defaults | CI deps-lint validates consistency (§7.3). |
| Full-name rename affects existing compose | Phase B renames base in one pass; consumer modules sync during Phase C migration. Lint blocks new abbreviations once Phase B goes live. |
| Service name `aibox-base-postgres` mistakenly blocked as a credential | deps-lint only blocks credential literals (`aibox:aibox@` / `postgres://aibox:`); the service name as host is allowed (§7.3). |

---

## Appendix A: Full module.yaml Examples

### A.1 Provider module (base)

```yaml
# tools/base/module.yaml
name: base
version: 1.0.0
description: "Shared base components (PostgreSQL 18 + Redis 7), each module with an independent database"
platform: ""
dir: tools/base

deps:
  - docker
  - docker-compose

provides:
  - postgres
  - redis

ports:
  - 35432/tcp:postgres
  - 36379/tcp:redis

files:
  - docker-compose.yml          # extra (standard 5 files implicit)

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
  - createdb

upstream:
  homepage: https://www.postgresql.org/
  docs: https://www.postgresql.org/docs/

dashboard:
  endpoints:
    - "postgres: postgres://127.0.0.1:35432  redis: redis://127.0.0.1:36379"
  hint: "aibox base createdb <module> to create a DB; connection info in $AIBOX_HOME/base.env"
```

### A.2 Consumer module (windmill, service-type)

```yaml
# tools/windmill/module.yaml
name: windmill
version: 1.1.0
description: "Windmill self-host ops CLI (init/upgrade/backup/drill/doctor)"
platform: ""
dir: tools/windmill

deps:
  - docker
  - docker-compose
  - python3

ports:
  - 8080/tcp:http

files:
  - windmill                   # extra CLI

services:
  - base:postgres#windmill
  - base:redis

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                       # contains start → service-type, must satisfy the lifecycle contract
  - start
  - stop
  - restart
  - status
  - logs
  - shell
  - credentials
  - systemd
  - destroy
  - backup
  - upgrade
  - rollback
  - check
  - deploy
  - restore
  - drill
  - snapshots
  - init

upstream:
  homepage: https://github.com/windmill-labs/windmill
  docs: https://www.windmill.dev/docs/

dashboard:
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "credentials in CREDENTIALS.txt + .env; DB connects to shared PG via ${AIBOX_POSTGRES_HOST} (value injected from base.env)"
```

### A.3 Distribution-type module (openmaic, no start → auto distribution-type, no extra field)

```yaml
# tools/openmaic/module.yaml
name: openmaic
version: 1.0.0
description: "OpenMAIC ops CLI (install/upgrade/backup/doctor)"
platform: ""
dir: tools/openmaic

deps:
  - docker
  - docker-compose
  - git

ports:
  - 3000/tcp:app

files:
  - openmaic                   # extra CLI

services:
  - base:postgres#openmaic

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                       # does not contain start → distribution-type, lifecycle not enforced
  - status
  - health
  - doctor
  - version
  - up
  - down
  - restart
  - logs
  - render
  - upgrade
  - rollback
  - backup
  - restore
  - db
  - config
  - models
  - install
  - clean
  - powerlog
  - url

upstream:
  homepage: https://github.com/THU-MAIC/OpenMAIC
  docs: https://github.com/THU-MAIC/OpenMAIC#readme

dashboard:
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "credentials in .env.local; DATABASE_URL constructed by shared.yml using ${AIBOX_POSTGRES_*} (injected from base.env)"
```

---

## Appendix B: base.env + hand-written stable shared.yml example (windmill)

### `$AIBOX_HOME/base.env` (generated by `aibox base start`)

```dotenv
# Generated by aibox base start — do not edit by hand; after changing base, run base restart to rewrite
AIBOX_POSTGRES_HOST=aibox-base-postgres
AIBOX_POSTGRES_PORT=35432
AIBOX_POSTGRES_USER=aibox
AIBOX_POSTGRES_PASSWORD=aibox
AIBOX_REDIS_HOST=aibox-base-redis
AIBOX_REDIS_PORT=36379
```

### Module `.env` (windmill's own, in-repo or in the deploy directory)

```dotenv
AIBOX_POSTGRES_DB=windmill      # DB name belongs to the module; host/port/user/password injected from base.env
# ...windmill's own variables
```

### `tools/windmill/docker-compose.shared.yml` (hand-written, stable, zero hardcoded credentials)

```yaml
# Network structure stable; credentials/port always ${AIBOX_POSTGRES_*} (injected via --env-file base.env when aibox invokes compose)
services:
  db:
    deploy:
      replicas: 0              # does not start a local PG
  windmill_server:
    depends_on: []
    networks: [default, aibox-base]
    environment:
      - DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@aibox-base-postgres:${AIBOX_POSTGRES_PORT}/${AIBOX_POSTGRES_DB}
  windmill_worker: { depends_on: [], networks: [default, aibox-base] }
  windmill_worker_native: { depends_on: [], networks: [default, aibox-base] }
  windmill_indexer: { depends_on: [], networks: [default, aibox-base] }
networks:
  aibox-base:
    external: true
```

What aibox actually executes when scheduling this module's compose (illustrative):

```bash
docker compose --env-file .env --env-file "$AIBOX_HOME/base.env" \
  -f docker-compose.yml -f docker-compose.shared.yml up -d
```

`DATABASE_URL` is interpolated from `${AIBOX_POSTGRES_*}` at compose parse time — `.env` provides `AIBOX_POSTGRES_DB`, `base.env` provides the rest. Change base credentials → `base restart` rewrites base.env → the next `aibox windmill restart` automatically uses the new values.

---

## 11. Implementation Status (2026-09-16)

**Implemented and verified (commit `1b3369a`):**

- **Phase A**: awk `esc()` + `download_module` files union + `cmd_module_action` lists help when no action + all 5 module.yaml updated (files slimmed / dashboard slimmed / ports full names / services·provides).
- **Phase B**: `base/lib.sh` `write_base_env()` + `base start` writes `$AIBOX_HOME/base.env`; `base/docker-compose.yml` service `pg`→`postgres`, container `aibox-base-pg`→`aibox-base-postgres`, env `AIBOX_BASE_PG_*`→`AIBOX_BASE_POSTGRES_*` (the `pg_data` volume retains old data); `bin/aibox` `ensure_services` (on install, seeing services → base start + createdb).
- **Phase C (openmaic)**: `docker-compose.shared.yml` + heredoc `DATABASE_URL` changed to `${AIBOX_POSTGRES_*}`; `compose()`/`compose_timed()` shared-mode append `--env-file base.env`.
- **Phase C (windmill)**: mechanical rename `aibox-base-pg`→`aibox-base-postgres` / `AIBOX_BASE_PG_*`→`AIBOX_BASE_POSTGRES_*` (CLI + shared.yml + DEVELOPMENT.md).
- **CI**: `module-lint` expanded (files exist / lifecycle / dashboard two subfields / full-name whitelist) + §2.2 grep excludes `${...}`; new `deps-lint` job added.

**Verified (docker):**

- `aibox base start` → `aibox-base-postgres` starts + `$AIBOX_HOME/base.env` written; old DBs (`testdb`/`windmill`) retained via the `pg_data` volume.
- `docker compose --env-file base.env -f … config` → `${AIBOX_POSTGRES_*}` interpolated to `postgres://aibox:aibox@aibox-base-postgres:5432/<db>`; without `--env-file` they are empty — proving base.env is the single source.
- openmaic's real shared.yml + base.env → `config` renders `DATABASE_URL` correctly parsed, `replicas:0`, joins `aibox-base`.
- `bash -n` all pass; bash 3.2 gotchas #1 #8 scan clean; `aibox list/ports/dashboard/dev-guide` regress normally.

**Remaining (the "separate iteration" noted in design §9; not in scope this round):**

- **windmill deep var-conversion**: currently windmill's `DATABASE_URL` is in the `.env` rendered by `init` (unquoted heredoc baked-in), using the `${AIBOX_BASE_POSTGRES_*:-aibox}` default; not a live read of base.env. Works with base's default credentials; if base credentials are customized, `windmill init` must re-render, or later move `DATABASE_URL` into shared.yml `environment:` + `_compose()` adds `--env-file base.env` (same as openmaic — i.e. the target form shown in Appendix B's windmill example, not yet landed).
- **Data migration `pg_dump`**: loading existing standalone PG → shared PG is a runtime ops task, to be executed on the deploy host (design §9 Phase C step 2).

---

## License

MIT.

# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the main CLI (`AIBOX_VERSION`
in `bin/aibox`). Each module versions independently (`version:` in its `module.yaml`).

GitHub release notes are auto-generated from the previous tag; this file is the curated summary.

## [0.17.0] — 2026-09-25

A consistency + upgrade-safety pass: docs/config drift on one side, and the
upgrade/rollback story turned into a framework with a recorded rollback point.
Semver: minor — new verbs, new dashboard rows and a normative doc rule; one stale
port declaration removed.

### Added

- **A recorded rollback point + `aibox upgrade <module> --rollback` / `--history`** — the
  engine writes `$AIBOX_HOME/upgrades/<module>.state` (+ `.log`) at every phase (`from`,
  `to`, `ts`, `envbak`, `databak`, `status`, `live`), so a manual rollback knows exactly
  what it is returning to. `--rollback` swaps the point (undo-the-undo), and both verbs
  work **offline** (state file + deploy `.env` only).
- **Pre-upgrade data snapshot for shared-PG consumers** — a module whose `services:`
  declares `base:postgres#<db>` gets that database dumped to
  `$AIBOX_HOME/upgrades/<module>-db-<ts>.sql.gz` before the version moves (container and
  user come from `base.env`); `--no-backup` skips it; the restore recipe is printed,
  never auto-run. Modules with no shared DB now say “rollback restores the version pin
  only” instead of implying safety.
- **Post-upgrade verification** — after a successful upgrade the version the RUNNING app
  reports (`dashboard_info`) is recorded, and a tag/app-version mismatch warns.
- **Dashboard detail rows** — `config` (declared knob count + `aibox <m> config list`),
  `upgrade` (last transition `from → to · status · timestamp · live`) and `rollback` (the
  recorded pin + the exact command). `aibox dashboard base` additionally prints
  `containers` and `env` — exactly the profile-derived values docs now point at instead
  of hardcoding.
- **Normative doc rule (spec §Doc hygiene + AGENTS.md rule 10)** — never hardcode derived
  values (profile ports, container names, env paths, credentials): label the
  default-profile default and point at `aibox dashboard <module>` / `aibox <module>
  config list`. The validator WARNs when a profile-deriving module documents numeric
  ports with no dashboard pointer, and `tests/docs-config-drift.bats` locks the whole
  class (env-key ↔ code references, port declarations ↔ published ports, exit codes).

### Changed

- **Verified auto-rollback + the documented exit codes** — a failed health check restores
  the `.env` pin, recreates, and then CHECKS the result: healthy → exit `10` (“upgrade
  failed, rolled back”), still broken → exit `20` (“manual intervention needed”) with the
  pin path and the retry command. The engine previously claimed “rolled back” without
  verifying, and always returned `20`.
- **The installed marker keeps the MODULE version** — the engine no longer overwrites it
  with the app version (that made the next `aibox update` report a bogus version
  transition); the app version now lives in the upgrade state, where the dashboard reads it.
- **Multi-hop rollback is precise** — it restores the previous hop's *resolved* version
  (read from that hop's `.env` backup) and records a path-level rollback point
  (`.prepath.<ts>.<pid>`) for returning to where the path started.
- **Dangerous backup-name collision removed** — `.env` backups are `<ts>.<pid>` suffixed:
  two runs inside the same second used to share a path, and a rollback in that window
  clobbered its own rollback point (caught by the new suite).
- base `1.4.3` → `1.4.4` (dashboard rows), openmaic `1.3.2` → `1.3.3` (port declaration).

### Fixed

- **openmaic declared `5432/tcp:postgres` while the upstream compose publishes only `3000`**
  (its PostgreSQL is compose-internal, with no host mapping) — a declared port is rendered
  by the dashboard with a listen mark and reserved by the port-conflict gate, so the stale
  entry misled both. Removed; `docs/DEVELOPMENT.md` explains where the connection really lives.
- **Docs no longer present profile-derived ports as universal** — base/pi-web READMEs and
  pi-web's DEVELOPMENT label the default-profile values and point at the dashboard (base also
  documents the profile-suffixed deploy root/env file).
- **`--history` / `--rollback` no longer require the registry** — they died with
  “Unknown module” on an offline host even though everything they need is local; unknown
  modules still report “Unknown module” on the resolution paths.
- **`.env` renderer executed backticks in its own comments** (windmill module, from 0.16's
  unquoted heredoc) — locked by a test there; noted here because it shipped in 0.16.0.

## [0.16.0] — 2026-09-25

The windmill module becomes configurable where it previously required hand-editing
GENERATED files (docker-compose.yml / Caddyfile / .env — all of which the next
render overwrites, so those edits never survived an upgrade).
Semver: minor — new knobs and new behavior; the entry-port default also changes
(80 → 8080, see Changed for the migration note).

### Added

- **`BASE_URL` — domain / HTTPS for the Windmill stack.** The generated Caddyfile
  now takes its site address from `BASE_URL`, so a real domain gets automatic
  HTTPS (ACME) and the compose publishes `443:443`; `https://` + a bare IP gets
  `tls internal` (self-signed — ACME cannot certify an IP, the old flow would have
  retried forever); empty keeps the previous plain-HTTP-behind-your-own-proxy
  behaviour. Hardening then sets Windmill's Base URL from it instead of the
  auto-detected LAN IP (wrong behind a domain). A port or path inside `BASE_URL`
  is rejected with guidance, because that would make Caddy listen on a container
  port the published mapping does not cover.
- **Worker / indexer sizing knobs** — `WM_WORKER_REPLICAS` (3), `WM_WORKER_MEMORY`
  (1536M), `WM_NATIVE_REPLICAS` (1), `WM_NATIVE_MEMORY` (1024M),
  `WM_INDEXER_REPLICAS` (0; `1` enables full-text job/log search). They are
  `.env`-interpolated into the compose, so scaling no longer means hand-editing a
  generated file.
- **`LOG_MAX_SIZE` (20m) / `LOG_MAX_FILE` (10) / `KEEP` (7)** — log-rotation and
  backup-retention knobs that already existed in the templates but had no way to
  be set; `KEEP` is baked into `windmill-backup.service` so the timer honours it.
- **`ENABLE_LSP` / `ENABLE_MULTIPLAYER` / `ENABLE_DEBUGGER`** — the compose comment
  advertised these as environment-switchable while they were hardcoded; they are
  real knobs now (boolean-validated).
- **`windmill init --base-url <url>`** — set the advertised URL at deploy time
  (host-wide default: `aibox windmill config set BASE_URL <url>`).
- **`windmill deploy --recreate` re-renders `docker-compose.yml` + `Caddyfile`** —
  the rendered artifacts are regenerated from the current knobs before the stack
  restarts, which is also the only path that can pick up a `BASE_URL` scheme change
  (compose cannot conditionally publish a port). `.env` is never re-rendered
  (version pins and the DB password must survive).
- **The seeded `/etc/windmill/windmill.conf` now documents every supported key**
  (commented, with defaults), so the knobs are discoverable without reading the
  docs; the CLI itself is now sourceable (source guard) for offline tests.

### Changed

- **Default entry port is 8080** (was 80 in code while three docs said 8080).
  *Migration:* existing deployments keep the value pinned in their `.env`/conf —
  nothing changes for them; only fresh installs get 8080.
- **Conf values flow into `.env` at every `up`/`deploy`** (`sync_env_knobs`), which
  is what makes `aibox windmill config set` effective without touching generated
  files. An explicit non-default conf value wins; otherwise an existing `.env`
  line is preserved, so a hand edit on the deploy instance still wins over the
  built-in default.
- windmill CLI `1.1.0` → `1.2.0`; module `1.4.2` → `1.5.0`.

### Fixed

- `aibox windmill config list` advertised `HTTP_PORT (default: 8080)` while the
  code default was 80 — the three-way drift (module.yaml / docs / code) is gone.
- The `.env` renderer executed backticks inside its own comments (the heredoc is
  intentionally unquoted so values expand): `` `tls internal` `` and
  `` `windmill systemd install` `` were run as commands while writing the file.

## [0.15.1] — 2026-09-25

### Fixed

- **A module start now ensures its declared service deps instead of demanding a
  second command** — `aibox xiaozhi start` died with "shared base not running
  (compose needs the external network aibox-base) — first: aibox base start"
  (live-caught); the same pattern existed for new-api and for dify in
  `DIFY_SHARED_BASE=1` mode, and `aibox base create <db>` died with "PG not
  running? aibox base start" whenever the stack was down. `start`/`restart` now
  ensure the provider first: the manager runs the ensure before dispatching
  (quiet when the base is already up) and the module hooks carry
  `ensure_shared_base` for direct invocation — down → started and awaited,
  already up → a silent no-op, unstartable → a clear failure naming
  `aibox base logs` / `aibox base status`. `stop`/`logs`/`status` never start
  anything.
- **The resource-less service entry form (`base:redis`) is honored** — it was
  skipped entirely, so a provider was started only by accident of a sibling
  entry; the manager now starts the shared base for it too (no resource to
  create).
- **`aibox <module> start` warns when a declared dep binary is missing** — a
  vanished node (pi-web) surfaced only as "the service did not come up" after a
  silent crash; the action now names the dep and points at `aibox check <module>`
  (existence-only probe: no network, no auto-install).

### Changed

- **`aibox base start` is quiet when there is nothing to do** — the idempotent
  path now reports "Shared PG/Redis already running (PG …:… / Redis …:…)"
  instead of re-running `compose up -d` and printing the container table on every
  consumer start. `base.env` is still rewritten when it went missing (a deleted
  file must come back even with the containers up).

## [0.15.0] — 2026-09-25

A usability pass over the whole surface: unknown arguments, dependency auto-install,
service readiness, and the messages around them. Semver: minor — new user-visible
behaviors and knobs, no breaking changes (defaults keep the previous behavior except
for message wording).

### Added

- **Typos get a suggestion** — `aibox instal base` used to die as
  "Unknown module: instal" with no way forward. Unknown verbs AND unknown modules
  now answer with the closest match (`did you mean: aibox install?`) plus one
  consistent catalog hint (`aibox dashboard --available`); the hint used to appear
  on some death paths only.
- **`aibox check self` covers the JS toolchain** — node/npm are reported alongside
  docker, and the docker line lost its hardcoded module list ("needed by
  base/openmaic/windmill" was stale — it missed new-api/dify/gitlab/xiaozhi and node
  entirely). The list is derived from the installed module metadata, or omitted when
  nothing declares the tool.
- **`AIBOX_PM_TIMEOUT` (default 600s)** — package-manager auto-installs are bounded
  and keep the user informed: the exact command is announced up front, a heartbeat
  prints every 30s, and on timeout the process tree is killed (children first) with
  the tail of the package log plus the knob to raise. Live-caught: `install pi-web`
  sat 10+ minutes inside a node auto-install with zero output. Set `0` to disable.
- **`AIBOX_STRICT_SERVICES=1`** — makes `aibox install <m>` exit non-zero when a
  declared service dependency failed to start (default stays exit 0 with the loud
  warning described under Fixed).
- **Profile creation reports what it derived** — "Created profile 'x'" now names the
  derived ports/containers (base: postgres/redis ports + container names; pi-web:
  port + service label) instead of leaving them to be discovered via `docker ps`.
- **`require_docker` guard in the shared module library** — docker-using module
  actions die with "docker CLI not found — this action needs it" instead of a raw
  `tools/base/lib.sh: line 138: docker: command not found` (exit 127, live-caught on
  `aibox base status` without docker).
- **`require_curl` guard** — a missing curl is named as such instead of surfacing as
  a misleading "Download … failed (check branch/path)".
- **The catalog explains its VERSION column** — the footer states VERSION = the aibox
  module version and points at `aibox dashboard <module>` for the deployed app
  version (the two are easy to confuse side by side).

### Changed

- **Module auto-install dedupes by package set** — `docker` + `docker-compose`
  (one `apt install docker.io docker-compose-v2`) and `node` + `npm` (one
  `apt install nodejs npm`) are attempted once per preflight instead of twice; the
  second entry says why it was skipped.
- **`AIBOX_NO_AUTO_DEPS=1` covers package-manager installs too** — it used to gate
  only service-dep installs, so `install x` still shelled out to apt.
- **Node auto-install skips a knowably-too-old distro candidate** — Ubuntu 24.04
  ships nodejs 18 while pi-web declares `node:22`: the old flow installed 18,
  rechecked, failed, and offered no path forward. When `apt-cache policy nodejs`
  shows a candidate below the requirement, the install is skipped and the exact nvm
  command is printed.
- **Package-install failure no longer blames the daemon** — "docker installed but the
  daemon didn't start" is printed only once the docker CLI actually exists;
  otherwise the message is about the install (and says so).
- **The manager resolves `AIBOX_BIN_DIR` with the bootstrap's precedence** — explicit
  → `~/.local/bin` when already in PATH → an in-PATH writable system dir
  (`AIBOX_SYSTEM_BIN_DIRS`, default `/usr/local/bin /opt/homebrew/bin`) →
  `~/.local/bin`. Module CLIs now land where the manager lives on deploy hosts,
  instead of diverging from the bootstrap's choice indefinitely.
- **The bootstrap tail distinguishes first install from re-install** — "Install your
  first module" on a self-update read as nonsense on a host that has modules; a
  re-install now reports "updated: X → Y" (or "re-installed … already up to date").

### Fixed

- **A service dependency that did not start is now loud** — install used to end with
  "✓ installed" and exit 0 while the module could not work (live-caught: new-api),
  leaving the failure buried mid-scroll. The default keeps exit 0 for compatibility
  but ends with a ⚠ block naming the fix (`aibox base start`) and the verification
  command; `AIBOX_STRICT_SERVICES=1` opts into a non-zero exit.
- **Preflight no longer suggests `--skip-checks` for hard failures** — the bypass
  hint is offered only for soft conditions (disk/domains/docker pull); missing
  dependencies/commands/services state explicitly that they cannot be bypassed,
  since bypassing only defers the failure to a confusing mid-install crash.
- **Re-install says it is re-deploying** — "Installing x" with identical output read
  as a silent no-op; it now reports `x is already installed (1.4.2) — re-deploying
  (hooks are idempotent)`.
- **Purge scans both bin dirs** — the residue map covers the resolved bin dir AND the
  legacy `~/.local/bin` copy, so pre-0.15 module CLIs are never reported as "clean".
- `aibox proxy check <url>` with no proxy configured said "Usage: aibox proxy check
  [url]" — the fix referenced the command that had just failed; it now names
  `aibox proxy set <url>`.

## [0.14.0] — 2026-09-24

### Added

- **Declared service dependencies auto-install first** — `aibox install xiaozhi`
  (`services: base:postgres#xiaozhi`) previously died with "fix: aibox install base";
  `cmd_install` now resolves the declared chain and installs missing providers BEFORE
  the target (recursive, cycle-guarded, same profile/flags inherit; a failed provider
  aborts the target). `AIBOX_NO_AUTO_DEPS=1` restores the manual gate.

### Fixed

- `cmd_install`: the install hook's exit status is now checked explicitly — in a
  condition context (the dependency path) `set -e` is suspended for the whole body,
  so a failing hook was swallowed and the module still marked installed (live-caught
  by the new dep-failure test).

## [0.13.5] — 2026-09-24

### Changed

- **`curl … | bash` PATH handling: install where the command works immediately** —
  bin-dir precedence is now: explicit `AIBOX_BIN_DIR` → `~/.local/bin` when already in
  PATH (no churn for existing setups) → an **in-PATH writable system dir**
  (`/usr/local/bin`, `/opt/homebrew/bin`; `AIBOX_SYSTEM_BIN_DIRS` overrides) →
  `~/.local/bin` with the rc block as the last resort. The root/deploy-host case that
  printed "`/root/.local/bin` is not in your PATH" right after the one-liner now
  installs to `/usr/local/bin` and just works — zero shell setup. When the last resort
  is used the block goes into BOTH `~/.bashrc` and `~/.profile` for bash users
  (interactive + LOGIN shells — Debian root's login reads only the latter),
  idempotently, and an apply-now line is printed for the current shell (the parent
  shell's PATH cannot be modified from the piped child — process boundary).

### Fixed

- `gitlab-upgrade-path` test mocked the pre-0.13.0 `upgrade_fetch` seam while the
  resolver had moved to `dockerhub_tags_fetch` — the case silently became
  NETWORK-dependent (green only while the runner's egress reached hub.docker.com and
  the real data matched the expectation; live-caught in the container).

## [0.13.4] — 2026-09-24

### Fixed

- **`aibox update <module>`: the update HOOK always runs** — v0.13.2's no-op gate
  short-circuited BEFORE the hook, silently dropping every module's app-level
  refresh when the script version was unchanged (pi-web's `@agegr/pi-web` npm
  upgrade + the pi CLI refresh, clash's kernel upgrade, openmaic/windmill's
  dispatched CLI install, the docker modules' compose refresh). Now only the
  SCRIPT re-fetch is skippable (same remote version + intact standard set +
  intact declared `files:`); the hook runs either way and the two layers report
  separately — the manager owns the script line, the hook owns the app line:

  ```text
  openmaic scripts already at 1.3.1 (no re-fetch) — running the update hook
  openmaic is up to date (1.0.1), no update needed              ← hook (app)
  openmaic module scripts unchanged at 1.3.1 · update hook ran above
  ```

## [0.13.3] — 2026-09-24

### Added

- **`aibox update pi-web` also refreshes the pi CLI itself** — `pi update --all`
  (pi + all its extensions) rides along on both the upgrade and the
  already-latest path, best-effort and never fatal (watchdog-bounded,
  `PI_WEB_PI_UPDATE_TIMEOUT` 240s; a missing/slow/failing pi degrades to a warn).
  (module 1.4.2)

### Fixed

- Test-suite portability (found by moving the suite into a clean Linux
  container): GNU `stat -f` semantics in two pool-cache tests (GNU-first order,
  as the other tests already do); the expect pty width test now counts
  characters locale-independently (Tcl `string length` counts BYTES under the
  C locale); the residue-section test skips without a docker CLI.

## [0.13.2] — 2026-09-24

### Fixed

- **`aibox update <module>`: the version transition is now visible** — the final line
  reports `updated: 1.3.3 → 1.4.1` instead of a bare "updated to 1.4.1" (measured user
  confusion: no way to tell whether anything actually changed); same version → the
  no-op gate skips the whole re-fetch (one pooled module.yaml probe + intact-cache
  check): `already at 1.4.1 — no update needed`. A BROKEN cache at the same version
  still self-heals (`refreshed at X (no version change)`); `update --all` short-circuits
  per module.
- **registry refresh noise**: `_load_registry_remote` fetched `tools/_shared/module.yaml`
  on every remote registry refresh — a file that does not exist (the include home is
  not a module): a 4-candidate pool miss + a warn line in every update's output
  (live-caught in the user's paste). `_*`-prefixed dirs are now skipped.

## [0.13.1] — 2026-09-24

### Fixed

- **gitlab: "the displayed password doesn't look like the generated one"** — it isn't, and
  that's correct: with the seeded `GITLAB_ROOT_PASSWORD` in effect, GitLab BYPASSES its own
  random generation entirely (measured: the 24h `initial_root_password` file is not even
  created). `aibox gitlab credentials` now labels the source ("seeded in the deploy .env —
  GitLab's own random + 24h file is bypassed") so the display is unambiguous; the live
  verification remains the ground truth. Hardened: an EMPTY seed value (which would seed a
  blank root password — Ruby treats `""` as truthy in `ENV[...] || random`) is now
  regenerated in place; `credentials` never displays a blank. (module 1.5.2)

## [0.13.0] — 2026-09-23

### Added

- **Docker source selector — one selector, three families, shared state** — all
docker.io / ghcr.io traffic now follows one strict, user-pinned priority:
  ① the official/default route (direct), ② the LOCAL addresses the host already
  has (the docker daemon's own registry-mirrors, auto-discovered from `docker info`,
  + the `AIBOX_DOCKER_MIRROR` / `AIBOX_GHCR_MIRROR` knobs), ③ only on
  timeout/failure a **live-verified acceleration pool** (10 docker.io mirrors
  measured direct, multi-source authoritative; 2 ghcr mirrors), speed-ranked,
  fastest-first with per-source failover. Covers image pulls (PULL family,
  `docker_pool_prepull`) AND upgrade **version resolution** (TAGS family,
  `dockerhub_tags_fetch` — the exact call path that made `aibox upgrade gitlab`
  die with "cannot resolve the latest version" on hub.docker.com-blocked
  networks), plus ghcr (family migrated into `_shared/common.sh` with a sticky
  winner). Rankings persist in `$AIBOX_HOME/dockerpool.cache` (TTL 600s,
  mode 600): a known-dead official route is skipped (no repeated timeout tax)
  until the TTL re-probes; total failure invalidates and re-resolves
  (self-healing — mirrors die AND revive; dockerproxy.net measured swinging
  within one day and is documented, not shipped).

### Fixed

- `aibox upgrade <dockerhub module>` / the dashboard's update probes only ever
  hit `hub.docker.com` directly — dead on CN-class networks; now they resolve
  through the docker source selector (verified live: `__dash-probe gitlab`
  went from empty to `19.4.1-ce.0` with hub.docker.com unreachable).
- `docker_pool_prepull` re-probed (direct + all mirrors) on EVERY start; the
  ranking is now cached per TTL.

## [0.12.1] — 2026-09-23

### Fixed

- **gitlab: root login with the shown password failed** — live-caught on a deploy host:
  `aibox gitlab credentials` read GitLab's 24h `initial_root_password` file, but the
  docker wrapper re-runs `gitlab-ctl reconfigure` on every container start, which
  REWRITES that file while the database keeps the first-seed password — the displayed
  password silently stops matching reality. Credentials are now deterministic and
  verified: install seeds `GITLAB_ROOT_PASSWORD` into the deploy `.env` (never rotated;
  compose passes it to the container, applying at first boot with fresh volumes), and
  `aibox gitlab credentials` checks it against the **live root account** — `✓ verified`,
  or `INVALID` with the reset recipe (`gitlab-rake "gitlab:password:reset[root]"`, modern
  syntax) when volumes predate the seed. Legacy installs self-heal: `start`/`install`
  append the seed to an existing `.env`. (module 1.5.0)

## [0.12.0] — 2026-09-23

### Highlights

- **Dashboard: app vs module versions, one keyline template** — the headline ask of this
  release: every dashboard now leads with the deployed **app version** (the thing you
  actually track — `pi-web 0.9.3`, the mihomo kernel tag, docker image tags), while the
  aibox **module packaging version** sinks to a dim footer row. The old ambiguous
  `· module <ver>` header is gone everywhere.

### Added

- **Dashboard: app vs module versions, one keyline template** — every dashboard now leads
  with the deployed **app version** (cyan header: npm package / image tag / kernel tag /
  dispatched CLI) and sinks the **aibox module version** to a dim footer row; the old
  ambiguous `· module <ver>` header is gone everywhere. `dashboard_info`'s `version=`
  key now feeds the manager views' header (the `upstream:` label is retired). Shared
  `dash_header`/`dash_row`/`dash_module_row` helpers (`_shared/common.sh`) unify the
  module rich views, the overview and the detail view: colon-free label grid, health
  merged into the endpoint row, dim keyline rules. New modules scaffold the template
  and the validator WARNs on gaps (S18/S19).

### Fixed

- **pi-web health mis-report**: an HTTP 307 redirect (the normal authed answer) was
  reported `⚠ starting` — now 2xx/3xx/401 count as healthy, aligned with the manager's
  verdict table.
- Four modules rendered stale hardcoded module versions (new-api `1.1.0`, dify `1.17.2`,
  gitlab `1.2.1`, xiaozhi `1.0.1` — vs their module.yaml): all read module.yaml now.
- `aibox <module> dashboard` no longer interleaves raw `launchctl`/`lsof` dumps with the
  rich view (raw detail stays in `diagnose`).

## [0.11.0] — 2026-09-23

### Highlights

- **Configuration system** — every module's config surface is now CLI-discoverable and settable:
  `aibox <module> config [get|set|unset]` + `aibox <module> --help` renders the config keys table.
- **Module-level `dashboard` merged into `status`** — one "show state" verb (facts + rich view).
- **README rewritten to open-source standards** — badges, Features, CLI Grammar, and a dedicated
  Ports & endpoints heads-up (aibox-deployed services don't use upstream default ports).
- **clash download: verification-gated failover** — a mirror serving a corrupt body is discarded,
  the next source is tried (previously: a valid gzip of the wrong thing killed the install).

### Added — configuration system (env: declaration + `config` action; spec §Configuration)

The missing piece of the module contract: how a deploy is configured, how
changes are discovered, and how they take effect. Model — **"seed at install,
store after"**: the deploy's store is the single source of truth; environment
variables are install-time seeds only.

- **`module.yaml env:` declaration** (flat map, same parser subset as
  `checks:`/`usage:`): `KEY: "default — description [flags]"`; flags `secret`
  (masked in listings) / `knob` (env-only, not persisted, excluded from the
  view). All 9 modules declare their surfaces (clash exempt: state-managed).
- **`aibox <module> config`** — list (values + masked secrets + defaults +
  apply hint) / `get KEY` (script-friendly plaintext) / `set KEY VALUE`
  (writes the store; interactively offers the apply, non-interactive prints
  the command) / `unset KEY` (back to the declared default).
  `aibox <module> --help` renders the config keys table (offline, local-first
  — same mechanism as the action table).
- **Stores per module type** (no new formats): compose → `.env`;
  service-defined (pi-web) → plist/unit `EnvironmentVariables` with
  regeneration via the single writer (`write_service`) and runtime key-name
  mapping (PI_WEB_BIND → PI_WEB_HOSTNAME); CLI (windmill) → `/etc/<m>/<m>.conf`;
  openmaic keeps its CLI's native config action. Shared helpers in
  `tools/_shared/common.sh` (cfg_kv_get/set/unset, cfg_env_declare,
  cfg_secret_p/mask, cfg_action — a compose module's config action is one call).
- **pi-web restart FIXED to honor its documented "applies config changes"**:
  bootout + bootstrap RE-READS the service definition (the old kickstart -k
  only restarted the process with the already-loaded definition — config
  changes silently did not apply).
- **Validator S17d**: env format ERROR; README ↔ env: bidirectional drift
  WARN (the discoverability gap this closes); declared-key-referenced-in-code
  WARN. Scaffolder emits the env: TODO skeleton.
- 11 new tests: kv helpers (mode/comments/order preserved, idempotent),
  declaration parsing, masking, the generic action, --help rendering,
  validator rules, pi-web plist roundtrip + key mapping, restart re-read.

Module bumps: base 1.3.4, clash —, dify 1.18.4, gitlab 1.3.5, new-api 1.1.3,
openmaic 1.2.3, pi-web 1.3.5, windmill 1.3.3, xiaozhi 1.1.4.

### Changed — module-level `dashboard` merged into `status` (one "show state" verb)

Both actions rendered overlapping information (status = operational facts,
dashboard = facts + structured extras) — a historical evolution artifact, not a
meaningful distinction for users. Now: `aibox <module> status` shows the
operational facts AND the rich view; `dashboard` is an alias producing identical
output (verified by test). All 7 compose/service modules converted; openmaic/
windmill already mapped dashboard → their CLI's status.

### Changed — README rewritten to open-source standards

Badge header (release/license/CI/bash/platforms), nav links, Features section,
Requirements, Quick Start, CLI Grammar (manager verbs vs module verbs,
update ≠ upgrade), and a dedicated **Ports & endpoints** heads-up: aibox-deployed
services use the internal port registry, not upstream defaults (new-api 30300 vs
upstream 3000, GitLab 8929, dify 8088; profiles derive further). Advanced topics
folded into collapsible details. README.zh.md mirrors the structure.

### Fixed — clash mihomo download: verification-gated failover

Live-caught on a Linux host: the rate-probe winner's body completed and passed
`gunzip -t`, but the payload was not a runnable mihomo — the install died at
the post-download `-v` check with "arch mismatch?" and never tried another
source. `_clash_verify_gz` (gzip integrity + payload runs `-v` + version pin)
now gates acceptance INSIDE the source loop: bad complete body → discard + next
source; incomplete gzip → resume seed.

### Fixed — pi-web: three latent bugs in the rich dashboard (all live-caught)

1. `SERVICE_ID: unbound variable` — the variable was never assigned anywhere
   in the module; the real service name is `LABEL`.
2. `MODULE_VERSION` also never set → the header showed a stale hardcoded
   "1.2.1"; now reads the module.yaml next to lib.sh.
3. pipefail killed `render_dashboard` when no service exists (launchctl exit 1
   rides the pipeline into the assignment; errexit kills the function).
   `|| true` neutralizes; verified with a fake exit-1 launchctl.

Also fixed: pi-web `restart` now actually honors its documented "applies config
changes" — bootout + bootstrap RE-READS the service definition (the old
kickstart -k only restarted the process with the already-loaded definition).

### Fixed — validator: BSD/GNU platform divergences (two new pitfall-class discoveries)

- **`\`` (backslash-backtick) in single-quoted grep ERE**: escaped backtick
  on BSD grep (matches), literal backslash+backtick on GNU (matches nothing) —
  the README↔env: drift WARN silently never fired on Linux.
- **GNU sed `\`` anchor trap**:`\`` is the start-of-pattern-space anchor
  (zero-width); a `+` quantifier on it → "Invalid preceding regular expression".

### Fixed — code-review findings

- pi-web Darwin branch: single `launchctl print` call (was two — a race window
  and a wasted fork).
- help config keys table: `%-28s` column width (was `%-22s`, overflowed on the
  27-char `AIBOX_BASE_POSTGRES_PASSWORD`).
- `cfg_env_declare`: one awk pass for key extraction + bash for value splitting
  (was one sed fork per key; the 3-byte em-dash separator is a C-locale awk
  byte/char counting divergence).

Module bumps in this release: base 1.3.4, clash 1.3.4, dify 1.18.4,
gitlab 1.3.5, new-api 1.1.3, openmaic 1.2.3, pi-web 1.3.5, windmill 1.3.3,
xiaozhi 1.1.4.

## [0.10.2] — 2026-09-22

### Fixed — purge --apply on running containers: inline stop question (one run, no partial state)

Live-caught on the deploy host: `aibox purge windmill --apply` with 7 running
containers warned TWICE per container, deleted the dirs anyway (containers
kept running as orphans), left the volumes busy, and told the user to re-run
with `--stop`. Now the same two-gate pattern as uninstall:

- **Inline question** after the delete confirm: "N container(s) are RUNNING —
  stop them as part of this purge?" — yes → stop+rm first, then volumes, then
  dirs (order verified by tests); one run completes everything.
- `--stop` = pre-answered yes; non-interactive / `--yes` without `--stop` =
  safe default (skip containers + ONE consolidated hint, no per-container
  spam) with an actionable closing line.
- The double warning (pre-warn + per-skip) is gone; the closing summary names
  the follow-up command instead.

## [0.10.1] — 2026-09-22

### Fixed — unified destructive-verb interaction (the two-gate uninstall)

Live-caught on the deploy host: `aibox uninstall new-api` executed with ZERO
confirmation (violating the project's own spec while uninstall self / purge
--apply / upgrade all had gates). Every destructive verb now follows the same
two-gate model:

1. **Gate 1 — the uninstall itself**: `[y/N]` default decline; `--yes` skips;
   non-interactive without `--yes` → exit 2, nothing runs.
2. **Gate 2 — data cleanup, asked inline**: the answer feeds AIBOX_PURGE_DATA
   into the SAME hook invocation. `--purge` = explicit intent (skips the
   question); non-interactive without it keeps data (safe default) + hint.

Also removes the dead round-trip the old flow forced: after a plain uninstall,
`uninstall <m> --purge` warns "not installed" — the correct cleanup is
`aibox purge <m>`, and the module hooks' post-uninstall guidance now says
exactly that (was: "to delete everything: aibox uninstall <m> --purge" — a
command that could no longer work at that point).

Final verdict line always states the data outcome (data deleted / RETAINED +
cleanup hint) regardless of profile/cache branches. 5 new interaction tests
(non-interactive decline, --yes retain, --purge, expect-driven both-gate
accept/decline); spec §Interactive confirmation documents the model.

## [0.10.0] — 2026-09-22

### Added — dashboard service-state icons (state= contract)

One icon per module on the dashboard header tells the whole story — installed
(presence) + started + health — with zero extra vertical space:

```text
  ✓ new-api 1.1.1 · ok        ← running & healthy (green)
  ⚠ dify     1.18.1 · starting ← booting (yellow; transient)
  ○ new-api 1.1.1 · stopped    ← installed, not running (dim) + the endpoint
                                  line gains "(stopped — aibox new-api start)"
```

- New machine-readable `state=` field in the `dashboard_info()` contract
  (`ok`/`starting`/`stopped`/`na`) — the module probes itself locally (pg_isready
  / http_up / docker health), so local-first holds. CLI-type modules
  (openmaic/windmill) emit `na` (no marker — their state is a remote deploy's).
- All 9 modules converted: base/clash/pi-web's old "copy-paste probe command"
  health hints became REAL bounded probes (localhost only); dify/gitlab/new-api/
  xiaozhi mirror their existing ok/starting/stopped branches.
- Fallback for stale caches without `state=`: the declared-port listening
  heuristic (named profiles keep the plain ✓ — derived ports would false-mark).
- The `stopped` endpoint annotation from the incident fix is now driven by the
  contract; spec §dashboard_info documents the field table + icon mapping.
- Fixed after CI review: single-space header (the icon printf rendered a double
  space when colors are off — piped/TAP contexts); test mocks pin `state=` so
  the header is deterministic on docker-less CI hosts.
- **Pitfall #10 recorded** (the investigation byproduct): this dev Mac's bash
  3.2.57 (arm64-darwin26) does NOT raise errexit for a failing `[[ ]]` — bats
  mid-test assertions are silently swallowed locally; CI (ubuntu bash 5) is the
  authoritative assertion gate. Workarounds documented in AGENTS.md.

## [0.9.1] — 2026-09-20

### Fixed — CI/test robustness (product code unchanged from 0.9.0)

- **Test portability (GNU vs BSD)**: new-api/xiaozhi `.env` mode checks used the
  BSD-first `stat -f '%Lp'` order — on GNU, `stat -f` is *filesystem* mode (exit 0
  with garbage; the fallback never fired). Flipped to the GNU-first order proven
  in tests/upgrade.bats; plus one stale catalog assertion (header changed in the
  0.8-era TUI redesign, test never updated).
- **macOS CI job hang**: the first `macos-bash32` run finished the suite in 2 min
  (230/230) then sat "in progress" ~50 min — an orphaned test `http.server` held
  the step's output pipes (runner cleanup: "Terminate orphan process: (Python)").
  Now: deterministic `_kill_srv` (TERM→KILL→wait) + teardown port sweep + a
  30-minute job timeout ceiling.
- **Cold-runner startup race**: a fixed `sleep 1` lost against a cold runner's
  first python3 start (>1s to bind → instant connection-refused). Replaced with
  `_wait_http` bounded readiness polling at all 5 test-server sites.
- Net effect: lint CI fully green across all 9 jobs (macOS job 5 min, was hanging).

## [0.9.0] — 2026-09-20

### Highlights

- **Help system framework** — every module carries a `usage:` map; `aibox <module> --help` renders the action table (local-first), `aibox <module> <action> --help` renders the single action; unknown actions point at help (drift-free).
- **Shared-library includes** (`includes: [common]`) — the output helpers + docker.io pool live ONCE in the repo (`tools/_shared/common.sh`); ~800 lines of cross-module copy-paste removed; modules stay self-contained per-directory.
- **GitLab staged upgrade path** — the official required-upgrade-stops rule, automated: multi-hop upgrades walk every stop (frozen ≤17.4 table + the ≥18 x.2/x.5/x.8/x.11 cadence derived), each hop on the latest patch, readiness-gated (db migrations), per-hop backup + rollback to the previous hop. Live-verified 19.1.8 → 19.2.6 → 19.4.0 on real containers.
- **CI now enforces the macOS bash-3.2 promise** — new `macos-bash32` job runs the full suite under /bin/bash 3.2 (measured: `bash -n` accepts most bash-4 constructs; only real execution detects them), plus a function-coverage probe (88% → drove +9 command-surface tests).

### Added — GitLab staged upgrade path (required upgrade stops, official rule automated)

- `aibox upgrade gitlab` is now **multi-hop aware**: cross-version upgrades walk the official
  required-upgrade-stops path (docs.gitlab.com/update/upgrade_paths) one hop at a time —
  every stop between current and target, each hop on the stop's **latest patch**
  (per-minor targeted tags fetch, `?name=` anchored), health-gated between hops, per-hop
  `.env` backup, rollback to the PREVIOUS hop on failure (exit 20).
- Data: module `lib.sh upgrade_stops()` — frozen ≤17.4 history (verified against upstream
  `config/upgrade_path.yml`) + the official ≥18 cadence (`x.2/x.5/x.8/x.11`) derived forward;
  path computation is offline, only patch resolution hits Docker Hub. Conditional stops
  (16.0/16.1/16.2/17.1) included by default (safe choice).
- Hop gate: omnibus `/-/readiness` (incl. db-migrations checks) via a compose
  `monitoring_whitelist` (127.0.0.1 only); falls back to the sign-in probe on older deploys.
  `svc.sh start` uses it, so single-hop upgrades get the stronger gate too.
  Knob: `AIBOX_UPGRADE_HOP_SETTLE=<seconds>` for extra background-migrations wait.
- `--check` prints the full hop table; cross-major auto-latest is now allowed for modules
  with a path provider (the hop sequence is the migration-safe path the guardrail demanded);
  modules without one keep the single-hop behavior + guardrail unchanged.
- Honest limitation documented (README/DEVELOPMENT): rollback ACROSS an omnibus-internal
  PostgreSQL major upgrade may refuse to boot with newer data files — `gitlab-backup create`
  before long paths.

### Quality — closing the three assurance gaps (architecture review follow-up)

- **CI now enforces the macOS bash-3.2 promise** (new `macos-bash32` job in lint.yml): parse check via /bin/bash + the FULL fast suite executed under bash 3.2 + the validator with its native 3.2 parse check. Measured rationale: `bash -n` on 3.2 catches only parse-level breakage — most bash-4 constructs (`declare -A`, `mapfile`, `${var,,}`) parse fine and fail only at RUNTIME, and ubuntu's `bash -n` accepts bash-4 syntax outright. Only real execution under 3.2 detects it. The job also asserts the runner's bash IS 3.2 (fail loudly on image drift).
- **Integration CI covers the read-only E2E suite**: `preflight-check.bats` (docker + network, never mutates) joins `base-profiles` on every dispatch; pi-web/windmill stay manual by design (service-manager side effects / ~6GB pulls).
- **Function-level coverage probe** (`scripts/coverage.sh`): AIBOX_TRACE hook in bin/aibox (bash 4.1+, xtrace → fd 9, zero assertion pollution — verified: 0 trace-only test failures), inventory-vs-executed diff, never-executed `cmd_*` listed first. First measurement: 88% (111/126). Drove: +9 command-surface tests (proxy family show/env/set-decline/toggle/unset, ports guidance, dev-guide, update flow) and removal of dead `cmd_ports` (unreachable since the dashboard merge). CI prints the report on every push.
- **AGENTS.md**: pitfall #2 corrected (parse-time was the exception, not the rule — measurement); new pitfall #9 (`exec 9>>f 2>/dev/null` makes fd-2→/dev/null PERMANENT shell state — silently eats every die/warn; live-caught while building the probe).

### Added — shared-library includes (architecture: single-source infra code)

- **`includes:` stanza** in module.yaml + **`tools/_shared/common.sh`** (single repo source for the output helpers `log/warn/ok/info/die` + the docker.io download pool). `download_module` ships it into each module cache as `_common.sh` (fetched FIRST, before hooks — a failed fetch never leaves the cache half-updated); modules stay self-contained per-directory.
- All 9 modules' lib.sh now source the include (cache layout `_common.sh` → repo layout `../_shared/common.sh` for direct exec/bats) — **~800 lines of copy-paste removed** (5× pool blocks + 7× output helpers + xiaozhi's shadow `_dk_bounded`).
- Validator: `includes` entries must resolve to `tools/_shared/<inc>.sh` (ERROR); `checks.docker_images` consumers without `includes: [common]` WARN. Scaffolder emits the include skeleton.
- Dispatched CLIs (openmaic/windmill `cli/`) keep their own copies by design — they run standalone on deploy hosts (pitfall #4).

### Added — action-level help

- `aibox <module> <action> --help` (also `-h`) renders the single action: args hint + description split from the `usage:` line, module context, and a pointer to the module table. Unknown actions fall back to the full module table — never a dead end.

### Added — optional-shared dependency declaration

- `services_optional:` field (same entry grammar as `services:`, validated but NOT install-gated): dify's deploy-time `DIFY_SHARED_BASE=1` shared-base mode is now machine-declared; spec documents the two consumption modes (hard `services:` vs opt-in `services_optional:`).

### Docs

- `docs/module-system-spec.md` marked SUPERSEDED (banner) — module-spec.md is the only normative contract; cross-references fixed; docs/README.md reorganized (active spec vs design history).

### Added — help system framework

- **`usage:` stanza in every `module.yaml`** — one line per declared action; `aibox <module> --help` (and bare / `help` / `-h`) renders a fixed-column action table from it, local-first (module cache → in-process registry → registry cache file, zero network when installed).
- **Validator**: WARNs when a declared action has no `usage:` entry (gaps render as bare action names).
- **Scaffolder**: generates a `usage:` skeleton per scaffolded action (TODO lines).
- **Spec**: `docs/module-spec.md` §Per-action help documents the stanza schema; onboarding checklist step 2 now includes usage entries, step 5 the module-owned `dashboard` action.
- **Unknown-action fallback unified** across all 7 compose/service modules: `unknown action: <action> — run: aibox <module> --help` (drift-free — replaces hand-maintained action lists that went stale).
- **Registry parser**: hyphenated `usage:` keys (`use-external`) no longer produce invalid shell variable names (parse error under `set -u`).
- Top-level `aibox help` foot now points to per-module help.

## [0.8.1] — 2026-09-19

### Fixed

- **stale-clash egress (the reported dashboard bug's root cause)**: `clash_active`
  trusted the state file (enabled=1) without probing the port — when the kernel
  died or its port changed, the CLI exported a DEAD socks5 proxy and every curl
  in the process failed instantly with connection-refused (breaking not just
  `dashboard` but all egress). The mixed port is now probed; a stale state
  warns ("clash state says enabled but :7890 is not listening — using direct")
  and falls back to direct. Measured: `check self` went from "core domains
  unreachable" to ✓ via direct.

### Changed

- **dashboard: local-first redesign (scales to hundreds of modules)** — the
  default view needs ZERO network (the reported error came from load_registry):
  per-PROFILE sections (active marked), one block per installed module
  (dashboard_info keys + ports from the local registry cache with live listen
  marks), and a residue section for not-installed leftovers — only
  installed/residue modules show. `--available` stays the catalog but degrades
  to installed-only instead of dying offline; `dashboard <module>` is
  local-first for installed modules. Latest upstream versions refresh
  ASYNC (probes launch before the render, each as a separate process —
  gh_pool_fetch misbehaves in nested background subshells — harvested after
  a bounded 10s wait; up-to-date modules are suppressed so offline adds zero
  noise). PURGE_MODULES_KNOWN now includes new-api + xiaozhi.

## [0.8.0] — 2026-09-19

### Added

- **Download source pools** — every download aibox performs now goes through a
  source pool: mainstream accelerated mirrors race the direct route with a REAL
  download, the fastest measured source serves, and a stalled/failed source fails
  over to the next; every reachable source is tried before giving up. On healthy
  networks the direct route wins and nothing changes. Families:
  - **npm** (pi-web): registry ranking + stall-watchdog failover — installs no
    longer hang on a dead `npm view` (measured).
  - **GitHub raw/api** (`gh_pool_fetch` in bin/aibox): concurrent race +
  per-family ranking cache (`ghpool.cache`, TTL 600s) + a raw→contents-API
  rewrite fallback — wired into all 5 manager download points (registry, module
  files, bootstrap, self-update, upgrades).
  - **GitHub releases ~20MB** (clash mihomo): rate-probed on the real asset,
  resumable, per-source failover.
  - **docker.io** (`docker_pool_prepull` in module lib.shs): daemon-routed
  hello-world probe (host egress ≠ daemon egress — never host-probe a
  daemon-consumed registry) → ranked mirror pre-pull + `docker tag`; live-verified
  mirrors: docker.1ms.run / daocloud / dockerproxy / rat.dev (dead ones
  excluded). Consumed by base/dify/gitlab/new-api/xiaozhi + the openmaic CLI.
  - **ghcr.io** (NEW family, xiaozhi): bounded direct attempt → ordered mirror
  failover (ghcr.nju.edu.cn + ghcr.dockerproxy.net) with pull-via-mirror +
  retag — the docker.io mirrors do NOT proxy ghcr.
  - **node dist** (`_node_dist_pick`): nodejs.org / npmmirror / Aliyun — exported
  as NVM_NODEJS_ORG_MIRROR for nvm.
  - **install.sh bootstrap** (`fetch_pool`): the curl|bash flow itself races
  direct + mirrors (measured: boots in 5.8s with no direct route).
  Per-family knobs: AIBOX_GH_POOL/AIBOX_GH_MIRROR, AIBOX_NPM_REGISTRIES,
  AIBOX_DOCKER_POOL/AIBOX_DOCKER_MIRROR, AIBOX_GHCR_* , AIBOX_NODE_POOL.
  Static direct-egress gates removed from pool-covered modules (they
  false-failed exactly the mirror-saved networks).

- **`new-api` module** (v1.0.0) — [QuantumNous/new-api](https://github.com/QuantumNous/new-api)
  v0.13.2: LLM API gateway (OpenAI-compatible relay, key/quota management,
  usage analytics). Single-service compose on the shared base (auto DB
  creation, base.env injection), `/api/status` health contract, docker.io pool.

- **`xiaozhi` module** (v1.0.0) — [xinnan-tech/xiaozhi-esp32-server](https://github.com/xinnan-tech/xiaozhi-esp32-server)
  v0.9.6: backend for xiaozhi-esp32 AI voice devices. 3-service compose
  (ws relay :8000 / console :8002 / bundled mysql:8.0) + shared-base redis;
  STAGED start with server.secret AUTO-APPLY (the Java manager-api generates
  it into MySQL sys_params; the Python server refuses to boot without it);
  ghcr source pool; `aibox xiaozhi secret <value>` manual override.

- **upgrade: images tag-prefix form** — upstreams that prefix their tags
  (xiaozhi ghcr: git v0.9.6 ↔ docker server_0.9.6) can now declare
  `ENV=repo:prefix` with a tag prefix; the engine's v-strip + prefix append
  reproduces the exact tag. validate-module.sh + module-spec.md updated.

### Changed

- **TUI redesign** (formal / clean / consistent, gh-CLI / kubectl style): symbol
  system (plain log, ✓ ok, ⚠ warn, ✗ die — two-space gap, dim 2-space info),
  sectioned `aibox help`, clean dashboard tables (✓ installed / · not),
  labeled detail views, probe-matrix marks unified. Module lib.sh helpers and
  both dispatched CLIs aligned; the scaffolder emits the new set; the output
  contract is documented in module-spec.md.

### Fixed

- xiaozhi: unescaped backticks in the .config.yaml heredoc ran as command
  substitution at render time (die mid-install + eaten comment text) — found
  by deploy-host verification.
- xiaozhi: secret auto-apply raced the Java boot (console HTTP passes before
  sys_params lands) — bounded retry.
- pools: `_dk_is_dockerio` misclassified the explicit `docker.io/library/x`
  form as foreign (silently skipped by the pool) — explicit branch added in
  all 6 copies.
- `gh_pool_fetch` win-notice printf arg-count bug (garbage repeat line on
  every race win); xiaozhi `_write_secret` sed metachar injection; NVM mirror
  export masking a failed pick; TUI stragglers ([?] prompts, purge title).
- review-hardening: 4 pool regression tests added; unquoted-heredoc
  command-substitution scan clean across the repo.

### Verified

- Full lifecycle of both new modules on the deploy host (192.168.50.88):
  bootstrap → install → start (pools) → health → status/dashboard/credentials
  → restart/stop/start → update → upgrade --check → purge → uninstall
  --purge (zero residue). 202 bats tests; validator 0 errors; shellcheck
  error-level clean; bash 3.2 parse clean.

## [0.7.0] — 2026-09-18

### Added

- **`aibox upgrade <module> [--check] [--to <version>] [--yes]`** — upstream component
  upgrades WITHOUT an aibox release. The repo pins the install FLOOR (module.yaml +
  compose `${VAR:-pinned}` + `checks.docker_images`; fresh installs stay reproducible);
  the deploy `.env` image keys hold the LIVE version and float independently:
  `aibox update` refreshes module scripts (floor), `aibox upgrade` bumps the component.
  The engine (`cmd_upgrade`) is data-driven from the module.yaml `upgrade:` stanza (flat,
  parser-compatible like `checks:`): resolve (`github-release` releases/latest |
  `dockerhub-tags` filtered by `tag_pattern`, dotted-version max) → cross-major
  guardrail (auto-latest refuses; `--to` pins) → **pairing, not guessing** (`mapping_url`
  points at the upstream compose AT the target tag — dify's sandbox/plugin-daemon/
  agent-backend pairing always matches what the target release ships) → pre-pull every
  new image BEFORE touching anything (exit 4) → `.env.bak.<ts>` backup + rewrite only
  the declared keys (missing keys appended, mode preserved) → recreate via the module's
  own `svc.sh start` (health-wait) → auto-rollback on failed health (exit 20).
  Resolver hardening (measured live on 192.168.50.88): raw.githubusercontent.com blocked
  while api.github.com is reachable (same family, different blocking) → the fetch falls
  back to the GitHub contents API (pure-bash base64 decode, BSD/GNU portable), then the
  configured `CLASH_MIRROR`/`AIBOX_GH_MIRROR`. Live-verified end-to-end on that host:
  `--to 1.17.0` (correct multi-image pairing extraction incl. unchanged companions;
  backup; recreate; health gate) and back to 1.17.1; the installed marker follows the
  live version. Spec: module-spec §Component upgrades; validator shape-checks the
  stanza; 14 new offline bats tests (unit + mocked-resolver engine paths + gh-api decode).
- **dify module** (new, 1.17.1): Dify self-hosted LLM app builder as a deploy-type
  compose module — 14 core services on a curated single-file compose (named volumes
  with explicit names, image refs `${DIFY_*_IMAGE:-floor}`), `nginx/` + `ssrf_proxy/`
  config templates vendored VERBATIM from dify v1.17.1 (envsubst/ACL entrypoints run
  inside the containers; aibox never sources them), `.env` written once by install.sh
  with the FULL ported upstream key set, default port 8088 (dify's :80 collides with
  windmill), optional shared-base mode (replicas 0 + aiboxbasenet + DB/REDIS remap;
  the base redis is password-less so REDIS_PASSWORD is forced empty), residue-map
  entries, dashboard reports the live version. Onboarded via the standard flow and
  live-smoked on 192.168.50.88 — the smoke caught 6 real defects pre-release, all in
  the unreleased module itself: incomplete `.env` port (DB_HOST/DB_PORT + 125 more
  wiring/tuning keys — api hit localhost:5432 and plugin_daemon crash-looped; the
  connection config lives in upstream `.env.example`, NOT the compose inline blocks),
  bash-sourcing the `.env` (spaced values → `fg: no job control` — now parsed with
  docker env_file semantics), the DIFY_PORT name collision (upstream: api gunicorn
  port 5001 — reusing it for the web port made gunicorn bind 8088 and nginx 502; knob
  renamed DIFY_WEB_PORT), restart-as-recreate (env changes don't apply on plain
  compose restart), an API-inclusive health gate (probing `/` passes while the api
  502s 30-60s behind the frontend; now probes /console/api/setup), and the shared-mode
  live-proof (PG18: 144+13 tables, zero redis AUTH errors, the external aibox-base
  network survives compose down).
- **gitlab module 1.1.0**: declares the `upgrade:` stanza (dockerhub-tags resolver,
  stable-tag regex `<dotted>-ce.0`); `aibox upgrade gitlab` auto-latest within a major,
  cross-major requires `--to` (GitLab's staged upgrade paths). README upgrade section
  rewritten around update-vs-upgrade.

### Changed

- Bumped `AIBOX_VERSION` 0.6.0 → 0.7.0 (two additive features; no CLI breaking changes).
- Module versions: gitlab → 1.1.0; dify new at 1.17.1.

## [0.6.0] — 2026-09-18

### Added

- **Preflight check system (mandatory for every module)**: `checks:` contract in `module.yaml`
  (`disk_gb` / `domains` / `docker_pull` / `docker_images` / `commands`) enforced as a hard gate
  before install/update hooks; recursive `services:` readiness into base; strict deps (missing
  after an auto-install attempt aborts). `aibox check <module>|self` runs it proactively;
  `--skip-checks` / `AIBOX_SKIP_CHECKS=1` bypass; `AIBOX_CHECK_TIMEOUT` tunes probe timeouts.
- **Network route fallback**: domain probes failing on the current egress try the CONFIGURED
  alternatives in order — direct → clash pool → **gh mirror** (`CLASH_MIRROR`/`AIBOX_GH_MIRROR`;
  solves the clash bootstrap paradox: github.com unreachable while the mirror works, and clash
  itself downloads FROM GitHub) → static proxy — adopting the first working route for that run
  (persist hint printed). One immediate retry before fallback absorbs mihomo node-settling
  blips (measured live).
- **Root-aware dependency auto-install**: as root, `install_dep` actually installs (docker family:
  docker-ce → moby-engine → docker.io package fallbacks; creates the missing `docker` group —
  AL4's moby-engine ships without it, causing a docker.socket 216/GROUP failure cascade; starts +
  enables the daemon); 3 backoff retries (5s/20s) ride out flaky distro mirrors (measured:
  Aliyun internal mirror "Empty reply" windows lasting minutes); `npm` joins the node branch.
- **Residue purge**: `aibox purge [<module>...|self] [--apply] [--stop] [--yes]` — embedded
  residue map (volumes, containers, apps/, /etc dirs, systemd/launchd units, dispatched binaries,
  npm globals, live processes, rc PATH blocks); dry-run report by default; RUNNING
  containers/processes refused without `--stop`; single-file rescue (curl `bin/aibox` → /tmp)
  cleans residue even after aibox itself is gone.
- **`--purge` data deletion**: `AIBOX_PURGE_DATA=1` contract implemented by all six module
  uninstall hooks (module-owned volume/state//etc knowledge; the manager never guesses);
  `aibox uninstall <m> --purge` and the cascade `aibox uninstall self --purge`.
- **gitlab module** (new, 1.0.0): GitLab CE omnibus docker — pinned image (19.2.6-ce.0,
  `GITLAB_IMAGE`-overridable), ports 8929/8922 (avoid windmill :80 + sshd :22 on shared hosts),
  named volumes, monitoring stack off (fits 4GB RAM), boot wait loop, `credentials` action (24h
  initial root password + reset recipe), staged upgrade-path warnings. Onboarded with — and the
  reference implementation of — the tooling below.
- **Module onboarding tooling**: `scripts/new-module.sh` (spec-compliant scaffold, passes the
  validator out of the box) + `scripts/validate-module.sh` (~25 rules: required fields, §2.2 YAML
  subset, port format + cross-module conflicts, services↔provides cross-refs, mandatory
  `checks:`, lifecycle completeness, docs presence, hook-script quality incl. precise portable
  gotcha #1/#8 detectors, credential scan, residue-map WARN). CI module-lint runs the same
  script (single rule source; the deps-lint job was retired into it). Spec: module-spec
  §Onboarding a new module.
- **windmill ghcr route resilience** (1.2.0): upfront throughput probe (direct vs public ghcr
  mirrors; adopt + persist `WM_GHCR_MIRROR` to `.env`) + failure-driven escalation when direct
  pulls stall out (an 8s burst probe can misjudge a stall-prone route — measured) +
  stall-guarded per-image pulls replace the bare `compose pull`.
- **clash download resilience** (1.1.0): resumable mihomo download (`curl -C -`, 8×120s windows,
  versioned partials — a throttled release CDN measured at ~21KB/s cannot finish in one window),
  `CLASH_DOWNLOAD_TIMEOUT/ATTEMPTS` knobs.

### Changed (BREAKING — CLI grammar v2.1)

- **One grammar: everything is a module** — `self` is the manager module:
  - `self` sub-family REMOVED → `aibox uninstall self [--purge] [--yes]`, `aibox update self`,
    `aibox check self` (environment check), `aibox version`. Old forms die with migration
    guidance. `self` is a reserved module name (validator + scaffolder enforce).
  - `list` / `list-available` / `ports` MERGED into **`aibox dashboard`**: overview
    (MODULE/VERSION/ENDPOINT/CREDENTIALS + the port table with live listening status),
    `--available` catalog, `<module>` detail + health.
  - `proxy test` MERGED into **`aibox proxy check [url]`** (no url = dev-site matrix; url =
    single target + direct-connection control; any non-000 = reachable, `proxy_used=0` warns
    "answered via DIRECT", curl <8.4 reports "can't confirm" instead of guessing).
  - `aibox check` now requires `<module>|self`.
- `uninstall self` semantics: default = manager-only (module services/data KEPT, `apps/`
  preserved so survivors stay manageable, marked rc block always surgically removed);
  `--purge` = cascade full teardown (every (module, profile) hook with `AIBOX_PURGE_DATA=1`,
  then apps/, then the manager). Non-interactive requires `--yes` — no silent defaults.
- Module **gitlab-ce renamed to `gitlab`** (pre-release); windmill's declared port aligned to
  the CLI default **80** (was 8080 — the ports table and conflict detection were watching the
  wrong port).
- `update self` passes `AIBOX_RAW` through to install.sh — SHA-pinned/mirrored updates now fetch
  the pinned payload instead of silently falling back to the lagging branch CDN (measured live);
  the registry cache is invalidated on self-update (stale declared ports for up to 1h before).
- Module versions: base/clash/openmaic/pi-web → 1.1.0, windmill → 1.2.0, gitlab 1.0.0 (new).

### Fixed (all caught by live cold-start tests on fresh Aliyun AL4 + Debian hosts)

- pi-web: binary path derived from `npm prefix -g` instead of assuming node's dir (AL4: node in
  `/usr/bin` but npm prefix `/usr/local` — `npm i -g` succeeded yet the hook died on
  "Not found: /usr/bin/pi-web"); port-listening checks fall back to `ss` when `lsof` is absent
  (same class in `check_ports` + the dashboard port status — they silently showed "not
  listening" while the service answered HTTP 200).
- Preflight probe: one retry on the current route before declaring failure (a single transient
  api.github.com blip right after `clash on` used to flip the whole run onto direct).
- clash `test` output: `%{proxy_used}` empty on curl <8.4 → field omitted instead of printing
  a bare `proxy_used=`.
- base: uninstall volume hint is profile-aware (was hardcoded base-profile names); `create`
  waits for `pg_isready` (≤30s) before CREATE DATABASE.
- Docs aligned with v2.1: SECURITY (destructive-ops semantics, `update self` forms),
  module-system-spec (port table inside dashboard §3.5, dashboard commands/output/health
  §4.2-4.6, credential table + base/gitlab rows), README×2 / AGENTS / module-spec /
  CONTRIBUTING command surfaces, base README mainland-China network recipes (daemon mirror +
  proxy drop-in + AL4 docker group), windmill README (`uninstall self` keeps data by default).

## [0.5.0] — 2026-09-17

### Added

- **`CLASH_MIRROR` env** for the clash module — opt-in GitHub mirror prefix for
  `download_mihomo`, for networks where github release downloads are reset/blocked.
- **Global TTY/NO_COLOR color scheme** — `bin/aibox` exports the `C_*` color vars so
  module hooks (child processes) inherit the scheme (single source of truth); module
  `lib.sh` no longer carry a per-module color block.
- **bats tests for `save_config`/`load_config`** (`tests/config.bats`) — guard the
  backtick-corruption regression + round-trip + no-leak + mode 600.

### Changed

- **TUI polish** — dashboard reworked (compact ✔/✘ status, truncated endpoint/credential
  cells so rows don't wrap, legend footer); `list-available`/`list` use a ✔ marker;
  `ports` columns tightened; `info()` indent fixed (8, aligns under `[aibox]`).
- **DRY module output** — removed the 5× duplicated TTY/NO_COLOR color block across
  module `lib.sh`; modules inherit `C_*` + use `${AIBOX_MODULE:-<name>}` as prefix.

### Fixed

- **CRITICAL: `save_config` corrupted `~/.aibox/config`.** The unquoted heredoc comment
  `# ... maintained by`aibox proxy`...` had backticks that EXECUTED `aibox proxy` on
  every `proxy set/unset/toggle`, embedding the show-output into the config file
  (unparseable). Backticks → single quotes.
- **Network `curl` calls lacked `--max-time`** — a packet-dropping/hanging proxy made
  `list-available`/`list`/`ports`/`dashboard` hang indefinitely. Added `--max-time`.
- **`proxy check`/`proxy test` didn't fall back to the clash pool** — died "No proxy
  configured" when clash was providing a working proxy. Added a `clash_active()` fallback.
- **pi-web on Linux** (4 bugs, same class: `$PLIST` unbound under `set -u`, PLIST only
  assigned on Darwin) — `resolve_password` crash + a password-reuse regression,
  `install.sh` crash (`Plist: $PLIST` + macOS-only `ipconfig`), `uninstall.sh` crash.
  All OS-branched; `resolve_password` now reuses the installed password from the
  systemd unit on Linux.
- **windmill `dashboard_info` hardcoded port 8080** but the deploy uses `HTTP_PORT=80` →
  wrong endpoint + health false-negative. Now reads `HTTP_PORT` from the deploy `.env`.
- **openmaic `doctor` disk check reported 0K** pre-deploy (`df -k $BASE_DIR` failed when
  BASE_DIR didn't exist). Falls back to `/`.

## [0.4.0] — 2026-09-16

### Added

- **English as the primary language.** All user-facing strings in `bin/aibox`, `install.sh`,
  and module hooks/libs are now English; Chinese is retained as an auxiliary README
  (`README.zh.md`) and in gotcha-context comments. (`README.md`, `AGENTS.md`)
- **Registry TTL cache** — remote registry results are cached to
  `~/.aibox/registry.cache` (1h TTL) to avoid hitting the unauthenticated GitHub API
  (60 req/hour/IP) on every command. Local `file://` sources are always fresh.
- **Checksum verification for the bootstrap** — `install.sh` / `aibox self update` now
  support `AIBOX_SHA256=<hex>` (pin) and `AIBOX_VERIFY=1` (check the release `SHA256SUMS`
  sidecar, graceful if absent). The release workflow attaches a `SHA256SUMS` asset.
- **Governance docs** — `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `CODEOWNERS`,
  issue/PR templates.
- **`aibox ports` and `aibox dashboard`** commands documented in usage.
- **`module.yaml` is the source of truth** for the registry (registry.sh removed);
  `load_registry` auto-discovers `tools/*/module.yaml`. `docs/module-spec.md` updated
  to reflect this, with registry.sh demoted to a history note.
- **`svc.sh` semantics documented** — an "action entry point", not necessarily a daemon
  (see `docs/module-spec.md` and the comment in `bin/aibox`).

### Changed

- Bumped `AIBOX_VERSION` 0.3.1 → 0.4.0.

### Internal

- Test scaffolding added under `tests/` (bats) for `proxy_probe`, `mark_installed`,
  `download_module`, `normalize_proxy_url`, and the registry cache path.

## [0.3.1] — 2026-09-15

- `fix:` lint §2.2 false positive (quoted strings with `<...>`/`${...}` are not YAML flow/block scalars).
- Bumped `AIBOX_VERSION` to 0.3.1.

## [0.3.0] — 2026-09-15

- `feat:` module.yaml refactor + shared component `base.env` propagation mechanism.
- `docs:` simplified shared-component propagation — `base.env` + `compose --env-file`, no codegen.

## [0.2.x] — 2026-09-14

- `feat:` `base` module (shared PostgreSQL 18 + Redis 7).
- `feat:` `clash` module (mihomo kernel orchestration, auto speed-test/switch/failover).
- `feat:` proxy subsystem with site connectivity check + direct-connection control.

## [0.1.0] — 2026-09-13

- Initial release: bootstrap + `pi-web` module (migrated from pi-web-ctl).
- Module manager core: `install` / `uninstall` / `update` / `list` / `self update`.
- CI quality gate: `bash -n`, `shellcheck`, bash 3.2 gotcha scans (#1, #8).

Compare links (Keep a Changelog convention — the `[x.y.z]` headers above resolve here):

[0.17.0]: https://github.com/lichengwu/aibox/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/lichengwu/aibox/compare/v0.15.1...v0.16.0
[0.15.1]: https://github.com/lichengwu/aibox/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/lichengwu/aibox/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/lichengwu/aibox/compare/v0.13.5...v0.14.0
[0.13.5]: https://github.com/lichengwu/aibox/compare/v0.13.4...v0.13.5
[0.13.4]: https://github.com/lichengwu/aibox/compare/v0.13.3...v0.13.4
[0.13.3]: https://github.com/lichengwu/aibox/compare/v0.13.2...v0.13.3
[0.13.2]: https://github.com/lichengwu/aibox/compare/v0.13.1...v0.13.2
[0.13.1]: https://github.com/lichengwu/aibox/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/lichengwu/aibox/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/lichengwu/aibox/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/lichengwu/aibox/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/lichengwu/aibox/compare/v0.10.2...v0.11.0
[0.10.2]: https://github.com/lichengwu/aibox/compare/v0.10.1...v0.10.2
[0.10.1]: https://github.com/lichengwu/aibox/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/lichengwu/aibox/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/lichengwu/aibox/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/lichengwu/aibox/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/lichengwu/aibox/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/lichengwu/aibox/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/lichengwu/aibox/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/lichengwu/aibox/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/lichengwu/aibox/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/lichengwu/aibox/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/lichengwu/aibox/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/lichengwu/aibox/compare/v0.1.0...v0.3.0
[0.1.0]: https://github.com/lichengwu/aibox/releases/tag/v0.1.0

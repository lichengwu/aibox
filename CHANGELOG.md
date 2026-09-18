# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the main CLI (`AIBOX_VERSION`
in `bin/aibox`). Each module versions independently (`version:` in its `module.yaml`).

GitHub release notes are auto-generated from the previous tag; this file is the curated summary.

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

# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the main CLI (`AIBOX_VERSION`
in `bin/aibox`). Each module versions independently (`version:` in its `module.yaml`).

GitHub release notes are auto-generated from the previous tag; this file is the curated summary.

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

# Historical cases — every logged bug and where it is locked

The pitfall log (`AGENTS.md`), the CHANGELOG `### Fixed` entries and the
live-caught bugs found while building are all *history*: this file maps each one to
the test that fails if it comes back. A bug with no row here is a bug that can
silently return — `tests/docs-integrity.bats` guards this file's coverage of the
pitfall log.

Run everything: `tests/docker/run.sh` (or `bats tests/*.bats` locally).

## AGENTS.md pitfall log (#1–#11)

| # | The bug | Locked by |
| --- | --- | --- |
| 1 | bare `$VAR` before full-width punctuation → unbound under bash 3.2 (UTF-8 locale) | `scripts/validate-module.sh` gotcha-#1 scanner + CI `bash32-gotchas` job; the validator's hook-quality pass |
| 2 | bash-4-only syntax reaching a 3.2 host (`exec {fd}>…` is parse-time) | validator parse-compat check (when a 3.2 bash is present) + the macOS CI job runs the whole suite under `/bin/bash 3.2` |
| 3 | proxy "success" judged by HTTP status instead of `%{proxy_used}` | `tests/history-cases.bats` (3 verdict cases: `used=1`, `used=0`, empty) |
| 4 | env vars cannot cross process/host boundaries → persist to the module's own conf | `tests/history-cases.bats` (`sync_proxy_to_conf` writes where the CLI reads, `OPENMAIC_CONF_DIR`) |
| 5 | three curl traps (empty `-w` on failure, `no_proxy` excluding an explicit `-x`, `used=0` ≠ "no data") | `tests/history-cases.bats` (empty `-w` → `000`; trailing-space `%{proxy_used}` → "can't confirm") + `tests/proxy.bats` / `proxy-fallback.bats` |
| 6 | multibyte characters sliced by substring expansion under the C locale | `tests/history-cases.bats` (whole-frame `SPIN` array, byte-width proof, no `${…:i:1}`) + the same rule restated in the validator's hook pass |
| 7 | `script` is unreliable for pty/prompt tests — use `expect` | `tests/cli-surface.bats` / `tests/self-uninstall.bats` use `expect` (`spawn`); the docker image ships it |
| 8 | `local a="x" b="${a}/y"` same-line self-reference → unbound on bash 3.2 | `tests/module-tools.bats` (detector + split-lines negative case) + validator gotcha-#8 scanner |
| 9 | `exec 9>>f 2>/dev/null` permanently swallows stderr | stderr assertions across the suite (`tests/install-sh.bats`, `tests/module-install.bats`, …) — the docker harness would show them as empty-output failures |
| 10 | macOS bash 3.2: a failing `[[ ]]` does not trip `set -e` (mid-test assertions silently pass) | CI `macos-bash32` job runs the full suite under 3.2; `tests/history-cases.bats` asserts the job + the documented rule exist |
| 11 | `*"X"` is a SUFFIX glob, not containment (misdiagnosed as a 3.2 multibyte bug) | `tests/dash-template.bats` ("bash glob semantics pin") |

## CHANGELOG `### Fixed` classes (by release)

| Release | Class of fix | Locked by |
| --- | --- | --- |
| 0.4–0.9 | registry auto-discovery, profile derivation contract, base.env KEY=VALUE only | `tests/registry.bats`, `tests/profile.bats`, `tests/base-env.bats` |
| 0.10 | `save_config` heredoc executing backticks into the config file | `tests/config.bats` |
| 0.11–0.12 | dashboard keyline template + app/module version rows | `tests/dash-template.bats` |
| 0.12.1 | gitlab deterministic root password (seed + verify + reset recipe) | `tests/gitlab-credentials.bats` |
| 0.13.0 | docker source selector (TAGS/PULL/GHCR families, ranking cache, sticky winner) | `tests/docker-tags-pool.bats`, `tests/gh-pool.bats`, `tests/dify-docker-pool.bats`, `tests/node-pool.bats`, `tests/clash-pool.bats` |
| 0.13.2–0.13.4 | update semantics: version transition report, no-op gate, hook-always-runs | `tests/command-surface.bats` |
| 0.13.5 | PATH-aware bin dir (explicit → in-PATH ~/.local/bin → in-PATH system dir → fallback) | `tests/install-sh.bats`, `tests/ux-hardening.bats` (parity with the manager) |
| 0.14.0 | declared service deps auto-install (recursive, cycle-guarded, failure aborts) | `tests/module-install.bats` |
| 0.15.0 | the 18-item UX pass (suggestions, hard/soft preflight hints, bounded PM install, dedupe, node distro skip, NO_AUTO_DEPS coverage, service-dep warning + strict mode, reinstall note, bootstrap copy, require_docker/curl, bin-dir parity, catalog footnote, check-self coverage, profile derivation output) | `tests/ux-hardening.bats`, `tests/module-install.bats` |
| 0.15.1 | dependency readiness at ACTION time (start/restart ensure services; base create auto-start; quiet idempotent base start) | `tests/deps-at-action.bats` |
| 0.16.0 | windmill knobs: BASE_URL/HTTPS, worker sizing, log rotation, KEEP, port default 8080, `.env` renderer executing backticks | `tests/windmill-config.bats` |
| 0.17.0 | upgrade/rollback framework: verified rollback + exit 10/20, rollback point/history, data snapshot, marker semantics; docs/config drift (profile-derived ports, openmaic fake 5432) | `tests/upgrade-rollback.bats`, `tests/gitlab-upgrade-path.bats`, `tests/docs-config-drift.bats` |
| 0.18.0 | instruction system: per-verb `--help`, usage-error exit 2, preflight exit 3/4, `doctor` everywhere, lifecycle aliases, `usage_die`; docs integrity (links/index/inventory/parity) | `tests/cli-consistency.bats`, `tests/docs-integrity.bats`, `tests/history-cases.bats` |

## The 2026-09 shared-base dependency review

| Finding | Locked by |
| --- | --- |
| Consumers hardcoded `base.env` → a named-profile module attached to the DEFAULT profile's instance | `tests/base-contract.bats` (profile linking, incl. the validator's hardcode rule) |
| No `base.env` contract (no version/profile/readiness) → a base rename would be read as empty values | `tests/base-contract.bats` (contract + `base_env_check`) |
| `base start` returned before PG/Redis were ready (consumer DB creation raced init) | `tests/base-contract.bats` (readiness wait) + `tests/integration/base-profiles.bats` |
| Shared Redis had no auth and three modules shared index 0 | `tests/base-contract.bats` (allocation) + `tests/integration/base-profiles.bats` (real `PING`/`NOAUTH`) |
| base had no dump/restore and no upgrade/rollback path (image pins were compose literals) | `tests/base-contract.bats` (dump/restore/upgrade, pin rollback, exit 10/20) |
| `base stop` / `uninstall base` / `purge base` never mentioned their dependents | `tests/base-contract.bats` (reverse-dependency gate) |
| Deploy roots were not profile-scoped → two profiles shared one deploy `.env` | `tests/base-contract.bats` (deploy root) + the validator rule |
| Spurious `base:redis` on windmill; dify's optional mode needed manual DB creation | `tests/base-contract.bats` (declarations + self-heal ensure) |
| Two fast-suite tests relied on the ambient registry cache (passed as root, failed as non-root) | `tests/cli-surface.bats` / `tests/docs-integrity.bats` (hermetic `file://` registry) |

## Live-caught bugs (found by building/running, not by review)

| Bug | Symptom | Locked by |
| --- | --- | --- |
| PATH hint on the deploy host | `/root/.local/bin is not in your PATH` right after the one-liner | `tests/install-sh.bats` (in-PATH system dir preferred) |
| service dep not started | `install new-api` exited 0 with every action failing | `tests/module-install.bats` (loud warning + `AIBOX_STRICT_SERVICES`) |
| unbounded package install | `install pi-web` sat 10+ min inside a node auto-install, silent | `tests/ux-hardening.bats` (`AIBOX_PM_TIMEOUT` + heartbeat) |
| duplicate package installs | the same `apt install docker.io …` twice per preflight | `tests/ux-hardening.bats` (dedupe by package set) |
| node 18 vs `node:22` | distro nodejs installed → recheck failed → dead end | `tests/ux-hardening.bats` (skip + nvm guidance) |
| raw shell error from a deep lib line | `tools/base/lib.sh: line 138: docker: command not found` (exit 127) | `tests/ux-hardening.bats` (`require_docker`), `tests/base-*.bats` |
| profile values hardcoded in docs | docs presented the default profile's ports as universal | `tests/docs-config-drift.bats` |
| a declared port nothing publishes | openmaic `5432/tcp:postgres` (upstream publishes only 3000) | `tests/docs-config-drift.bats` (declaration ↔ compose reference) |
| upgrade "rolled back" without verifying | claimed a healthy rollback, always exited 20 | `tests/upgrade-rollback.bats` (10 vs 20) |
| backup-name collision | two runs in the same second shared a path; a rollback clobbered its own point | `tests/upgrade-rollback.bats` (pid-suffixed backups) |
| `--history`/`--rollback` needed the registry | offline host: `Unknown module` for a local-only operation | `tests/upgrade-rollback.bats` (dead-registry case) |
| `.env` renderer ran backticks in its comments | `tls internal` / `windmill systemd install` executed while writing the file | `tests/windmill-config.bats` |
| module marker overwritten with the app version | the next `aibox update` reported a bogus transition | `tests/upgrade-rollback.bats` (marker stays the module version) |
| `clash use-external` crashed | `desc: command not found` (a missing `=""` made bash run `desc`) | `tests/cli-consistency.bats` |
| help was purge-only | `install --help` fetched the registry for a module named `--help` | `tests/cli-consistency.bats` (per-verb help) |
| hint pointed at a non-existent action | `see aibox base doctor` with no `doctor` action | `tests/cli-consistency.bats` |
| two broken doc links + a missing test inventory | links 404'd; new suites shipped unlisted | `tests/docs-integrity.bats` |

## Adding a case

1. Reproduce the bug in a test FIRST (this repo's suite is the bug's memory).
2. Put it in the suite that matches its scope (fast vs integration).
3. Add a row here — the row is what turns "we fixed it once" into "it cannot come back".
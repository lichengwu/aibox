# aibox tests

Two suites, both [bats](https://github.com/bats-core/bats-core):

```
tests/*.bats              fast unit/regression suite — no docker, no network, ~seconds
tests/integration/*.bats  docker-host E2E suites — distilled from live-machine testing
```

## Running

```bash
npm install -g bats                       # or: brew install bats-core

bats tests/*.bats                         # fast suite (CI runs this on every push)

bats tests/integration/base-profiles.bats # base multi-profile E2E (needs docker; safe on
                                          # hosts with real deploys — see Safety below)

AIBOX_IT_PIWEB=1   bats tests/integration/pi-web-profiles.bats    # real launchd/systemd
AIBOX_IT_WINDMILL=1 bats tests/integration/windmill-consumer.bats # pulls ~6GB images
```

CI: `.github/workflows/lint.yml` job `tests` runs the fast suite on every push/PR.
`.github/workflows/integration.yml` (manual `workflow_dispatch`) runs the base E2E on
ubuntu-latest. The flag-gated suites are for throwaway hosts (they touch the real
service manager / pull gigabytes).

## Safety (integration suites)

- **Unique test profiles** (`itta`/`ittb`, `itp1`/`itp2`, `itwm`) — never `base`/`prod` —
  so docker object names, networks, volumes and ports never collide with real deployments.
- **Volume snapshot teardown**: teardown removes only volumes that did not exist before
  the run (snapshot diff), and only with the test-profile suffixes.
- Derived ports are checked for availability first; occupied → the suite skips.

## Case ↔ bug mapping (why each test exists)

Every regression test below was born from a real bug found in review or live testing:

| Test file / case | Bug it locks |
| --- | --- |
| `config.bats` — save_config parseable / no leaked output | `save_config` heredoc backticks executed `aibox proxy` into the config file (P0) |
| `base-env.bats` — write_base_env only KEY=VALUE | same class regressed in `write_base_env` (`$(aibox base start)` recursion → empty `base-<profile>.env`, found live) |
| `base-env.bats` — prod path/host + hash 1073 | profile derivation is a cross-machine contract (same name → same ports everywhere) |
| `profile.bats` — pinned ports/labels for "prod" | changing the hash algorithm or ranges silently breaks every deployed profile |
| `profile.bats` — range invariants (12 names) | derived ports must exclude well-known ports (<35000) and the defaults (35432/36379/30141) |
| `profile.bats` — cross-module single config | base and pi-web must share ONE `profiles/<name>.conf` |
| `installed.bats` — profile-scoped markers | live bug: prod uninstall orphaned the default instance (global marker + shared cache deleted) |
| `module-install.bats` — nested `cli/` fetch | `download_module` needs `mkdir -p` for nested `files:` entries (cli/openmaic restructure) |
| `module-install.bats` — profile-scoped uninstall keeps cache | same live bug, at the module level |
| `install-sh.bats` — temp+mv, checksum pin | live bug: self-update overwrote the RUNNING binary in place → garbage execution ("ugh: command not found"); wrong pin must leave the old binary untouched |
| `proxy-fallback.bats` — clash fallback + precedence | live bug: `proxy check/test` died "No proxy configured" while clash provided a working proxy |
| `base-svc.bats` — create dispatch/alias/usage | `createdb`→`create <component>` refactor must keep the deprecated alias + clear errors |
| `ux-hardening.bats` — suggestions/preflight hints/bounded PM/profile output | the 0.15.0 UX pass: typos must suggest, hard deps must not advertise `--skip-checks`, package auto-install must be bounded (`AIBOX_PM_TIMEOUT`) + deduped, bin-dir precedence must match the bootstrap |
| `deps-at-action.bats` — start/restart ensure declared services | live bug: `aibox xiaozhi start` died with "shared base not running — first: aibox base start" (two commands for one intent); the redis-only entry form was skipped entirely, and `base create` died with "PG not running?" instead of starting the stack |
| `upgrade-rollback.bats` — 18 tests: recorded rollback point, verified rollback, exit 10/20, data snapshot | live review: the engine claimed "rolled back" without verifying, always returned 20 (spec says 10/20), had no rollback POINT (only an automatic one), and overwrote the module marker with the app version |
| `docs-config-drift.bats` — 10 tests: env keys ↔ code, derived values ↔ dashboard pointer, declared ports ↔ published ports, exit-code contract | live audit: docs hardcoded profile-derived ports (base/pi-web), openmaic declared a port nothing publishes (5432 vs upstream 3000), and the docs index needed the superseded banner kept |
| `windmill-config.bats` — 29 render/knob tests | live audit: the windmill stack's domain/HTTPS, worker sizing, log rotation and backup retention were unreachable through `config set` (hand edits to the generated compose/.env are lost at the next render); the default entry port said 8080 in three docs and was 80 in code; the `.env` renderer executed backticks in its own comments |
| `registry.bats` — cache hit/stale, YAML escaping | GitHub-API rate-limit cache + no command injection through module.yaml values |
| `integration/base-profiles.bats` | live scenario: two stacks coexisting, DB/network isolation, per-profile env files |
| `integration/pi-web-profiles.bats` | live scenario: 37173+`pi-web-prod.service`, password reuse (no rotation), per-profile uninstall |
| `integration/windmill-consumer.bats` | live scenario: prod init → prod PG/network/UI; **bug #5 regression** (health gate required the replicas:0 db service) |

## Adding tests

- Fast suite: no docker, no network, no writes outside `mktemp -d` sandboxes (including
  `HOME` when testing `install.sh`). Sub-second per test.
- Anything touching the service manager, docker, or large downloads → `integration/`,
  guarded (skip) by default, unique test profile names, snapshot-diff teardown.

## Coverage probe (function-level, zero-dependency)

Bash has no coverage tooling; `scripts/coverage.sh` is the substitute. `bin/aibox`
honors `AIBOX_TRACE=<file>` (bash 4.1+ only — silently inert on the macOS 3.2
runtime): xtrace is redirected to fd 9 (`BASH_XTRACEFD`) so stdout/stderr
assertions are untouched, and every executed line is marked `+|<function>|<lineno>|`.

```bash
scripts/coverage.sh --bats        # run the fast suite under tracing + report
scripts/coverage.sh --trace FILE  # parse an existing trace
scripts/coverage.sh --list        # function inventory
```

The report diffs "functions with ≥1 executed line" against the inventory and
prints the never-executed list (user-facing `cmd_*` first). Informational, not a
gate — it tells you WHERE coverage is missing; the lint CI prints it on every
push (ubuntu job), and the dev Mac (bash 3.2) can parse traces produced elsewhere.

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
| `registry.bats` — cache hit/stale, YAML escaping | GitHub-API rate-limit cache + no command injection through module.yaml values |
| `integration/base-profiles.bats` | live scenario: two stacks coexisting, DB/network isolation, per-profile env files |
| `integration/pi-web-profiles.bats` | live scenario: 37173+`pi-web-prod.service`, password reuse (no rotation), per-profile uninstall |
| `integration/windmill-consumer.bats` | live scenario: prod init → prod PG/network/UI; **bug #5 regression** (health gate required the replicas:0 db service) |

## Adding tests

- Fast suite: no docker, no network, no writes outside `mktemp -d` sandboxes (including
  `HOME` when testing `install.sh`). Sub-second per test.
- Anything touching the service manager, docker, or large downloads → `integration/`,
  guarded (skip) by default, unique test profile names, snapshot-diff teardown.

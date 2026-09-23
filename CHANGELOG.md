# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the main CLI (`AIBOX_VERSION`
in `bin/aibox`). Each module versions independently (`version:` in its `module.yaml`).

GitHub release notes are auto-generated from the previous tag; this file is the curated summary.

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

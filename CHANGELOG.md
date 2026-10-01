# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the main CLI (`AIBOX_VERSION`
in `bin/aibox`). Each module versions independently (`version:` in its `module.yaml`).

GitHub release notes are auto-generated from the previous tag; this file is the curated summary.

## [0.31.0] — 2026-10-01

### Added

- **First-run preparation: `aibox <module> start` now performs the module's declared deploy
  step.** `aibox install <module>` was never meant to be heavy — it caches the module, places
  the CLI/compose/.env and ensures the shared base (fast, repeatable) — while *deploying the
  app* belongs to the verb whose contract is "make it run": `start`. Eight of nine modules
  deliver the app as a published image / npm package / binary, so `install` → `start` just
  worked; **openmaic is the only source-build module** (clone + local `docker build` with a
  Chromium layer, up to ~1h, ~20G), which is why it needed a separate deploy and why
  "install then start" died with a raw `cd: …/app: No such file or directory` (live-reported
  on 50.55). Now:
  - `module.yaml` declares the contract: `first_run: install` + `first_run_note: "clone +
    build …"`;
  - the shared helper `module_ensure_deployed` (one implementation, used by the module's
    `start`) checks the artifact, prints `first run: … — running: …` with the note, runs the
    prepare command and re-checks the artifact (exit `30` = not ready);
  - `--no-prepare` / `AIBOX_NO_PREPARE=1` refuses the heavy step and prints the command
    instead; `status_info` reports `state=stopped` + a `health=` line naming the deploy
    command when the app is not deployed yet;
  - `aibox install <module>` prints `Next: aibox <module> start` (plus the first-run note),
    so the sequence is stated rather than implied;
  - validator **S17** requires `first_run` to be one of the declared `actions:`.
  The net effect: for every module, `aibox install X` → `aibox X start` works — the heavy
  step is performed on demand, announced first, and refusable.

### Module versions

base 1.10.3 · clash 1.9.2 · dify 1.24.3 · gitlab 1.12.2 · new-api 1.6.2 · openmaic 1.7.3 ·
pi-web 1.9.3 · windmill 1.9.3 · xiaozhi 1.7.3  (the shared include changed)

## [0.30.1] — 2026-10-01

### Fixed

- **`aibox openmaic start` on a host where the app was never deployed died with a bare
  `cd: …/apps/openmaic/app: No such file or directory`.** The two installs are one word order
  apart and completely different: `aibox install openmaic` installs the *module* (ops CLI +
  shared base), while `aibox openmaic install` deploys the *app* (clone + build + start). The
  README warned about the collision; the error and `--help` did not — so "install then start"
  hit a raw `cd` failure with no clue. Now every compose-backed verb checks the precondition
  and answers with the missing step (`deploy it: aibox openmaic install …`, exit `30` = not
  ready), the module-install hook prints the next step, and the `up`/`start`/`install` help
  lines state it. The guard deliberately does NOT auto-deploy: that step is a clone plus a
  docker build (heavy, ~20G), unlike windmill's cheap re-render self-heal.

### Module versions

openmaic 1.7.2

## [0.30.0] — 2026-10-01

### Changed

- **A tight disk no longer blocks install/update — it warns.** `checks.disk_gb` was enforced as
  a hard preflight failure, so a host with 4G free could not install a module whose requirement
  was a *safety margin* (5G) while the actual images needed ~0.5G — live-hit on a deploy host,
  where the operator had to free disk space by hand before the install would even start. Disk is
  now informational: the preflight prints `⚠ disk: NG free … recommends NG — continuing` and
  proceeds. Dependencies, `checks.commands`, `checks.domains`/`checks.docker_pull` and
  `services:` readiness still gate. The spec was self-contradictory (one table said FAIL while
  the exit-code section already called disk a soft check) and AGENTS rule 3 listed it as a hard
  gate — both now agree with the code.
- **Lowered the disk floors that were pure margin** (measured against real installs):
  base 5 → 3 GB · pi-web 2 → 1 GB · xiaozhi 10 → 8 GB. windmill (12 GB; images measured ~9.5 GB),
  gitlab (15 GB; data grows with repositories), dify (10 GB; eight images) and openmaic (20 GB;
  source build with a Chromium layer) keep theirs.

### Module versions

base 1.10.2 · pi-web 1.9.2 · xiaozhi 1.7.2  (checks.disk_gb changed)

## [0.29.4] — 2026-10-01

### Fixed

- **`aibox <module> config set` quoted values that compose interpolates INSIDE a scalar.**
  Modules write knobs into the deploy `.env`, and many compose lines embed the variable in a
  larger string (`- "${NEW_API_PORT:-30300}:3000"`, `image: ${NEW_API_IMAGE:-…}`). A quoted
  value survives into that scalar: the port became `"3000":3000` (`invalid hostPort`) and the
  image reference `"calciumion/new-api:v1.0.0-rc.30"` (`invalid reference format`) — both
  live-caught while migrating a new-api deployment onto aibox, where the stack could not start
  at all until the `.env` was hand-fixed. `cfg_kv_set` now writes simple values BARE (only
  whitespace, quotes, `$`, backticks … force quoting) and the next write repairs an
  already-quoted value in place. Whole-value interpolations (`FOO=${FOO}`) were never
  affected — that is why the earlier gitlab migration did not hit this.
- new-api: the start hint claimed `First login: root / 123456` unconditionally; it now states
  that this holds for a VIRGIN database only — a restored/migrated DB keeps its own accounts
  (the same honesty rule the credentials audit applied elsewhere).

### Module versions

base 1.10.1 · clash 1.9.1 · dify 1.24.2 · gitlab 1.12.1 · new-api 1.6.1 · openmaic 1.7.1 ·
pi-web 1.9.1 · windmill 1.9.2 · xiaozhi 1.7.1  (the shared include changed)

## [0.29.3] — 2026-09-29

### Fixed

- **Up/Down still did not move the selection — the renderer ignored it.** The pane frames
  received a selection index, but `_dash_render_once` passed a hardcoded `0`, so ↑/↓ updated
  the state while every frame kept highlighting the first row. The selection is now passed
  through to the frames (modules AND containers), so the marker follows the cursor.
- **Two test bugs that had hidden the above**: the selection assertions were containment
  checks (`*▸*xiaozhi*`), which pass even when the marker never moves — they now assert PER
  LINE (the marker's own line must name the expected row), and one test lost its data
  because bats' `run` OVERWRITES `$output` (the output is snapshotted before asserting).
  That is the lesson of AGENTS pitfall #11 applied to the suite itself.

## [0.29.2] — 2026-09-29

### Fixed

- **Up/Down did not work in terminals that use SS3 arrow sequences.** Navigation keys
  arrive as ESC + a sequence in two spellings: CSI (`ESC[A`, normal mode) and SS3
  (`ESCOA`, the "application cursor keys" mode many terminals switch to). The parser only
  knew CSI — and its accumulator broke on the first letter, which also kept SS3
  unreachable — so Up/Down looked dead. Both spellings (plus `ESC[5~`, `ESC[1~`,
  `ESC[1;2A` …) are handled now, with a regression test driving the raw bytes.
- **Keys felt sluggish.** The loop slept a full second AFTER every keypress, so each input
  waited for the timer before the next frame. The key read already waits up to a second, so
  that sleep is gone: a pressed key is handled immediately (a test asserts 10 keypresses
  cost well under the old ≥9s).
- **The selection could walk off the last row** (the marker simply disappeared, which reads
  as "selection doesn't work"). `sel` is now clamped to the visible row count.

### Changed

- **Readability pass on the frames**: the selected row is highlighted (reverse video) and
  marked, column headers are bold, the duplicated separator line is gone, and the stub
  `AGE` column (always `0s`) was removed — the honest sample age now lives in the status
  line (`age:12s`, formatted s/m/h). `AIBOX_DASH_FORCE_COLOR=1` forces the highlight when
  output is piped.

## [0.29.1] — 2026-09-29

### Fixed

- **`aibox dashboard`: Ctrl-C now EXITS the loop, not merely cleans up.** A signal trap
  that only runs the cleanup RESUMES the loop, so with an unlimited frame budget a pty
  session never reached `eof` — the exact shape that can stall a CI runner. The trap now
  exits (130) after the idempotent cleanup, and the key reader additionally treats the raw
  Ctrl-C byte as quit, so a terminal without ISIG (or the injected key source used by the
  tests) leaves the loop too. Covered by a keys-suite regression test plus the pty suite.

## [0.29.0] — 2026-09-29

### Added

- **`aibox dashboard` — an htop-style LIVE view.** `status` is unchanged (the instantaneous,
  scriptable snapshot); the new verb is the monitor. Four panes: **Modules** (state, ports
  with the listening verdict, endpoint, cached upgrade), **Containers** (`docker stats`:
  CPU%, MEM, uptime, restarts, health), **Upgrades** (cached latest-version probes + the
  apply hint), **Residue** (a READ-ONLY preview of what `aibox autoclean --apply` would free).
  Keys: `q` quit · Tab pane · ↑↓/j k select · `d` detail · `/` filter · `s` sort · `p` pause ·
  `+`/`-` interval (1·2·5·10·30s) · `r` resample · `?` help · `a` about. Narrow terminals drop
  columns (<80 → compact, <40 → name+state). Non-interactive use is first-class: `--once`
  (single frame; automatic when stdout is not a TTY, with a one-line hint) and `--json`
  (a superset of `status --json`; `status --json` itself is untouched).
- Architecture, grounded in this repo's own incidents: the UI **never** runs docker or network
  calls — a separate process (`aibox __dashboard-sample`) samples on a hard budget (2s local /
  8s docker stats / 60s disk / 15min cached upgrade probes) and publishes the snapshot
  **atomically** into a double buffer. The snapshot is line records parsed by pure bash (data,
  never sourced). The terminal state is saved and restored exactly (`stty -g`) through an
  idempotent signal trap; pty tests (expect) cover entering/leaving the alternate screen,
  cursor restore, exit 0 and Ctrl-C cleanup. **Strictly read-only** — every write stays an
  explicit command (`aibox <module> start`, `aibox autoclean --apply`, `aibox upgrade <module>`).

### Changed

- The `dashboard` tombstone from 0.26.0 is gone: the name is a first-class verb again, now with
  the interactive semantics above. Module-level `aibox <module> dashboard` points at the two
  real views (`aibox dashboard` / `aibox <module> status`).

### Fixed

- **dify: the vector store now ships from Docker Hub, so `aibox dify start`
  works on mirror-saved networks.** The default `WEAVIATE_IMAGE` moved from
  `cr.weaviate.io/semitechnologies/weaviate` (same tag, same upstream release)
  to `semitechnologies/weaviate`: a docker daemon with `registry-mirrors`
  configured cannot pull OTHER registries on blocked networks — it resolves the
  pull against the blocked `registry-1.docker.io` and times out (live-measured
  on a CN deploy host: `aibox dify start` died mid-pull while every docker.io
  image and the host's own route to cr.weaviate.io were fine). The Hub ref
  rides the daemon's docker.io mirrors and the module's ranked pool.
  `aibox dify update` migrates the old rendered default in the deploy `.env`
  automatically — a deliberately customized `WEAVIATE_IMAGE` is kept untouched.

### Module versions

dify 1.24.1 — this release DOES carry a `tools/**` change (the vector-store fix
above); module content ships from main, so hosts pick it up via
`aibox update dify` without a manager upgrade.

## [0.28.5] — 2026-09-29

### Fixed

- **`aibox --no-proxy` now really clears the shell's proxy.** `bypass_proxy` unsets
  the UPPERCASE `ALL_PROXY` as well: curl reads that form (socks setups export
  exactly it), and it used to survive the bypass — every fetch kept dying inside
  a dead local proxy while the operator believed they had bypassed it. `apply_proxy`'s
  env-respect branch now detects the uppercase form too. Live-caught on a deploy
  host: `ALL_PROXY=socks5h://127.0.0.1:20808` with hysteria listening but its
  tunnel dead — `aibox --no-proxy <command>` still routed through it.
- **The download source pool names a dead shell proxy instead of hinting "network?".**
  curl drags every pool candidate (direct, mirrors, the api.github.com fallback)
  through a shell-exported `ALL_PROXY`/`all_proxy`/`http_proxy`/`https_proxy`/
  `HTTPS_PROXY`, so one dead local proxy fails the WHOLE pool with a verdict that
  sends the operator to fix the wrong thing (the same deploy host: all four routes
  were 200 without the var, yet `update self` hinted "try clash / pin a mirror").
  On the no-winner path a control fetch with the proxy env removed now separates
  "your shell's proxy is dead" from "the network is down", and the failure names
  the exact variable to unset. `install.sh`'s inlined pool carries the same
  diagnosis, and `update self` no longer discards the pool's stderr — the
  diagnosis actually reaches the operator.

## [0.28.4] — 2026-09-29

### Fixed

- **The apt index refresh did nothing where GNU coreutils are missing.** The helper
  bounded its update with `timeout 300`, and `timeout` does not exist on macOS/BSD:
  the command failed instantly and the refresh was silently skipped — leaving the very
  situation the helper exists for (an emptied `/var/lib/apt/lists`) unfixed there. It
  was the only `timeout` use in the tree; the refresh is now bounded when `timeout` is
  available and runs plainly otherwise. Caught by CI's macOS bash 3.2 job — the third
  defect that job surfaced in this area, after the GNU-only `find -quit` and the
  duplicate-default-server HTTPS bug.

## [0.28.3] — 2026-09-29

### Fixed

- **The apt index refresh ran on every call on macOS/BSD hosts** (caught by CI's
  macOS bash 3.2 job, which is exactly why that job runs the whole suite): the
  emptiness check used `find … -print -quit`, a GNU-only flag. BSD find rejects it,
  the check read a POPULATED index as empty, and every dependency install paid for
  a needless `apt-get update`. Now a pure-bash glob (portable, no subprocess), with
  the same unit test passing under Linux and macOS.

## [0.28.2] — 2026-09-29

### Fixed

- **"cannot resolve the latest version" even though every mirror answered.** Two
  independent defects, both live-caught on a host whose docker.io mirrors returned
  the full tag list in milliseconds:
  1. the tag pool's racers run in BACKGROUND subshells, and when the caller is
     itself a command substitution they fail silently — the same documented failure
     mode the status probe already worked around. The manager now exposes a hidden
     `__docker-tags` verb, and the three call sites (upgrade · pool `--latest` ·
     the status "updates available" probe) go through a fresh process
     (`dockerhub_tags_fresh`, with an in-process fallback for hook contexts).
  2. the module metadata parser shell-escapes values (backslash, quote, dollar,
     backtick) when it emits them for `eval`; a raw read handed gitlab's
     `tag_pattern` over in escaped form, which matched nothing. `upgrade_pick_tag`
     now normalises an over-escaped pattern — a no-op for a clean one.
  The resolver also distinguishes "cannot fetch any tag list" from "no tag matches
  the pattern", and names the module rather than the env key.

  Verified live: on the reporting host `aibox upgrade gitlab --check` now resolves
  the full staged path (39 hops, 18.9.1 → 19.4.1-ce.0).
## [0.28.1] — 2026-09-29

### Fixed

- `aibox status <module>`'s endpoint verdict gave the live probe 3 seconds; a TLS
  endpoint costs a handshake plus an application request, so a healthy https service
  could be reported "(unreachable)". 8 seconds now — and the verdict was checked
  against an expired operator certificate, where "(unreachable)" is the honest
  answer (curl will not verify it).

## [0.28.0] — 2026-09-29

### Fixed

- **gitlab HTTPS actually serves.** `nginx['listen_port']` is the port nginx's
  EXTERNAL protocol listens on: with `external_url https://…` it must be the TLS
  port. Rendering the plain HTTP port there made nginx create two default servers
  on 80 ("duplicate default server for 0.0.0.0:80") and never start — HTTPS was
  silently dead while the module reported success. It is now a derived key
  (`GITLAB_NGINX_LISTEN_PORT`, synced by start/restart/config) so the TLS listener
  follows the URL's protocol. Live-caught migrating a native 18.9.1 install.
- **gitlab: honest endpoint + effective-port diagnostics.** With TLS on,
  `status_info` reports the operator-facing `https://…` endpoint (previously the
  plain port, which only redirects — reported as "✓ HTTP 301"), and a new
  `doctor_ports()` hook tells the shared `module_doctor` the DEPLOYMENT's ports
  (80/443 here) instead of the module defaults (31110/31143), which used to report
  "not listening" for a service that was publicly serving. The port-policy hint now
  applies to module defaults only — an operator's deliberate 80/443 is not policed.
- **gitlab restore is no longer silent.** A restore that failed told the operator
  nothing (it ran with output discarded): now the output is kept, the tail is shown
  on failure, and the specific "another backup/restore task is still running" case
  is named with the fix. (Live-caught: the second attempt "failed in 24s" while the
  real cause was a previous task still unpacking the archive.)
- **Dependency install on apt hosts, per package.** One unknown package name fails
  the WHOLE `apt-get install`: Debian 13 has no `docker-compose-v2`, which silently
  blocked `docker.io` itself. The engine is now installed alone first, compose is
  tried name-by-name, and a standalone `docker-compose` binary is linked into the
  docker CLI plugin dir so `docker compose` (what every module runs) works.

### Added

- gitlab `backup` / `restore` / `import-secrets` were exercised end-to-end on a
  real migration; the module README carries the measured native-omnibus recipe.

### Module versions

gitlab 1.12.0

## [0.27.1] — 2026-09-28

### Fixed

- **Dependency install on a host whose apt index was cleaned.** Reclaiming disk by
  removing `/var/lib/apt/lists` is a normal operation (aibox autoclean itself
  advises space reclaiming), after which EVERY `apt-get install` fails with
  "Unable to locate package" — and the deps step just reported "package install
  failed", leaving the operator to decode a package-manager error. The docker
  install path now refreshes the index when it is empty (and once more on failure,
  the retry path), bounded at 300s. Live-caught while installing aibox on a deploy
  host whose lists had just been cleaned.

## [0.27.0] — 2026-09-28

### Added

- **gitlab: HTTPS/TLS support (opt-in).** The module could only speak plain HTTP,
  which blocked the real job of taking over an existing deployment that terminates
  TLS itself: `GITLAB_HTTPS_ENABLE`, `GITLAB_HTTPS_PORT`, `GITLAB_TLS_DIR`,
  `GITLAB_HTTPS_REDIRECT` + a read-only cert mount. Certs are operator state
  (`state_files: ssl/` — never overwritten); when HTTPS is on and no cert exists,
  `start` generates a self-signed pair and says so. The TLS port must equal the one
  in `GITLAB_EXTERNAL_URL` (omnibus derives nginx's TLS listener from it).
- **gitlab: `backup` / `restore` / `import-secrets`** — the migration path itself.
  `backup` creates a tar inside the container and prints the `docker cp` line;
  `restore <tar|latest> --yes` stops puma+sidekiq, restores by `BACKUP=<id>`,
  restarts and waits for the web endpoint; `import-secrets` brings in a source
  instance's `gitlab-secrets.json` — without it a restored DB keeps its CI
  variables/tokens unreadable, silently (restore warns when it is missing). Both
  destructive verbs are two-gated. README documents the measured native-omnibus →
  aibox recipe; DEVELOPMENT records the quirks (same-version restore, the tar-name
  suffix, the first-boot wait).

### Fixed

- **Exit-code contract:** `die "msg" 30` never set 30 — the number was printed as
  part of the message and the process exited 1, so automation could not tell
  "not ready" (30) from a runtime failure (1). Repo-wide sweep to `die_code 30`
  (gitlab ×3, windmill CLI ×4), with a test pinning `container down → 30`.
- gitlab: a comment mangled by the dashboard→status rename ("status is an alias of
  status") and the duplicated `backup)` case arm the arm relocation produced.

### Module versions

gitlab 1.11.0 · windmill 1.9.1

## [0.26.1] — 2026-09-28

### Fixed

- `tests/new-api.bats` still asserted the pre-0.26.0 credential wording (`first login:
  root / 123456`), so the fast suite failed on the relabelled text. The suite is the gate,
  so the assertion moved with the copy — caught by the full harness (root + non-root), not
  by the subset runs.

## [0.26.0] — 2026-09-28

### Changed

- **BREAKING: `dashboard` is gone — `status` is the one view.** The verb and the
  per-module action were merged, because two names for one question ("what is the state?")
  split the answer in two half-views: `aibox dashboard` = the manager overview/detail,
  `aibox <module> dashboard` = the module's rich view, `aibox <module> status` = a plain
  status. Now: `aibox status` (overview) · `aibox status <module>` (detail + health) ·
  `aibox status --available` (catalog) · `aibox status --json` · `aibox <module> status`
  (the module's own rich view — node latency for clash, databases for base, the CLI's
  status for windmill/openmaic). Both removed names answer with a pointer:
  `aibox dashboard` → *"merged into `status` — use: aibox status"* (exit 2), and
  `aibox <module> dashboard` says the same at the module level.
- Module contract renames so names match reality: `render_dashboard` → `render_status`,
  `dashboard_info` → `status_info`, the shared `dash_*` helpers → `status_*`,
  `module.yaml`'s `dashboard:` metadata block → `status:`, and the async probe env knob
  `AIBOX_DASH_UPDATE_TIMEOUT` → `AIBOX_STATUS_UPDATE_TIMEOUT`. Docs point at
  `aibox status`; the test-file rename (`dash-template.bats` → `status-template.bats`)
  keeps the inventory honest.

### Fixed

- **Credentials are recorded only when they are TRUE.** windmill's `init --harden` writes
  `ADMIN_PASSWORD=<generated>` into `CREDENTIALS.txt` even when the rotation failed — the
  file then claims a password that never worked, and the operator is locked out while the
  app quietly keeps its old (default!) one. Live-caught on the deploy host: the file's
  28-char password returned `400 Invalid login` while `changeme` still worked. Now the
  file records the password **only after a login test with it succeeds**; otherwise it
  writes an explicit "NOT on record — rotation did not verify; change it in the UI" note,
  and `init` warns instead of silently lying. `credentials` keeps showing "not on record"
  as before.
- Module credential audit (the same class of lie elsewhere): new-api now labels
  `root / 123456` as "upstream default for a virgin DB" (a pre-existing DB keeps its own
  password); gitlab's already-correct "applies at first boot with fresh volumes" stays;
  base/clash/pi-web/xiaozhi generate and own their secrets (verified authoritative in
  code, no fabricated values).

### Module versions

base 1.10.0 · clash 1.9.0 · dify 1.24.0 · gitlab 1.10.0 · new-api 1.6.0 · openmaic 1.7.0 ·
pi-web 1.9.0 · windmill 1.9.0 · xiaozhi 1.7.0

## [0.25.1] — 2026-09-28

### Fixed

- The new drift check inside `doctor` never ran: the inserted line declared
  `local _drift "" _deproot=""` (an empty word where a variable NAME belongs), so the
  block mis-parsed and the report stayed silent. Caught by the final live verification
  (the stale `.env` came back clean); now `doctor` prints e.g.
  `DATABASE_URL: embeds a stale connection fact in .env (contract says aibox@aibox-base-postgres)
  — restart the module, or: aibox <module> deploy --recreate`.

### Module versions

base 1.9.1 · clash 1.8.1 · dify 1.23.1 · gitlab 1.9.1 · new-api 1.5.1 · openmaic 1.6.1 ·
pi-web 1.8.1 · windmill 1.8.1 · xiaozhi 1.6.1

## [0.25.0] — 2026-09-28

### Changed

- **One config, read at runtime — credentials stop being copied.** The provider's
  contract (`$AIBOX_HOME/base[-<profile>].env`) is now the single source of connection
  facts, and every consumer *reads* it instead of keeping a snapshot:

  | mechanism | what it does |
  | --- | --- |
  | `base_contract_export` (shared) | the manager **exports the contract before dispatch**, so every hook, dispatched CLI and `docker compose` interpolation inherits the CURRENT values (shell env beats `--env-file`) |
  | `--env-file <profile contract>` | what the compose-based consumers already did; profile-aware, resolved at every `up` |
  | `base_pg_url` / `base_redis_url` (shared) | derived strings get ONE implementation, evaluated at call time — never written into a module's files |
  | `contract_drift_report` (shared) | `doctor` scans the module's own deploy `.env` and warns when it still holds a stale copy (with the one-line fix) |

  A rendered copy goes stale the moment base rotates its secret — live-caught as a
  crash-loop (`password authentication failed`), with the app pinned to a 5-char legacy
  default while the contract said 32 chars, surviving every recreate.

- Compose-based consumers (new-api, xiaozhi, dify, openmaic) were already
  contract-referenced via `--env-file` + `${AIBOX_POSTGRES_*}` interpolation — audited
  and documented rather than changed. windmill was the only module that baked the value.

### Added

- validator **S13k**: a literal credential in a compose file, or a silent credential
  default (`${AIBOX_POSTGRES_PASSWORD:-aibox}` — the exact shape that caused the
  crash-loop), is an ERROR; `:-}` / `:-${…}` templates are fine.
- spec §One config, read at runtime + AGENTS iron rule 15.

### Module versions

base 1.9.0 · clash 1.8.0 · dify 1.23.0 · gitlab 1.9.0 · new-api 1.5.0 · openmaic 1.6.0 ·
pi-web 1.8.0 · windmill 1.8.0 · xiaozhi 1.6.0

## [0.24.1] — 2026-09-28

### Fixed

- **The contract was not actually loaded when the CLI ran from its installed location.**
  0.24.0 resolved the shared library relative to the CLI's own path, but the module
  installs the CLI into a bin dir (`/usr/local/bin/windmill`), where neither sibling path
  exists — so `cfg_kv_load_export` was undefined, the loader silently returned, and the
  stale `.env` copy was used again. The module CACHE
  (`$AIBOX_HOME/modules/windmill/_common.sh`) is now the first candidate: it is the one
  location guaranteed to exist, because the hook that dispatches the CLI lives there.
  Verified live on the deploy host that had crash-looped: with the broken `.env` restored,
  `windmill up` reported `✓ stack is fully ready version CE v1.818.0`, the server went
  `running/healthy` and the API answered **200 `CE v1.818.0`**.

### Module versions

windmill 1.7.4

## [0.24.0] — 2026-09-28

### Changed

- **Connection facts are the PROVIDER's, not a copy.** windmill's shared-PG
  `DATABASE_URL` is now resolved from `base.env` (the contract) on every invocation and
  exported, so `docker compose` starts the containers with the CURRENT values — the shell
  environment wins over `--env-file`, so a stale copy in `.env` can no longer pin a dead
  password. `.env` keeps a resolved snapshot only for the CLI's own tooling
  (`psql`/`backup`) and is realigned when it drifts; `check`/`doctor` report the drift
  without writing.
  This is the live-caught crash-loop: base rotated its secret (the 1.2.0-era default was
  the 5-char `aibox`, the modern contract value is 32 chars), the render had silently
  baked the legacy default into `.env`, and every recreate kept it — the app died with
  `password authentication failed for user "aibox"` in a restart loop.
- The env render now **dies with an actionable message** when the contract exists but
  carries no password (fix: `aibox base start`, or `aibox update base` on an older
  deployment) instead of inventing the legacy default.

### Fixed

- `deps: docker-compose` was probed with `command -v docker-compose`; modern hosts ship
  the **compose v2 plugin** (`docker compose`) and have no standalone binary, so healthy
  hosts were told "⚠ missing docker-compose — without it the service will not come up"
  even though the compose file was present and the plugin worked (live-caught on a host
  where `aibox base start` said it).

### Module versions

windmill 1.7.3

## [0.23.2] — 2026-09-28

### Fixed

- **`aibox windmill start` failed on a freshly installed module** with the CLI's raw
  `docker-compose.yml not found. Run windmill init or windmill deploy first.` — windmill
  separates MODULE install (aibox fetches hooks + CLI) from DEPLOYMENT (`init` renders
  secrets/.env/compose/Caddyfile and starts the stack), but every other module is
  install-and-start, so the natural first command had no artifacts to start. `start`
  (and `restart`) now self-heal the deploy root, in the spirit of "aibox <module> start
  works everywhere":
  - never deployed (no `.env`) → the CLI's `init` (secrets + config + render + stack),
  - rendered before but the artifacts are gone → `deploy --recreate` (keeps `.env`/secrets),
  - healthy → `up`, exactly as before.
  Live-reported: `aibox install windmill` → `aibox windmill start` → the raw CLI error.

### Module versions

windmill 1.7.2

## [0.23.1] — 2026-09-28

### Fixed

- **The autoclean integration step broke `integration.yml`** with a duplicate `run:` key
  (a step can carry only one) — PyYAML keeps the last one, so the local gate stayed quiet
  while GitHub rejected the whole workflow file and every dispatch answered HTTP 422. The
  case is now its own step, and `scripts/check-sources.sh` parses workflows with a
  duplicate-key-rejecting loader so this class fails the gate instead of the API.
- The new duplicate-key fixture skips when PyYAML is absent (macOS runners), falling back
  to the heuristic exactly like the gate does.

### Module versions

unchanged — these are CI/test-surface fixes; no module content moved.

## [0.23.0] — 2026-09-28

### Changed

- **`purge` and the cleanup surface are ONE verb now: `aibox autoclean`.** The old
  `aibox purge` is gone (no shim — an unknown verb takes the normal path). The merged
  verb keeps every purge capability and adds the safe-reclamation half:

  ```bash
  aibox autoclean                                  # report (default: deletes nothing)
  aibox autoclean --apply [--stop] [--yes]         # residue of everything it can see
  aibox autoclean <module>...|self [--apply]       # named residue (containers, volumes,
                                                   #   deploy dirs, /etc configs, units,
                                                   #   CLI binaries, npm packages)
  ```

  The no-argument form additionally reports and reclaims what passes **two proofs —
  aibox can prove ownership, and nothing references it**:

  | class | rule |
  | --- | --- |
  | dangling images | untagged, unreferenced |
  | build cache | entries older than 24h |
  | orphan volumes | attributable to a module that is **uninstalled**, with zero container references |
  | stale image tags | unreferenced by containers/pins/`upgrades/*.state`/`.env.bak.*`, newest 2 per repo kept |
  | stale `.env.bak.*` | newest 2 per module kept |

  Never touched: volumes any container references (running **or** stopped), images a
  rollback point needs, **data of an installed module**, and anything not provably
  aibox's. `aibox dashboard` now shows a `reclaim` line (docker system df).

### Added

- `tools/_shared/lib/75-reclaim.sh` — the reclamation engine (list + apply helpers),
  shared by the manager and available to module hooks.

### Removed

- **BREAKING: the `purge` verb.** Use `autoclean` (`aibox autoclean --help`). The
  `uninstall --purge` flag, the `AIBOX_PURGE_DATA` hook contract and the internal
  `_purge_*` helpers are unchanged — they are about *data purging*, which is what the
  nominally-named half still does.

### Module versions

base 1.8.1 · clash 1.7.1 · dify 1.22.1 · gitlab 1.8.1 · new-api 1.4.7 · openmaic 1.5.1 ·
pi-web 1.7.1 · windmill 1.7.1 · xiaozhi 1.5.1

## [0.22.0] — 2026-09-28

### Changed

- **Default host ports moved into the aibox reserved band.** Auditing every component
  showed the fleet parked on ports that other software also claims: windmill 8080 (+ an
  HTTPS publish on 443), dify 8088 **and 443** and 5003, openmaic 3000, xiaozhi
  8000/8002/8003, clash 7890/9090 (7890 is every Clash client's default), gitlab
  8929/8922 — and base's defaults plus ALL profile-derived ports sat inside Linux's
  **ephemeral range (32768–60999)**, where the kernel can hand the port to an outbound
  connection first. New defaults:

  | module | was | now |
  | --- | --- | --- |
  | windmill HTTP / HTTPS | 8080 / 443 | **31100** / **31443** (new `HTTPS_PORT` knob; set 443 only with a public domain) |
  | dify entry / HTTPS / plugin debug | 8088 / 443 / 5003 | **31101** / **31443** / **31503** |
  | gitlab HTTP / git-SSH | 8929 / 8922 | **31110** / **31222** |
  | openmaic | 3000 | **31140** |
  | xiaozhi ws / console / http | 8000 / 8002 / 8003 | **31130 / 31131 / 31132** |
  | clash mixed / API | 7890 / 9090 | **31790 / 31791** (your own client keeps 7890) |
  | base PG / Redis | 35432 / 36379 | **32432 / 32379** |
  | profile bands (PG/Redis/pi-web) | 35100+/36100+/37100+ | **32100+/32600+/31150+** |

  Only **fresh installs** are affected: a deployed instance pins its ports in `.env`
  (or its own conf) and keeps them. Migrating an existing instance:
  `aibox <module> config set <PORT_KEY> <new>` then restart — windmill:
  `aibox windmill config set HTTP_PORT 31100 && aibox windmill deploy --recreate`.
  Container-internal ports (80/443/5432/6379/3000/8002 …) are unchanged.

### Added

- **Spec §Port allocation** — the normative rule, with the three refused zones
  (privileged <1024, the common-service conventions, Linux's ephemeral 32768–60999),
  the `:public` escape hatch for a genuine public port, and the profile allocator as
  the only source of derived ports. AGENTS iron rule 14 points contributors at it.
- **validator S13j**: a host port outside `30000–32999` is an ERROR (`:public` opts out);
  the scaffolder now emits an in-band placeholder (31100), so a new module is compliant
  from its first second.
- **`port_policy_hint`** (shared library): `doctor` and the install-time port check now
  explain *why* an out-of-band port is risky, so existing hosts see it too.
- windmill `HTTPS_PORT` (default 31443) as a conf knob, and `module.yaml` for windmill
  finally declares its entry port (it had none).

### Fixed

- `tools/windmill/module.yaml` had no `ports:` at all — the dashboard/preflight never
  knew windmill's entry port.
- tests that encoded the old defaults (including the profile derivation values) were
  updated; a new `port-policy.bats` cross-checks every module's code default against its
  `module.yaml` declaration so the two cannot drift again.

### Module versions

base 1.8.0 · clash 1.7.0 · dify 1.22.0 · gitlab 1.8.0 · new-api 1.4.6 · openmaic 1.5.0 ·
pi-web 1.7.0 · windmill 1.7.0 · xiaozhi 1.5.0

## [0.21.2] — 2026-09-27

### Fixed

- **`aibox windmill start` (and `stop`) reached the CLI as unknown commands.** windmill is a
  dispatch-CLI module whose own spelling is `up`/`down`, and its `svc.sh` passed the standard
  lifecycle verbs through untranslated — exactly what the spec forbids for dispatch CLIs
  (openmaic already translated them). `start`/`stop`/`restart` are now mapped onto the CLI's
  verbs, so `aibox windmill start` works on every host. Live-caught on a deploy host:
  `aibox windmill dashboard` showed the stack down and `aibox windmill start` answered
  `unknown command: start`.
- **A deploy root whose `docker-compose.yml` was gone could neither start nor redeploy.**
  The compose is a render artifact (`render_compose`), but `deploy --recreate` validated it
  *before* the render step, so a missing/broken artifact was unrecoverable from the CLI side.
  The validation now runs only when the compose exists and the mode is not `--recreate`
  (which re-renders first). Host recipe for the reported case:
  `aibox update windmill && aibox windmill deploy --recreate`.
- validator rule S13i: a dispatch-CLI module must resolve `start`/`stop`/`restart` — either by
  aliasing them in `svc.sh` or by its CLI implementing that spelling. The rule immediately
  caught openmaic's `restart` pass-through (its CLI does implement it, so the check accepts it)
  and would have caught windmill's gap.

## [0.21.1] — 2026-09-27

### Fixed

- **bash 3.2 crashed on the `--check` path of a single-hop component upgrade**
  (`a[@]: unbound variable`): bash 3.2 treats an EMPTY array expansion as an unbound
  variable under `set -u` (bash 4.4+ made it safe, which is why the docker suite — bash 5 —
  stayed green and only the macOS job caught it). Every possibly-empty expansion in the
  upgrade path now uses the `${a[@]+"${a[@]}"}` idiom, in both the hop list and the
  image-pair list, and the bash-3.2 semantics plus the idiom were verified against the
  official `bash:3.2` image.

## [0.21.0] — 2026-09-27

The maintainability batch from the architecture review: every item with its own test
and, where behaviour could have shifted, a mechanical equivalence check.

### Added

- **Contract capability version (`module_iface`)** — the manager↔module contract surface
  (dashboard_info keys, `residue:` / `upgrade:` stanzas, hook behaviour) is now versioned
  like `base.env`: modules declare what they target, `AIBOX_IFACE_SUPPORTED` is exported
  to hooks, and the manager warns once when a module is newer (fix: `aibox update self`).
  Validator WARNs when the field is missing and ERRORs on a non-integer.
- **Shared platform-service renderers** (`tools/_shared/lib/70-service.sh`): the shapes of
  a launchd plist and a systemd unit (sections, Environment= quoting, logging keys,
  install target per scope) live in one place; pi-web supplies content and renders through
  them. Equivalence to the previous template was verified line by line (the only change is
  cosmetic: two `<string>` elements move onto separate lines).
- `lib-<domain>.sh` is now a first-class module library convention (sourced by `lib.sh`,
  declared in `files:`, downloaded with the module, no shebang/strict line).

### Changed

- **`aibox purge` and the dashboard derive their candidate module list** (module cache
  dirs + installed markers + registry cache + `residue.conf` keys) instead of the
  manager's hardcoded list — a newly added module is scanned, cleaned and displayed
  without touching the manager. Profile deploy roots (`apps/<name>-<profile>`) are folded
  back onto the module name via the known profile set.
- **`cmd_upgrade` (342 lines) split into named phases** — `_upg_show_history`,
  `_upg_do_rollback`, `_upg_build_newvals`, `_upg_pull_images`, `_upg_check_report`,
  `_upg_apply` — same flags, same messages, same exit codes (0/10/20), verified against
  the pre-split statement set and the upgrade suites.
- **Three module libraries split by domain**: base → `lib-upgrade.sh`,
  clash → `lib-kernel.sh`, pi-web → `lib-npm.sh`. Function inventory is byte-for-byte the
  same set as before (39/39, 39/39, 18/18 — nothing lost, nothing invented).
- **Docs tell the truth again**: the normative spec no longer describes the pre-bundler
  "inline twins" build (three passages contradicted its own §Source layout), the stale
  twin comments in `src/aibox` and the shared library are gone, and the v2.1 migration
  shims (`aibox list` / `ports` / `self`) were deleted — unknown first words take the
  normal suggestion path, and the retired words are no longer offered as verb guesses.

### Fixed

- validator: `lib-<domain>.sh` was treated as a hook (shebang + strict-mode errors);
  it is a sourced library, exactly like `lib.sh`.
- `svc_render_systemd_unit` ignored the scope when choosing the install target
  (`multi-user.target` for system units) — caught by its own test.
- the data-not-sourced gate now allowlists `LIB_*` include variables and
  `lib-<domain>.sh` (it flagged the new split includes).
- `tests/command-surface.bats` claimed to be offline but never pinned the registry to
  `file://` — `aibox ports` fetched the real network, so its message (and the suite)
  depended on connectivity; caught by the root-vs-non-root harness double-run.

### Module versions

base 1.7.0 · clash 1.6.0 · dify 1.21.5 · gitlab 1.7.5 · new-api 1.4.5 · openmaic 1.4.5 ·
pi-web 1.6.0 · windmill 1.6.5 · xiaozhi 1.4.5

## [0.20.4] — 2026-09-27

### Fixed

- **`--json` broke when a captured command line carried ANSI colour.**
  `json_escape` only handled `\n`, `\r` and `\t`; every other control byte went
  out raw, which is illegal inside a JSON string. The macOS lint job reproduced it
  end to end: the preflight's auto-install of docker captured brew's coloured
  output, the ESC byte reached a `details[]` entry, and the whole envelope failed
  to parse (`Invalid control character at: line 10 column 6`). Every control byte
  below 0x20 is now escaped as `\uXXXX`, and the package-manager calls that feed
  those lines run with `NO_COLOR=1 TERM=dumb HOMEBREW_NO_COLOR=1`.

### Module versions

base 1.6.4 · clash 1.5.4 · dify 1.21.4 · gitlab 1.7.4 · new-api 1.4.4 ·
openmaic 1.4.4 · pi-web 1.5.4 · windmill 1.6.4 · xiaozhi 1.4.4

## [0.20.3] — 2026-09-27

### Changed

- **Profile port conflicts are decided from aibox's own knowledge only.** The
  `docker ps --filter publish=<port>` lookup was removed: on two different
  machines (CI runner and a dev host, both with real daemons) it returned
  *unrelated* containers as the port's owner, and a wrong owner is worse than no
  owner. The rule is now: a live derived port that the registry does not attribute
  to THIS profile is a conflict — the holder is named when another profile
  registered it, otherwise reported as `unknown` (the case that used to surface as
  docker's raw `Bind for 127.0.0.1:35177 failed: port is already allocated`).
  The check runs BEFORE the profile registers itself (a squatted port must not
  look like "ours" just because we are about to claim it); a re-start of an
  already-registered profile stays clean.

### Fixed

- `_json_valid` merged stderr into its verdict: a python warning on the macOS
  runner replaced the `ok` answer and turned a valid `--json` payload into a test
  failure. The verdict is parse-only now, and the failure path prints the actual
  decoder error (stderr-free) for diagnosis.

### Module versions

base 1.6.3 · clash 1.5.3 · dify 1.21.3 · gitlab 1.7.3 · new-api 1.4.3 ·
openmaic 1.4.3 · pi-web 1.5.3 · windmill 1.6.3 · xiaozhi 1.4.3

## [0.20.2] — 2026-09-27

### Fixed

- **`json_escape` produced invalid JSON under a non-UTF-8 locale**: bash's
  substring expansion counts bytes there, so a multibyte character (`·`, `…` in
  the preflight details) was sliced into invalid UTF-8 and the `--json` envelope
  stopped parsing (CI macOS job). Escaping now iterates bytes (`LC_ALL=C`) and
  passes anything ≥ 0x80 through untouched — valid UTF-8 in every locale.
- **Port-owner detection trusted a single docker filter**: `docker ps --filter
  publish=<port>` returned *unrelated* containers as the owner on a CI runner
  (measured), so a clean profile was reported as conflicting. It now requires an
  aibox-named container too.
- A CI-flaky pool test asserted a fixed mirror as the PULL winner; the ranking is
  measured latency, so it now asserts the cached winner equals the mirror that
  actually pulled and is a pool member (CI-caught on the macOS job).

### Module versions

base 1.6.2 · clash 1.5.2 · dify 1.21.2 · gitlab 1.7.2 · new-api 1.4.2 ·
openmaic 1.4.2 · pi-web 1.5.2 · windmill 1.6.2 · xiaozhi 1.4.2

## [0.20.1] — 2026-09-27

### Fixed

- **Profile port conflicts were only half-detected**: the "is this port ours?"
  check compared against an empty owner and matched, so a *live* port held by
  another tenant was silently ignored and the start died with docker's raw
  `Bind for 127.0.0.1:35177 failed: port is already allocated`. Conflicts are now
  decided registry-first, the docker container lookup only adds detail, and the
  refusal names the holder (exit 4). Live-caught on a host whose real `prod`
  profile holds the slot a fresh profile hashes to.
- The integration suite now **picks profile names whose derived ports are free**
  on the host (asking with an lsof-free `/dev/tcp` probe, 60 candidates) instead
  of hardcoding `itta`/`ittb` — a test must not collide with a real deployment,
  and the conflict gate is the feature being tested, not an obstacle.
- `shellcheck` and the workflow YAML: a misplaced inline directive inside a
  `case` branch is invalid (it broke the lint job); the workflow parser gate now
  also runs the real PyYAML parse in the docker harness (the image installs it).

### Module versions

base 1.6.1 · clash 1.5.1 · dify 1.21.1 · gitlab 1.7.1 · new-api 1.4.1 ·
openmaic 1.4.1 · pi-web 1.5.1 · windmill 1.6.1 · xiaozhi 1.4.1

## [0.20.0] — 2026-09-27

Structural release: the project's design review (first-principles pass over the whole
repo) implemented end to end. The theme is **one source of truth per fact** — the
drift classes the last three releases kept patching one by one (manager/module twins,
five parsers of the same dialect, ten state stores, a per-module residue map in the
manager, hand-synced doc tables) are now structural impossibilities, each with a gate.

### Added

- **`aibox dashboard --json` / `aibox check --json`** — machine-readable surfaces for
  the consumers that actually drive aibox (scripts, timers, CI): the overview as one
  JSON object (module/app version, state, endpoint, ports, upgrade state) and the
  preflight verdict as `{module, ok, exit, details[]}` with the exit code preserved.
  Escaping lives in the shared library so modules can emit JSON with the same rules.
- **Content verification of module downloads** (`modules.SHA256SUMS`, generated by
  `scripts/manifest.sh`, CI-gated): every fetched file (hooks, libs, module.yaml,
  compose, `cli/**`, the shared include) is checked against the manifest while it is
  downloaded; a mismatch stops the install naming the file, `AIBOX_VERIFY=0` is the
  explicit bypass, a missing manifest degrades to a loud "unverified" notice.
- **Profile port registry + collision refusal** (`$AIBOX_HOME/ports.conf`, mode 600):
  profiles are registered where they are created, and starting into a port that a
  *live* other profile owns refuses with exit 4 and names that profile.
- **Generated README blocks** (`scripts/gen-docs.sh`): the action table and the
  config-key table in every module README are output of `module.yaml`
  (`actions`/`usage`/`env`), CI-checked.
- **`scripts/bundle.sh` + `scripts/check-sources.sh`**: the single-file CLI is now
  assembled from `src/aibox/*.sh`; `check-sources.sh` fails on a helper defined twice
  (anti-twin), a sourced data file, or a duplicate fragment prefix.
- `install_managed_file`: a user-edited shipped file survives an update (the new
  version lands as `<name>.new`); `state_files:` in `module.yaml` marks the files that
  are never overwritten.
- Shared readers for state and metadata: `cfg_kv_load`/`cfg_kv_load_export`
  (KEY=VALUE, values literal), `meta_field`/`meta_map_value`/`meta_sub_field`/
  `meta_version` (the module.yaml dialect), `profile_hash`/`profile_port`/… .
- AGENTS pitfall #12 (`while IFS= read -r a b c` reads the whole line into the first
  variable) — measured while writing the JSON emitter.

### Changed

- **BREAKING (contributors): `bin/aibox` is a generated artifact.** Sources live in
  `src/aibox/*.sh`; run `scripts/bundle.sh` after editing (CI fails on drift). The
  shipped file is unchanged in shape — still one file for `curl | bash`.
- **BREAKING (state files are no longer executed).** Config, registry cache, clash
  state, profile confs and deploy `.env` files are *parsed*: values are literal, so a
  config that relied on `$VAR` expansion (or command substitution) in
  `~/.aibox/config` no longer expands. `scripts/check-sources.sh` fails the build when
  a data file is sourced.
- `tools/_shared/common.sh` is generated from `tools/_shared/lib/*.sh` and the same
  fragments are injected into `bin/aibox`, so the manager and module hooks run the
  same bytes for every shared helper (the old hand-maintained "twins" are gone).
- Module metadata is read through the shared readers; module libs no longer parse
  their own `module.yaml` (validator ERROR). The validator also gained rules for
  residue declarations, `state_files:`, `deploy_root()` on upgrade-capable modules,
  and the file-ownership overlap.
- Residue knowledge for `aibox purge` is declared by the module (`residue:` stanza /
  `residue_paths()` override) and captured into `$AIBOX_HOME/residue.conf` at install
  time — purge works after uninstall and offline; the manager's per-module map is gone.
- Deploy roots are refreshed through `install_managed_file`; `state_files:` documents
  what the user owns.

### Fixed

- The validator called `parse_yaml_module_stdin` without defining or sourcing it, so
  every registry-derived cross-module rule silently never ran.
- `download_module` mis-detected the end of its own function (brace counting inside
  awk/printf strings) — caught by the residue hook landing outside the body.
- The dashboard's port columns read the module registry (network/cache) instead of the
  local cache — they are local-first now, like the rest of the overview.

### Module versions

base 1.6.0 · clash 1.5.0 · dify 1.21.0 · gitlab 1.7.0 · new-api 1.4.0 · openmaic 1.4.0 ·
pi-web 1.5.0 · windmill 1.6.0 · xiaozhi 1.4.0 (all consume the regenerated shared include).

## [0.19.1] — 2026-09-26

### Fixed

- **`aibox upgrade base --rollback` died with "cannot locate base deploy root"** — base
  exposed its deploy dir as `base_deploy_root` while the manager's upgrade engine (and
  purge's residue scan) locate modules through the contract name `deploy_root()`. base now
  provides both, and the validator WARNs when a module uses the manager's upgrade paths
  (`upgrade:` stanza, or writes `$AIBOX_HOME/upgrades/…`) without defining `deploy_root()`.
  Caught by the post-implementation review, not by the tests — the new case in
  `tests/base-contract.bats` locks the full manager → base → pin-restore path.
- Two validator refinements from the same review: the profile-scope rule now accepts a
  delegating alias (`deploy_root() { base_deploy_root; }`), and the deploy-root rule only
  applies to modules that actually use the manager's upgrade paths (dispatch CLIs keep
  their own state and stay silent).

## [0.19.0] — 2026-09-25

The shared-base dependency review, fixed end-to-end.
Semver: minor — new base verbs (dump/restore/upgrade), a versioned `base.env` contract,
Redis auth + per-module logical DBs, profile-scoped deploy roots and a reverse-dependency
gate; all with compatible defaults (existing deployments keep their paths, secrets and
unsuffixed deploy roots).

### Added

- **`aibox base dump|restore`** — whole-cluster `pg_dumpall` + a Redis snapshot into
  `$AIBOX_HOME/backups/base[-<profile>]/`; `restore` prints its warning and takes a file (or
  the newest). This is the safety net that only existed inside the consumers' own CLIs.
- **A real upgrade path for base** — `aibox base upgrade [--check|--pg <tag>|--redis <tag>|--rollback]`:
  the image pins moved to the deploy root's `.env` (the compose reads
  `${AIBOX_BASE_PG_IMAGE:-postgres:18}`), so a switch dumps first, rewrites the pin,
  recreates through the readiness gate, rolls the pin back on failure (exit `10`, or `20`
  when the rollback is unhealthy too) and records the transition in the same
  `$AIBOX_HOME/upgrades/base.state` the manager uses — `aibox dashboard base` shows it and
  `aibox upgrade base --rollback` restores the same pin file.
- **A versioned `base.env` contract** — `AIBOX_BASE_ENV_VERSION`, `AIBOX_BASE_PROFILE`,
  `AIBOX_BASE_MODULE_VERSION`, `AIBOX_BASE_READY` plus the connection keys; consumers call
  `base_env_check` and get `aibox update base` guidance on a mismatch instead of
  interpolating empty values. Keys are additive by contract; pre-0.19 files keep working.
- **Redis auth + one logical DB per module** — the password is generated once (or
  operator-set) and published in `base.env`; `aibox base create redis <module> [slots]`
  allocates a slot range (registry `apps/base[-<profile>]/redis-dbs.conf`) and writes the
  module's `redis-<profile>-<module>.env`. dify reserves three consecutive slots; new-api and
  xiaozhi read `AIBOX_REDIS_DB`. Three modules used to share index 0 with no password at all.
- **Reverse-dependency protection** — `base stop`, `uninstall base` and `purge base` now name
  the installed dependents and gate on a confirmation; purge also scans every profile's
  deploy root (`apps/<name>-<profile>`).

### Changed

- **Profile-aware linking, everywhere** — `base_env_file` / `base_pg_container` /
  `base_network_name` / `ensure_shared_base` / `ensure_shared_db` / `ensure_shared_redis_db`
  / `redis_env_file` in the shared library are the single resolver; the manager, the three
  compose-type consumers (dify, new-api, xiaozhi) and base itself derive through them. A
  hardcoded `$AIBOX_HOME/base.env` silently attached a named-profile module to the DEFAULT
  instance (wrong database, wrong network) — the validator now errors on it.
- **Deploy roots are profile-scoped** — `deploy_root()` ends with `$(profile_suffix)` for
  dify/gitlab/new-api/xiaozhi (the default profile keeps the unsuffixed path, so nothing
  moves). Two profiles used to overwrite each other's deploy `.env`/compose.
- **`base start` waits for readiness** — bounded `pg_isready` + authenticated Redis `PING`
  (`AIBOX_BASE_READY_TIMEOUT`, default 90s) before writing the contract file; the
  multi-profile integration suite used to catch a consumer racing an initializing PG.
- **Secrets are never rotated silently** — resolution order: explicit env/config → the value
  already in the contract file → `$AIBOX_HOME/.base-secret` (600) → a fresh random value
  (fresh installs only). The role password is ALTERed on start so DB and contract agree.
- **Host ports bind to 127.0.0.1 by default** (`AIBOX_BASE_BIND`; consumers use the compose
  network) — the old default published the admin DB (and an unauthenticated Redis) to every
  interface; set `0.0.0.0` explicitly when a remote host must reach them.
- **windmill no longer declares `base:redis`** (it never used Redis), and dify's optional
  shared mode self-heals its two databases + slot range at start.
- `aibox upgrade <module>` on a module that owns its upgrade verbs (base, openmaic, windmill)
  now says so and points at `aibox <module> upgrade --help` instead of a bare "no support".

### Fixed

- Two fast-suite tests depended on the ambient registry cache (green as root, red as
  non-root — caught by the docker harness's CI-parity pass): both now pin a `file://`
  registry.
- `base create redis` used to print "no resource creation needed" while every module shared
  index 0; it now allocates and publishes the slot.

## [0.18.0] — 2026-09-25

An instruction-system + documentation + test-infrastructure pass.
Semver: minor — new CLI behaviors (per-verb help, exit codes, `doctor` everywhere)
and new test tooling; no breaking change.

### Added

- **Per-verb help, everywhere** — `aibox <verb> --help` (any argument position) and
  `aibox help <verb>` render that verb's usage/options and exit 0. Before this only
  `purge` answered; `install`/`check`/`dashboard` treated `--help` as a MODULE name and
  even hit the registry, the rest reported an unknown option. `aibox help` now lists the
  real sub-verb surface (proxy `unset`/`env`, clash `set/on/off/status/refresh/select/
  test/logs/doctor/use-external`, `--rollback`/`--history`, the exit-code table).
- **`doctor` on every module** — the standard diagnostic: declared deps, docker daemon
  reachability, the module's own reported state and its declared port listeners (shared
  `module_doctor`, local-only). Exit `0` healthy / `3` dep missing / `30` not ready.
  Five modules had no diagnostic at all and one hint pointed at a non-existent
  `aibox base doctor`; clash and openmaic keep their deeper domain-specific `doctor`.
- **Dispatch-CLI lifecycle aliases** — openmaic now maps `start`/`stop`/`restart` onto its
  own `up`/`down`, so `aibox <module> start` works on every module (windmill already did).
- **Docker test harness** (`tests/docker/`) — one command builds a pinned image (bats,
  shellcheck, the GO yq CI uses, expect, a non-root `tester`) and runs gates + the fast
  suite as **root AND non-root** + (opt-in) the docker-backed integration suites against
  the host daemon. `bash 3.2` stays covered by the macOS CI job and is documented as such.
- **`tests/CASES.md`** — every pitfall-log entry, every CHANGELOG `### Fixed` class and
  every live-caught bug mapped to the test that locks it (guarded by `tests/docs-integrity.bats`).
- **Three new fast suites**: `cli-consistency.bats` (18: help/exit codes/doctor/aliases),
  `docs-integrity.bats` (10: links, index, inventory, en/zh parity, stale verbs),
  `history-cases.bats` (8: the four historical gaps — proxy verdict, proxy persistence,
  multibyte frames, docker-daemon wording).

### Changed

- **Exit codes follow the documented contract**: usage errors are `2` (were `1`), a failed
  preflight is `3` (missing hard dependency) or `4` (soft check, with the `--skip-checks`
  hint) — automation can now distinguish "called wrong" from "ran and failed" from
  "environment not ready". Module hooks use `usage_die` for the same reason (validator-enforced).
- **Validator gained three rules**: service modules must declare `doctor` and `dashboard`;
  dispatch modules declaring `up` must also declare `start`; hooks must not `die` for usage
  errors. The scaffolder emits a compliant skeleton for both styles (the `--no-compose`
  variant previously emitted the *compose* svc.sh and failed its own rules).
- **openmaic's proxy hook writes where its CLI reads** (`OPENMAIC_CONF_DIR` honoured —
  a custom conf dir silently got no proxy before).
- `aibox help`'s overview is now generated from the same data the code uses, and
  `README(.zh)` documents `--help`, the exit codes, `doctor` and the test harness.

### Fixed

- **`aibox clash use-external` crashed** with `desc: command not found` — a missing `=""`
  made bash run `desc` as a command (exit 127); the port-less invocation is the common one.
- **Typo suggestions no longer shadow real modules** — a 3-letter typo matched a 4-letter
  verb at two differences (`bas` → `list`), hiding the real suggestion (`base`); the
  tolerance now scales with word length.
- **Two stale integration assertions** (`aibox check self`'s disk line, `check base`'s
  docker-pull line) could never pass and had never run in CI (the workflow is
  dispatch-only) — both fixed, plus the `psql` calls in the profile suites are pinned to
  `-d postgres` (without it they depended on a user-named DB existing, which raced
  container init).
- **Two broken relative doc links** and the missing test-suite inventory.

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

[0.28.5]: https://github.com/lichengwu/aibox/compare/v0.28.4...v0.28.5
[0.31.0]: https://github.com/lichengwu/aibox/compare/v0.30.1...v0.31.0
[0.30.1]: https://github.com/lichengwu/aibox/compare/v0.30.0...v0.30.1
[0.30.0]: https://github.com/lichengwu/aibox/compare/v0.29.4...v0.30.0
[0.29.4]: https://github.com/lichengwu/aibox/compare/v0.29.3...v0.29.4
[0.29.3]: https://github.com/lichengwu/aibox/compare/v0.29.2...v0.29.3
[0.29.2]: https://github.com/lichengwu/aibox/compare/v0.29.1...v0.29.2
[0.29.1]: https://github.com/lichengwu/aibox/compare/v0.29.0...v0.29.1
[0.29.0]: https://github.com/lichengwu/aibox/compare/v0.28.5...v0.29.0
[0.28.4]: https://github.com/lichengwu/aibox/compare/v0.28.3...v0.28.4
[0.28.3]: https://github.com/lichengwu/aibox/compare/v0.28.2...v0.28.3
[0.28.2]: https://github.com/lichengwu/aibox/compare/v0.28.1...v0.28.2
[0.28.1]: https://github.com/lichengwu/aibox/compare/v0.28.0...v0.28.1
[0.28.0]: https://github.com/lichengwu/aibox/compare/v0.27.1...v0.28.0
[0.27.1]: https://github.com/lichengwu/aibox/compare/v0.27.0...v0.27.1
[0.27.0]: https://github.com/lichengwu/aibox/compare/v0.26.1...v0.27.0
[0.26.1]: https://github.com/lichengwu/aibox/compare/v0.26.0...v0.26.1
[0.26.0]: https://github.com/lichengwu/aibox/compare/v0.25.1...v0.26.0
[0.25.1]: https://github.com/lichengwu/aibox/compare/v0.25.0...v0.25.1
[0.25.0]: https://github.com/lichengwu/aibox/compare/v0.24.1...v0.25.0
[0.24.1]: https://github.com/lichengwu/aibox/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/lichengwu/aibox/compare/v0.23.2...v0.24.0
[0.23.2]: https://github.com/lichengwu/aibox/compare/v0.23.1...v0.23.2
[0.23.1]: https://github.com/lichengwu/aibox/compare/v0.23.0...v0.23.1
[0.23.0]: https://github.com/lichengwu/aibox/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/lichengwu/aibox/compare/v0.21.2...v0.22.0
[0.21.2]: https://github.com/lichengwu/aibox/compare/v0.21.1...v0.21.2
[0.21.1]: https://github.com/lichengwu/aibox/compare/v0.21.0...v0.21.1
[0.21.0]: https://github.com/lichengwu/aibox/compare/v0.20.4...v0.21.0
[0.20.4]: https://github.com/lichengwu/aibox/compare/v0.20.3...v0.20.4
[0.20.3]: https://github.com/lichengwu/aibox/compare/v0.20.2...v0.20.3
[0.20.2]: https://github.com/lichengwu/aibox/compare/v0.20.1...v0.20.2
[0.20.1]: https://github.com/lichengwu/aibox/compare/v0.20.0...v0.20.1
[0.20.0]: https://github.com/lichengwu/aibox/compare/v0.19.1...v0.20.0
[0.19.1]: https://github.com/lichengwu/aibox/compare/v0.19.0...v0.19.1
[0.19.0]: https://github.com/lichengwu/aibox/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/lichengwu/aibox/compare/v0.17.0...v0.18.0
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

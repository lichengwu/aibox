# Dashboard: app/module version display + Keyline template — design

Date: 2026-09-23
Status: approved design (visual variant A "Keyline" selected in browser review)

## 1. Problem

`aibox pi-web dashboard` renders:

```text
pi-web · module 1.3.5                     ← the aibox packaging version
  service:  running (pid 38243)           ← raw launchctl output above, too
  app:      http://127.0.0.1:30141 · HTTP 307
  log:      /Users/lichengwu/Library/Logs/pi-web.log
  module:   /Users/lichengwu/.aibox/modules/pi-web/
```

Three defects:

1. **The deployed app version is invisible.** The managed `@agegr/pi-web` npm
   package is 0.9.3; nothing on screen says so. "module 1.3.5" reads as
   "pi-web is version 1.3.5" — wrong version, wrong concept.
2. **Terminology is ambiguous.** `dashboard_info()`'s `version=` key is
   documented as "deployed upstream version" and rendered `upstream:` —
   colliding mentally with the updates section's "latest upstream version".
   Module-owned rich views drift (clash/base show no module version at all;
   pi-web shows no app version; each hand-rolls its header).
3. **The view isn't refined.** Mixed label paddings, redundant `health:` row,
   colons as noise, raw `launchctl`/`lsof` dumps mixed into the dashboard
   action, no visual framing.

## 2. Goals / non-goals

### Goals

1. Every module dashboard shows the **app version** (normal prominence,
   cyan) and the **module version** (de-emphasized: dim, sunk to the last
   row) — unambiguous labels.
2. One shared visual template (**Keyline**) used by module-owned rich views
   (`render_dashboard`), the manager overview (`aibox dashboard`), and the
   generic detail view (`aibox dashboard <m>`).
3. New modules cannot miss the feature: scaffolder emits the skeleton,
   validator WARNs on gaps.
4. `dashboard`/`status` show the refined view only; raw diagnostics stay in
   `diagnose` (where they already exist).

### Non-goals

- Upgrade-engine npm source (pi-web "update available" probe) — follow-up.
- `aibox <module> --help` header changes (module-documentation context;
   `· module <ver>` stays).
- Secret masking in dashboards (possible later hardening; current
   plaintext-credential behavior unchanged).

## 3. Terminology (normative)

| term | meaning | source |
| --- | --- | --- |
| **app version** | version of the managed software as deployed | npm package version, docker image tag, mihomo kernel tag, dispatched CLI version |
| **module version** | version of the aibox wrapper scripts | `module.yaml` `version:` |

`dashboard_info()`'s `version=` key **is** the app version (key name
unchanged for stale-cache compatibility; rendered label changes
`upstream:` → `app:`). The overview updates section compares exactly this
value against the probed latest — now unambiguous.

## 4. Keyline template

### 4.1 Shapes

Module-owned rich view (`render_dashboard`, via helpers):

```text
pi-web 0.9.3 · ✓ running                          ← bold name, cyan appver, dim ·, green state
────────────────────────────────────────────      ← dim rule
  service    launchd · pid 38243                  ← dim label, %-10s, no colon
  endpoint   http://127.0.0.1:30141 · HTTP 307 ✓  ← health merged into the endpoint row
  auth       pi / ai-coding
  log        ~/Library/Logs/pi-web.log
  module     1.3.5 · ~/.aibox/modules/pi-web/     ← whole row dim (sunk)
```

Manager overview block (one per installed module, blank line between):

```text
── profile base (active) ────────────────────    ← section header: dim ── + bold-cyan title + dim rule
  ✓ clash 1.19.31                                ← state icon + bold name + cyan appver (no state word)
     endpoint   socks5://127.0.0.1:7890 · ok (API :9090 answers)
     auth       secret 66c4…f45e
     log        ~/.aibox/apps/clash/logs/mihomo.log
     ports      7890/tcp:mixed ✓  9090/tcp:api ✓
     module     1.3.3 · ~/.aibox/modules/clash/  ← whole row dim
```

Generic detail view (`aibox dashboard <m>`, no rich view):

```text
pi-web 0.9.3 · ✓ ok
────────────────────────────────────────────
  endpoint   http://127.0.0.1:30141 · ✓ HTTP 307
  auth       pi / ai-coding
  log        ~/Library/Logs/pi-web.log
  ports      30141/tcp:http ✓
  module     1.3.5 · ~/.aibox/modules/pi-web/
```

`residue` / `updates` sections use the same section-header style
(`── residue ──…`); content lines unchanged.

### 4.2 Rules

- **Colors**: name `C_BOLD`; app version `C_CYA`; state icon+word
  `C_GRN` ok / `C_YEL` starting / `C_DIM` ○ stopped; rule, labels, `·`
  separators, the whole module row: `C_DIM`. Values default. Only the
  existing palette — no new colors.
- **State mapping**: `ok` → `✓ ok`, `starting` → `⚠ starting`,
  `stopped` → `○ stopped`, `na`/empty → no state segment (CLI-type
  modules). Overview header: icon only (no word) — the health detail
  lives in the endpoint row.
- **Grid**: rows are `  <label %-10s> <value>` (2-space indent, label
  field 10, one space, value). Overview rows indent 5 spaces. Labels are
  a fixed ASCII set — byte-safe `%-10s`; values are NEVER truncated or
  byte-sliced (CJK node names stay ragged-right; pitfall #6).
- **Rule width**: TTY → `tput cols` clamped to [40, 72]; non-TTY/NO_COLOR →
  fixed 64 (stable for tests and pipes). Rules are complete `─` literals
  repeated (no slicing).
- **Version fallbacks**: app version unknown → header omits the version
  segment; the manager overview falls back to the module version rendered
  **dim** (distinguishing it from a cyan app version).
- **health merge**: the endpoint row carries the probe verdict
  (`… · ok (API :9090 answers)`); `state=stopped` appends the dim hint
  `(stopped — aibox <m> start)` instead. No standalone `health:` row.
- **No colons** after labels anywhere in the three dashboard views.
- `NO_COLOR` / non-TTY: colors off, shapes identical.

## 5. Component changes

### 5.1 `tools/_shared/common.sh` — template helpers

```bash
dash_header()      # $1=name $2=app_version(""=omit) $3=state(ok|starting|stopped|na|"")
                   #   prints "<bold>name</bold> <cyan>appver</cyan> <dim>·</dim> <state>"
                   #   + the dim rule line (width per §4.2)
dash_row()         # $1=label(ASCII) $2=value (printed verbatim; modules may embed
                   #   color spans / dim separators)
dash_module_row()  # $1=module_version $2=module_dir — the sunk all-dim row
dash_rule()        # standalone rule (clash sub-tables may want extra rules)
```

Helpers use `${C_*:-}` fallbacks (safe when a module hook runs standalone
without aibox's exported palette). bash 3.2-safe (no self-referencing
multi-`local`, pitfall #8).

### 5.2 `bin/aibox` — manager views (inline same template)

- `_dash_block`: keyline overview block (§4.1) — header icon+name+app
  version (dim module-version fallback), rows from `dashboard_info` with
  `version=` → `app:` label, health merged, ports row kept, sunk module
  row (`<mver> · $AIBOX_MOD_DIR/<m>/`). Section headers `── profile <p> ──`.
- `cmd_dashboard_detail`: keyline generic detail (§4.1). Not-installed
  branch keeps warn + hint.
- The `app:` label change (was `upstream:`) applies to both.
- The manager does NOT source `_shared/common.sh` (single-file CLI) — it
  inlines the same formats, as it already does for the yaml parsers.

### 5.3 Per-module changes

| module | app version source | `dashboard_info` `version=` | rich view header |
| --- | --- | --- | --- |
| pi-web | `app_version()`: `npm ls -g @agegr/pi-web --depth=0` grep (local, ~0.7s; empty when absent) | add | `pi-web 0.9.3 · ✓ running` |
| clash | internal: `KERNEL_TAG`; external mode: omit | add (`KERNEL_TAG`) | `clash mihomo 1.19.31 · ✓ ok`; nodes table below unchanged |
| base | omit (multi-component; rows already show image tags) | `postgres <pg> / redis <rd>` | `base · ✓ ok` |
| new-api | `NEW_API_IMAGE` tag (extract `app_version()`) | has | `new-api <tag> · ✓` |
| dify | `DIFY_API_IMAGE` tag | has | `dify <tag> · ✓` (stack row stays) |
| gitlab | `.env` image tag (`app_version()`) | add | `gitlab <tag> · ✓` (container row keeps image+status) |
| xiaozhi | server/web image tags | has (`x / y`) | `xiaozhi <server> / <web> · ✓` |
| openmaic | installed CLI's `OPENMAIC_CLI_VERSION` (file read, windmill-style) | add | n/a — `dashboard` dispatches to CLI status (exempt from `dash_header`) |
| windmill | installed CLI version (`installed_version()`, fallback `cli_version()`) | add | n/a — dispatch (exempt) |

pi-web svc.sh: `status|dashboard` render the refined view only
(`render_dashboard` now carries service+pid, endpoint+HTTP verdict, log,
module). Raw `launchctl`/`lsof` dumps remain in `diagnose` (already
implemented there). `show_status()` stays as the internal function used by
install/restart confirmations.

### 5.4 `scripts/new-module.sh` (scaffolder)

Skeleton `lib.sh`: `app_version()` stub (TODO comment: npm pkg / image tag
/ kernel), `render_dashboard()` calling `dash_header` + `dash_row` +
`dash_module_row`, `dashboard_info()` emitting `version=…` TODO line.
Scaffold must pass the validator with 0 ERROR / 0 new WARN out of the box.

### 5.5 `scripts/validate-module.sh`

- **S18**: `actions` contains `dashboard` and lib.sh defines
  `render_dashboard` but never calls `dash_header` → WARN
  ("dashboard template: use dash_header (spec §Dashboard template)").
- **S19**: lib.sh defines `dashboard_info` but emits no `version=` → WARN
  ("dashboard_info must report the app version (version=)").
  (Approximate grep — WARNs are advisory.)

### 5.6 Docs

- `docs/module-spec.md`: new normative §"Dashboard template" — terminology
  table (§3), template shapes (§4.1), helper API (§5.1), data-source
  guidance, validator enforcement, the "dashboard = refined view,
  raw diagnostics in diagnose" rule.
- `README.md` / `README.zh.md`: refresh the dashboard example blocks.
- `CHANGELOG.md`: `[Unreleased]` entries (Added).

### 5.7 Version bumps

Every touched module bumps its `module.yaml` `version:` (minor — feature);
`AIBOX_VERSION` bump at release time. Per repo flow, bumps ride in the
release commit message.

## 6. Compatibility & constraints

- **Stale caches**: old cached lib.sh (no `dash_header` call) + old cached
  `_common.sh` (no helper) stay self-consistent; the manager's new template
  degrades gracefully (appver absent → dim module-version fallback).
  Helper + calling lib.sh ship atomically via `aibox update` (standard-6 +
  includes fetched together).
- **`version=` key name unchanged** — only the rendered label changes.
- **bash 3.2**: `%-10s` on ASCII labels only; box/rule chars are complete
  literals (never sliced); no bash-4 syntax; no `local a= b="${a}"` chains.
- **CJK**: values never byte-truncated (ragged-right accepted).
- **NO_COLOR / pipes**: identical shapes, no escapes (existing gating).
- **Perf**: `npm ls` is local-only; dashboards stay local-first, async
  probes unchanged.

## 7. Testing

- **New `tests/dash-template.bats`**: helper shapes under NO_COLOR/non-TTY
  (exact-string asserts): header with/without appver, all four states,
  `dash_row` grid, `dash_module_row`, rule width 64 (non-TTY).
- **Update**: `cli-surface.bats` (overview block header/rows/labels),
  `command-surface.bats` (generic detail), `new-api.bats` + `xiaozhi.bats`
  (`upstream:` → `app:`), `pi-web-npm.bats` (new status shape,
  `app_version()`), `module-tools.bats` (scaffold contains `dash_header`
  and passes the validator).
- Full suite under `/bin/bash` 3.2 (macos-bash32 CI job) — pitfall #10:
  mid-test assertions get `|| false`.

## 8. Deliverables

1. `tools/_shared/common.sh` — dash helpers
2. `bin/aibox` — `_dash_block`, `cmd_dashboard_detail`, label change
3. 9 modules' `lib.sh` (+ pi-web `svc.sh` status split) + version bumps
4. `scripts/new-module.sh`, `scripts/validate-module.sh`
5. `docs/module-spec.md` §Dashboard template; README(.zh); CHANGELOG
6. `tests/dash-template.bats` + updated suites

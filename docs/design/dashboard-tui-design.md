# aibox dashboard — Interactive (htop-style) View Design

> Status: **Confirmed design** (no code yet; this round writes the design only)
> Date: 2026-09-29
> Scope: A new interactive `aibox dashboard` verb — a continuously refreshing, keyboard-driven
> view ("htop for aibox"). `aibox status` keeps its current meaning untouched.
> Related: `docs/module-spec.md` §Status template / §CLI surface · `src/aibox/70-status.sh` ·
> `tools/_shared/lib/25-status.sh` (render primitives) · `AGENTS.md` §Test environment
> Principle: **the UI never blocks and never writes.** Sampling is a separate process; the
> interactive loop only reads files and draws frames; every state mutation stays behind an
> explicit command (`status` / `autoclean` / `install` / `upgrade`).

---

## 0. Confirmed decisions (2026-09-29)

| # | Decision | Choice |
|---|---|---|
| 1 | Pane set | **Four panes**: `Modules` (P1) · `Containers` (P3) · `Upgrades` (P3) · `Residue` (P4) |
| 2 | Write actions in V1 | **Strictly read-only.** No start/stop/restart/uninstall/cleanup inside the TUI; the help overlay states it |
| 3 | Cadence | **2s local / 8s docker stats / 60s disk / 15min upgrade cache**; runtime `+`/`-` cycles 1·2·5·10·30s |
| 4 | Degraded modes | **Auto-degrade + one-line hint**: non-TTY → single frame (with a hint about `--json`); no docker → module table still works, container pane shows `—` |

### 0.1 Why a *new* `dashboard` (history)

0.26.0 folded the old `dashboard` into `status` — two names for one static question. This design
re-introduces the name with a **different semantic**: `status` is an instantaneous, scriptable
snapshot; `dashboard` is a live monitor. The two tombstones that currently intercept the name
(`src/aibox/90-main.sh` verb arm, `src/aibox/70-status.sh` module-action guard) are removed as
part of P1.

---

## 1. Positioning

| Command | Semantic | Lifecycle |
|---|---|---|
| `aibox status [<module>] [--available] [--json]` | Instantaneous snapshot: local-first, one output, stable schema, scriptable | Prints and exits |
| **`aibox dashboard`** | **Continuous observation**: full-screen, periodic refresh, keyboard-driven | Runs until you quit; **strictly read-only** |

`status --json` keeps its current schema (backward compatible). `dashboard --json` is a superset
(adds `containers[]`, `cpu`, `mem`, `load`, `stale`).

## 2. Goals / non-goals

**Goals**: htop-like feel (sub-second input latency, 2s data freshness); **the UI never blocks**
(sampling is asynchronous); zero dependencies (pure ANSI, no ncurses); bash 3.2 + BSD tools;
graceful degradation; **no module contract change** (no `tools/**` edit → no nine module bumps);
all automated tests run in the docker harness.

**Non-goals (V1)**: any write action; replacing `status`; log streaming (`aibox <m> logs` exists);
historical graphs (V2, structure reserved); remote-host dashboards (a host without the CLI runs
its own).

## 3. Screen design

### 3.1 Pane 1 — Modules (P1, the first shippable slice)

```text
 aibox 0.28.4 · profile:default · mac · 14:07:33 · sample 2s(last 0.38s) · modules 7 ok 1 warn 1 down · containers 12
────────────────────────────────────────────────────────────────────────────────────────────────────────────
  MODULE     PROFILE  MODULE  APP           STATE       PORTS            ENDPOINT                UP    AGE
▸ base       default  1.10.0  postgres16.4  ● ok        32432 32379      pg://127.0.0.1:32432    —     1s
  windmill   default  1.9.1   CE v1.818.0   ● ok        31100 31443      http://host:31100       —     2s
  gitlab     default  1.12.0  18.9.1-ce.0   ● ok        80 443 31222     https://gitlab.…        ⬆19.4 5s
  new-api    default  1.6.0   v0.13.2       ● ok        30300            http://host:30300       —     2s
  dify       default  1.24.0  1.17.1        ● ok        31101 31503      http://host:31101       —     4s
  clash      default  1.9.0   mihomo 1.19.x ● ok        31790 31791      http://host:31790       —     1s
  xiaozhi    default  1.7.0   v1.5.0        ⚠ drift     31130 31131      http://host:31131       —     2s
  openmaic   default  1.7.0   —             ✗ stopped   31140            —                       —     9s
────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Tab pane · ↑↓ select · Enter detail · / filter · s sort · p pause · +/- interval · r resample · ? help · q quit
 snapshot 14:07:33 (samplers: local 2s · upgrade check in 9m)            [stale: docker unresponsive — last good snapshot]
```

Notes: `STATE` uses the module contract vocabulary (`status_info` `state=`); `⚠ drift` reuses the
existing `contract_drift_report` signal; `UP` shows the cached latest version when newer than the
deployed one; `AGE` is the age of this module's last successful sample (a row going stale is itself
information).

### 3.2 Pane 2 — Containers (P3)

```text
  CONTAINER                 IMAGE                       CPU%   MEM        UPTIME   ↻   PORTS          HEALTH
▸ aibox-base-postgres       postgres:16-alpine          0.4%   86M/256M   3d 4h    0   32432          ● healthy
  aibox-base-redis          redis:7-alpine              0.2%   12M/64M    3d 4h    0   32379          ● healthy
  windmill-windmill_server  windmill:1.818.0            3.1%   412M       18h      0   31100          ● healthy
  windmill-caddy            caddy:2-alpine              0.1%   18M        18h      0   31100 31443    ● healthy
  aibox-gitlab              gitlab/gitlab-ce:18.9.1     8.7%   2.4G       1d 2h    0   80 443 31222   ● healthy
  … (sorted by CPU% by default)
```

`CPU%`/`MEM` come from `docker stats --no-stream` (one call, every 4th sample = 8s). When stats are
unavailable (daemon slow, cgroup-less platform) the columns show `—` and the pane stays usable.

### 3.3 Pane 3 — Upgrades (P3)

```text
  MODULE     DEPLOYED       LATEST          HOPS  NOTES
  gitlab     18.9.1-ce.0    19.4.1-ce.0     39    staged path: 18.2 → 18.5 → 18.8 → 18.11 → 19.2 → 19.4
  windmill   CE v1.818.0    CE v1.818.0     —     up to date
```

Data comes from the **cached** latest-version files written by the existing `__status-probe`
machinery (never a network call in the UI loop); the hop path reuses the upgrade framework's
`upgrade_stops` logic.

### 3.4 Pane 4 — Residue (P4, read-only preview)

```text
  CATEGORY          RECLAIMABLE   EXAMPLES (first 3)
  dangling images   1.2G          sha256:1a2b… (7d) …
  build cache       3.4G          —
  orphan volumes    0             —
  stale tags        860M          windmill:1.810.1 …      (protected: pins / upgrade state)
  total             5.5G          apply with an explicit command: aibox autoclean --apply
```

Reuses the `reclaim_*` scanners; the pane **never applies** — it only reports what `autoclean`
would do. The footer repeats the explicit-command path.

### 3.5 Help overlay (`?`) and about (`a`)

```text
 ┌─ Help — aibox dashboard 1 ───────────────────────────────────────────┐
 │ q / F10 / Esc   quit (restores the terminal)   Tab / S-Tab  next pane │
 │ r / F5          resample now                    ↑↓ j k      move      │
 │ p / space       pause / resume                  g / G       first/last│
 │ + / -           interval 1·2·5·10·30s           PgUp/PgDn   page      │
 │ /               filter (name/state)             Enter       module    │
 │ s               sort (name/cpu/mem/state/port/up)           detail    │
 │ ?  F1           this help                       a           about     │
 ├──────────────────────────────────────────────────────────────────────┤
 │ READ-ONLY: the dashboard changes nothing. Writes stay explicit:      │
 │   aibox <module> start|stop|restart   ·   aibox autoclean --apply    │
 │   aibox install|uninstall|upgrade                                    │
 │ Legend: ● green ok   ⚠ yellow degraded/drift   ✗ red down   ⬆ cyan upgrade available │
 └──────────────────────────────────────────────────────────────────────┘
```

## 4. Key map

| Key | Action | htop equivalent |
|---|---|---|
| `q` `F10` `Esc` | Quit (restores the terminal) | F10 |
| `r` `F5` `Ctrl-L` | Resample + redraw now | F5 |
| `p` `space` | Pause / resume auto-refresh (footer shows `PAUSED 14:03:11`) | — |
| `+` `-` | Cycle interval 1→2→5→10→30s | — |
| `Tab` `Shift-Tab` | Cycle panes | — |
| `↑` `↓` `j` `k` | Move selection | ↑↓ |
| `PgUp` `PgDn` `g` `G` | Page / first / last | PgUp/PgDn |
| `Enter` | Module detail — reuses `cmd_status_detail` (leaves the alternate screen, prints the full snapshot, any key returns) | Enter |
| `/` | Filter (live; name / state / pane-specific fields) | F4 |
| `s` | Sort-key picker | F6 |
| `?` `F1` | Help overlay | F1 |
| `a` | About: version, paths, sampler parameters | — |

Letter keys are primary and **F-keys are aliases**: many terminals and multiplexers swallow
function keys, so the letter set must be able to do everything on its own.

## 5. CLI surface

```bash
aibox dashboard                     # interactive (pane 1 by default)
aibox dashboard <module>            # open focused on that module (filter preset)
aibox dashboard --pane containers   # modules | containers | upgrades | residue
aibox dashboard --once              # single frame (auto-selected when not a TTY; pipeable)
aibox dashboard --interval 5        # refresh interval in seconds (any positive integer)
aibox dashboard --no-color          # same as NO_COLOR=1
aibox dashboard --json              # snapshot JSON (superset of status --json)
aibox dashboard --help              # usage block (same text as `aibox help dashboard`)
```

Exit codes follow the existing contract: `0` normal quit · `2` usage error (`usage_die`) ·
`30` not-ready (e.g. `--pane residue` with no docker daemon).

## 6. Architecture

### 6.1 Process model — UI and collection are separate processes

```text
┌───────────────────────┐   read snapshot (files; never blocks)   ┌────────────────────────────┐
│ UI process            │◀───────────────────────────────────────│ Sampler process            │
│ aibox dashboard       │    snapshot.<n> (atomic publish)        │ aibox __dashboard-sample   │
│ keys / frames / timer │                                         │ 2s : docker ps + inspect,  │
│ NEVER runs docker/curl│                                         │      ports, status_info    │
└───────────────────────┘                                         │ 8s : docker stats          │
        │ reads cache files only                                  │ 60s: docker system df      │
        ▼                                                         └────────────────────────────┘
┌───────────────────────┐      ┌─────────────────────────────────────────────────────────────┐
│ upgrades cache        │◀─────│ upgrade-check processes (reuse __status-probe machinery)    │
│ modules/<m>.latest    │      │ one process per module, per 15 min, each with a timeout     │
└───────────────────────┘      └─────────────────────────────────────────────────────────────┘
```

Rationale, grounded in this repo's own incidents: the pool/tag races and probes **fail silently
inside command substitutions and nested subshells** — already solved by "hidden verb + separate
process" (`__status-probe`, `__docker-tags`). A dashboard samples inside a loop, so its sampler is a
separate process by design. Correspondingly, any `docker`/`curl` call inside the UI loop would
destroy interactivity, so the UI only reads files.

### 6.2 Snapshot format (state is data, never code)

Written under `$AIBOX_HOME/dashboard/`:

```text
snapshot.version=1
snapshot.ts=1790652453
snapshot.cost_ms=380
snapshot.stale=0                 # 1 = this pass failed; UI shows the last good snapshot
snapshot.docker=ok               # ok | down
snapshot.load=1.24               # 1-min host load average (optional)
---
m.name=gitlab
m.profile=default
m.module_version=1.12.0
m.app_version=18.9.1-ce.0
m.state=ok                       # ok | starting | stopped | na
m.health=healthy
m.endpoint=https://gitlab.example.com
m.ports=80/tcp:http 443/tcp:https 31222/tcp:git-ssh
m.listening=80 443 31222         # what actually listens (declared vs fact)
m.upgrade_target=19.4.1-ce.0     # from cache; may be empty
m.age_s=5
---
c.name=aibox-gitlab
c.image=gitlab/gitlab-ce:18.9.1-ce.0
c.cpu_pct=8.7
c.mem=2.4G
c.uptime=1d2h
c.restarts=0
c.ports=80 443 31222
c.health=healthy
```

Plain `KEY=VALUE` records separated by `---`, parsed with the existing `cfg_kv_*` helpers
(**never sourced** — spec §State model). Publication is atomic: write `snapshot.tmp`, then `mv`
into the alternating `snapshot.1` / `snapshot.2`. `cost_ms` and `stale` make the dashboard
self-diagnosing.

### 6.3 Collection budget (hard caps)

| Data | Frequency | Per-call cap | Mechanism |
|---|---|---|---|
| Module `status_info` (local lib) | 2s | 200ms/module | child `bash` sourcing the module `lib.sh` (same as `_status_block`) |
| Port listeners | 2s | 50ms | `ss -Htln` (Linux) / `lsof` (macOS) — existing `port_listening` logic |
| Container list | 2s | 300ms | one `docker ps --format …` |
| Container CPU/MEM | every 4th sample (8s) | 1.5s | one `docker stats --no-stream --format …`; `—` when unavailable |
| Disk reclaimable | 60s | 1s | `docker system df` (reuse `reclaim_df_summary`) |
| Upgrade availability | 15min | 8s/module | existing `__status-probe` + cache files |
| Host load | 2s | 20ms | `uptime` (portable) |

Every external call is bounded when `timeout` exists and runs plainly otherwise — the macOS/BSD
gap fixed in 0.28.4, now a project rule.

### 6.4 Terminal lifecycle (the part that can break a user's terminal)

Enter:
1. Preconditions: `[ -t 0 ] && [ -t 1 ]`, `TERM != dumb`, `AIBOX_NO_TUI` unset. Otherwise
   **auto-degrade** to `--once` and print one hint line.
2. `SAVED_STTY=$(stty -g)` (exact restore, not `stty sane`) → `tput smcup` (alternate screen) →
   `tput civis` (hide cursor).
3. `stty -echo -icanon min 1 time 0` — **not** `raw`: Ctrl-C keeps its meaning and is handled by us
   (byte `0x03`).

Exit (idempotent, signal-safe):

```bash
_dash_cleanup() {
  [ "${_DASH_CLEANED:-0}" = 1 ] && return 0
  _DASH_CLEANED=1
  [ -n "${SAVED_STTY:-}" ] && stty "$SAVED_STTY" 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  kill "${SAMPLER_PID:-}" 2>/dev/null || true
  rm -rf "${DASH_TMPDIR:-}" 2>/dev/null || true
}
trap _dash_cleanup EXIT INT TERM HUP QUIT
```

`SIGWINCH` sets a resize flag (`trap '_dash_resize=1' WINCH`); the next frame re-reads `stty size`.
A `kill -9` cannot be trapped — the help overlay and README say `reset` recovers the terminal
(honest, not pretended).

### 6.5 Rendering

- One frame = `\033[H`, then per line `content\033[K\n`, then `\033[J`, emitted in **one `printf`**
  (single write, no tearing). No full-screen clear per frame.
- Truncation uses a display-width helper (`_dash_dwidth`: ASCII=1, CJK/emoji=2), never byte
  slicing (pitfall #6), with a single-character ellipsis appended as a whole string.
- Small terminals: `< 80×24` switches to a compact mode (name + state + key ports);
  `< 40` columns shows name + state only.
- Colors reuse `C_GRN/C_YEL/C_RED/C_DIM/C_CYA`; `NO_COLOR` or non-TTY renders uncolored but still
  readable.

### 6.6 bash 3.2 constraints (design-time, not discovered later)

No `coproc`, no associative arrays, no `${v,,}`; **no fractional `read -t`** (integer 1s tick plus
`date +%s` alignment); empty-array expansion uses `${arr[@]+"${arr[@]}"}`; no same-line
`local a=x b=${a}`; multibyte strings are never sliced; `[[ ]]` errexit quirk is respected in tests
(`|| false`).

## 7. Phased delivery (each phase independently shippable)

| Phase | Content | Acceptance (docker-only) |
|---|---|---|
| **P1** | Sampler + snapshot format + `--once` + `--json` + degraded modes (no interaction) | snapshot field/atomicity/budget assertions; `--once` frame render; no-docker degrade; `--json` schema |
| **P2** | Interactive shell: alt-screen/stty/traps/resize/key loop + Modules pane + status line + `q r p + -` | key parsing via injectable input fd; idempotent cleanup; compact mode; optional pty case |
| **P3** | Containers pane (CPU/MEM/UPTIME) + Upgrades pane + `Enter` detail + `?` help | frame assertions from a fixed snapshot (exact text); pagination/selection/filter/sort state machine |
| **P4** | Residue pane (read-only `autoclean` preview) + `--pane/--interval/--no-color` + docs | frame assertions; help/README consistency gate |
| V2 (candidates) | Historical sparklines (reuse the double-buffered snapshot as a ring), optional **two-gated** write actions, optional per-module `dashboard_info()` metrics hook | — |

## 8. Impact

| File | Change |
|---|---|
| `src/aibox/90-main.sh` | Remove the verb tombstone → real dispatch; add `dashboard` to the `--help` pre-case list |
| `src/aibox/70-status.sh` | Remove the module-level `dashboard` action tombstone |
| `src/aibox/10-ui.sh` | `AIBOX_VERBS` += `dashboard`; `_verb_help` gets the usage block |
| **new** `src/aibox/72-dashboard-sample.sh` | Sampler, snapshot read/write, `__dashboard-sample` entry |
| **new** `src/aibox/74-dashboard-tui.sh` | Key loop, frame builder, terminal lifecycle |
| `README.md` / `README.zh.md` | Command table + a "dashboard (interactive view)" section with the key map |
| `docs/module-spec.md` | §Status template / CLI surface: two commands, two semantics (the current text says "merged") |
| `AGENTS.md` | Verb table += `dashboard`; TUI pitfalls (terminal restore, display width, pty testing) |
| `tests/` | 3–4 new suites + `tests/README.md` inventory (docs gate checks it) |
| **Untouched** | **all of `tools/**`** — no module contract change, no nine module bumps; only the manager version bumps |

## 9. Risk register

| Risk | Mitigation |
|---|---|
| Terminal left broken (classic TUI accident) | exact `stty` save/restore + idempotent trap + alternate screen + `reset` hint for `kill -9` |
| Sampling slows the interaction | UI reads files only; sampler is a separate process with hard budgets; `stale` flag keeps the last good snapshot |
| Scope creep ("full htop") | four phases, P1 ships without interaction; each phase independently useful |
| Accidental run in ssh/CI | non-TTY auto-degrades to a single frame instead of erroring |
| Wide-character alignment (CJK/emoji) | display-width helper + whole-string truncation + frame assertions; data columns stay ASCII |
| pty testing inside the test image | keys are an injectable fd (`AIBOX_DASH_KEYS`) so the core cases need no pty; the pty case is optional and requires `expect` in the test image (or runs in CI's macOS job) |
| Interactive acceptance vs "no aibox runs on the host" | interactive feel can only be verified in a real terminal: handled as a deployment/acceptance step on a dedicated machine per AGENTS §Test environment — never as a host-side test run |

## 10. Open items for the operator

1. **pty test tooling**: add `expect` to `tests/docker/Dockerfile` (so a pty smoke case runs in the
   harness) or keep the pty case CI-only (macOS job).
2. **Interactive acceptance host**: confirm the machine where the interactive feel is signed off
   (a dedicated/throwaway terminal session), per the rule that host-side runs are deployment steps.
3. **`dashboard --json` consumers**: confirm nobody scripts against `status --json` fields that
   would move (the design keeps `status --json` untouched; only additions).
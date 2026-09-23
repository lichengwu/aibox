# Dashboard app/module version + keyline template — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every aibox dashboard shows the deployed app version (cyan, header) and the aibox module version (dim, sunk row), rendered through one shared keyline template.

**Architecture:** Shared `dash_*` render helpers live in `tools/_shared/common.sh` (ships into every module cache as `_common.sh`); `bin/aibox` inlines the same template (single-file CLI, cannot source the include); each module's `render_dashboard` is converted to the helpers and gains an `app_version()` source; `dashboard_info`'s `version=` key (name unchanged) feeds the manager views' header and the async updates comparison.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), bats test framework, zero new runtime deps.

**Spec:** `docs/superpowers/specs/2026-09-23-dashboard-app-version-keyline-design.md` — the plan argues from the spec; read both.

## Global Constraints

- bash 3.2 compatible (macOS `/bin/bash`); hooks run `set -euo pipefail`; no bash-4 syntax.
- Always `${VAR}` braces (pitfall #1: non-ASCII adjacent to `$VAR` breaks under UTF-8 + `set -u`).
- ASCII labels only in the `%-10s` grid field; values NEVER byte-sliced — CJK stays ragged-right (pitfall #6); `─ ✓ ⚠ ○ ·` are complete string literals, never concatenated/sliced.
- Colors: the existing palette only (`C_BOLD C_DIM C_GRN C_YEL C_RED C_CYA C_RST`), via `${C_*:-}` fallbacks (helpers must be standalone-safe); TTY + NO_COLOR gated by the existing scheme; no new color codes.
- Rule width: TTY → `tput cols` clamped [40, 72]; non-TTY → fixed 64 (stable for pipes/tests).
- `dashboard_info`'s `version=` KEY NAME stays (stale-cache compatibility); only its rendered label changes (`upstream:` → header segment / `app:`).
- bats: every mid-test `[[ ]]`/`[ ]` assertion this plan writes or touches gets `|| false` (pitfall #10: macOS bash 3.2 swallows failing `[[ ]]` mid-test). Final line of a test is safe bare.
- Conventional Commits (`feat:` / `fix:` / `docs:` / `chore:`); each module task bumps that module's `module.yaml` `version:`.
- Test invocation from repo root: `bats tests/<file>.bats`; full gate: `bats tests/*.bats`; validator: `bash scripts/validate-module.sh <module>` / `--all`.

## Review Focus

1. **CJK values byte-sliced** (clash node names in `dash_row` values) → expected: verbatim pass-through, ragged right. Test: Task 1 dash_row CJK case.
2. **Piped/NO_COLOR output leaks ANSI or unstable width** → expected: identical shapes, rule exactly 64 `─`. Tests: Task 1 no-escape assert; Tasks 2/3 run through bats (non-TTY) exact-shape asserts.
3. **Stale module cache** (old lib.sh: no `version=`, no `dash_header`) → expected: manager views render with dim module-version fallback, no crash. Tests: Task 2 (base mock without `version=` asserts `✓ base 1.2.1`), Task 3 (`base 1.2.1` header).
4. **npm absent / `npm ls` failing under `set -e`** (pi-web `app_version`) → expected: empty string, exit 0. Test: Task 4 `app_version` sandbox test with stripped PATH.
5. **Dead probes killing render under `set -euo pipefail`** (curl 000, launchctl/systemctl absent, docker absent) → expected: degraded rows, exit 0. Tests: Task 4 no-deployment render; Task 7 clash/base render smoke.

---

### Task 1: `dash_*` keyline helpers in `_shared/common.sh`

**Files:**
- Modify: `tools/_shared/common.sh` (append after the output-helpers block, before the docker pool section)
- Create: `tests/dash-template.bats`

**Interfaces:**
- Consumes: exported `C_BOLD C_DIM C_GRN C_YEL C_CYA C_RST` (all `${...:-}` fallback).
- Produces (used by Tasks 4–8): `dash_header <name> <appver|""> <state>` (prints header line + rule line), `dash_row <label> <value>`, `dash_module_row <mver> <mdir>`, `dash_rule`, `dash_secheader <title>`; internal `_dash_width`, `_dash_rule_n`, `_dash_state_seg`. State words: `ok|running` → `✓ <word>` green, `starting` → `⚠` yellow, `stopped` → `○` dim, `na`/other/empty → no segment.

- [ ] **Step 1: Write the failing test** — create `tests/dash-template.bats`:

```bash
#!/usr/bin/env bats
# dash_* keyline template helpers (tools/_shared/common.sh).
# Spec: docs/superpowers/specs/2026-09-23-dashboard-app-version-keyline-design.md §4-5.
# Assertions carry `|| false` — pitfall #10 (macOS bash 3.2 swallows failing
# [[ ]] mid-test under set -e).
# Sourcing standalone: no C_* exported → plain output; non-TTY → rule width 64.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091
  . "$REPO_ROOT/tools/_shared/common.sh"
}

@test "dash_header: name + app version + state word, then the rule" {
  run dash_header "pi-web" "0.9.3" "ok"
  [ "$status" -eq 0 ] || false
  [ "${lines[0]}" = "pi-web 0.9.3 · ✓ ok" ] || false
  [ "${lines[1]}" = "$(printf '─%.0s' $(seq 1 64))" ] || false
}

@test "dash_header: empty app version / na state omit their segments" {
  run dash_header "base" "" ""
  [ "${lines[0]}" = "base" ] || false
  run dash_header "openmaic" "" "na"
  [ "${lines[0]}" = "openmaic" ] || false
}

@test "dash_header: state words map icons (running ✓ / starting ⚠ / stopped ○)" {
  run dash_header "m" "1" "running"
  [[ "${lines[0]}" == *"✓ running" ]] || false
  run dash_header "m" "1" "starting"
  [[ "${lines[0]}" == *"⚠ starting" ]] || false
  run dash_header "m" "1" "stopped"
  [[ "${lines[0]}" == *"○ stopped" ]] || false
}

@test "dash_row: %-10s label grid, no colon; value verbatim (CJK never truncated)" {
  run dash_row "endpoint" "http://127.0.0.1:30141 · HTTP 307"
  [ "$output" = "  endpoint   http://127.0.0.1:30141 · HTTP 307" ] || false
  run dash_row "kernel" "日本-TY-4-HY2-流量倍率:0.6 16ms"
  [[ "$output" == *"日本-TY-4-HY2-流量倍率:0.6 16ms" ]] || false
}

@test "dash_module_row: sunk row — version + path, grid-consistent" {
  run dash_module_row "1.3.5" "/home/u/.aibox/modules/pi-web/"
  [ "$output" = "  module     1.3.5 · /home/u/.aibox/modules/pi-web/" ] || false
}

@test "dash_secheader: ── title ──… reaches the rule width" {
  run dash_secheader "profile base (active)"
  [[ "$output" == "── profile base (active) ─"* ]] || false
  [[ "$output" == *$(printf '─%.0s' $(seq 1 3)) ]] || false
}

@test "dash_rule: non-TTY = exactly 64 complete ─ literals, zero ANSI escapes" {
  run dash_rule
  [ "$output" = "$(printf '─%.0s' $(seq 1 64))" ] || false
  case "$output" in *$'\033'*) false ;; *) : ;; esac
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats tests/dash-template.bats`
Expected: FAIL — `dash_header: command not found` on every test.

- [ ] **Step 3: Implement** — insert into `tools/_shared/common.sh` right after the `die()` helper (before the docker pool comment block):

```bash
# ---------- dashboard keyline template (spec §Dashboard template) ----------
# Shared render helpers for module-owned rich views (render_dashboard); the
# manager (bin/aibox, a single-file CLI that cannot source this file) inlines
# the SAME shapes — keep them in sync via the spec. Plain (NO_COLOR) shapes:
#   <name> <appver> · ✓ running
#   ─────────────────────────────────────────────────────────────────
#     service    launchd · pid 38243
#     module     1.3.5 · ~/.aibox/modules/<name>/        (whole row dim)
# Colors inherit aibox's exported C_* (empty standalone → plain). Rule width:
# TTY → tput cols clamped [40,72]; non-TTY → 64 (pipes/tests get a stable
# shape). Rules repeat COMPLETE ─ literals — never sliced (pitfall #6).

_dash_width() { # prints the rule width for this context
  local w=64
  if [ -t 1 ] 2>/dev/null && command -v tput >/dev/null 2>&1; then
    w="$(tput cols 2>/dev/null || echo 64)"
    case "${w}" in '' | *[!0-9]*) w=64 ;; esac
    [ "${w}" -lt 40 ] && w=40
    [ "${w}" -gt 72 ] && w=72
  fi
  printf '%s' "${w}"
}

_dash_rule_n() { # $1=count → that many complete ─ literals
  local i=0
  while [ "${i}" -lt "${1}" ]; do
    printf '─'
    i=$(( i + 1 ))
  done
}

dash_rule() { # the dim horizontal rule
  printf '%s%s%s\n' "${C_DIM:-}" "$(_dash_rule_n "$(_dash_width)")" "${C_RST:-}"
}

# state word → colored "<icon> <word>" segment; empty for na/unknown words
_dash_state_seg() { # $1=state word (ok|running|starting|stopped|na|"")
  case "${1:-}" in
  ok | running) printf '%s✓ %s%s' "${C_GRN:-}" "${1}" "${C_RST:-}" ;;
  starting) printf '%s⚠ %s%s' "${C_YEL:-}" "${1}" "${C_RST:-}" ;;
  stopped) printf '%s○ %s%s' "${C_DIM:-}" "${1}" "${C_RST:-}" ;;
  *) printf '' ;;
  esac
}

dash_header() { # $1=name $2=app_version (""=omit) $3=state word (see _dash_state_seg)
  local seg
  printf '%s%s%s' "${C_BOLD:-}" "${1}" "${C_RST:-}"
  [ -n "${2}" ] && printf ' %s%s%s' "${C_CYA:-}" "${2}" "${C_RST:-}"
  seg="$(_dash_state_seg "${3:-}")"
  [ -n "${seg}" ] && printf ' %s·%s %s' "${C_DIM:-}" "${C_RST:-}" "${seg}"
  printf '\n'
  dash_rule
}

dash_row() { # $1=label (ASCII, ≤10 chars) $2=value (verbatim; may embed color spans)
  printf '  %s%-10s%s %s\n' "${C_DIM:-}" "${1}" "${C_RST:-}" "${2}"
}

dash_module_row() { # $1=module_version $2=module_dir — sunk, whole row dim
  printf '  %s%-10s %s · %s%s\n' "${C_DIM:-}" "module" "${1:-\?}" "${2:-}" "${C_RST:-}"
}

dash_secheader() { # $1=title (ASCII) → "── title ───…" to the rule width
  local n
  n=$(( $(_dash_width) - ${#1} - 6 ))
  [ "${n}" -lt 3 ] && n=3
  printf '%s%s── %s%s%s %s%s%s\n' \
    "${C_DIM:-}" "" "${C_BOLD:-}${C_CYA:-}" "${1}" "${C_RST:-}" \
    "${C_DIM:-}" "$(_dash_rule_n "${n}")" "${C_RST:-}"
}
```

Note: every function's last statement is a successful `printf` (or `dash_rule`) — safe under the caller's `set -e`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/dash-template.bats`
Expected: 7/7 PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/_shared/common.sh tests/dash-template.bats
git commit -m "feat: dash_* keyline template helpers (shared dashboard rendering)"
```

---

### Task 2: manager overview — keyline blocks + section headers

**Files:**
- Modify: `bin/aibox` — `_dash_block` (≈ line 2626), `cmd_dashboard_overview` (≈ line 2711: profile/residue/updates headers), plus four new inline helpers near `_dash_block`.
- Test: `tests/cli-surface.bats` (3 tests updated)

**Interfaces:**
- Consumes: `dashboard_info` keys (`state`, `version`, `endpoint`, `credential`, `log`, `health`, other), `_module_meta_local` ports, `_port_is_listening` (all existing).
- Produces: overview block shape (used by nothing else; contract is visual). `_dash_width`/`_dash_rule_n`/`_dash_rule_line`/`_dash_secheader` — inline manager twins of Task 1's helpers (Task 3 consumes `_dash_rule_line`).

- [ ] **Step 1: Update the failing tests first** — in `tests/cli-surface.bats`:

In `dashboard overview: local-first (dead network OK), per-profile sections, module blocks`:
- after the existing `[[ "$output" == *"profile base"* ]]`, keep it but append `|| false` (pitfall #10 discipline for touched lines); same for `*"profile work"*`.
- replace `[[ "$output" == *"✓ new-api 1.0.1"* ]]` with:
```bash
  [[ "$output" == *"✓ new-api 0.13.2"* ]] || false        # app version in the header
```
- keep `[[ "$output" == *"✓ base 1.2.1"* ]] || false` (base mock has no version= → dim module-version fallback).
- replace `[[ "$output" == *"endpoint: pg://127.0.0.1:35432"* ]]` and `*"endpoint: http://127.0.0.1:30300"*` with (health merged, colon-free grid):
```bash
  [[ "$output" == *"pg://127.0.0.1:35432 · ok"* ]] || false
  [[ "$output" == *"endpoint"*"http://127.0.0.1:30300"* ]] || false
```
- replace `[[ "$output" == *"upstream: v0.13.2"* ]]` with:
```bash
  [[ "$output" != *"upstream:"* ]] || false               # version= is header-only now
  [[ "$output" == *"module"*"·"*"modules/new-api/"* ]] || false   # sunk module row
```

In `dashboard overview: empty state + residue section for not-installed leftovers`:
- keep `*"✓ base"*` (add `|| false`), keep `*"residue"*`/`*"gitlab"*`/`!= *"✓ gitlab"*` (add `|| false`).

In `dashboard overview: state= contract renders the composite icon + word`:
- `ok)` branch: `[[ "$output" == *"✓ new-api 1.1.1"* ]] || false` and `[[ "$output" != *"· ok"* ]] || false` (the state word is gone — icon only).
- `starting)`: `[[ "$output" == *"⚠ new-api 1.1.1"* ]] || false`
- `stopped)`: `[[ "$output" == *"○ new-api 1.1.1"* ]] || false` and
```bash
      [[ "$output" == *"http://127.0.0.1:30300 (stopped — aibox new-api start)"* ]] || false
```
- `na)`: keep `[[ "$output" == *"  new-api 1.1.1"* ]] || false` and the `!=` icon asserts.

In `dashboard overview: stale cache without state= falls back to the port heuristic`: add `|| false` to both asserts.

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/cli-surface.bats`
Expected: the 3 overview tests FAIL (old header/rows/labels).

- [ ] **Step 3: Implement** — in `bin/aibox`, add above `_dash_block` (inline manager twins; the manager never sources `_shared/common.sh`):

```bash
# keyline template inline twins (spec §Dashboard template) — same shapes as
# tools/_shared/common.sh's dash_* helpers; keep in sync via the spec.
_dash_width() {
  local w=64
  if [ -t 1 ] 2>/dev/null && command -v tput >/dev/null 2>&1; then
    w="$(tput cols 2>/dev/null || echo 64)"
    case "${w}" in '' | *[!0-9]*) w=64 ;; esac
    [ "${w}" -lt 40 ] && w=40
    [ "${w}" -gt 72 ] && w=72
  fi
  printf '%s' "${w}"
}
_dash_rule_n() {
  local i=0
  while [ "${i}" -lt "${1}" ]; do
    printf '─'
    i=$(( i + 1 ))
  done
}
_dash_rule_line() { printf '%s%s%s\n' "${C_DIM}" "$(_dash_rule_n "$(_dash_width)")" "${C_RST}"; }
_dash_secheader() { # $1=title (ASCII) → "── title ───…"
  local n
  n=$(( $(_dash_width) - ${#1} - 6 ))
  [ "${n}" -lt 3 ] && n=3
  printf '\n%s%s── %s%s%s %s%s%s\n' \
    "${C_DIM}" "" "${C_BOLD}${C_CYA}" "${1}" "${C_RST}" \
    "${C_DIM}" "$(_dash_rule_n "${n}")" "${C_RST}"
}
```

Replace the whole `_dash_block` body with:

```bash
# Render ONE module block from LOCAL data (cache lib.sh dashboard_info +
# cache module.yaml ports) — keyline template (spec §Dashboard template).
# The app version (dashboard_info version=, v-stripped, full string shown) is
# the cyan header segment; its FIRST token is written to $3 for the async
# updates comparison. Module version is the dim fallback when version= is
# absent (stale caches) and the sunk module row otherwise.
# $4 = profile: module-level state marking is default-profile only — a named
# profile's ports are DERIVED, so the declared-port probe would false-mark.
_dash_block() { # $1=module $2=module-version $3=cur-upstream-outfile $4=profile
  local m="$1" mver="$2" cur_out="$3" prof="${4:-base}" info aver
  local mstate ports entry port h down="0" sym="" running="0"
  info=""
  [ -f "$AIBOX_MOD_DIR/$m/lib.sh" ] && \
    info="$(AIBOX_MODULE="$m" AIBOX_HOME="$AIBOX_HOME" bash -c ". '$AIBOX_MOD_DIR/$m/lib.sh' 2>/dev/null && type dashboard_info >/dev/null 2>&1 && dashboard_info 2>/dev/null || true" 2>/dev/null)"
  aver="$(printf '%s\n' "${info}" | sed -n 's/^version=//p' | head -1)"
  aver="${aver#v}"
  if [ -n "${cur_out}" ]; then
    printf '%s\n' "${aver%% *}" >"${cur_out}" 2>/dev/null || true
  fi
  # module state: the machine-readable state= contract (module's lib.sh probes
  # locally; local-first holds); ICON ONLY on the header (no state word — the
  # endpoint row's merged health carries the nuance).
  #   ok=✓ (green) · starting=⚠ (yellow) · stopped=○ (dim) · na=(none — CLI modules)
  # Fallback for stale caches without state=: declared-port listening heuristic
  # (default profile only).
  mstate="$(printf '%s\n' "${info}" | sed -n 's/^state=//p' | head -1)"
  ports="$(_module_meta_local "${m}" ports)"
  case "${mstate}" in
    ok)       sym="${C_GRN}✓${C_RST}" ;;
    starting) sym="${C_YEL}⚠${C_RST}" ;;
    stopped)  sym="${C_DIM}○${C_RST}"; down="1" ;;
    na)       sym="" ;;
    *)
      if [ -n "${ports}" ] && [ "${prof}" = "base" ]; then
        for entry in ${ports}; do
          _port_is_listening "${entry%%/*}" && running="1"
        done
        if [ "${running}" = "1" ]; then
          sym="${C_GRN}✓${C_RST}"
        else
          sym="${C_DIM}○${C_RST}"; down="1"
        fi
      else
        sym="${C_GRN}✓${C_RST}"
      fi
      ;;
  esac
  # header: icon + bold name + version (app version cyan; module-version dim)
  printf '  %s%s%s%s' "${sym:+${sym} }" "${C_BOLD}" "${m}" "${C_RST}"
  if [ -n "${aver}" ]; then
    printf ' %s%s%s\n' "${C_CYA}" "${aver}" "${C_RST}"
  else
    printf ' %s%s%s\n' "${C_DIM}" "${mver}" "${C_RST}"
  fi
  # rows: endpoint (health merged / stopped hint), auth, log, other keys
  printf '%s\n' "${info}" | while IFS='=' read -r k v; do
    [ -n "${k}" ] || continue
    # state= feeds the header icon; version= the header segment — never rows
    [ "${k}" = "state" ] && continue
    [ "${k}" = "version" ] && continue
    [ "${k}" = "credential" ] && k="auth"
    if [ "${k}" = "endpoint" ]; then
      h="$(printf '%s\n' "${info}" | sed -n 's/^health=//p' | head -1)"
      if [ "${down}" = "1" ]; then
        v="${v} ${C_DIM}(stopped — aibox ${m} start)${C_RST}"
      elif [ -n "${h}" ]; then
        v="${v} ${C_DIM}·${C_RST} ${h}"
      fi
    fi
    printf '     %s%-10s%s %s\n' "${C_DIM}" "${k}" "${C_RST}" "${v}"
  done
  # ports from LOCAL metadata + listen marks
  if [ -n "${ports}" ]; then
    local plist="" mark
    for entry in ${ports}; do
      port="${entry%%/*}"
      if _port_is_listening "${port}"; then mark="${C_GRN}✓${C_RST}"; else mark="${C_DIM}—${C_RST}"; fi
      plist="${plist:+${plist}  }${entry} ${mark}"
    done
    printf '     %s%-10s%s %s\n' "${C_DIM}" "ports" "${C_RST}" "${plist}"
  fi
  printf '     %s%-10s %s · %s%s%s\n' "${C_DIM}" "module" "${C_DIM}" "${mver}" "${AIBOX_MOD_DIR}/${m}/" "${C_RST}"
}
```

In `cmd_dashboard_overview`, replace the three section-header printfs:
- `printf '\n%s%sprofile %s%s%s\n' "${C_BOLD}" "${C_CYA}" "${p}${tag}" "${C_DIM}" "${C_RST}"` → `_dash_secheader "profile ${p}${tag}"`
- `printf '\n%s%sresidue%s\n' "${C_BOLD}" "${C_CYA}" "${C_RST}"` → `_dash_secheader "residue"`
- `printf '\n%s%supdates%s\n' "${C_BOLD}" "${C_CYA}" "${C_RST}"` → `_dash_secheader "updates"`

- [ ] **Step 4: Run tests**

Run: `bats tests/cli-surface.bats`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add bin/aibox tests/cli-surface.bats
git commit -m "feat: dashboard overview — keyline blocks, app version in header, module row sunk"
```

---

### Task 3: manager generic detail view — keyline

**Files:**
- Modify: `bin/aibox` — `cmd_dashboard_detail` (≈ line 2828)
- Test: `tests/cli-surface.bats` (detail test)

**Interfaces:**
- Consumes: `_dash_rule_line` (Task 2), `_module_meta_local`, `_port_is_listening`, `dashboard_info` keys.
- Produces: the generic detail shape (`aibox dashboard <module>` for modules without a module-owned rich view).

- [ ] **Step 1: Update the failing test** — in `tests/cli-surface.bats`, test `dashboard detail: local-first — installed module renders with a dead registry`:
- replace `[[ "$output" == *"base v1.2.1"* ]]` with `[[ "$output" == *"base 1.2.1"* ]] || false` (dim module-version fallback, no `v` prefix);
- replace `[[ "$output" == *"installed"* ]]` with:
```bash
  [[ "$output" == *"module"*"·"*"modules/base/"* ]] || false   # sunk module row
  [[ "$output" == *"pg://127.0.0.1:35432 · ok"* ]] || false    # health merged into endpoint
```
- keep the `!= *"Failed to fetch module list"*` assert (add `|| false`).

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/cli-surface.bats`
Expected: detail test FAILs.

- [ ] **Step 3: Implement** — replace `cmd_dashboard_detail` body:

```bash
cmd_dashboard_detail() {
  # local-first keyline detail (spec §Dashboard template): app version (dim
  # module-version fallback) in the header, live HTTP probe merged into the
  # endpoint row, sunk module row. Raw diagnostics stay in the module's
  # diagnose action.
  local name="$1" ver hint info aver endpoint cred logf health state sym code ports entry port mark plist
  if [ ! -f "${AIBOX_MOD_DIR}/$name/module.yaml" ] && ! _installed_any_profile "$name"; then
    load_registry
    module_exists "$name" || die "Unknown module: $name"
  fi
  ver="$(_module_version_local "$name")"
  [ -n "${ver}" ] || ver="$(module_field "$name" version)"
  if ! is_installed "$name"; then
    warn "$name is not installed"
    hint="$(module_field "$name" dashboard_hint)"
    [ -n "${hint}" ] || hint="(registry offline; catalog: aibox dashboard --available)"
    info "credentials: ${hint}"
    info "install: aibox install $name"
    return 0
  fi
  info="$(AIBOX_MODULE="$name" AIBOX_HOME="$AIBOX_HOME" bash -c ". '$AIBOX_MOD_DIR/$name/lib.sh' 2>/dev/null && dashboard_info 2>/dev/null || true" 2>/dev/null)"
  aver="$(printf '%s\n' "$info" | sed -n 's/^version=//p' | head -1)"
  aver="${aver#v}"
  endpoint=$(printf '%s\n' "$info" | sed -n 's/^endpoint=//p')
  cred=$(printf '%s\n' "$info" | sed -n 's/^credential=//p')
  logf=$(printf '%s\n' "$info" | sed -n 's/^log=//p')
  health=$(printf '%s\n' "$info" | sed -n 's/^health=//p')
  state="$(printf '%s\n' "$info" | sed -n 's/^state=//p' | head -1)"
  sym=""
  case "${state}" in
  ok)       sym="${C_GRN}✓ ok${C_RST}" ;;
  starting) sym="${C_YEL}⚠ starting${C_RST}" ;;
  stopped)  sym="${C_DIM}○ stopped${C_RST}" ;;
  esac
  printf '%s%s%s' "$C_BOLD" "$name" "$C_RST"
  if [ -n "$aver" ]; then
    printf ' %s%s%s' "$C_CYA" "$aver" "$C_RST"
  else
    printf ' %s%s%s' "$C_DIM" "${ver:-\?}" "$C_RST"
  fi
  [ -n "$sym" ] && printf ' %s·%s %s' "$C_DIM" "$C_RST" "$sym"
  printf '\n'
  _dash_rule_line
  if [ -n "$endpoint" ]; then
    local verdict=""
    case "$endpoint" in
    http://*|https://*)
      code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$endpoint" 2>/dev/null) || code="000"
      [ -n "$code" ] || code="000"
      case "$code" in
      200|204|301|302|307|308|401) verdict=" ${C_DIM}·${C_RST} ${C_GRN}✓${C_RST} HTTP $code" ;;
      000) verdict=" ${C_DIM}(unreachable)${C_RST}" ;;
      *) verdict=" ${C_DIM}·${C_RST} HTTP $code" ;;
      esac ;;
    *) [ -n "$health" ] && verdict=" ${C_DIM}·${C_RST} $health" ;;
    esac
    printf '  %s%-10s%s %s%s\n' "$C_DIM" "endpoint" "$C_RST" "$endpoint" "$verdict"
  elif [ -n "$health" ]; then
    printf '  %s%-10s%s %s\n' "$C_DIM" "health" "$C_RST" "$health"
  fi
  [ -n "$cred" ] && printf '  %s%-10s%s %s\n' "$C_DIM" "auth" "$C_RST" "$cred"
  [ -n "$logf" ] && printf '  %s%-10s%s %s\n' "$C_DIM" "log" "$C_RST" "$logf"
  plist=""
  ports="$(_module_meta_local "$name" ports)"
  if [ -n "$ports" ]; then
    for entry in ${ports}; do
      port="${entry%%/*}"
      if _port_is_listening "${port}"; then mark="${C_GRN}✓${C_RST}"; else mark="${C_DIM}—${C_RST}"; fi
      plist="${plist:+${plist}  }${entry} ${mark}"
    done
    printf '  %s%-10s%s %s\n' "$C_DIM" "ports" "$C_RST" "$plist"
  fi
  printf '  %s%-10s %s · %s%s%s\n' "$C_DIM" "module" "${C_DIM}" "${ver:-\?}" "$AIBOX_MOD_DIR/$name/" "$C_RST"
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/cli-surface.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/aibox tests/cli-surface.bats
git commit -m "feat: dashboard detail view — keyline template with app version + live probe merged"
```

---

### Task 4: pi-web module — app version + keyline rich view

**Files:**
- Modify: `tools/pi-web/lib.sh` (add `app_version()`; rewrite `dashboard_info` version+health mapping; rewrite `render_dashboard`), `tools/pi-web/svc.sh` (status/dashboard split), `tools/pi-web/module.yaml` (1.3.5 → 1.4.0)
- Test: `tests/pi-web-npm.bats` (2 tests rewritten, 2 added)

**Interfaces:**
- Consumes: `dash_header`/`dash_row`/`dash_module_row` (Task 1), `MODULE_VERSION` (existing), `resolve_password` (existing).
- Produces: `app_version()` → prints the installed `@agegr/pi-web` npm version or empty; `dashboard_info` now emits `version=` (when known) and maps 2xx/301/302/307/308/401 → `state=ok`.

- [ ] **Step 1: Write the failing tests** — in `tests/pi-web-npm.bats`, REPLACE the two `render_dashboard` tests and ADD two new tests:

```bash
@test "app_version: empty when npm or the package is absent (no die under set -e)" {
  local sb
  sb="$(mktemp -d)"
  run bash -c "set -euo pipefail; HOME='$sb'; PATH=/usr/bin:/bin; . '$REPO_ROOT/tools/pi-web/lib.sh'; app_version"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || false
}

@test "dashboard_info: keeps the endpoint/state contract; state ok on redirects" {
  local sb
  sb="$(mktemp -d)"
  out="$(HOME="$sb" bash -c ". '$REPO_ROOT/tools/pi-web/lib.sh'; dashboard_info" 2>/dev/null)"
  printf '%s\n' "$out" | grep -q '^endpoint=http://127.0.0.1:30141$' || false
  printf '%s\n' "$out" | grep -q '^state=stopped$' || false   # nothing listens in the sandbox
  printf '%s\n' "$out" | grep -q '^credential=Username pi / password ' || false
}

@test "render_dashboard: keyline template, no unbound variables under set -u" {
  # live-caught history: the SERVICE_ID crash — render_dashboard must degrade
  # gracefully with NO deployment at all (fresh sandbox HOME).
  local sb
  sb="$(mktemp -d)"
  run bash -c "set -euo pipefail; HOME='$sb'; . '$REPO_ROOT/tools/pi-web/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"· module"* ]] || false                  # ambiguous header gone
  [ "${lines[1]}" = "$(printf '─%.0s' $(seq 1 64))" ] || false   # rule, non-TTY width
  [[ "$output" == *"not running"* || "$output" == *"inactive"* ]] || false
  [[ "$output" == *"endpoint"*"http://127.0.0.1:30141"* ]] || false
  [[ "$output" == *"module"*"·"*"modules/pi-web/"* ]] || false  # sunk module row
  rm -rf "$sb"
}

@test "render_dashboard: running service detected via the label" {
  launchctl print "gui/$(id -u)/pi-web" >/dev/null 2>&1 || skip "no local pi-web service"
  run bash -c ". '$REPO_ROOT/tools/pi-web/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || false
  [[ "$output" == *"launchd"*"pid "* ]] || false
  [[ "$output" == *"pi-web"*"· ✓" || "$output" == *"pi-web"*"⚠" ]] || false
}
```

Note: the sandboxed render still sees the machine-global npm package and a possibly-live 30141 listener — the asserts above are union-shaped on purpose (only structural claims).

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/pi-web-npm.bats`
Expected: new tests FAIL (`app_version: command not found`; `· module` still in header; `lines[1]` is a detail row not the rule).

- [ ] **Step 3: Implement**

In `tools/pi-web/lib.sh` — add after the `MODULE_VERSION=` line:

```bash
# Deployed app version: the @agegr/pi-web npm package installed globally
# (local read, ~0.7s, no network). Empty when npm or the package is absent —
# callers omit the segment (update.sh's npm_registry_pick is the network path).
app_version() {
  command -v npm >/dev/null 2>&1 || return 0
  npm ls -g @agegr/pi-web --depth=0 2>/dev/null |
    grep -oE '@agegr/pi-web@[0-9][0-9A-Za-z.-]*' | head -1 | sed 's/.*@//' || true
}
```

Replace `dashboard_info()`:

```bash
# Dashboard interface (machine-readable; the manager's views render it).
# version= is the app version contract key (spec §Dashboard template).
# Health classes align with the manager's verdict table: 2xx + 3xx + 401 =
# alive (a 307 redirect to the UI was previously mis-reported "starting").
dashboard_info() {
  resolve_password
  local v code
  v="$(app_version)"
  [ -n "${v}" ] && echo "version=${v}"
  echo "endpoint=http://127.0.0.1:${PORT}"
  echo "credential=Username pi / password ${PASSWORD}"
  echo "log=${LOG_DIR}/pi-web.log"
  code="$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  case "${code}" in
  200 | 204 | 301 | 302 | 307 | 308 | 401)
    echo "state=ok"
    echo "health=ok (HTTP ${code}, basic auth pi)"
    ;;
  000 | "")
    echo "state=stopped"
    echo "health=stopped (no listener on :${PORT})"
    ;;
  *)
    echo "state=starting"
    echo "health=starting (HTTP ${code})"
    ;;
  esac
}
```

Replace `render_dashboard()` (keep the raw `launchctl`/`lsof` dumps in `diagnose` only):

```bash
# ---------- dashboard (the module's rich view — keyline template) ----------
render_dashboard() {
  resolve_password
  local aver code state svc="" _pid="" _lcout
  aver="$(app_version)"
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -u "pi:${PASSWORD}" "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
  [ -z "${code}" ] && code="000"
  case "$(uname -s)" in
  Darwin)
    _lcout="$(launchctl print "gui/${UID_}/${LABEL}" 2>/dev/null || true)"
    _pid="$(printf '%s\n' "${_lcout}" | awk '/^[[:space:]]*pid[[:space:]]*=/{print $3; exit}')"
    if printf '%s\n' "${_lcout}" | grep -qE 'state[[:space:]]*=[[:space:]]*running'; then
      if [ "${code}" = "000" ]; then
        state="starting"
        svc="launchd running · app not answering yet${_pid:+ (pid ${_pid})}"
      else
        state="running"
        svc="launchd${_pid:+ · pid ${_pid}}"
      fi
    else
      state="stopped"
      svc="not running (aibox pi-web start)"
    fi
    ;;
  *)
    if systemctl --user is-active "${LABEL}" >/dev/null 2>&1; then
      if [ "${code}" = "000" ]; then
        state="starting"
        svc="systemd active · app not answering yet"
      else
        state="running"
        svc="systemd active"
      fi
    else
      state="stopped"
      svc="inactive (aibox pi-web start)"
    fi
    ;;
  esac
  dash_header "pi-web" "${aver}" "${state}"
  dash_row "service" "${svc}"
  if [ "${code}" = "000" ]; then
    dash_row "endpoint" "http://127.0.0.1:${PORT} ${C_DIM:-}(stopped — aibox pi-web start)${C_RST:-}"
  else
    local mark=""
    case "${code}" in
    200 | 204 | 301 | 302 | 307 | 308 | 401) mark=" ${C_GRN:-}✓${C_RST:-}" ;;
    esac
    dash_row "endpoint" "http://127.0.0.1:${PORT}${C_DIM:-} · ${C_RST:-}HTTP ${code}${mark}"
  fi
  dash_row "auth" "pi / ${PASSWORD}"
  dash_row "log" "${LOG_DIR}/pi-web.log"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/pi-web/"
}
```

In `tools/pi-web/svc.sh` — replace the `status | dashboard)` branch:

```bash
# status/dashboard: the keyline rich view only — it carries the service state,
# pid, endpoint + HTTP verdict; raw launchctl/systemctl/lsof dumps live in
# `diagnose` (dashboard 精修: no raw noise above the view).
status | dashboard)
  render_dashboard
  ;;
```

In `tools/pi-web/module.yaml`: `version: 1.3.5` → `version: 1.4.0`.

- [ ] **Step 4: Run tests**

Run: `bats tests/pi-web-npm.bats && bats tests/dash-template.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/pi-web/lib.sh tools/pi-web/svc.sh tools/pi-web/module.yaml tests/pi-web-npm.bats
git commit -m "feat(pi-web): app version + keyline rich view; redirect=healthy; raw dumps stay in diagnose (module 1.4.0)"
```

---

### Task 5: new-api + dify — app version + keyline rich views

**Files:**
- Modify: `tools/new-api/lib.sh`, `tools/dify/lib.sh` (MODULE_VERSION yaml-read fix, `app_version()`, keyline `render_dashboard`), `tools/new-api/module.yaml` (1.1.4 → 1.2.0), `tools/dify/module.yaml` (1.18.4 → 1.19.0)
- Test: `tests/new-api.bats` (1 test added)

**Interfaces:**
- Consumes: `dash_header`/`dash_row`/`dash_module_row` (Task 1).
- Produces: `app_version()` in each lib (docker-image tag), keyline render shape.

- [ ] **Step 1: Write the failing test** — add to `tests/new-api.bats` (after the `dashboard_info` test):

```bash
@test "render_dashboard: keyline header (app version) + sunk module row" {
  export PATH="$FAKEBIN:$PATH"
  run bash -c ". '$REPO_ROOT/tools/new-api/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"new-api 0.13.2"* ]] || false                 # app version, not module
  [[ "$output" != *"· module"* ]] || false                       # old ambiguous header gone
  [[ "$output" == *"module"*"·"* ]] || false                     # sunk module row present
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/new-api.bats`
Expected: new test FAILs (`· module` header still there).

- [ ] **Step 3: Implement**

`tools/new-api/lib.sh`:
- line 5 `MODULE_VERSION="1.1.0"` (stale hardcode — module.yaml says 1.1.4) → replace with:
```bash
MODULE_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$(dirname "${BASH_SOURCE[0]}")/module.yaml" 2>/dev/null | head -1 || true)"
```
- add next to the dashboard section:
```bash
# Deployed app version: the docker image tag (dockerhub-style image:tag).
app_version() {
  local ver
  load_env
  ver="${NEW_API_IMAGE:-${DEFAULT_IMAGE}}"
  printf '%s' "${ver##*:}"
}
```
- `dashboard_info()`: replace `ver="${NEW_API_IMAGE:-${DEFAULT_IMAGE}}"; echo "version=${ver##*:}"` with `v="$(app_version)"; [ -n "${v}" ] && echo "version=${v}"` (add `local v` to its locals).
- replace `render_dashboard()` with:

```bash
# ---------- dashboard (the module's rich view — keyline template) ----------
render_dashboard() {
  load_env
  local port st state tbl="0"
  port="$(effective_port)"
  st="$(docker ps --filter "name=${CONTAINER}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1)"
  if [ -n "${st}" ] && api_up "${port}"; then
    state="ok"
  elif [ -n "${st}" ]; then
    state="starting"
  else
    state="stopped"
  fi
  dash_header "new-api" "$(app_version)" "${state}"
  if [ -n "${st}" ]; then
    dash_row "container" "${st}"
  else
    dash_row "container" "${C_YEL:-}not running (aibox new-api start)${C_RST:-}"
  fi
  if api_up "${port}"; then
    dash_row "app" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓ API up${C_RST:-}"
  elif [ -n "${st}" ]; then
    dash_row "app" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_YEL:-}starting${C_RST:-}"
  else
    dash_row "app" "http://127.0.0.1:${port}"
  fi
  tbl="$(docker exec aibox-base-postgres psql -U aibox -d new_api -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo 0)"
  [ "${tbl}" != "0" ] && dash_row "db" "shared PG new_api ${C_DIM:-}·${C_RST:-} ${tbl} tables"
  dash_row "auth" "first login: root / 123456 (change it immediately)"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/new-api/"
}
```

`tools/dify/lib.sh` (same pattern):
- add the MODULE_VERSION yaml-read (dify currently relies on a stale `1.17.2` printf fallback; module.yaml is 1.18.4) — same two lines as new-api, placed near the top.
- add:
```bash
# Deployed app version: the api container image tag.
app_version() {
  local ver
  load_env
  ver="${DIFY_API_IMAGE:-${DEFAULT_API_IMAGE}}"
  printf '%s' "${ver##*:}"
}
```
- `dashboard_info()`: replace the `ver=` + `echo "version=..."` pair with `v="$(app_version)"; [ -n "${v}" ] && echo "version=${v}"` (add `local v`).
- replace `render_dashboard()` with:

```bash
# ---------- dashboard (the module's rich view — keyline template) ----------
render_dashboard() {
  load_env
  local port n="" state
  port="$(effective_port)"
  n="$(docker ps --filter "name=dify-" --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
  if [ "${n}" -gt 0 ] && http_up "${port}"; then
    state="ok"
  elif [ "${n}" -gt 0 ]; then
    state="starting"
  else
    state="stopped"
  fi
  dash_header "dify" "$(app_version)" "${state}"
  if [ "${n}" -gt 0 ]; then
    dash_row "stack" "${n} containers ${C_DIM:-}·${C_RST:-} $(docker ps --filter 'name=dify-' --filter 'status=running' --format '{{.Names}}' 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')…"
  else
    dash_row "stack" "${C_YEL:-}not running (aibox dify start)${C_RST:-}"
  fi
  if http_up "${port}"; then
    dash_row "console" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓ HTTP up${C_RST:-}"
  elif [ "${n}" -gt 0 ]; then
    dash_row "console" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_YEL:-}starting (1-2 min)${C_RST:-}"
  fi
  if shared_base_enabled; then
    dash_row "db" "shared base (PG + redis via base.env)"
  else
    dash_row "db" "bundled postgres/redis"
  fi
  dash_row "auth" "first-visit INIT_PASSWORD (see: aibox dify credentials)"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/dify/"
}
```

- `tools/new-api/module.yaml`: 1.1.4 → 1.2.0. `tools/dify/module.yaml`: 1.18.4 → 1.19.0.

- [ ] **Step 4: Run tests**

Run: `bats tests/new-api.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/new-api tools/dify tests/new-api.bats
git commit -m "feat(new-api,dify): app version + keyline rich views; MODULE_VERSION read from module.yaml (fixes stale hardcodes)"
```

---

### Task 6: gitlab + xiaozhi — app version + keyline rich views

**Files:**
- Modify: `tools/gitlab/lib.sh`, `tools/xiaozhi/lib.sh`, `tools/gitlab/module.yaml` (1.3.5 → 1.4.0), `tools/xiaozhi/module.yaml` (1.1.4 → 1.2.0)
- Test: `tests/xiaozhi.bats` (1 test added)

**Interfaces:**
- Consumes: `dash_header`/`dash_row`/`dash_module_row` (Task 1), `load_env`/`http_up`/`container_running` (gitlab), `stack_running`/`console_up`/`server_running`/`ws_listening` (xiaozhi).
- Produces: `app_version()` per module; keyline render shape.

- [ ] **Step 1: Write the failing test** — add to `tests/xiaozhi.bats` (after its `dashboard_info` test; mirror its sandbox setup — fake docker, no listeners):

```bash
@test "render_dashboard: keyline header (server/web app versions) + sunk module row" {
  run bash -c ". '$REPO_ROOT/tools/xiaozhi/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"· module"* ]] || false
  [[ "$output" == *"xiaozhi"* ]] || false
  [[ "$output" == *"module"*"·"* ]] || false
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/xiaozhi.bats`
Expected: new test FAILs (`· module` in header).

- [ ] **Step 3: Implement**

`tools/gitlab/lib.sh`:
- add the MODULE_VERSION yaml-read lines near the top (replacing the stale `1.2.1` printf fallback);
- add:
```bash
# Deployed app version: the gitlab-ce image tag (19.2.6-ce.0).
app_version() {
  local img
  load_env
  img="${GITLAB_IMAGE:-$DEFAULT_IMAGE}"
  printf '%s' "${img##*:}"
}
```
- `dashboard_info()`: add `echo "version=$(app_version)"` as the first output line (before `endpoint=`).
- replace `render_dashboard()` with:

```bash
# ---------- dashboard (the module's rich view — keyline template) ----------
render_dashboard() {
  load_env
  local port st state code
  port="${GITLAB_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  st="$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Image}} {{.Status}}' 2>/dev/null | head -1)"
  if [ -n "${st}" ]; then
    if http_up "${port}"; then state="ok"; else state="starting"; fi
  else
    state="stopped"
  fi
  dash_header "gitlab" "$(app_version)" "${state}"
  if [ -n "${st}" ]; then
    dash_row "container" "${st}"
    code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    [ -z "${code}" ] && code="000"
    case "${code}" in
    2?? | 3?? | 401) dash_row "web" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_GRN:-}✓ HTTP ${code}${C_RST:-}" ;;
    *) dash_row "web" "http://127.0.0.1:${port} ${C_DIM:-}·${C_RST:-} ${C_YEL:-}HTTP ${code}${C_RST:-}" ;;
    esac
    dash_row "ssh" ":${GITLAB_SSH_PORT:-8922} (git over SSH)"
  else
    dash_row "container" "${C_YEL:-}not running (aibox gitlab start)${C_RST:-}"
  fi
  dash_row "auth" "root / initial password (see: aibox gitlab credentials)"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/gitlab/"
}
```

`tools/xiaozhi/lib.sh`:
- add the MODULE_VERSION yaml-read lines (replacing the stale `1.0.1` fallback);
- add:
```bash
# Deployed app version: "server <tag> / web <tag>" (two images).
app_version() {
  local sver hver
  load_env
  sver="${XIAOZHI_SERVER_IMAGE:-${DEFAULT_SERVER_IMAGE}}"
  hver="${XIAOZHI_WEB_IMAGE:-${DEFAULT_WEB_IMAGE}}"
  printf '%s / %s' "${sver##*:server_}" "${hver##*:web_}"
}
```
- `dashboard_info()`: replace the `sver=`/`hver=`/`echo "version=…"` lines with `v="$(app_version)"; [ -n "${v}" ] && echo "version=${v}"` (add `local v`).
- `render_dashboard()`: replace the header printf
  `printf '%s%sxiaozhi%s %s· module %s%s\n' … "${MODULE_VERSION:-1.0.1}" …` with
  `dash_header "xiaozhi" "$(app_version)" "${state}"` (compute `state` first: `stack_running && console_up && server_running && ws_listening` → `ok`; `stack_running` → `starting`; else `stopped` — same expressions `dashboard_info` uses); convert each `printf '  %s%-9s %s\n' "${C_DIM:-}" "<label>:" <value>` row to `dash_row "<label>" "<value>"`; append `dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/xiaozhi/"` as the last row. Keep the row ORDER and VALUES exactly as today (server / web / mysql rows).

- `tools/gitlab/module.yaml`: 1.3.5 → 1.4.0. `tools/xiaozhi/module.yaml`: 1.1.4 → 1.2.0.

- [ ] **Step 4: Run tests**

Run: `bats tests/xiaozhi.bats && bash scripts/validate-module.sh gitlab && bash scripts/validate-module.sh xiaozhi`
Expected: PASS / PASS / PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/gitlab tools/xiaozhi tests/xiaozhi.bats
git commit -m "feat(gitlab,xiaozhi): app version + keyline rich views; MODULE_VERSION from module.yaml"
```

---

### Task 7: clash + base — keyline rich views + `version=`

**Files:**
- Modify: `tools/clash/lib.sh`, `tools/base/lib.sh`, `tools/clash/module.yaml` (1.3.4 → 1.4.0), `tools/base/module.yaml` (1.3.4 → 1.4.0)
- Test: `tests/clash-pool.bats`, `tests/base-svc.bats` (1 smoke test each — only if those files lack a render smoke; otherwise extend)

**Interfaces:**
- Consumes: `dash_header`/`dash_row`/`dash_module_row` (Task 1), `state_load`/`kernel_running`/`pid_file`/`detect_external_clash` (clash), docker probes (base).
- Produces: `dashboard_info` `version=` for both (clash: `mihomo v< tag>` internal mode; base: `postgres <pg> / redis <rd>`); keyline render shape.

- [ ] **Step 1: Write the failing tests** — add to `tests/base-svc.bats`:

```bash
@test "render_dashboard: keyline header + module row with no docker" {
  run bash -c ". '$REPO_ROOT/tools/base/lib.sh'; PATH=/usr/bin:/bin; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"· module"* ]] || false
  [[ "$output" == *"base"* ]] || false
  [[ "$output" == *"module"*"·"* ]] || false
}
```

Add to `tests/clash-pool.bats` (mirror its sandbox state-file setup if one exists; a bare source is acceptable — clash's `state_load` tolerates a missing state file):

```bash
@test "render_dashboard: keyline header degrades with no state file" {
  local sb
  sb="$(mktemp -d)"
  run bash -c "HOME='$sb'; . '$REPO_ROOT/tools/clash/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"· module"* ]] || false
  [[ "$output" == *"module"*"·"* ]] || false
  rm -rf "$sb"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/base-svc.bats tests/clash-pool.bats`
Expected: new tests FAIL (old headers / no module row).

- [ ] **Step 3: Implement**

`tools/clash/lib.sh`:
- add the MODULE_VERSION yaml-read lines near the top (clash never showed its module version);
- `dashboard_info()`: after `state_load`, add:
```bash
  # app version: the deployed mihomo kernel tag (internal mode only —
  # external mode has no kernel of ours)
  if [ "${CLASH_MODE:-internal}" = "internal" ] && [ -n "${KERNEL_TAG:-}" ]; then
    echo "version=mihomo v${KERNEL_TAG}"
  fi
```
- `render_dashboard()`: replace the header printf
  `printf '%s%s clash%s %s· %s mode%s\n' …` with:
```bash
  local aver state
  if [ "${mode}" = "internal" ]; then
    aver="mihomo v${KERNEL_TAG:-unknown}"
    if kernel_running; then
      state="ok"
    else
      state="stopped"
    fi
  else
    aver=""
    state=""
  fi
  dash_header "clash" "${aver}" "${state}"
```
  then convert every leading row `printf '  %s%-9s %s\n' "${C_DIM:-}" "<label>:" <value>` (kernel: / egress: / api: / sub:) to `dash_row "<label>" "<value>"` (values unchanged); leave the nodes table (the `#  node  latency` block and its rows) EXACTLY as is; append after the nodes/current-node tail:
```bash
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/clash/"
```

`tools/base/lib.sh`:
- add the MODULE_VERSION yaml-read lines near the top;
- `dashboard_info()`: add at the top of the function:
```bash
  local v="" pg_tag rd_tag
  pg_tag="$(docker inspect -f '{{.Config.Image}}' "${POSTGRES_CONTAINER}" 2>/dev/null | sed -n 's/.*://p')"
  rd_tag="$(docker inspect -f '{{.Config.Image}}' "${REDIS_CONTAINER}" 2>/dev/null | sed -n 's/.*://p')"
  [ -n "${pg_tag}" ] && [ -n "${rd_tag}" ] && v="postgres ${pg_tag} / redis ${rd_tag}"
  [ -n "${v}" ] && echo "version=${v}"
```
- `render_dashboard()`: replace the header printf
  `printf '%s%sbase%s %s· shared PG + Redis%s\n' …` with a computed state + `dash_header "base" "" "${state}"` (docker unreachable → `state=""`; both containers up → `ok`; else → `stopped`); convert the postgres:/redis:/network: rows and the databases sub-rows to `dash_row` calls (same values); keep the `docker daemon unreachable` early row as `dash_row "state" "docker daemon unreachable"` followed by `dash_module_row` and `return 0`; append `dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-$HOME/.aibox}/modules/base/"` at the end of the normal path.

- `tools/clash/module.yaml`: 1.3.4 → 1.4.0. `tools/base/module.yaml`: 1.3.4 → 1.4.0.

- [ ] **Step 4: Run tests**

Run: `bats tests/base-svc.bats tests/clash-pool.bats && bash scripts/validate-module.sh clash && bash scripts/validate-module.sh base`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/clash tools/base tests/base-svc.bats tests/clash-pool.bats
git commit -m "feat(clash,base): keyline rich views + app version reporting (mihomo tag / pg+redis tags)"
```

---

### Task 8: openmaic + windmill — `dashboard_info` version= (dispatch modules)

**Files:**
- Modify: `tools/openmaic/lib.sh`, `tools/windmill/lib.sh`, `tools/openmaic/module.yaml` (1.2.3 → 1.3.0), `tools/windmill/module.yaml` (1.3.3 → 1.4.0)
- Test: none new (their dashboard dispatches to the CLI status — the manager views consume `version=`; covered by Task 2/3 tests' machinery). Validator run is the gate.

**Interfaces:**
- Consumes: existing `installed_version()` in both libs (reads the installed CLI's `*_CLI_VERSION` line).
- Produces: `version=` key in `dashboard_info` (app version = the dispatched ops CLI's version; the remote deploy's own version stays the CLI status's business).

- [ ] **Step 1: Implement** — in `tools/windmill/lib.sh`, `dashboard_info()`: add as the first output line:

```bash
  local v
  v="$(installed_version 2>/dev/null || true)"
  [ -n "${v}" ] && [ "${v}" != "unknown" ] && echo "version=${v}"
```

In `tools/openmaic/lib.sh`, `dashboard_info()`: add the same three lines (its `installed_version` has identical semantics).

- `tools/openmaic/module.yaml`: 1.2.3 → 1.3.0. `tools/windmill/module.yaml`: 1.3.3 → 1.4.0.

- [ ] **Step 2: Verify**

Run: `bash -c '. tools/windmill/lib.sh 2>/dev/null; type installed_version' && bash -c '. tools/openmaic/lib.sh 2>/dev/null; type installed_version' && bash scripts/validate-module.sh openmaic && bash scripts/validate-module.sh windmill && bats tests/cli-surface.bats`
Expected: both `type` checks print `installed_version is a function`; validators PASS; cli-surface PASS.

- [ ] **Step 3: Commit**

```bash
git add tools/openmaic tools/windmill
git commit -m "feat(openmaic,windmill): dashboard_info reports the installed CLI version as the app version"
```

---

### Task 9: scaffolder + validator — new modules cannot miss the template

**Files:**
- Modify: `scripts/new-module.sh` (lib.sh template: MODULE_VERSION/app_version/dashboard_info/version= TODO + render_dashboard; module.yaml actions + usage; svc.sh dashboard route), `scripts/validate-module.sh` (S18/S19 after S17b)
- Test: `tests/module-tools.bats` (3 tests added)

**Interfaces:**
- Consumes: Task 1's helpers (the scaffolded lib.sh sources `_common.sh` already).
- Produces: scaffolded modules that pass validation with 0 errors AND 0 warnings; validator rules S18 (render_dashboard must call `dash_header`) and S19 (dashboard_info must emit `version=`) — both WARN level.

- [ ] **Step 1: Write the failing tests** — add to `tests/module-tools.bats`:

```bash
@test "scaffold: lib.sh ships the keyline template skeleton" {
  run bash "$REPO_ROOT/scripts/new-module.sh" tmplmod --desc "T" --out "$OUT"
  [ "$status" -eq 0 ] || echo "$output"
  grep -q 'app_version()' "$OUT/tmplmod/lib.sh" || false
  grep -q 'dash_header' "$OUT/tmplmod/lib.sh" || false
  sed -n '/dashboard_info()/,/^}/p' "$OUT/tmplmod/lib.sh" | grep -q 'version=' || false
  grep -q 'render_dashboard' "$OUT/tmplmod/svc.sh" || false
}

@test "validator: S18 — dashboard action whose render_dashboard skips dash_header WARNs" {
  bash "$REPO_ROOT/scripts/new-module.sh" s18mod --desc "T" --out "$OUT" >/dev/null 2>&1
  printf 'render_dashboard() { printf "custom view\\n"; }\n' >"$OUT/s18mod/lib.sh"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" s18mod
  [ "$status" -eq 0 ] || echo "$output"        # WARN, not ERROR
  [[ "$output" == *"dash_header"* ]] || false
}

@test "validator: S19 — dashboard_info without version= WARNs" {
  bash "$REPO_ROOT/scripts/new-module.sh" s19mod --desc "T" --out "$OUT" >/dev/null 2>&1
  printf 'dashboard_info() { echo "endpoint=http://x"; }\n' >"$OUT/s19mod/lib.sh"
  run env VALIDATE_TOOLS_DIR="$OUT" bash "$REPO_ROOT/scripts/validate-module.sh" s19mod
  [ "$status" -eq 0 ] || echo "$output"        # WARN, not ERROR
  [[ "$output" == *"version="* ]] || false
}
```

Note: the two existing "validates clean (0 errors, 0 warnings)" scaffold tests become the regression gate that the scaffold satisfies S18/S19.

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/module-tools.bats`
Expected: the 3 new tests FAIL (no app_version in scaffold; no S18/S19 output).

- [ ] **Step 3: Implement**

`scripts/validate-module.sh` — after the S17b block:

```bash
  # --- S18: dashboard keyline template (rich views use the shared header) ---
  if printf '%s\n' $acts | grep -qx dashboard && [ -f "$d/lib.sh" ] && grep -q 'render_dashboard()' "$d/lib.sh"; then
    grep -q 'dash_header' "$d/lib.sh" ||
      warn "render_dashboard must render via dash_header (spec §Dashboard template)"
  fi

  # --- S19: dashboard_info must report the app version ---
  if [ -f "$d/lib.sh" ] && grep -q 'dashboard_info()' "$d/lib.sh"; then
    sed -n '/dashboard_info()/,/^}/p' "$d/lib.sh" | grep -q 'version=' ||
      warn "dashboard_info must report the deployed app version (version=…; spec §Dashboard template)"
  fi
```

`scripts/new-module.sh`:
- in the module.yaml templates (both compose and cli variants): add `  - dashboard` to `actions:` (after `  - status`), and keep the existing `dashboard:` usage line.
- in the svc.sh template: add before the `*)` case:
```bash
  dashboard)
    render_dashboard
    ;;
```
- in the lib.sh template, after the `deploy_root()` function, append:

```bash
# Module version — read from module.yaml next to this lib (cache and repo
# layouts agree; empty on a missing file → callers fall back to dim ?).
MODULE_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$(dirname "${BASH_SOURCE[0]}")/module.yaml" 2>/dev/null | head -1 || true)"

# ---------- dashboard (keyline template; spec §Dashboard template) ----------
# App version = the DEPLOYED software's version (npm package / image tag /
# kernel tag — whatever THIS module manages). Empty when not locally knowable.
app_version() {
  # TODO: report the deployed app version, e.g.
  #   npm ls -g <pkg> --depth=0 | grep -oE '<pkg>@[0-9][0-9A-Za-z.-]*' | head -1 | sed 's/.*@//'
  #   docker inspect -f '{{.Config.Image}}' <container> 2>/dev/null | ...
  printf ''
}

# Dashboard interface (machine-readable; the manager's overview + detail views
# render it). version= is the app version (validator S19 WARNs without it).
dashboard_info() {
  local v
  v="$(app_version)"
  [ -n "${v}" ] && echo "version=${v}"
  echo "endpoint=http://127.0.0.1:TODO_PORT"
  # state= contract: ok / starting / stopped / na
  echo "state=stopped"
  echo "health=TODO probe verdict (one line)"
}

# The module's rich view (aibox __NAME__ dashboard) — keyline via the shared
# helpers (_common.sh ships them; spec §Dashboard template).
render_dashboard() {
  local v
  v="$(app_version)"
  dash_header "__NAME__" "${v}" "stopped"
  dash_row "endpoint" "http://127.0.0.1:TODO_PORT"
  dash_row "health" "TODO probe verdict"
  dash_module_row "${MODULE_VERSION:-}" "${AIBOX_HOME:-${HOME:-~}/.aibox}/modules/__NAME__/"
}
```

- [ ] **Step 4: Run tests**

Run: `bats tests/module-tools.bats`
Expected: PASS — including the pre-existing "0 errors, 0 warnings" scaffold tests (the scaffold now satisfies S18/S19).

- [ ] **Step 5: Commit**

```bash
git add scripts/new-module.sh scripts/validate-module.sh tests/module-tools.bats
git commit -m "feat(tooling): scaffold + validator enforce the dashboard keyline template (S18/S19)"
```

---

### Task 10: docs — module-spec section, README(.zh), CHANGELOG

**Files:**
- Modify: `docs/module-spec.md` (§dashboard_info interface → point at the new section; add §Dashboard template), `README.md`, `README.zh.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above (docs describe the shipped behavior).

- [ ] **Step 1: module-spec.md** — in the `### dashboard_info() interface` table, update the `version` row to:

```markdown
| `version` | deployed app version | the keyline header segment (cyan); first token feeds the async updates comparison; `version=` is REQUIRED (validator S19) |
```

Add a new `### Dashboard template (keyline)` section right after it (the
4-backtick fence below carries a nested ```text block — write the section
CONTENT into module-spec.md, not the outer wrapper):

````markdown
### Dashboard template (keyline)

Spec source: `docs/superpowers/specs/2026-09-23-dashboard-app-version-keyline-design.md`.

Every dashboard surface (module rich view via `render_dashboard`, manager
overview, manager detail view) renders the SAME keyline template, from shared
helpers in `tools/_shared/common.sh` (`dash_header` / `dash_row` /
`dash_module_row` / `dash_rule` / `dash_secheader`; bin/aibox inlines twins):

```text
pi-web 0.9.3 · ✓ running
────────────────────────────────────────────
  service    launchd · pid 38243
  endpoint   http://127.0.0.1:30141 · HTTP 307 ✓
  auth       pi / ai-coding
  log        ~/Library/Logs/pi-web.log
  module     1.3.5 · ~/.aibox/modules/pi-web/
```

Rules:

- **Two versions, two places**: the **app version** (deployed software: npm
  package / image tag / kernel tag / dispatched CLI) is the cyan header
  segment, reported by `dashboard_info`'s `version=` and, in rich views, an
  `app_version()` helper; the **module version** (aibox packaging,
  module.yaml `version:`) is the SUNK last row — whole row dim. Never show
  the module version where the app version is expected.
- `dash_header <name> <appver> <state>`: appver `""` omits the segment;
  states `ok|running` → `✓`, `starting` → `⚠`, `stopped` → `○`,
  `na`/`""` → no segment. Manager overview headers show the icon only.
- `dash_row <label> <value>`: ASCII label ≤10 chars in a `%-10s` grid, NO
  colon; values verbatim — never byte-truncate (CJK stays ragged-right,
  pitfall #6).
- Rule width: TTY → `tput cols` clamped [40,72]; non-TTY → 64. `─` literals
  are complete characters, never sliced.
- `health=` merges into the endpoint row (`<url> · <health>`); `state=stopped`
  appends the dim `(stopped — aibox <module> start)` hint instead.
- `dashboard`/`status` actions render the keyline view only; raw
  launchctl/systemctl/lsof dumps belong to `diagnose`.
- New modules: the scaffolder emits the skeleton (app_version TODO +
  dashboard_info with `version=` + render_dashboard via dash_header);
  the validator WARNs on gaps (S18/S19).
````

- [ ] **Step 2: README.md** — update:
  - the "Local-first dashboards" feature bullet → append: `every block leads with the deployed app version (module packaging version is the dim footer row); one keyline template across overview, detail and module rich views.`
  - `aibox dashboard             # all modules: state, endpoints, credentials, ports` → `aibox dashboard             # all modules: app versions, state, endpoints, credentials, ports`
  - `aibox dashboard <module>          single-module detail + health probe` → `aibox dashboard <module>          single-module detail + health probe (app version in the header)`
  - in "Ports & endpoints": `aibox dashboard            # the port table + listeners for every installed module` → `aibox dashboard            # versions + the port table + listeners for every installed module`
- `README.zh.md`: apply the same four edits to the corresponding bullets/lines (keep full-width punctuation, `${VAR}` braces — copy the existing zh phrasing style).

- [ ] **Step 3: CHANGELOG.md** — add at the top (after the header block):

```markdown
## [Unreleased]

### Added

- **Dashboard: app vs module versions, one keyline template** — every dashboard now leads
  with the deployed **app version** (cyan header: npm package / image tag / kernel tag /
  dispatched CLI) and sinks the **aibox module version** to a dim footer row; the old
  ambiguous `· module <ver>` header is gone everywhere. `dashboard_info`'s `version=`
  key now feeds the manager views' header (rendered label `upstream:` → `app:`).
  Shared `dash_header`/`dash_row`/`dash_module_row` helpers (`_shared/common.sh`) unify
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
```

- [ ] **Step 4: Verify + commit**

Run: `bats tests/*.bats && bash scripts/validate-module.sh --all`
Expected: full suite PASS, validator PASS (0 ERRORs; 0 new WARNs).

```bash
git add docs/module-spec.md README.md README.zh.md CHANGELOG.md
git commit -m "docs: dashboard keyline template + app/module version semantics (spec, README, changelog)"
```

---

## Final verification (whole branch)

```bash
bats tests/*.bats                          # full suite
/bin/bash -c 'bats tests/*.bats'           # bash 3.2 (macOS) — the platform promise
bash scripts/validate-module.sh --all      # 0 errors, 0 warnings
bin/aibox dashboard                        # visual smoke: keyline overview
bin/aibox pi-web dashboard                 # visual smoke: pi-web app version 0.9.3 in header
bin/aibox dashboard clash                  # visual smoke: generic detail + live probe
```

Self-review notes (already folded in): every spec §5 deliverable maps to a task (1→common.sh, 2-3→bin/aibox, 4-8→modules, 9→scaffolder+validator, 10→docs); `dash_header`'s state set was extended with `running` (pi-web/clash word) over the spec's four — a superset, spec §5.1 comment updated accordingly in Task 10's module-spec text; no placeholders; helper names consistent across tasks (`dash_header/dash_row/dash_module_row/dash_rule/dash_secheader` vs manager twins `_dash_rule_line/_dash_secheader`).

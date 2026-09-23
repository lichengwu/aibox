# AGENTS.md

> Collaboration guide for AI coding agents and human contributors. Read this before touching code.

## Project overview

aibox is a lightweight, pure-bash module manager (zero runtime dependencies, compatible with the bash 3.2 that ships with macOS). One-line `curl|bash` install; install / update / uninstall each module on demand. Each "module" is a directory under `tools/<name>/` in the repo, shipping its own `install / uninstall / update / svc` hooks and dispatched uniformly by the `aibox` main CLI.

## Repo layout

```text
bin/aibox            main CLI (install.sh downloads to ~/.local/bin/aibox)
install.sh           bootstrap (curl|bash install / self-update, idempotent; optional AIBOX_SHA256/AIBOX_VERIFY)
tools/<name>/        module dir: lib.sh + install/uninstall/update/svc.sh + module.yaml
                     shipped: pi-web (macOS launchd service), openmaic (Linux deploy-host ops CLI),
                              windmill (Windmill self-host docker compose ops CLI), clash (Clash subscription proxy pool, mihomo), base (shared PG+Redis)
tools/_shared/       shared module library (common.sh: output helpers + docker.io pool) — single source in the
                     repo; ships into each module cache as _common.sh via module.yaml `includes: [common]`
docs/module-spec.md  the module hook contract (normative; module-system-spec.md is the superseded design draft)
.github/workflows/   CI (release automation + lint quality gate: bash -n / shellcheck / gotcha #1 #8 scans / module-lint / port-conflict / bats tests + coverage probe / macos-bash32 job — the full suite executed under /bin/bash 3.2, the platform this project promises)
```

## Core commands

```text
aibox install <module> [--skip-checks]
aibox uninstall <module>|self [--purge] [--yes]   # --purge: also delete data; self = manager (--purge = cascade full teardown)
aibox update <module>|self|--all [--restart|--no-restart] [--skip-checks]   # self = aibox itself; --all = modules + self
aibox check <module>|self                    # module preflight; self = environment check
aibox dashboard [--available] [<module>]     # overview (versions+endpoints+credentials+ports) / catalog / detail+health
aibox purge [<module>...|self] [--apply] [--stop] [--yes]  # residue scan/cleanup (dry-run default)
aibox <module> <action> [args]            # pass-through to module svc.sh
aibox proxy {show|set <url>|unset|on|off|check [url]|env}   # static proxy config (global; see README "Proxy")
aibox --no-proxy <command>                                # bypass the proxy once
aibox clash {set <sub-url>|on|off|status|refresh|select|test|logs|doctor}  # clash pool (mihomo; see tools/clash/README)
```

## Contribution conventions

### bash coding conventions (mandatory)

1. **`set -euo pipefail`** at the top of every script.
2. **Always quote variables as `${VAR}` (braces), never bare `$VAR`** — especially when a variable is immediately followed by a **non-ASCII** character (CJK text, full-width punctuation `，。、；：`). This is pitfall #1 below, the project's #1 footgun.
3. **Declare `local` before assigning** (or on two lines).
4. **Idempotent**: `install.sh` / `update.sh` must be safe to re-run without erroring.
5. **No `jq` / `python`**: the registry is shell-sourceable; the main CLI sources it directly, bash 3.2 compatible. (Since v0.4.0 the registry is auto-discovered from `tools/*/module.yaml` via a zero-dependency awk subset parser; yq validates the subset in CI.)
6. **Keep full-width punctuation in Chinese copy** (README.zh.md), but always separate variable boundaries with `${VAR}`.

### commit style

Conventional Commits: `fix:` / `feat:` / `docs:` / `style:` / `chore:`.

### Versioning & release flow

- Main CLI version: `AIBOX_VERSION` at the top of `bin/aibox`. **The main CLI and each module version independently** (a module's dispatched CLI carries its own `*_CLI_VERSION`).
- Module version: the `version:` field in `tools/<name>/module.yaml`.
- **A release = bump `AIBOX_VERSION` → push main.** GitHub Actions (`.github/workflows/release.yml`) reads `AIBOX_VERSION`; if the remote has no matching `v<version>` tag, it auto-creates the tag + release — the release notes carry the **curated `CHANGELOG.md` section for that version** (extracted by the workflow) plus the auto-generated commit list — and attaches a `SHA256SUMS` sidecar. Unchanged version → skip (idempotent, safe to re-push).
- **Changelog standard (every release, open-source bar — Keep a Changelog + semver):**
  1. Header: `## [x.y.z] — YYYY-MM-DD` (the `[x.y.z]` resolves via the compare-link definitions at the file bottom; add the new link when releasing).
  2. Body grouped by `### Added / Changed / Deprecated / Removed / Fixed / Security` — only the groups with content.
  3. Each entry: **what changed + why it matters to the user** (one or two sentences; link the commit/PR when the entry is a fix with a story, e.g. "live-caught on the deploy host: …"). No bare commit-subject dumps.
  4. A **semver rationale** line in the release commit message (why major/minor/patch).
  5. **Breaking changes / migration notes** get their own `### Changed` bullet starting with **BREAKING:** — plus the two-gate interaction model applies to any new destructive verb.
  6. Module version bumps ride in the release commit message (they are independent of `AIBOX_VERSION`).
  7. The `[Unreleased]` section accumulates during development; at release time it is renamed to the version header (date = release day) and a fresh empty `[Unreleased]` is NOT required (start it with the next change).
- Self-update still runs `curl install.sh | bash` (idempotent re-install), **independent of releases** — releases are publication/change records. Optional `AIBOX_SHA256`/`AIBOX_VERIFY=1` add checksum verification.

## Pitfall log

> The Chinese characters that appear in these examples are deliberate — they are the trigger for the bugs. Do not "fix" them by translating the example strings.

### #1 bash 3.2 + UTF-8 locale: full-width punctuation right after `$VAR` → unbound variable

**Symptom**: under `set -u`, a line like `log "当前 $name，继续"` reports `name<replacement-char>: unbound variable` (the variable name is followed by garbled bytes) and exits. Only triggers under a UTF-8 locale; the `C` locale doesn't trigger it, so it doesn't reproduce in some environments / CI.

**Root cause**: macOS's bash 3.2.57 has a multibyte variable-name parsing defect. When `$VAR` is immediately followed by a UTF-8 multibyte character (CJK text, full-width punctuation `，。、；：！？` etc.), bash erroneously absorbs its bytes into the variable name, producing a non-existent variable, which `set -u` flags as unbound. The `C` locale processes bytes one at a time; a leading byte like `0xEF` isn't a name character, so it terminates the variable name and no error occurs.

**Fix**: always delimit variable references with `${VAR}` — `当前 ${name}，继续` is fine.

**History**: `ad7cfed` swept the repo with perl and fixed 9 occurrences, but `876206d`'s new `cmd_self_update` missed `$before，`; fixed in 2026-09 by `e5311bf`.

**Detection**:

```bash
sed -n <line>p <file> | xxd   # see if full-width bytes like ef bc 8c follow the variable name
LC_ALL=zh_CN.UTF-8 bash <script>   # reproduce under a UTF-8 locale (the C locale won't reproduce it)
```

**One-liner self-check** (the regex requires a non-ASCII char immediately adjacent to the variable name to match):

```bash
grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[，。、；：！？（）「」]' <file>
```

### #2 Don't use bash 4-only syntax in scripts dispatched to other machines

**Symptom**: a module's `svc.sh` only forwards to the dispatched script, but on macOS even `--version` fails with `syntax error near unexpected token '>'` — with no hint that it's about the local bash version.

**Root cause**: macOS ships bash 3.2, but the script used bash 4's `exec {fd}>file` (auto-allocated file descriptor). For THAT construct it was a **parse-time** error — the whole file can't execute, no branch is reachable.

**Correction (measured 2026-09, while building the coverage probe)**: `exec {fd}>file` is the EXCEPTION, not the rule — most bash-4 constructs (`declare -A`, `mapfile`, `${var,,}`) **parse fine under `bash -n` on 3.2** and only fail at RUNTIME. So:

- `bash -n` under 3.2 catches only parse-level breakage (a minority)
- **actually EXECUTING the code under 3.2 is the only complete detector** — CI's `macos-bash32` job runs the whole fast suite under /bin/bash 3.2 for exactly this reason (and ubuntu's `bash -n` accepts bash-4 syntax, so it proves nothing here)

**Fix**: use a fixed fd (`exec 9>file` / `flock -n 9`). If you genuinely need bash 4+, ensure the script is only parsed on the target machine — don't let it appear in a path that gets sourced/executed on macOS.

**Why "parseable" is worth the concession**: staying parseable lets you give a clear message on unsupported platforms ("this command requires a Linux deploy host") instead of throwing a syntax error. See `require_deploy_host` in `tools/openmaic/cli/openmaic`.

### #9 `exec` with a redirection makes it PERMANENT shell state — `exec 9>>f 2>/dev/null` eats stderr forever

**Symptom**: under the coverage probe, every `die`/`warn` message vanished — tests asserting stderr failed with EMPTY output, no error anywhere.

**Root cause**: `exec` without a command name applies its redirections to the SHELL itself, permanently. `exec 9>>$file 2>/dev/null` was meant to silence just the open-failure error — but fd 2 got pointed at /dev/null for the REST OF THE PROCESS. Every later `>&2` write (die/warn) went to the void, silently.

**Fix**: never hang a stray `2>/dev/null` onto an fd-opening `exec`. Guard the failure with `if exec 9>>"$file"; then ... fi` (a failing exec inside an `if` condition is safe under `set -e`) — one real error line to stderr on a bad path is the correct degradation, not silence.

**Detection**: any stderr assertion failing with empty output while the command exits nonzero; `grep -n 'exec [0-9]*>>.*2>'` over the codebase.

### #3 Proxy testing: status-code-only is always a false positive

**Symptom**: after adding proxy support, `proxy test` (now `proxy check <url>`) reports "proxy ok" (HTTP 200) — but with the port wrong or the proxy off, the test **still says 200**.

**Root cause**: the test was written as "reach GitHub via the proxy = proxy works". But on a directly-reachable network, that 200 came from the **direct connection** — the proxy may not have been used at all. The same machine, with a different network (Clash TUN on/off), flips the verdict without a line of test code changing.

**Fix**: judge by curl's `%{proxy_used}` (`1` = actually went through the proxy, `0` = direct), not the HTTP status:

```bash
curl -s -x "$url" -o /dev/null -w '%{http_code} %{proxy_used}' "$target"
```

And **also run a direct-connection control** (`curl --noproxy '*'`), telling the user whether the proxy is required on the current network. The criterion itself goes stale, so re-measure every time.

**Case-sensitivity** (measured, curl 8.7.1 / macOS):

| Variable | curl honors it? |
| --- | --- |
| `http_proxy` (lowercase) | yes |
| `HTTP_PROXY` (uppercase) | **ignored** |
| `https_proxy` / `HTTPS_PROXY` | both honored |

So export **both cases**, or one class of tools won't pick it up. Also: `file://` sources aren't affected by `http_proxy` (curl reads the file directly), so local/intranet sources need no special-case — but intranet HTTP sources get proxied out; the default `no_proxy` covers private ranges to handle that.

### #4 Env vars don't cross the "process boundary"; cross-machine/cross-time needs persistence to disk

**Symptom**: configured a proxy for `aibox`; `aibox install openmaic` used it; but later `openmaic upgrade` on the deploy host pulling source **can't connect again**.

**Root cause**: the proxy is injected via env vars, but `openmaic upgrade` is a process on **another machine, at another time** — by then `aibox` has exited and the env vars can't be inherited.

**Fix**: for "the module networks elsewhere on its own" scenarios, the module must **write the value into its own config file** (`tools/openmaic/lib.sh`'s `sync_proxy_to_conf` writes `/etc/openmaic/openmaic.conf`).

**Rule of thumb**: network requests run **in the hook right now** → env vars suffice; requests run by a **dispatched command elsewhere, later** → must persist to disk. Don't expect `export` to cross processes and hosts.

### #5 Three counter-intuitive curl semantics (all silently corrupt the verdict)

Three traps hit while writing `aibox proxy check`, all sharing "looks fine, conclusion is wrong":

1. **On connection failure `-w` emits nothing.** Pointed at a port nobody listens on, `curl -w '%{http_code}'` doesn't emit `000` — it prints nothing, so `code` becomes an empty string. Judging `code == 000` misses all failures. Must `|| out=""` as an empty fallback, then fill in `000` yourself.
2. **An explicitly `-x`'d proxy is still excluded by `no_proxy`.** If the check script doesn't clear `no_proxy` and the network happens to have an exclusion rule, "can this proxy reach X" **silently becomes "can a direct connection reach X"** — a false verdict with no error. Fix: `env -u no_proxy -u NO_PROXY curl -x ...`.
3. **`%{proxy_used}` can't be judged by "is it empty".** The fallback failure result has `used=0` (non-empty), so "all proxies dead" aggregates into "all traffic confirmed via proxy". Must strictly judge `= 1`.

**Lesson**: for proxy-connectivity checks, **"failed" and "not measured" must be distinguished**. When inferring state from empty/non-empty, first ask "what would this field be on the failure path".

### #6 Multibyte characters can't be sliced as substrings (bash 3.2 + C locale)

**Symptom**: spinner frames stored as `spin='⠋⠙⠹⠸'` with `"${spin:$i:1}"` to take one frame; works under a UTF-8 locale, garbled under a `C` locale.

**Root cause**: bash's substring expansion under a non-UTF-8 locale counts **bytes** not characters, slicing the 3-byte `⠋` into halves and emitting invalid UTF-8.

**Fix**: store **complete** frames in an array, take elements instead of slicing:

```bash
SPIN=( '⠋' '⠙' '⠹' )          # each item is a complete character; can't be sliced wrong
probe_render "${SPIN[$i]}"
```

Likewise, symbols like `✔ ✘ ⠋` must always be passed as **complete string literals** in code — don't concatenate or slice them.

### #7 Don't use `script` to test TTY interaction; use `expect`

`script -q /dev/null cmd` looks like it can feed piped input into a pty to test `read` prompts, but it's unreliable: stdin forwarding and pty line-buffering desync, so `read` doesn't get the line you expect (manifesting as "fed y but treated as N"), or the child gets killed early at EOF. macOS ships `expect` (`/usr/bin/expect`); use it directly:

```tcl
spawn bash bin/aibox proxy set http://127.0.0.1:1
expect -re {\[y/N\]} { send "y\r" }
```

Note that in Tcl regex the `[y/N]` brackets are a character class; write `\[y/N\]`.

**Verification**: pty output contains ANSI control sequences; use `cat -v` to see the real content; counting `^[[<n>A` (cursor-up) **and checking the number equals the block height** is the fastest way to catch a redraw-line-count bug.

### #8 bash 3.2: `local a="x" b="${a}/y"` same-line self-reference → unbound under `set -u`

When `local` declares multiple variables, bash 3.2 **expands all right-hand sides before any assignment** — the second variable's `${a}` expands while the first isn't assigned yet, and with `set -u` it blows up:

```bash
/bin/bash -c 'set -u; f(){ local a="/etc/w" b="${a}/windmill.conf"; echo "$b"; }; f'
# bash: a: unbound variable
```

bash 5 doesn't have this, so "ran fine locally on the dev box" scripts blow up on macOS bash 3.2.
(The windmill module's lib.sh actually hit this; `bash -n` can't catch it — pure runtime-expansion issue.)
**Fix**: split into two lines: `local a="..."` / `local b="${a}/..."`.
**Detection**: `grep -rnE 'local [a-z_]+="[^"]*"[ ]+[a-z_]+="\$\{[a-z_]+\}'`.

## Developing a new module (spec + tooling)

**Spec**: [`docs/module-spec.md`](docs/module-spec.md) §Onboarding a new module — the normative checklist (definition of done).

**Tooling** (repo-local, zero-dependency, same rules CI enforces):

```bash
scripts/new-module.sh <name> [--desc "..."] [--no-compose] [--out <dir>]   # scaffold a conformant skeleton (passes the validator out of the box)
scripts/validate-module.sh <name> | --all                                  # conformance gate: 0 ERRORs required (WARNs tolerated)
```

**Flow**: scaffold → fill `module.yaml` (ports/checks/deps/services/usage/includes) → implement the hooks → `scripts/validate-module.sh <name>` until PASS → `bats tests/*.bats` → live smoke (install / start / status / logs / stop / uninstall on a docker host) → add the module row to README(.zh). **`tools/gitlab/` is the reference implementation onboarded with exactly this flow.**

**Help system**: every module carries a `usage:` map in module.yaml (one line per declared action, args hint first: `"<node-name> — switch the active node"`); `aibox <module> --help` renders the action table, `aibox <module> <action> --help` renders the single action — both local-first. The validator WARNs on actions without usage entries; the scaffolder emits a TODO skeleton. Unknown actions die with `run: aibox <module> --help` (never a hand-maintained action list).

**Iron rules** (validator + CI enforce; details in the spec):

1. `module.yaml` is the source of truth — the registry auto-discovers `tools/*/module.yaml` (no registry.sh to edit; local `file://` source needs zero global changes). Hyphenated names map to underscored variable keys internally (`pi-web` → `AIBOX_MODULE_pi_web_*`); hyphenated usage keys normalize the same way. `module.yaml` ships in the cache alongside the 5 hooks (standard-6 download set), so per-module help/metadata renders offline.
2. Hooks (`install/uninstall/update/svc.sh`): bash shebang, `set -euo pipefail`, idempotent; shared code lives in `lib.sh` (sourced library — no shebang, no strict-mode line) and infra helpers in the shared include (`tools/_shared/common.sh` — output helpers `log/warn/ok/info/die` + the docker.io pool; declared via `includes: [common]`, cached per-module as `_common.sh`; lib.sh resolves cache layout first, repo layout `../_shared/` for direct exec). NEVER copy pool/helper code into a new module — source the include (spec §Shared library includes). Module scripts are downloaded and cached to `~/.aibox/modules/<name>/`.
3. **Every module declares `checks:` (preflight contract)**: install/update is hard-gated by `preflight_module` — deps (strict), `checks.commands`, `checks.disk_gb`, `checks.domains` (host-probed) / `checks.docker_pull` (daemon-probed — the docker daemon's egress differs from the host's; never host-probe a daemon-consumed registry), with the `checks.docker_images` cache short-circuit, and `services:` readiness (recursive into base). Host network failures try the configured alternative routes (direct/clash/mirror/static proxy) and adopt a working one for the run. CI enforces the section's presence + field formats; `aibox check self` / `aibox check <module>` run it proactively; `--skip-checks` bypasses. Full spec + per-module matrix: `docs/module-spec.md` §Preflight checks.
4. **Install paths must be overridable**: start from `${AIBOX_BIN_DIR:-$HOME/.local/bin}` and expose a module-specific override (e.g. `OPENMAIC_BIN_DIR`) — deploy hosts often want `/usr/local/bin`.
5. **`svc.sh` is an "action entry point", NOT "must be a daemon"**: long-lived services (pi-web) use `start/stop/restart`; pure-CLI dispatch (openmaic) can pass actions straight through to the dispatched command. Service-type modules (`actions` contains `start`) MUST implement the full lifecycle `start/stop/restart/status/logs`.
6. **Platform differences: warn, don't hard-block**: install is usually cross-platform (just copying files); the real limit is reported by the script at execution time, which is less false-positive-prone than blocking at install.
7. The local machine is macOS (bash 3.2); hooks must be compatible. Scripts **dispatched to other platforms** must avoid bash 4 syntax — see pitfall #2. (The validator runs a bash-3.2 parse check when available.)
8. **Deploy-type modules: don't invent your own paths** (see [`docs/module-spec.md`](docs/module-spec.md) "Deploy directory & config path conventions"): deploy root is uniformly `$AIBOX_HOME/apps/<name>` (same expression on both platforms, no branch); config is `/etc/<name>/<name>.conf`. Two empirical hard constraints: Docker Desktop on macOS **doesn't share `/opt`** by default (putting things there makes compose relative mounts fail with `Mounts denied`); **a systemd system service has no `HOME`** (paths derived from `$HOME` resolve to empty in the service context; units must use explicit `Environment=`).
9. **Self-starting services use the platform-native init system**: long-lived services (pi-web, windmill's scheduled task, clash) auto-start/daemonize per-platform — don't mix:

    - **macOS → launchd**: user-level `~/Library/LaunchAgents/<label>.plist`, `launchctl bootstrap gui/$(id -u)`, no root needed. `KeepAlive` = auto-restart, `StartCalendarInterval` = scheduled.
    - **Linux → systemd**: user-level `~/.config/systemd/user/<name>.{service,timer}`, `systemctl --user` + `loginctl enable-linger` to survive logout, no root needed. `Restart=always` = auto-restart, `OnCalendar` = scheduled.
    - One service, one unit per platform, generated by a `case "$(uname -s)"` branch. System-level services (need root / start at boot) use `/etc/systemd/system` + `systemctl` (no `--user`) — see windmill's `cmd_systemd`/`cmd_launchd` and pi-web's `write_plist`/`write_service`.
10. **Docs are part of the contract**: `README.md` (commands / ports / env overrides / preflight — validator: ERROR if missing) and `docs/DEVELOPMENT.md` (upstream links, version-pin policy, design decisions, known quirks — validator: WARN if missing).
11. **No hardcoded credentials** in compose files; shared-PG consumers read `${AIBOX_POSTGRES_*}` from the injected `base.env` (validator scans; base is the only exception by design).
12. **Residue map for `aibox purge`**: extend the `residue_*` map functions in `bin/aibox` with the module's leftovers (volumes / containers / `/etc/<name>` / units / dispatched binaries / npm packages) — `aibox purge` must be able to remove residue even AFTER the module (or aibox itself) is uninstalled (rescue: curl the single-file `bin/aibox` to /tmp and run `purge --apply`). Validator WARNs when the entry is missing; spec: `docs/module-spec.md` §Residue cleanup.

### #10 macOS bash 3.2 (arm64-darwin26 build): a failing `[[ ]]` does NOT trigger `set -e` — bats mid-test assertions are silently swallowed locally

**Symptom**: tests "pass" on the dev Mac while the identical assertions fail on CI (ubuntu). Observed twice in one day: a stale header assertion ("Available modules", removed by an earlier TUI change) and a spacing regression — both green locally, red on CI.

**Root cause** (measured, minimal repro): on this machine's `/bin/bash 3.2.57 (arm64-apple-darwin26)`:

```bash
bash -e -c '[[ a == b ]]; echo SURVIVED'   # → SURVIVED, exit 0 (!!)
bash -e -c '[ a = b ];  echo SURVIVED'     # → exits 1 (correct)
bash -e -c '[[ a == b ]] || false; echo X' # → exits 1 (correct — the workaround)
```

`[[ ]]` is a keyword, and this build fails to raise errexit for it; `[ ]` (a builtin command) works. bats runs test bodies under `set -e` and treats the test's EXIT STATUS as the verdict — so a failing `[[ ]]` in the MIDDLE of a test is ignored locally; only the last command's status decides. **Every local "green" only validates the last line of each test.**

**Consequences**:

- CI (ubuntu bash 5, correct errexit) is the AUTHORITATIVE assertion gate — never trust local-only green for assertion changes.
- A test whose final line passes can hide any number of broken assertions above it.

**Mitigations**:

- For assertions that matter mid-test: `[[ ... ]] || false` (restores errexit semantics on the quirk build), or make the critical assertion the test's LAST line.
- Verified workaround list: `|| false`, `[ ]` form, or running the suite under a correct bash (CI / `docker run bash:5`).

**Detection**: a test that should obviously fail passes locally — re-run it on ubuntu (`docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04` + `apt-get install bats`) before trusting it.

### #11 Test glob patterns: `*"X"` anchors at END-OF-STRING — a miss is pattern semantics, not a bash bug (a misdiagnosis post-mortem)

**Symptom**: an assertion like `[[ "$output" == *"pi-web"*"· ✓" ]]` fails while the output plainly contains `pi-web · ✓ running` — and it's tempting to blame the macOS bash 3.2 build.

**Root cause (verified — NOT a bash bug)**: `*"X"` requires X at the END of the
string (suffix anchor); `*"X"*` is containment. `· ✓` mid-string followed by
`running` correctly fails a suffix pattern. Measured on `/bin/bash 3.2.57
arm64-apple-darwin26` AND bash 5.3: `[[ "m 1 · ✓" == *"· ✓" ]]` matches —
multibyte tails are fine. (This entry replaces an earlier "measured bash
3.2 multibyte glob quirk" claim that was a misdiagnosis of exactly this
suffix-vs-containment mistake — caught by whole-branch review with a
cross-version repro.)

**Fix**: for containment use `*"X"*` (trailing `*`); for a real suffix test
keep `*"X"` and put X last in the string. Multibyte characters (✓ ⚠ ○ · — …)
are safe in either form.

**Detection**: when an assert contradicts visible output, test the pattern
against a string that ENDS with the literal before suspecting the shell:

```bash
[[ "x · ✓" == *"· ✓" ]]   # matches → the shell is fine; check your pattern
```

**Interaction with #10**: the suffix-pattern miss was invisible for months
because pitfall #10 swallows failing mid-test `[[ ]]` — the `|| false`
discipline is what surfaced it.

## License

MIT.

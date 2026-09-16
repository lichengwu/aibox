# Contributing to aibox

Thanks for your interest in contributing! aibox is a pure-bash module manager — zero runtime dependencies, compatible with the bash 3.2 that ships with macOS. This guide gets you productive fast.

> The canonical contributor guide (with the full pitfall log, versioning, and release flow) is [`AGENTS.md`](AGENTS.md). Read it before touching code — it documents the non-obvious bash 3.2 gotchas this project has hit.

## Quick start

```bash
git clone https://github.com/lichengwu/aibox.git
cd aibox

# trial against your working tree, no network needed:
AIBOX_RAW=file://$PWD aibox list-available
AIBOX_RAW=file://$PWD aibox install pi-web   # installs from your tree
```

Install the main CLI locally without the network:

```bash
AIBOX_BIN_DIR=$PWD/.bin AIBOX_HOME=$PWD/.aibox-local bash install.sh
```

## Project layout

```
bin/aibox            main CLI (install.sh downloads to ~/.local/bin/aibox)
install.sh           bootstrap (curl|bash install / self-update, idempotent)
registry             discovered from tools/*/module.yaml (no registry.sh anymore)
tools/<name>/        module dir: lib.sh + install/uninstall/update/svc.sh + module.yaml
docs/module-spec.md  the module hook contract
.github/workflows/   CI (release automation + lint quality gate)
```

## Bash coding conventions (mandatory)

The CI lint gate enforces these. See AGENTS.md for the full pitfall log.

1. **`set -euo pipefail`** at the top of every script.
2. **Always quote variables as `${VAR}`** (braces), never bare `$VAR` — especially when a variable is immediately followed by a **non-ASCII** character (CJK text, full-width punctuation `，。、；：`). This is pitfall #1, the project's #1 footgun. CI scans for it.
3. **Declare locals before assigning**: `local x; x="..."`, or on two lines. Pitfall #8: `local a="/etc/w" b="${a}/y"` on one line explodes under bash 3.2 + `set -u`.
4. **Idempotent**: `install.sh` / `update.sh` must be safe to re-run.
5. **No `jq` / `python`**: the registry is shell-sourceable; the main CLI sources it directly, bash 3.2 compatible.
6. **Keep full-width punctuation in Chinese copy** (README.zh.md), but always separate variable boundaries with `${VAR}`.

### Bash 3.2 is the floor

macOS ships bash 3.2.57. Do not use bash 4+ syntax (e.g. `exec {fd}>file` auto-allocated FDs — pitfall #2). Scripts that are **dispatched to Linux only** may use bash 4 features, but must remain *parseable* on bash 3.2 so the macOS host can still source/inspect them — see `require_deploy_host` in `tools/openmaic/openmaic`.

## Adding a module

1. Create `tools/<name>/` with at least `install.sh` (hook contract: [`docs/module-spec.md`](docs/module-spec.md)).
2. Add `tools/<name>/module.yaml` — the source of truth (name/version/description/dir/hooks/deps/ports/actions/...). The registry is auto-discovered from these files.
3. If the module ships a long-lived service, implement `svc.sh` with `start/stop/restart/status/logs/diagnose`.
4. Module scripts are downloaded to `~/.aibox/modules/<name>/`; reuse `lib.sh` across hooks.
5. **Install paths must be overridable**: start from `${AIBOX_BIN_DIR:-$HOME/.local/bin}` and provide a module-specific override (e.g. `OPENMAIC_BIN_DIR`) — deploy hosts often want `/usr/local/bin`.
6. **`svc.sh` is an "action entry point", not "must be a daemon"**: long-lived services (pi-web) use `start/stop/restart`; pure-CLI dispatch (openmaic) can pass actions straight through to the dispatched CLI.
7. **Platform differences: warn, don't hard-block**: install is usually cross-platform (just copying files); real platform limits are reported by the script at execution time, less false-positive-prone than blocking at install.
8. **Self-start services use the platform-native init system** — never mix: macOS → launchd (user-level `~/Library/LaunchAgents/<label>.plist`); Linux → systemd (`~/.config/systemd/user/` + `loginctl enable-linger`, no root needed). See AGENTS.md item 10.
9. Declare ports in `module.yaml` (`ports:`) — CI detects conflicts across modules.
10. If you consume the shared base (PG/Redis), declare `services: [base:postgres#<your-db>]`; CI validates the provider/component and DB-name prefix.

## Commit style

Conventional Commits: `fix:` / `feat:` / `docs:` / `style:` / `chore:`.

## Versioning & release

- Main CLI version: `AIBOX_VERSION` at the top of `bin/aibox`. **The main CLI and each module version independently** (modules' dispatched CLIs carry their own `*_CLI_VERSION`).
- Module version: the `version:` field in `tools/<name>/module.yaml`.
- **A release = bump `AIBOX_VERSION` → push main.** GitHub Actions reads it; if no matching `v<version>` tag exists remotely, it auto-creates the tag + release (notes auto-generated from the previous tag) and attaches a `SHA256SUMS` sidecar. Unchanged version → skip (idempotent).
- Self-update still runs `curl install.sh | bash` (idempotent re-install), **independent of releases** — releases are publication records. Optional `AIBOX_SHA256`/`AIBOX_VERIFY=1` add checksum verification.

## CI quality gate (`.github/workflows/lint.yml`)

- `bash -n` — syntax
- `shellcheck --severity=error` — static analysis (errors only)
- `bash32-gotchas` — regex scan for pitfalls #1 (#full-width-after-`$VAR`) and #8 (`local` same-line self-reference)
- `module-lint` — yq validates `module.yaml` (required fields, §2.2 subset, ports format, files exist, lifecycle, dashboard, component names)
- `deps-lint` — services/provides contracts + no hardcoded credentials in module composes
- `port-conflict` — no two modules declare the same port+proto

Run locally before pushing:

```bash
bash -n bin/aibox install.sh tools/*/*.sh tools/*/openmaic tools/*/windmill
# shellcheck --severity=error --external-sources --shell=bash <files>
```

## License

MIT. By contributing you agree your contributions are licensed under the project's [MIT](LICENSE) license.

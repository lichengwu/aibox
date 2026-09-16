# Security policy

## Reporting a vulnerability

If you discover a security vulnerability in aibox, please report it responsibly:

- **Preferred:** open a private security advisory on GitHub
  (`Security` tab → `Report a vulnerability`), or
- email the maintainer via the email on the GitHub profile.

**Do NOT open a public issue for security reports.** Please include:

- a description of the issue and its impact,
- reproduction steps (input, environment, aibox version),
- a suggested fix if you have one.

We will acknowledge receipt within 72 hours and aim for a fix or mitigation within 30 days for high-severity issues. Coordinated disclosure is fine — let us know your planned publication date.

## Scope

aibox is a pure-bash module manager. Security-relevant surfaces include:

- **Bootstrap / self-update**: `install.sh` and `aibox self update` run `curl|bash` from `raw.githubusercontent.com`. Since v0.4.0 the bootstrap supports **checksum verification** (`AIBOX_SHA256` to pin, or `AIBOX_VERIFY=1` to check the release `SHA256SUMS` sidecar, graceful if absent). The release workflow attaches a `SHA256SUMS` asset. **Boundary:** the check verifies the payload `bin/aibox`, **not `install.sh` itself** — a `curl|bash` MITM can serve a malicious `install.sh` that skips the check. This is inherent to `curl|bash`; for full assurance pin `AIBOX_SHA256` from a trusted channel or use `AIBOX_RAW=file://`. Also note: with `AIBOX_VERIFY=1`, `aibox self update` fetches `bin/aibox` from raw `main` but the sidecar from `releases/latest`, so a mismatch can occur when `main` is ahead of the latest release — the check is most reliable right after a release.
- **Remote `module.yaml` parsing**: the registry is fetched over HTTPS from the maintainer's own repo and parsed by a hand-written awk escaper before `eval`. CI's `module-lint` guarantees the YAML stays within the parseable subset. The trust boundary is "whatever is at `AIBOX_RAW`" — point `AIBOX_RAW` at a mirror you control or use `file://` to fully eliminate remote trust.
- **Credential handling**: proxy config and module state files are written with `umask 077` / mode `600`. Passwords are generated from `openssl rand` / `/dev/urandom` with fallbacks. Module composes must not hardcode credentials (CI `deps-lint` enforces this; the shared `base.env` + `--env-file` injection is the sanctioned path).
- **Destructive ops**: `aibox self uninstall` is fail-closed — it blocks if `$AIBOX_HOME/apps/` has deploy instances unless `--yes` is given; non-interactive environments decline by default.
- **Dispatched CLIs** (`openmaic`, `windmill`): run on Linux deploy hosts, may require root/Docker. They gate dangerous ops behind interactive confirmation (`--yes` required non-interactively) and use `flock`/lock files for concurrency.

## Hardening recommendations for users

- Pin the version: `AIBOX_SHA256=<expected> aibox self update`.
- For air-gapped / high-assurance setups, use `AIBOX_RAW=file:///path/to/aibox` so no remote fetch happens.
- Review the `base` module's default PG/Redis credentials (`aibox/aibox`, overridable via `AIBOX_BASE_POSTGRES_*`) — acceptable for loopback-only, change them before binding to a non-loopback interface.

## Out of scope

- Vulnerabilities in **upstream products** orchestrated by modules (pi-web, OpenMAIC, Windmill, mihomo, PostgreSQL, Redis) — report those to their respective projects.
- Issues that require already having compromised the user's `$HOME` or root.

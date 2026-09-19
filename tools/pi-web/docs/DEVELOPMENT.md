# pi-web Development Guide

> AI uses this guide to upgrade this module.

## upstream

- Homepage: <https://github.com/agegr/pi-web>
- Docs: <https://github.com/agegr/pi-web#readme>
- npm: <https://www.npmjs.com/package/@agegr/pi-web>

## Installation

- aibox module: `aibox install pi-web`
- upstream native: `npm install -g @agegr/pi-web`

## npm registry probe + stall watchdog (design)

- **Why**: `npm i -g` against registry.npmjs.org stalls on CN-class networks
  (measured: this package's metadata 4.3s vs 0.15s on npmmirror; worse hangs).
  npm is SILENT in non-TTY → "no progress" is unobservable from output → a
  wall-clock watchdog is the only portable stall signal.
- **Mirror candidates** (authoritative, full-sync, verified to carry this package):
  `registry.npmmirror.com` (Alibaba; official successor of the retired
  registry.npm.taobao.org), Tencent Cloud `mirrors.cloud.tencent.com/npm`,
  Huawei Cloud `mirrors.huaweicloud.com/repository/npm`; npmjs stays a candidate
  so non-CN networks keep using it when fastest.
- **Probe** (`npm_registry_pick` in lib.sh): per candidate, fetch the metadata
  (validates availability, yields latest + tarball URL), then download THAT tarball
  — the exact file npm will fetch — and rank by measured throughput (bytes/sec;
  a --max-time cutoff yields a partial-download rate, so throttled-but-alive
  registries rank honestly). Ranking adapts per network (measured: different hosts
  rank npmmirror/huawei first). The user's
  non-default `.npmrc` registry joins the candidates; `AIBOX_NPM_REGISTRY` hard-pins.
  The probe also yields `NPM_LATEST` — `update.sh` uses it instead of `npm view`
  (which has NO timeout and hangs on stalled networks).
- **Watchdog** (`npm_install_global`): `npm i -g --registry <winner>` in background;
  kill on timeout and fail over to the runner-up, once per candidate. Kill order is
  SIGTERM-to-npm FIRST, then pkill children — the reverse order lets a shell-based
  process win the race and exit 0 after its child dies (measured with the test shim).
- **module.yaml has no `domains:` gate on the npm registry** — the runtime probe
  supersedes a static npmjs-only reachability check (which would false-fail exactly
  the mirror-saved networks).
- Tests: `tests/pi-web-npm.bats` (offline, fake curl/npm shims; note bats `run`
  runs in a subshell — global-setting functions must be called directly to assert
  their side effects).

## Testing

- Service status: `aibox pi-web status`
- Health check: `curl -u pi:<password> http://127.0.0.1:30141/`
- Diagnostics: `aibox pi-web diagnose`

## Module Configuration

- Port: 30141/tcp:http (overridable via `PI_WEB_PORT`)
- Password: randomly generated (`resolve_password`, persisted to plist, read back idempotently on reinstall/update); overridden by `PI_WEB_PASSWORD`
- Deployment target: mac launchd plist (`~/Library/LaunchAgents`) / linux systemd --user (`~/.config/systemd/user/pi-web.service`)
- Autostart: mac launchd `KeepAlive` / linux systemd `Restart=always` (no root required)
- Dependencies: node 22+ (nvm auto-installs if missing) + npm
- Customization points: none (uses the upstream npm package directly; aibox only handles launchd/systemd service-ization)

## Upgrade Procedure

1. Check upstream latest version: `npm view @agegr/pi-web version`
2. `aibox update pi-web` (compares installed vs latest; upgrades the npm package + rewrites plist + prompts for restart if an update is available)
3. Verify: `aibox pi-web status` + curl health check

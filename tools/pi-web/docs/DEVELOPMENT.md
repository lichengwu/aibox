# pi-web Development Guide

> AI uses this guide to upgrade this module.

## upstream

- Homepage: <https://github.com/agegr/pi-web>
- Docs: <https://github.com/agegr/pi-web#readme>
- npm: <https://www.npmjs.com/package/@agegr/pi-web>

## Installation

- aibox module: `aibox install pi-web`
- upstream native: `npm install -g @agegr/pi-web`

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

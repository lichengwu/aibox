# gitlab — development notes

- Upstream: <https://about.gitlab.com/> (Community Edition, MIT-licensed core)
- Docs: <https://docs.gitlab.com/omnibus/docker/> (the official docker shape this
  module wraps) + <https://docs.gitlab.com/update/#upgrade-paths>
- Image: `gitlab/gitlab-ce:19.2.6-ce.0` — pinned in `module.yaml`
  (`checks.docker_images`) and `docker-compose.yml` (`GITLAB_IMAGE` default).
  Bump BOTH together; tags follow `<major>.<minor>.<patch>-ce.<build>`
  (verified against Docker Hub tags, 2026-09).

## Design decisions

- **Embedded PostgreSQL/Redis (no shared base):** the upstream docker
  distribution is supported and tested with omnibus's embedded services;
  external-PG omnibus setups exist but add reconfigure/migration complexity —
  deliberately out of scope. So this module declares NO `services:` and does
  not touch `aibox-base-*`.
- **Single instance:** fixed `container_name: aibox-gitlab` + project-scoped
  named volumes (project = deploy-root basename `gitlab`). Multi-instance
  GitLab per host is out of scope (use separate hosts/profiles of the whole
  aibox home if ever needed).
- **Ports 8929/8922, not 80/22:** aibox hosts commonly run windmill on :80 and
  sshd on :22; GitLab's SSH maps host 8922 → container 22 (gitlab-shell keeps
  its default listener; `gitlab_rails['gitlab_shell_ssh_port']` only rewrites
  the clone URLs GitLab renders).
- **host port == container HTTP port:** `external_url` embeds the port and
  omnibus derives nginx's listen port from it; mapping X:X keeps override
  semantics sane (`GITLAB_HTTP_PORT` changes both sides together).
- **Monitoring stack off** (prometheus/alertmanager/grafana) to fit 4 GB-RAM
  hosts; re-enable via `GITLAB_OMNIBUS_CONFIG` edits in the compose if needed.
- **Named volumes only** — Docker Desktop does not share `/opt` (module-spec
  §Deploy directory); bind mounts of /srv/gitlab would break mac hosts.
- **install ≠ start:** booting GitLab is heavy (3-5 min, 4 GB RAM); the install
  hook only places files, `aibox gitlab start` boots and waits (poll
  `/users/sign_in` for 200/302, `GITLAB_START_TIMEOUT` default 600s).
- **Uninstall preserves volumes:** GitLab data is irreversible to lose; the
  hook prints the exact `docker volume rm` command instead of running it.

## Known quirks

- First boot: container health stays `starting` for minutes (start_period 300s
  in the compose healthcheck); `aibox gitlab status` surfaces the health
  state so callers don't mistake booting for failure.
- `initial_root_password` (GitLab's 24h file) is deliberately NOT used for
  credentials: the docker wrapper re-runs `gitlab-ctl reconfigure` on every
  container start, which REWRITES the file's password while the DB keeps the
  first-seed one — the file stops matching reality (live-caught on a deploy
  host: the displayed password stopped logging root in). The module seeds
  `GITLAB_ROOT_PASSWORD` in the deploy `.env` at install (applies at first
  boot with fresh volumes; ENV wins over random generation per omnibus
  source) and `credentials` VERIFIES it against the live account
  (`gitlab-rails runner ... valid_password?`), printing the reset recipe
  (`gitlab-rake "gitlab:password:reset[root]"` — modern bracket syntax) when
  invalid.
- Upgrade paths are enforced by GitLab migrations, not by us: bumping
  `GITLAB_IMAGE` across majors without the staged stops can wedge the DB. The
  update hook deliberately does NOT touch `GITLAB_IMAGE`.

## Local testing

```bash
scripts/validate-module.sh gitlab     # conformance (same rules as CI)
bats tests/*.bats                        # fast suite
# live (needs docker + ~4GB RAM + ~4GB disk):
aibox install gitlab && aibox gitlab start && aibox gitlab credentials
```

## Multi-hop upgrade path (2026-09)

Upstream rule: <https://docs.gitlab.com/update/upgrade_paths/> — cross-version upgrades
must visit every required upgrade stop in order, each hop on the stop's LATEST patch
(16.8.7, not 16.8.0), background migrations finished before the next hop.

**Data source decision**: the stop table lives in `lib.sh: upgrade_stops()` — the
≤17.4 stops are FROZEN history (verified line-by-line against
`gitlab-org/gitlab config/upgrade_path.yml`); from 18.0 the official cadence is fixed
(`x.2/x.5/x.8/x.11`) so future stops are DERIVED, never table-chased. No network is
needed to compute a path (only per-hop patch resolution hits Docker Hub's tag API,
`?name=<major.minor>` — substring filter, anchored by the module's tag pattern).

**Engine**: the manager's `cmd_upgrade` detects `upgrade_stops()` in the module's
cached lib (the same implicit-function contract as `render_dashboard`/`deploy_root`),
computes the hop sequence (`_upgrade_path_compute`, pure + table-tested), and loops
`_upgrade_multi_hop`: pull → per-hop `.env` backup → rewrite → `svc.sh start`
(health gate) → settle knob → mark. Failure rolls back to the previous hop (exit 20).
Modules without `upgrade_stops()` keep the exact single-hop behavior.

**Hop gate**: `http_up_readiness` (omnibus `/-/readiness`, enabled by the
`monitoring_whitelist` compose entry) includes the db-migrations checks; falls back
to the sign-in probe on older deploys. `svc.sh start` uses it directly, so single-hop
upgrades benefit too.

**Known limitation (documented in README)**: rollback across an omnibus-internal
PostgreSQL major upgrade can refuse to boot with the newer data files — real backup
(`gitlab-backup create`) before long paths.

Conditional stops (16.0/16.1/16.2/17.1 — required only for specific data shapes) are
INCLUDED by default: minutes of extra hops vs. the risk of a broken migration.

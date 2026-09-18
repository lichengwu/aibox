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
- `initial_root_password` disappears after 24h — the `credentials` action falls
  back to printing the `gitlab-rake gitlab:password:reset` recipe.
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

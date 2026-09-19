# gitlab

GitLab CE self-hosted via the official omnibus docker image: web UI, git over
HTTP/SSH, issues, CI — with embedded PostgreSQL/Redis (upstream's supported
docker shape; this module does NOT wire GitLab to the shared aibox base).

## Commands

```text
aibox install gitlab            # place compose + write .env (does NOT start)
aibox gitlab start              # boot + wait until the UI answers (3-5 min first time)
aibox gitlab stop|restart|status|logs
aibox gitlab credentials        # initial root password (file auto-deletes 24h after first boot)
aibox update gitlab             # refresh compose; .env is never clobbered
aibox uninstall gitlab          # stop + remove compose; DATA VOLUMES ARE RETAINED
```

## Ports & endpoints

| What | Default | Override (deploy `.env`) |
| ------ | --------- | -------------------------- |
| Web UI / git HTTP | `8929` | `GITLAB_HTTP_PORT` |
| git over SSH | `8922` → container `22` | `GITLAB_SSH_PORT` |
| external_url (clone URLs) | `http://<detected-ip>:8929` | `GITLAB_EXTERNAL_URL` |
| image | `gitlab/gitlab-ce:19.2.6-ce.0` | `GITLAB_IMAGE` |

8929/8922 are deliberately NOT 80/443/22: aibox hosts commonly already run
windmill (:80) and sshd (:22). The deploy root is `$AIBOX_HOME/apps/gitlab`
(compose + `.env`); data lives in named volumes `gitlab_gitlab_{config,logs,data}`.

## Resource floors

- **RAM ≥ 4 GB free** (GitLab omnibus with prometheus/grafana disabled — this
  module turns them off by default; puma workers and sidekiq concurrency are
  conservative, tune via `GITLAB_PUMA_WORKERS` / `GITLAB_SIDEKIQ_CONCURRENCY`).
- **Disk ≥ 15 GB free** (image ≈ 3.5 GB + repos/artifacts growth) — enforced by
  the preflight `checks.disk_gb`.

## Upgrades (read before bumping)

Two verbs, two concerns:

- **`aibox update gitlab`** — refreshes the module's own scripts (compose/templates) from
  the aibox repo; the version stays on the repo-pinned floor.
- **`aibox upgrade gitlab`** — bumps the deployed GitLab **version** without an aibox
  release: resolves the latest stable `gitlab/gitlab-ce` tag from Docker Hub
  (`<dotted>-ce.0` only), pre-pulls, rewrites `GITLAB_IMAGE` in the deploy `.env`
  (backup kept), recreates + health-waits, auto-rolls-back on failure.
  `--check` is a dry run. Requires hub.docker.com reachable from the host
  (proxy/mirror), or pin directly: `aibox upgrade gitlab --to 19.3.0-ce.0`.

GitLab requires a **staged upgrade path** across major versions (e.g.
18.x → 19.0 → 19.2 — see <https://docs.gitlab.com/upgrade-paths/>), so
`aibox upgrade` auto-latest **refuses to cross a major** (16→17→…): step
explicitly with `--to <next-stop>`, watch `aibox gitlab status` until healthy,
take a backup (`docker exec aibox-gitlab gitlab-backup create`), then continue.
Same-major minor bumps are safe to auto-latest.

## Credentials

- First boot writes `/etc/gitlab/initial_root_password` inside the container
  (user `root`); GitLab **auto-deletes it after 24h** → `aibox gitlab
  credentials` shows it while it exists.
- After expiry, reset: `docker exec -it aibox-gitlab gitlab-rake gitlab:password:reset USERNAME=root`

## Docker image source pool

The compose images are pulled through the docker.io **source pool** (main
README → "Download source pools"): at start a bounded direct daemon-route
probe runs — healthy networks pull directly with zero overhead; when the
direct route is dead, mirrors (docker.1ms.run, docker.m.daocloud.io,
dockerproxy.net, hub.rat.dev — live-verified) are ranked by concurrent probe
pulls and the images are pre-pulled via `docker pull <mirror>/<image>` +
`docker tag` (mirrors proxy identical digests), so `compose up` finds them
cached.

| Variable | Default | Description |
| --- | --- | --- |
| `AIBOX_DOCKER_POOL` | shipped pool | mirror list override (`direct` = no pool) |
| `AIBOX_DOCKER_MIRROR` | (unset) | your mirror — joins the race first |
| `AIBOX_DOCKER_FORCE_POOL` | `0` | `1` = skip the direct probe, always engage |

## Preflight

Declared in `module.yaml` `checks:` (disk 15G + daemon pull probe + cached-image
short-circuit) — enforced by `aibox install/update`; manual run:

```text
aibox check gitlab
```

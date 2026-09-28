# gitlab

GitLab CE self-hosted via the official omnibus docker image: web UI, git over
HTTP/SSH, issues, CI — with embedded PostgreSQL/Redis (upstream's supported
docker shape; this module does NOT wire GitLab to the shared aibox base).

## Commands

```text
aibox install gitlab            # place compose + write .env (does NOT start)
aibox gitlab start              # boot + wait until the UI answers (3-5 min first time)
aibox gitlab stop|restart|status|logs
aibox gitlab credentials        # root password (seeded, verified against the live account)
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
  release. **Multi-hop aware** (see below): when the target is several stops away, the
  engine walks the official required-upgrade-stops path one hop at a time, each hop
  landing on that minor's **latest patch**, health-gated (readiness, incl. db migrations)
  before the next hop, with per-hop backup + rollback to the previous hop on failure.
  `--check` is a dry run that prints the whole hop table. Requires hub.docker.com
  reachable from the host (proxy/mirror), or pin directly: `aibox upgrade gitlab --to 19.3.0-ce.0`.

### The staged upgrade path (official rule, now automated)

GitLab mandates required upgrade stops between versions
(<https://docs.gitlab.com/update/upgrade_paths/>): every stop between your current and
target version must be visited **in order**, each hop on the stop's latest patch, and
background migrations must finish before the next hop. The CLI computes this path from
the module's stop table (frozen ≤17.4 history + the official ≥18 cadence `x.2/x.5/x.8/x.11`):

```
$ aibox upgrade gitlab --to 19.8.3-ce.0 --check
current : 19.2.6-ce.0
target  : 19.8.3-ce.0
path    : 1 required upgrade stop(s) …
  hop 1/2  19.5.z → latest patch of 19.5    required stop
  hop 2/2  19.8.3-ce.0    target
```

- `AIBOX_UPGRADE_HOP_SETTLE=<seconds>` — extra wait between hops for background
  migrations on big instances (the readiness gate already covers the db-migration
  checks; default 0).
- Cross-major auto-latest (`aibox upgrade gitlab` with no `--to`) is **allowed** for
  this module: the hop sequence is the migration-safe path the guardrail demands.
- Rollback honesty: a failed hop restores the previous hop's image and recreates —
  but omnibus's bundled PostgreSQL upgrades its data files in-place per major; rolling
  back ACROSS a PG upgrade may refuse to boot with the newer data. Take a real backup
  first on long paths: `docker exec aibox-gitlab gitlab-backup create`.

## Credentials

- `aibox gitlab credentials` shows the seeded `GITLAB_ROOT_PASSWORD` (generated at
  install, stored in the deploy `.env`, never rotated) **and verifies it against the
  live root account** — the printed verdict comes from GitLab itself, not a file.
- The seed applies at **first boot with fresh volumes** (compose passes it to the
  container; omnibus prefers the env over random generation). Volumes seeded before
  the seed existed ignore it — `credentials` detects that (INVALID) and prints the
  reset recipe.
- Reset (also the recovery for any stale password):
  `docker exec -it aibox-gitlab gitlab-rake "gitlab:password:reset[root]"`
- GitLab's own `/etc/gitlab/initial_root_password` (24h file) is deliberately NOT
  used: every container restart re-runs reconfigure, which rewrites that file while
  the database keeps the first-seed password — the file stops matching reality
  (live-caught on a deploy host).

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

## Diagnostics

`aibox gitlab doctor` — declared deps, docker daemon reachability, the module's own
reported state (`status_info`) and its declared port listeners. Shared
implementation (`module_doctor`, `tools/_shared/common.sh`), local-only:
exit `0` healthy · `3` a dependency is missing · `30` the service is not ready.

<!-- BEGIN GENERATED: actions (scripts/gen-docs.sh) -->
| action | what it does |
| --- | --- |
| `start` | Start the container (source pool pulls; 3-5 min first boot) |
| `stop` | Stop the container |
| `restart` | Recreate the container |
| `status` | Container + web health + rich view |
| `doctor` | Deep diagnostics: deps, docker, state, declared ports |
| `logs` | Container logs |
| `credentials` | Show the seeded root password + verify it against the live account |
| `config` | Show/set config keys (store: apps/gitlab/.env) |
| `backup` | Create a GitLab backup inside the container (docker cp to fetch) |
| `restore` | DESTRUCTIVE: restore a backup tar (same version). Two-gate: --yes |
| `import-secrets` | Import another instance's gitlab-secrets.json (needed before its restore) |
<!-- END GENERATED: actions -->
<!-- BEGIN GENERATED: config (scripts/gen-docs.sh) -->
| key | default | notes |
| --- | --- | --- |
| `GITLAB_EXTERNAL_URL` | `http://localhost:31110` | external URL GitLab renders in links |
| `GITLAB_HTTP_PORT` | `31110` | host HTTP port (upstream default 80 is privileged; the aibox band avoids collisions) |
| `GITLAB_SSH_PORT` | `31222` | host SSH clone port |
| `GITLAB_ROOT_PASSWORD` | `random` | root password seeded at install; applies at first boot with fresh volumes (verify: aibox gitlab credentials) (secret) |
| `GITLAB_HTTPS_ENABLE` | `false` | true = nginx serves TLS (self-signed if no cert) |
| `GITLAB_HTTPS_PORT` | `31143` | must equal the port in GITLAB_EXTERNAL_URL |
| `GITLAB_TLS_DIR` | `<deploy root>/ssl` | gitlab.crt (incl. chain) + gitlab.key |
| `GITLAB_HTTPS_REDIRECT` | `false` | true = redirect plain HTTP to HTTPS |
| `GITLAB_PUMA_WORKERS` | `2` | rails workers |
| `GITLAB_SIDEKIQ_CONCURRENCY` | `10` | background job workers |
| `AIBOX_DOCKER_POOL` | `shipped pool` | docker.io mirror list override (knob) |
| `AIBOX_DOCKER_MIRROR` | `(unset)` | user mirror, tried first (knob) |
| `AIBOX_DOCKER_FORCE_POOL` | `0` | 1 = skip the direct probe, always engage the pool (knob) |
<!-- END GENERATED: config -->

## HTTPS / TLS (opt-in)

The module ships HTTP-only by default (it is happy behind a reverse proxy). For a
deployment that terminated TLS itself — the usual case when migrating a native
omnibus install — turn it on:

```bash
aibox gitlab config set GITLAB_HTTPS_ENABLE true
aibox gitlab config set GITLAB_HTTPS_PORT 443            # must equal the port in the URL below
aibox gitlab config set GITLAB_EXTERNAL_URL https://gitlab.example.com
aibox gitlab config set GITLAB_HTTPS_REDIRECT true       # plain HTTP redirects to HTTPS
# drop your certs in: <deploy root>/ssl/gitlab.crt (with chain) + gitlab.key
aibox gitlab restart
```

- The cert pair is **operator state** (`state_files: ssl/`): hooks never overwrite
  it. When HTTPS is on and the pair is missing, `start` generates a self-signed one
  and says so — replace it with your real cert and restart.
- The TLS port and the port inside `GITLAB_EXTERNAL_URL` must match: omnibus
  derives nginx's TLS listener from `external_url`, not from a separate knob.
- certs are read-only inside the container (`./ssl:/etc/gitlab/ssl:ro`).

## Backup, restore, and migrating a native install

```bash
aibox gitlab backup                       # tar inside the container's data volume
docker cp aibox-gitlab:/var/opt/gitlab/backups/<tar> .    # fetch it (printed by backup)
aibox gitlab import-secrets <gitlab-secrets.json> --yes   # secrets of the SOURCE instance
aibox gitlab restore <tar|latest> --yes   # DESTRUCTIVE: overwrites DB + repositories
```

- **Same version only.** GitLab refuses (and should refuse) a restore whose backup
  version differs from the running instance — pin `GITLAB_IMAGE` to the source
  version first (`aibox gitlab config set GITLAB_IMAGE gitlab/gitlab-ce:<ver>-ce.0`).
- **Secrets before restore.** Import the source's `gitlab-secrets.json` first:
  without it every encrypted column (CI variables, runner tokens, 2FA) stays
  unreadable and the failure is silent. `restore` warns when the file is missing.
- Both `restore` and `import-secrets` are two-gated: `--yes` (or an interactive
  confirm). `restore` stops puma+sidekiq, restores, restarts, then waits for the
  web endpoint (`GITLAB_RESTORE_WAIT` seconds, default 900).

### Recipe: native omnibus package → aibox-managed (measured, 18.9.1)

```bash
# 1. on the SOURCE: backup + the two files that carry identity
sudo gitlab-backup create CRON=1
sudo install -d /root/gitlab-migration && sudo cp -a /etc/gitlab/gitlab.rb \
     /etc/gitlab/gitlab-secrets.json /etc/gitlab/ssl /root/gitlab-migration/
# 2. on the TARGET (same machine or a new one): aibox + docker, then the module,
#    pinned to the source version and the SAME ports/URL
aibox install gitlab
aibox gitlab config set GITLAB_IMAGE gitlab/gitlab-ce:18.9.1-ce.0
aibox gitlab config set GITLAB_HTTP_PORT 80          # keep the old public ports
aibox gitlab config set GITLAB_HTTPS_PORT 443
aibox gitlab config set GITLAB_HTTPS_ENABLE true
aibox gitlab config set GITLAB_EXTERNAL_URL https://gitlab.example.com
cp /root/gitlab-migration/ssl/gitlab.lichengwu.cn_public.crt <deploy>/ssl/gitlab.crt
cp /root/gitlab-migration/ssl/gitlab.lichengwu.cn.key        <deploy>/ssl/gitlab.key
aibox gitlab start                                   # first boot takes minutes
aibox gitlab import-secrets /root/gitlab-migration/gitlab-secrets.json --yes
aibox gitlab restore /root/gitlab-migration/<ts>_<date>_<ver>_gitlab_backup.tar --yes
# 3. verify (counts must match the source), then retire the source:
#    gitlab-ctl stop && systemctl disable gitlab-runsvdir
```

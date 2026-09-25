# clash

> Clash subscription proxy pool — orchestrates the local mihomo core; auto-tests subscription nodes for the fastest, auto-fails over on failure.

`aibox clash` turns a clash subscription URL into aibox's egress: aibox ships the mihomo binary, generates a config that hands the subscription to mihomo's `proxy-providers`, mihomo automatically pulls/parses/tests/switches, and aibox points the egress at the local mixed port.

## How it works

```
Subscription URL ──clash set──> apps/clash/config.yaml (proxy-providers + url-test group)
                              │
        mihomo daemon ──> local mixed port 127.0.0.1:7890 (socks5+http)
            ├─ auto-pull subscription (24h) / test latency (5min) / pick fastest / fail over
            └─ external-controller 127.0.0.1:9090 (aibox calls it reload/select/status)
                              │
        aibox egress ──> socks5://127.0.0.1:7890 (overrides static proxy when clash is on)
```

Latency testing, picking the fastest, and fail-over are **all delegated to mihomo's `url-test`/`fallback` strategy groups** — aibox implements no switching logic of its own; it only orchestrates (download the core, generate config, start/stop the process, refresh the fallback).

## Commands

```
aibox install clash               Install the mihomo core (aibox auto-downloads the binary)
aibox clash set <subscription URL>  Save the subscription + generate config + pull a subscription cache once
aibox clash on | off               Start/stop mihomo (after `on`, aibox egress auto-switches to the local port)
aibox clash restart                Restart
aibox clash status                 mihomo status + current node + subscription/refresh time
aibox clash refresh                Force-refresh the subscription (overrides the 1-week fallback)
aibox clash select <node name>     Manually switch to a node (via the API)
aibox clash test [url]             Probe through the local 7890 port
aibox clash logs                   View mihomo logs
aibox clash doctor                 Self-check (binary/process/config/subscription cache)
aibox clash set/refresh auto re-pulls the subscription if the cache is older than 1 week
```

## Relationship with the static proxy

Priority: **clash on > static proxy (`aibox proxy set`) > direct**.

- `aibox clash on` → aibox egress = `socks5://127.0.0.1:7890` (local mihomo)
- `aibox clash off` → falls back to the static proxy set via `aibox proxy set`, or direct

The two coexist: the static proxy acts as a fallback, the clash pool as the primary.

## Cold start (when the subscription site is blocked)

The clash pool needs a subscription to come up, but **pulling the subscription itself requires access to the subscription site** — if the subscription site is interfered with domestically (connection EOF), aibox/mihomo cannot fetch it directly and the node list is empty.

In that case, first use a static proxy to pull the subscription by hand:

```bash
aibox proxy set http://<proxy that can reach the subscription site>   # temporary static proxy
aibox clash refresh                          # aibox fetches the subscription through the static proxy into the pool.yaml cache
aibox clash on                               # mihomo comes up using the cached nodes
aibox proxy off                              # optional: stop the static proxy, egress now goes through the clash pool
```

mihomo is a nohup child process that inherits aibox's `http_proxy` at startup — if a proxy is present in the environment at startup, mihomo's own subsequent subscription refreshes will also go through it. Day-to-day, mihomo `interval:86400` auto-refreshes; aibox fallback: on `clash status`/`on` it checks `state.LAST_REFRESH` and re-pulls if older than 1 week.

## Refresh strategy

Two complementary layers:

1. **Inside mihomo**: `proxy-providers.interval: 86400` (auto-pull subscription every 24h)
2. **aibox fallback**: on `clash status`/`clash on` it checks `state.LAST_REFRESH`; if older than 1 week (or never refreshed), aibox itself `curl`s the subscription again, overwrites `pool.yaml`, and triggers a mihomo reload. A manual `clash refresh` triggers this immediately.

## Fail-over

- `AUTO` (url-test) group: probes each node's latency every 5 minutes and picks the lowest; a dead node has latency=∞ and is skipped automatically
- `FALLBACK` group: ordered; if the current one is unavailable it auto-switches to the next
- aibox does not participate in switching; `clash status` calls `/proxies/AUTO` to report the current node

## Layout (module-spec deployment conventions)

| Path | Content | Permission |
| --- | --- | --- |
| `${AIBOX_BIN_DIR}/mihomo` | mihomo binary (shipped by aibox) | 0755 |
| `$AIBOX_HOME/apps/clash/config.yaml` | generated mihomo config | 600 |
| `$AIBOX_HOME/apps/clash/providers/pool.yaml` | subscription cache | 600 |
| `$AIBOX_HOME/apps/clash/state` | subscription URL/secret/port/refresh time | 600 |
| `$AIBOX_HOME/apps/clash/logs/mihomo.log` | logs | — |

## Environment variable overrides

| Variable | Default | Description |
| --- | --- | --- |
| `CLASH_BIN_DIR` | `AIBOX_BIN_DIR` → `~/.local/bin` | mihomo binary location |
| `CLASH_BASE_DIR` | `$AIBOX_HOME/apps/clash` | deployment root override |
| `CLASH_MIRROR` | (unset) | GitHub mirror prefix — JOINS the download pool as a candidate (raced, not pinned) |
| `AIBOX_GH_POOL` | shipped pool | mirror list override (`direct` = no pool) |
| `CLASH_PROBE_TIME` | `5` | per-source rate-probe seconds |
| `CLASH_DOWNLOAD_TIMEOUT` | `120` | per-attempt download window seconds |
| `CLASH_DOWNLOAD_ATTEMPTS` | `2` | attempts PER SOURCE before failover |
| `CLASH_TAG_TIMEOUT` | `10` | version-resolve race timeout seconds |
| `CLASH_PORT` | `7890` | mixed port |
| `CLASH_API_PORT` | `9090` | external controller port |

## Download source pool (the mihomo binary)

The binary comes from a GitHub release (~20MB) — on CN-class networks direct
release downloads are throttled to a crawl (measured: ~21KB/s on Aliyun) or reset.
The install hook now runs the same pattern as aibox's other downloads:

- **Version resolve** (`clash_gh_get`): races DIRECT + the mirror pool
  concurrently; the first complete response wins.
- **Rate-probe ranking** (`clash_rank_candidates`): every candidate gets a
  bounded (~5s) partial download of the ACTUAL release asset; candidates are
  ranked by measured bytes/sec. The winner's partial is a real prefix of the
  asset — it seeds the resumable download (on fast routes the probe even
  completes the whole file).
- **Verification-gated failover** (`download_mihomo` + `_clash_verify_gz`):
  every completed body is verified BEFORE acceptance — gzip integrity AND the
  payload runs `-v` reporting the pinned tag. A mirror can serve a valid gzip
  of the WRONG thing (error page / other asset; live-caught: "fast route"
  completed, binary died, install died with it). A verified-bad COMPLETE body
  is discarded and the next source is tried; an INCOMPLETE gzip stays as a
  resumable partial (mirrors proxy the identical asset).
- **Resumable failover** (`download_mihomo`): the throttled-CDN lesson
  (partials carry across attempts) extends across sources — mirrors proxy the
  identical asset bytes, so a partial from one source resumes on another.
  Per-source attempt windows (default 2) then fail over down the measured
  ranking; every reachable source is tried before dying.

Candidate pool (live-verified on a CN mac + an Aliyun host): **gh-proxy.com**
(proxies github releases + api), **ghproxy.net**; ghproxy.link / ghproxy.cn
served corrupt content — excluded. `CLASH_MIRROR` / `AIBOX_GH_MIRROR` join as
high-priority candidates (raced, not pinned — the fastest route serves).
`AIBOX_GH_POOL="url..."` overrides the pool; `direct` disables it.

## Design trade-offs

- **Does not parse the subscription yaml itself**: mihomo natively consumes the subscription URL; aibox does not write a yaml parser (parsing clash yaml in pure bash is fragile; format changes are handled by mihomo).
- **Latency testing/switching delegated to mihomo**: the `url-test`/`fallback` strategy groups are mature; aibox only calls the API to report/trigger.
- **nohup+pid for a simple daemon**: works immediately cross-platform (macOS/Linux) without depending on launchd/systemd unit files. If mihomo dies, aibox detects `CLASH_ENABLED` but no port response and falls back to the static proxy (no silent failure). A systemd/launchd unit for boot-time auto-start is a future optional enhancement.
- **mihomo is shipped by aibox**: users need not install it manually; the install hook downloads the matching-platform binary from the GitHub release — through the source pool (direct + mirrors, rate-probed, resumable failover) above.

## Standard actions

`aibox clash start|stop|restart|status|logs` — the shared lifecycle; `dashboard` is the
rich view (alias of `status`), and `doctor` is the standard diagnostic (deps, docker,
state, declared ports; see below).

#!/usr/bin/env bats
# GitLab multi-hop upgrade path — the required-upgrade-stops rule
# (docs.gitlab.com/update/upgrade_paths) as implemented by the module's
# upgrade_stops() + the manager's _upgrade_path_compute / _upgrade_multi_hop.
# Pure-function table tests + a mocked 2-hop execution with rollback.
# (Functions are sourced via test_helper into THIS shell — call them directly,
# never `bash -c`, which would lose them.)

load test_helper

STOPS_ALL="15.0 15.4 15.11 16.0 16.1 16.2 16.3 16.7 16.11 17.1 17.3 17.5 17.8 17.11 18.2 18.5 18.8 18.11 19.2 19.5 19.8 19.11"

@test "_upgrade_path_compute: 17.3 → 19.2 walks every stop (7 intermediates)" {
  out="$(printf '%s\n' ${STOPS_ALL} | _upgrade_path_compute 17.3.7-ce.0 19.2.6-ce.0)"
  [ "$out" = "17.5
17.8
17.11
18.2
18.5
18.8
18.11" ]
}

@test "_upgrade_path_compute: same-minor patch upgrade → no intermediate hops" {
  out="$(printf '%s\n' ${STOPS_ALL} | _upgrade_path_compute 19.2.1-ce.0 19.2.6-ce.0)"
  [ -z "$out" ]
}

@test "_upgrade_path_compute: adjacent stop (16.3→16.11) → single intermediate" {
  out="$(printf '%s\n' 16.3 16.7 16.11 17.1 | _upgrade_path_compute 16.3.9-ce.0 16.11.10-ce.0)"
  [ "$out" = "16.7" ]
}

@test "_upgrade_path_compute: target minor IS a stop → no trailing hop for it" {
  # 17.5 → 17.8.7: the 17.8 stop equals the target minor — landing there IS the stop
  out="$(printf '%s\n' 17.5 17.8 17.11 | _upgrade_path_compute 17.5.5-ce.0 17.8.7-ce.0)"
  [ -z "$out" ]
}

@test "_upgrade_path_compute: conditional stops are included (safe default)" {
  # 16.1 → 16.4 must stop at 16.2 AND 16.3 (conditional in that range — included)
  out="$(printf '%s\n' 16.1 16.2 16.3 16.7 | _upgrade_path_compute 16.1.8-ce.0 16.4.2-ce.0)"
  [ "$out" = "16.2
16.3" ]
}

@test "_upgrade_path_compute: stops at/below current are excluded (idempotent re-run)" {
  out="$(printf '%s\n' ${STOPS_ALL} | _upgrade_path_compute 18.11.10-ce.0 19.4.0-ce.0)"
  [ "$out" = "19.2" ]
}

@test "gitlab upgrade_stops(): frozen history + ≥18 derived cadence" {
  out="$(. "$REPO_ROOT/tools/gitlab/lib.sh"; upgrade_stops 0.0 19.11 | tr '\n' ' ')"
  # frozen tail + derived 18/19 cadence
  [[ "$out" == *"17.3 17.5 17.8 17.11 "* ]]
  [[ "$out" == *" 18.2 18.5 18.8 18.11 "* ]]
  [[ "$out" == *" 19.2 19.5 19.8 19.11"* ]]
  # conditional stops included
  [[ "$out" == *" 16.0 16.1 16.2 16.3 "* ]]
  # nothing ≥20 derived when target is 19
  [[ "$out" != *"20."* ]]
}

@test "_upgrade_hop_latest_patch: highest patch, anchored to the minor (no 17.80/8.17.8)" {
  # mock the CURRENT fetch seam (dockerhub_tags_fetch — the resolver's input
  # since the docker source selector landed): tag names, one per line. Mocking
  # the old upgrade_fetch silently made this test NETWORK-dependent (it kept
  # passing only while the runner's egress happened to reach hub.docker.com
  # AND the real data matched the expectation — live-caught in the container).
  dockerhub_tags_fetch() { cat <<'MOCK'
17.8.6-ce.0
8.17.8-ce.0
17.8.7-ce.0
17.80.1-ce.0
MOCK
  }
  out="$(_upgrade_hop_latest_patch "gitlab/gitlab-ce" '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' "17.8")"
  # 17.80 must NOT match (prefix anchor), 8.17.8 must NOT match, highest patch wins
  [ "$out" = "17.8.7-ce.0" ]
}

@test "_upgrade_multi_hop: 2 hops — hop-2 failure rolls back to hop-1's version" {
  local root envf svc
  root="$(mktemp -d)"
  envf="$root/.env"
  printf 'GITLAB_IMAGE=gitlab/gitlab-ce:19.2.6-ce.0\n' >"$envf"
  # stub svc: exit 0 on first invocation, 1 on the second (hop 2 fails)
  svc="$root/svc.sh"
  cat >"$svc" <<STUB
#!/usr/bin/env bash
n="\$(cat '$root/hopcount' 2>/dev/null || echo 0)"
n=\$((n + 1)); echo "\$n" > '$root/hopcount'
[ "\$n" -eq 2 ] && exit 1
exit 0
STUB
  chmod +x "$svc"
  # mocks: docker always cached; hop patch resolution fixed; installed marker no-op
  docker() { return 0; }
  _upgrade_hop_latest_patch() { printf '19.5.9-ce.0'; }
  mark_installed() { :; }

  run _upgrade_multi_hop gitlab 19.2.6-ce.0 "$envf" "$svc" \
    "GITLAB_IMAGE=gitlab/gitlab-ce:" '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' gitlab/gitlab-ce dockerhub-tags 0 19.5 19.8.3-ce.0
  # 10 = "upgrade failed, rolled back" (spec §Exit codes): the mid-path rollback to
  # hop 1 is a healthy, resumable state — 20 is reserved for a failing rollback
  [ "$status" -eq 10 ]
  [[ "$output" == *"hop 1/2: 19.5.9-ce.0"* ]]
  [[ "$output" == *"hop 2/2: 19.8.3-ce.0"* ]]
  [[ "$output" == *"rolled back to 19.5.9-ce.0"* ]]
  # rollback restored hop-1's image (not the original, not the failed hop-2)
  [ "$(grep -m1 '^GITLAB_IMAGE=' "$envf" | cut -d= -f2-)" = "gitlab/gitlab-ce:19.5.9-ce.0" ]
  # hop-1 backup holds the ORIGINAL image (the pre-upgrade state)
  [ "$(grep -m1 '^GITLAB_IMAGE=' "$envf".hop1.* | cut -d= -f2-)" = "gitlab/gitlab-ce:19.2.6-ce.0" ]
  rm -rf "$root"
}

@test "_upgrade_multi_hop: both hops healthy → exit 0, .env at the final target" {
  local root envf svc
  root="$(mktemp -d)"
  envf="$root/.env"
  printf 'GITLAB_IMAGE=gitlab/gitlab-ce:19.2.6-ce.0\n' >"$envf"
  svc="$root/svc.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$svc"
  chmod +x "$svc"
  docker() { return 0; }
  _upgrade_hop_latest_patch() { printf '19.5.9-ce.0'; }
  mark_installed() { :; }

  run _upgrade_multi_hop gitlab 19.2.6-ce.0 "$envf" "$svc" \
    "GITLAB_IMAGE=gitlab/gitlab-ce:" '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' gitlab/gitlab-ce dockerhub-tags 0 19.5 19.8.3-ce.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"upgraded to 19.8.3-ce.0 through 1 required stop(s)"* ]]
  [ "$(grep -m1 '^GITLAB_IMAGE=' "$envf" | cut -d= -f2-)" = "gitlab/gitlab-ce:19.8.3-ce.0" ]
  rm -rf "$root"
}

@test "render_dashboard: no docker → degrades, exit 0 under set -euo pipefail" {
  run bash -c "set -euo pipefail; PATH=/usr/bin:/bin; . '$REPO_ROOT/tools/gitlab/lib.sh'; render_dashboard"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"not running (aibox gitlab start)"* ]] || false
}

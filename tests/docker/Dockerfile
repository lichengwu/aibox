# aibox docker test image — the reproducible test environment (tests/docker/run.sh).
#
# Why a container at all: the fast suite must be runnable identically on a dev Mac
# (bash 3.2), a Linux deploy host and CI, and the historical bugs were repeatedly
# "green locally, red on CI" because of environment differences (root vs non-root,
# GNU vs BSD tools, bash 3.2 vs 5). One image removes the "works on my machine"
# class from the equation.
#
# Contents: bats (the runner), shellcheck (the lint gate CI enforces at error
# level), yq (module.yaml well-formedness), expect (TUI/prompt tests — AGENTS.md
# pitfall #7: `script` is unreliable for pty tests), curl/git/python3 (fixtures),
# gawk (pattern parity with the macOS/CI awk), a NON-ROOT user `tester` (the CI
# parity run: root can mask permission bugs — live-caught twice).
#
# NOTE: bash 3.2 itself is NOT reproducible here (it predates every supported
# distro). The macOS CI job (`lint.yml: macos-bash32`) stays the authoritative 3.2
# runtime gate; this image runs the same suite plus the static 3.2 checks the
# validator can do (parse-compat + the gotcha scanners).
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      bats \
      bash \
      shellcheck \
      expect \
      curl \
      ca-certificates \
      git \
      python3 \
      gawk \
      jq \
      unzip \
      make \
      coreutils \
      procps \
      iproute2 \
      lsof \
      gzip \
      tar \
      rsync \
      netcat-openbsd \
      docker.io \
      docker-compose-v2 \
    && rm -rf /var/lib/apt/lists/*
# docker.io brings the CLI (the integration suites drive a REAL daemon): the
# harness mounts the host's /var/run/docker.sock for --integration, so nothing
# runs a nested daemon here.

# yq: the GO implementation (mikefarah), the same one CI installs — the apt
# package is a different (python) implementation with divergent CLI semantics.
RUN curl -fsSL -o /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    && chmod +x /usr/local/bin/yq \
    && yq --version

# Non-root runner for the CI-parity pass. It needs a writable HOME (bats uses
# TMPDIR) and, for bash-3.2-style checks, no assumptions about /root.
RUN useradd -m -s /bin/bash tester \
    && mkdir -p /repo \
    && chown tester:tester /repo

# Do not run as root by default: the harness switches identities explicitly.
WORKDIR /repo
CMD ["bats", "tests"]
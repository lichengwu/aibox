# ---------- mihomo kernel acquisition ----------
# Split out of lib.sh (D3): downloading the kernel (direct/mirror/GitHub API) is its
# own domain. Sourced by lib.sh, cache layout first.

download_mihomo() {
  local ver asset url tmp attempt cands cand ok rankf psz tsz
  ver="${1:-$(latest_mihomo_tag)}"
  [ -n "$ver" ] || die "Cannot get the latest mihomo version (network? every source-pool candidate failed — set a proxy (run: aibox proxy set) and retry, or pin AIBOX_GH_POOL)"
  asset="$(detect_asset)-v${ver}.gz"
  url="https://github.com/MetaCubeX/mihomo/releases/download/v${ver}/${asset}"
  log "Downloading mihomo v${ver} -> ${asset}"
  mkdir -p "${CLASH_BIN_DIR}"
  # Versioned temp file: a stale partial of a DIFFERENT version must never be
  # resumed into corruption (curl -C - would request a bogus byte range).
  tmp="${CLASH_BIN_DIR}/mihomo-${ver}.gz"
  # Source pool: rank the candidates by MEASURED download rate (bounded partial
  # downloads of the actual asset, concurrent). Called directly + ranked via a
  # file (a $( ) capture would lose the CLASH_PROBE_PARTIAL global).
  rankf="$(mktemp "${TMPDIR:-/tmp}/clashrank.out.XXXXXX")" || rankf="/tmp/clashrank.out.$$"
  clash_rank_candidates "$url" "$rankf"
  cands="$(cat "$rankf")"
  rm -f "$rankf"
  [ -n "$cands" ] || die "no download candidates for ${url}"
  # Seed the resumable tmp with the probe winner's partial — ONLY when it is
  # larger than any partial already on disk (a previous attempt's progress
  # must not be clobbered by a smaller probe partial).
  if [ -n "${CLASH_PROBE_PARTIAL}" ] && [ -s "${CLASH_PROBE_PARTIAL}" ]; then
    psz="$(wc -c <"${CLASH_PROBE_PARTIAL}" | tr -d ' ')"
    tsz=0
    if [ -f "$tmp" ]; then tsz="$(wc -c <"$tmp" | tr -d ' ')"; fi
    if [ "${psz:-0}" -gt "${tsz:-0}" ]; then
      cp -f "${CLASH_PROBE_PARTIAL}" "$tmp"
      if _clash_verify_gz "$tmp" "$ver"; then
        log "  fast route: the rate probe already fetched the whole file (verified)"
      fi
    fi
  fi
  # Resumable failover loop: throttled release CDNs (measured: ~21KB/s on
  # Aliyun direct) cannot finish inside one --max-time window — partials carry
  # across attempts AND across sources (mirrors proxy the identical asset).
  # Per-source attempt windows (CLASH_DOWNLOAD_ATTEMPTS, now per source,
  # default 2) then fail over down the measured ranking; every reachable source
  # is tried before dying.
  ok=0
  # shellcheck disable=SC2086
  for cand in $cands; do
    if _clash_verify_gz "$tmp" "$ver"; then
      ok=1
      break
    fi
    log "  source: ${cand}"
    attempt=0
    until _clash_verify_gz "$tmp" "$ver" ||
      curl -fsSL -C - --max-time "${CLASH_DOWNLOAD_TIMEOUT:-120}" "$cand" -o "$tmp"; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge "${CLASH_DOWNLOAD_ATTEMPTS:-2}" ]; then
        warn "  ${cand}: interrupted ×${attempt} — failing over to the next source"
        break
      fi
      warn "  attempt $((attempt + 1)) interrupted — resuming partial download..."
    done
    if _clash_verify_gz "$tmp" "$ver"; then
      ok=1
      break
    fi
    # Distinguish the two failure shapes: an INCOMPLETE gzip (gunzip -t fails)
    # is a resumable partial — mirrors proxy the identical asset, so it carries
    # over to the next source. A COMPLETE gzip whose payload is not the mihomo
    # we asked for (mirror garbage / wrong asset) can never resume into
    # goodness — discard it so the next source starts clean.
    if [ -f "$tmp" ] && gunzip -t "$tmp" 2>/dev/null; then
      warn "  ${cand}: complete body failed verification (not a runnable mihomo v${ver}) — discarding, trying the next source"
      rm -f "$tmp"
    fi
  done
  [ "$ok" = 1 ] || die "Download failed on every source tried ($(printf '%s' "$cands" | tr '\n' ' ')); $(du -h "$tmp" 2>/dev/null | cut -f1) partial retained
  Hint: a HTTP/SOCKS proxy →  aibox proxy set <url>
        pin a mirror       →  CLASH_MIRROR=https://gh-proxy.com aibox install clash"
  gunzip -f "$tmp" || die "Decompress failed (mihomo .gz)"
  mv -f "${tmp%.gz}" "$KERNEL_DEST"
  chmod 0755 "${KERNEL_DEST}"
  "${KERNEL_DEST}" -v >/dev/null 2>&1 || die "Downloaded binary won't run (arch mismatch? asset=$(detect_asset), host=$(uname -s)/$(uname -m))"
  log "Placed mihomo v${ver} -> ${KERNEL_DEST}"
}
clash_gh_get() { # $1=url → body on stdout; nonzero when every candidate fails
  local url="$1" tmpd pid pids="" body="" rounds i j p candurl
  case "${AIBOX_GH_POOL:-}" in
  direct)
    curl -fsSL --max-time "${CLASH_TAG_TIMEOUT:-10}" "$url" 2>/dev/null
    return $?
    ;;
  esac
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/clashget.XXXXXX")" || return 1
  i=0
  while read -r p; do
    i=$((i + 1))
    candurl="$(_clash_cand_url "$p" "$url")"
    printf '%s\n' "${candurl}" >"$tmpd/u${i}"
    (
      curl -fsSL --max-time "${CLASH_TAG_TIMEOUT:-10}" "${candurl}" -o "$tmpd/b${i}" 2>/dev/null &&
        : >"$tmpd/b${i}.ok"
    ) &
    pids="${pids} $!"
  done < <(_clash_gh_candidates)
  rounds=0
  while [ -z "${body}" ] && [ "${rounds}" -lt 80 ]; do
    for ((j = 1; j <= i; j++)); do
      if [ -f "$tmpd/b${j}.ok" ]; then
        body="$tmpd/b${j}"
        break
      fi
    done
    if [ -n "${body}" ]; then break; fi
    sleep 0.25
    rounds=$((rounds + 1))
  done
  # SIGTERM to workers FIRST, then orphaned curl children (kill-order lesson);
  # the loop-level 2>/dev/null also silences bash's job-termination notices.
  # shellcheck disable=SC2086
  for pid in $pids; do
    kill "${pid}" 2>/dev/null || true
    pkill -P "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done 2>/dev/null
  if [ -n "${body}" ] && [ -s "${body}" ]; then
    cat "${body}"
    rm -rf "${tmpd}"
    return 0
  fi
  rm -rf "${tmpd}"
  return 1
}

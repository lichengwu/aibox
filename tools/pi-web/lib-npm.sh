# ---------- npm / node resolution ----------
# Split out of lib.sh (D3): finding the npm prefix, the node binary and installing
# the global package is its own domain. Sourced by lib.sh, cache layout first.

npm_registry_pick() {
  NPM_REGISTRY=""
  NPM_LATEST=""
  NPM_REGISTRY_ORDER=""
  local tmp reg f ranked user_reg pin_note=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/npm-reg.XXXXXX")" || die "mktemp failed"

  # Hard pin: single fetch, no probing, no ranking.
  if [ -n "${AIBOX_NPM_REGISTRY:-}" ]; then
    _npm_probe_one "${AIBOX_NPM_REGISTRY}" "${tmp}/pin.res"
    if [ -s "${tmp}/pin.res" ]; then
      NPM_REGISTRY="${AIBOX_NPM_REGISTRY}"
      NPM_LATEST="$(cut -f3 "${tmp}/pin.res")"
      NPM_REGISTRY_ORDER="${AIBOX_NPM_REGISTRY}"
      log "npm registry: ${AIBOX_NPM_REGISTRY} (AIBOX_NPM_REGISTRY pin)"
      rm -rf "${tmp}"
      return 0
    fi
    rm -rf "${tmp}"
    die "AIBOX_NPM_REGISTRY is unreachable (or lacks ${NPM_PACKAGE}): ${AIBOX_NPM_REGISTRY}"
  fi

  # Candidates: the user's configured registry (if non-default) first-class, plus
  # the shipped list. Same registry is not probed twice.
  user_reg="$(npm config get registry 2>/dev/null | tr -d '[:space:]' || true)"
  local cands="${AIBOX_NPM_REGISTRIES:-${NPM_REGISTRIES_CANDIDATES}}"
  if [ -n "${user_reg}" ] && [ "${user_reg}" != "${NPM_REGISTRY_DEFAULT}" ] &&
    [ "${user_reg}" != "${NPM_REGISTRY_DEFAULT}/" ] &&
    ! printf '%s' " ${cands} " | grep -qF " ${user_reg} "; then
    cands="${user_reg} ${cands}"
    pin_note=" (user .npmrc: ${user_reg} joins the probe)"
  fi

  # Parallel probes — one result file per registry.
  # shellcheck disable=SC2086
  for reg in $cands; do
    f="${tmp}/$(printf '%s' "${reg}" | tr -c 'A-Za-z0-9' '_').res"
    _npm_probe_one "${reg}" "${f}" &
  done
  wait

  # Rank: measured download throughput DESCENDING (fastest first); drop
  # candidates without a usable latest (dead / package missing).
  local sorted wline
  sorted="$(cat "${tmp}"/*.res 2>/dev/null | sort -rn)"
  rm -rf "${tmp}"
  ranked="$(printf '%s\n' "${sorted}" | awk -F'\t' 'NF==3 && $3!="" {print $2}')"
  [ -n "${ranked}" ] || die "no usable npm registry (probed: ${cands}) — network? or pin one: AIBOX_NPM_REGISTRY=<url>"
  NPM_REGISTRY_ORDER="${ranked}"

  # Winner line (speed<TAB>reg<TAB>latest): NPM_LATEST comes straight from the
  # probe — no extra fetch.
  wline="$(printf '%s\n' "${sorted}" | awk -F'\t' 'NF==3 && $3!=""' | head -1)"
  NPM_REGISTRY="$(printf '%s' "${wline}" | cut -f2)"
  NPM_LATEST="$(printf '%s' "${wline}" | cut -f3)"
  export NPM_LATEST
  local wspeed n
  wspeed="$(printf '%s' "${wline}" | cut -f1)"
  n="$(printf '%s\n' "${ranked}" | grep -c .)"
  log "npm registry: ${NPM_REGISTRY} ($(_npm_speed_human "${wspeed}") tarball download, fastest of ${n} probed${pin_note})"
  if [ "${NPM_REGISTRY}" != "${NPM_REGISTRY_DEFAULT}" ] && [ "${NPM_REGISTRY}" != "${user_reg:-}" ]; then
    log "to pin it permanently: npm config set registry ${NPM_REGISTRY}"
  fi
  return 0
}
npm_install_global() {
  local timeout_s="${AIBOX_NPM_TIMEOUT:-240}" reg pid waited timed_out rc logf
  # shellcheck disable=SC2086
  for reg in $NPM_REGISTRY_ORDER; do
    [ -n "${reg}" ] || continue
    logf="$(mktemp "${TMPDIR:-/tmp}/npm-i.XXXXXX")"
    log "npm install -g ${NPM_PACKAGE}@latest --registry ${reg} (watchdog ${timeout_s}s) ..."
    npm install -g "${NPM_PACKAGE}@latest" --silent --registry "${reg}" >"${logf}" 2>&1 &
    pid=$!
    waited=0
    timed_out=0
    while kill -0 "${pid}" 2>/dev/null; do
      if [ "${waited}" -ge "${timeout_s}" ]; then
        timed_out=1
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
    rc=0
    if [ "${timed_out}" = 1 ]; then
      # SIGTERM to npm FIRST (it must be pending when the child cleanup releases
      # bash/npm's foreground wait), THEN kill orphaned children — the reverse order
      # lets a shell-based process win the race and fall through to exit 0 (measured:
      # a stalled shim exited 0 because pkill released its sleep before TERM landed).
      kill "${pid}" 2>/dev/null || true
      pkill -P "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || rc=$?
      if [ "${rc}" -eq 0 ]; then
        ok "installed via ${reg} (finished as the watchdog fired)"
        rm -f "${logf}"
        return 0
      fi
      warn "npm stalled on ${reg}: no completion within ${timeout_s}s — killing and failing over"
      rm -f "${logf}"
      continue
    fi
    wait "${pid}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
      ok "installed via ${reg}"
      rm -f "${logf}"
      return 0
    fi
    warn "npm failed on ${reg} (rc=${rc}): $(tail -2 "${logf}" 2>/dev/null | tr '\n' ' ')"
    rm -f "${logf}"
  done
  die "npm install failed on every registry tried (${NPM_REGISTRY_ORDER})"
}
resolve_node() {
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
  elif [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh"
    NODE_BIN="$(command -v node || true)"
  fi

  if [ -z "${NODE_BIN:-}" ] || ! "$NODE_BIN" -v >/dev/null 2>&1; then
    warn "node not found"
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      log "Trying to install node 22 via nvm ..."
      # shellcheck disable=SC1091
      . "$HOME/.nvm/nvm.sh"
      nvm install 22
      nvm use 22 >/dev/null
      NODE_BIN="$(command -v node)"
    else
      die "Please install Node.js 22+ first (recommended: brew install nvm, then nvm install 22)"
    fi
  fi

  NODE_DIR="$(dirname "$NODE_BIN")"
  NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -lt 22 ]; then
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      log "Current node $($NODE_BIN -v) < 22, installing 22 via nvm ..."
      # shellcheck disable=SC1091
      . "$HOME/.nvm/nvm.sh"
      nvm install 22 && nvm use 22 >/dev/null
      NODE_BIN="$(command -v node)"
      NODE_DIR="$(dirname "$NODE_BIN")"
    else
      die "node version $($NODE_BIN -v) is too old, need >= 22"
    fi
  fi
  log "node: $NODE_BIN ($($NODE_BIN -v))"
  export PATH="$NODE_DIR:$PATH"
}

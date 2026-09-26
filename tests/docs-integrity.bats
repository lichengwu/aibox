#!/usr/bin/env bats
# Documentation integrity (0.18.0). The docs are part of the contract, so drift
# there is a bug: two relative links were broken, the new standard actions were
# undocumented in six module READMEs, and the test-suite README had no complete
# inventory (so a new suite could ship unlisted).
# Guards: link resolution, index completeness, en/zh parity, per-module action
# docs, and the spec's CLI conventions staying in sync with the implementation.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "docs: every relative markdown link resolves" {
  local bad="" f tgt d
  while IFS= read -r f; do
    while IFS= read -r tgt; do
      [ -n "${tgt}" ] || continue
      case "${tgt}" in
      http://*|https://*|mailto:*|'#'*) continue ;;
      esac
      d="$(dirname "${f}")"
      [ -e "${d}/${tgt}" ] || bad="${bad} ${f}->${tgt}"
    done <<LINKS
$(grep -oE '\]\([^)#]+' "${f}" 2>/dev/null | sed 's/^](//' | sort -u)
LINKS
  done <<FILES
$(cd "${REPO_ROOT}" && find . -name '*.md' -not -path './.git/*' -not -path './.superpowers/*')
FILES
  [ -z "${bad}" ] || { echo "broken links:${bad}"; false; }
}

@test "docs: the index lists every docs/*.md" {
  local idx f base bad=""
  idx="$(cat "${REPO_ROOT}/docs/README.md")"
  for f in "${REPO_ROOT}"/docs/*.md; do
    base="$(basename "${f}")"
    [ "${base}" = "README.md" ] && continue
    [[ "${idx}" == *"${base}"* ]] || bad="${bad} ${base}"
  done
  [ -z "${bad}" ] || { echo "not indexed:${bad}"; false; }
}

@test "docs: tests/README.md lists every test file (inventory stays complete)" {
  local f base idx bad=""
  idx="$(cat "${REPO_ROOT}/tests/README.md")"
  for f in "${REPO_ROOT}"/tests/*.bats "${REPO_ROOT}"/tests/integration/*.bats; do
    base="$(basename "${f}")"
    [[ "${idx}" == *"${base}"* ]] || bad="${bad} ${base}"
  done
  [ -z "${bad}" ] || { echo "missing from tests/README.md:${bad}"; false; }
}

@test "docs: README.md and README.zh.md stay structurally in sync" {
  local en zh
  en=$(grep -c '^## ' "${REPO_ROOT}/README.md"); zh=$(grep -c '^## ' "${REPO_ROOT}/README.zh.md")
  [ "${en}" = "${zh}" ] || { echo "sections en=${en} zh=${zh}"; false; }
  # the command surface must be identical (only prose is translated)
  en=$(grep -oE '^\s*aibox [a-z-]+' "${REPO_ROOT}/README.md" | tr -d ' ' | sort -u)
  zh=$(grep -oE '^\s*aibox [a-z-]+' "${REPO_ROOT}/README.zh.md" | tr -d ' ' | sort -u)
  [ "${en}" = "${zh}" ] || { echo "command sets differ:"; diff <(echo "${en}") <(echo "${zh}"); false; }
}

@test "docs: no stale references to merged verbs anywhere" {
  local f bad=""
  while IFS= read -r f; do
    grep -nE 'aibox (list|ports)([[:space:]]|$)|aibox self (status|restart|logs)|aibox proxy test([[:space:]]|$)' "${f}" \
      | grep -v 'merged into' | grep -v 'merged 2026' >/dev/null 2>&1 && bad="${bad} $(basename "${f}")"
  done <<FILES
$(cd "${REPO_ROOT}" && find . -name '*.md' -not -path './.git/*' -not -path './.superpowers/*')
FILES
  [ -z "${bad}" ] || { echo "stale verb references:${bad}"; false; }
}

@test "docs: every module README documents the standard actions it declares" {
  local f m acts need bad=""
  for f in "${REPO_ROOT}"/tools/*/module.yaml; do
    m="$(basename "$(dirname "${f}")")"
    acts="$(awk '/^actions:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^  - /{print $2}' "${f}")"
    for need in doctor dashboard logs; do
      printf '%s\n' ${acts} | grep -qx "${need}" || continue
      grep -q "${need}" "${REPO_ROOT}/tools/${m}/README.md" || bad="${bad} ${m}:${need}"
    done
  done
  [ -z "${bad}" ] || { echo "actions undocumented in README:${bad}"; false; }
}

@test "docs: the spec documents the CLI conventions the code implements" {
  local spec; spec="$(cat "${REPO_ROOT}/docs/module-spec.md")"
  [[ "${spec}" == *"Action-surface conventions"* ]] || false
  [[ "${spec}" == *"usage_die"* ]] || false
  [[ "${spec}" == *"module_doctor"* ]] || false
  [[ "${spec}" == *"| 2 | usage error"* ]] || false
  [[ "${spec}" == *"| 3 | dependency missing"* ]] || false
  [[ "${spec}" == *"| 4 | precheck failed"* ]] || false
  # …and the manager really behaves that way (spot-check the documented hints)
  # a file:// registry keeps this hermetic (the ambient cache may not exist —
  # the non-root pass has no /root/.aibox)
  run env AIBOX_RAW="file://${REPO_ROOT}" bash "${REPO_ROOT}/bin/aibox" install nosuch-zzz
  [ "$status" -eq 2 ] || { echo "unknown-module exit=${status}"; false; }
  grep -q '_verb_help' "${REPO_ROOT}/bin/aibox" || false
}

@test "docs: AGENTS.md carries the CLI conventions (agent-facing contract)" {
  grep -q 'CLI conventions' "${REPO_ROOT}/AGENTS.md" || false
  grep -q 'usage_die' "${REPO_ROOT}/AGENTS.md" || false
  grep -q 'doctor' "${REPO_ROOT}/AGENTS.md" || false
}

@test "docs: tests/README.md documents the docker harness" {
  grep -q 'tests/docker' "${REPO_ROOT}/tests/README.md" || { echo "docker harness undocumented"; false; }
}

@test "docs: CASES.md maps every pitfall-log entry to a locking suite" {
  local cases; cases="$(cat "${REPO_ROOT}/tests/CASES.md")"
  [[ "${cases}" == *"Historical cases"* ]] || false
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 11; do
    grep -qE "^\| ${n} \|" "${REPO_ROOT}/tests/CASES.md" || { echo "pitfall #${n} unmapped"; false; }
  done
  [[ "${cases}" == *"tests/cli-consistency.bats"* ]] || false
  [[ "${cases}" == *"tests/docker"* ]] || grep -q 'docker/run.sh' "${REPO_ROOT}/tests/CASES.md" || false
}

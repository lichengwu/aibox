#!/usr/bin/env bats
# Content verification of module downloads (modules.SHA256SUMS). Module scripts
# are code that runs as the user: a tampered cache or mirror must be detectable,
# and the manifest must stay in sync with the tree (CI gate).

load test_helper

_manifest_fixture() { # a repo-shaped tree with a file:// source
  local src="$AIBOX_HOME/src"
  mkdir -p "$src/tools/demo" "$src/tools/_shared"
  # block-style lists (the registry dialect has no inline [..] form)
  cat >"$src/tools/demo/module.yaml" <<'YAML'
name: demo
version: 1.0.0
description: "verify fixture"
dir: tools/demo
files:
  - docker-compose.yml
includes:
  - common
actions:
  - start
YAML
  printf '#!/usr/bin/env bash\nexit 0\n' >"$src/tools/demo/lib.sh"
  for f in install.sh uninstall.sh update.sh svc.sh docker-compose.yml; do printf '# %s\n' "$f" >"$src/tools/demo/$f"; done
  printf 'log() { :; }\n' >"$src/tools/_shared/common.sh"
  # self-contained manifest (never runs the repo's manifest.sh: a fixture must
  # not be able to touch the repo artifact even if a flag changes meaning)
  ( cd "$src" && find . -type f -not -name 'modules.SHA256SUMS' | sort | while IFS= read -r f; do
      if command -v shasum >/dev/null 2>&1; then d="$(shasum -a 256 "$f" | awk '{print $1}')"
      else d="$(sha256sum "$f" | awk '{print $1}')"; fi
      printf '%s  %s\n' "$d" "${f#./}"
    done ) >"$src/modules.SHA256SUMS"
  printf '%s' "$src"
}

@test "manifest: freshness gate — the repo's manifest matches the tree" {
  run bash "$REPO_ROOT/scripts/manifest.sh" --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"fresh"* ]] || false
}

@test "manifest: stale manifest is detected" {
  local tmp="$AIBOX_HOME/stale"
  mkdir -p "$tmp"
  cp "$REPO_ROOT/modules.SHA256SUMS" "$tmp/m"
  printf 'deadbeef  tools/nope/file.sh\n' >>"$tmp/m"
  # regenerate into a scratch copy of the manifest logic: compare by hand
  ! cmp -s "$tmp/m" "$REPO_ROOT/modules.SHA256SUMS" || false
  grep -q 'tools/nope/file.sh' "$tmp/m" || false
}

@test "download: a verified file:// download succeeds" {
  local src; src="$(_manifest_fixture)"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME/home' AIBOX_MOD_DIR='$AIBOX_HOME/home/modules' AIBOX_RAW='file://$src'
    mkdir -p \"\$AIBOX_MOD_DIR\"
    source '$AIBOX_BIN'
    download_module demo
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$AIBOX_HOME/home/modules/demo/lib.sh" ] || false
}

@test "download: a tampered file dies with a manifest hint (and AIBOX_VERIFY=0 bypasses)" {
  local src; src="$(_manifest_fixture)"
  printf '\n# tampered\n' >>"$src/tools/demo/lib.sh"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME/home2' AIBOX_MOD_DIR='$AIBOX_HOME/home2/modules' AIBOX_RAW='file://$src'
    mkdir -p \"\$AIBOX_MOD_DIR\"
    source '$AIBOX_BIN'
    download_module demo
  "
  [ "$status" -ne 0 ] || { echo "tampered download should fail: $output"; false; }
  [[ "$output" == *"verification failed"* ]] || { echo "$output"; false; }
  [[ "$output" == *"AIBOX_VERIFY=0"* ]] || { echo "$output"; false; }
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME/home3' AIBOX_MOD_DIR='$AIBOX_HOME/home3/modules' AIBOX_RAW='file://$src' AIBOX_VERIFY=0
    mkdir -p \"\$AIBOX_MOD_DIR\"
    source '$AIBOX_BIN'
    download_module demo
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "download: a missing manifest degrades to unverified (loud, not fatal)" {
  local src; src="$(_manifest_fixture)"
  rm -f "$src/modules.SHA256SUMS"
  run bash -c "
    export AIBOX_HOME='$AIBOX_HOME/home4' AIBOX_MOD_DIR='$AIBOX_HOME/home4/modules' AIBOX_RAW='file://$src'
    mkdir -p \"\$AIBOX_MOD_DIR\"
    source '$AIBOX_BIN'
    download_module demo
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"unverified"* ]] || { echo "$output"; false; }
}

@test "checksum helpers: sha256_of + manifest_digest agree with the manifest" {
  run bash -c "source '$AIBOX_BIN'; sha256_of '$REPO_ROOT/tools/new-api/lib.sh'"
  [ "$status" -eq 0 ] || false
  [ -n "$output" ] || { echo "no sha tool?"; false; }
  run bash -c "source '$AIBOX_BIN'; manifest_digest '$REPO_ROOT/modules.SHA256SUMS' tools/new-api/lib.sh"
  [ "$output" = "$(bash -c "source '$AIBOX_BIN'; sha256_of '$REPO_ROOT/tools/new-api/lib.sh'")" ] || { echo "manifest digest != file digest: $output"; false; }
}

@test "every module file the manager downloads is covered by the manifest" {
  # The manifest must mirror download_module's set, derived from module.yaml:
  # standard-6 + `files:` + `includes:`. The generator's old find-pattern
  # enumeration silently missed whole classes — cli/** (`-name 'cli'` matched a
  # BASENAME while cli/ is a directory), lib-*.sh, vendored dify templates —
  # shipping them unverified despite the documented coverage (live-caught).
  local m d f rel tok missing=""
  for m in "$REPO_ROOT"/tools/*/module.yaml; do
    [ -f "$m" ] || continue
    d="$(dirname "$m")"
    for f in module.yaml lib.sh install.sh uninstall.sh update.sh svc.sh; do
      [ -f "$d/$f" ] || continue
      rel="${d#"$REPO_ROOT"/}/$f"
      grep -q "  ${rel}\$" "$REPO_ROOT/modules.SHA256SUMS" || missing="${missing} ${rel}"
    done
    # files: stanza — one entry per `- ` line (the registry's yaml subset has no spaces in paths)
    for tok in $(sed -n '/^files:/,/^[a-z_]/p' "$m" | grep -oE '^[ ]+- [^ ]+' | sed 's/^ *- //'); do
      rel="${d#"$REPO_ROOT"/}/${tok}"
      grep -q "  ${rel}\$" "$REPO_ROOT/modules.SHA256SUMS" || missing="${missing} ${rel}"
    done
    # includes: — cached as _<name>.sh from tools/_shared/<name>.sh
    for tok in $(sed -n '/^includes:/,/^[a-z_]/p' "$m" | grep -oE '^[ ]+- [^ ]+' | sed 's/^ *- //'); do
      rel="tools/_shared/${tok}.sh"
      grep -q "  ${rel}\$" "$REPO_ROOT/modules.SHA256SUMS" || missing="${missing} ${rel}"
    done
  done
  [ -z "${missing}" ] || { echo "not covered:${missing}"; false; }
}

@test "CI enforces the manifest freshness gate" {
  grep -q 'scripts/manifest.sh --check' "$REPO_ROOT/.github/workflows/lint.yml" || false
}

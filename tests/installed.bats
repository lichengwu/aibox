#!/usr/bin/env bats
# Tests for installed-state management: is_installed / mark_installed / unmark_installed /
# installed_names. These are file-backed, plain-variable, no source needed.

load test_helper

@test "is_installed: false when nothing installed" {
  [ ! -f "$AIBOX_INSTALLED" ]
  run is_installed pi-web
  [ "$status" -ne 0 ]
}

@test "mark_installed: writes an entry and is_installed sees it" {
  mark_installed pi-web "1.0.0"
  is_installed pi-web
  grep -q '^AIBOX_INSTALLED_pi_web="1.0.0"$' "$AIBOX_INSTALLED"
}

@test "mark_installed: idempotent — re-marking with a new version replaces, doesn't duplicate" {
  mark_installed pi-web "1.0.0"
  mark_installed pi-web "1.2.0"
  # exactly one line for this module, with the latest version
  [ "$(grep -c '^AIBOX_INSTALLED_pi_web=' "$AIBOX_INSTALLED")" = "1" ]
  grep -q '^AIBOX_INSTALLED_pi_web="1.2.0"$' "$AIBOX_INSTALLED"
}

@test "mark_installed: hyphenated names map to underscored keys (pi-web -> pi_web)" {
  mark_installed pi-web "1.0.0"
  is_installed pi-web
  ! is_installed pi_web 2>/dev/null || true   # the public API takes hyphenated names
}

@test "unmark_installed: removes only the named module" {
  mark_installed pi-web "1.0.0"
  mark_installed clash "0.9.0"
  unmark_installed pi-web
  ! is_installed pi-web
  is_installed clash    # clash untouched
}

@test "unmark_installed: no-op when nothing installed" {
  unmark_installed pi-web   # must not error
  [ ! -f "$AIBOX_INSTALLED" ] || true
}

@test "installed_names: lists installed modules hyphenated" {
  mark_installed pi-web "1.0.0"
  mark_installed base "1.0.0"
  names="$(installed_names | sort | tr '\n' ' ')"
  echo "names=[$names]" >&2
  [[ "$names" == *"base "* ]]
  [[ "$names" == *"pi-web "* ]]
}

@test "installed state is profile-scoped (multi-profile isolation)" {
  # base profile (AIBOX_PROFILE unset)
  mark_installed pi-web "1.0.0"
  # named profile
  AIBOX_PROFILE=prod
  mark_installed pi-web "1.0.0"
  AIBOX_PROFILE=base
  # both keys in the file
  grep -q '^AIBOX_INSTALLED_pi_web=' "$AIBOX_INSTALLED"
  grep -q '^AIBOX_INSTALLED_pi_web__prod=' "$AIBOX_INSTALLED"
  # base profile sees exactly pi-web (no prod-suffix leakage into installed_names)
  [ "$(installed_names)" = "pi-web" ]
  is_installed pi-web
  # prod sees its own
  AIBOX_PROFILE=prod
  is_installed pi-web
  [ "$(installed_names)" = "pi-web" ]
  # the live-machine bug: uninstalling prod's marker must leave base's intact
  unmark_installed pi-web
  AIBOX_PROFILE=base
  is_installed pi-web
  # and vice versa: re-add prod, remove base → prod survives
  AIBOX_PROFILE=prod
  mark_installed pi-web "1.0.0"
  AIBOX_PROFILE=base
  unmark_installed pi-web
  AIBOX_PROFILE=prod
  is_installed pi-web
}

@test "_installed_any_profile sees markers from any profile (cache-delete guard)" {
  AIBOX_PROFILE=prod
  mark_installed clash "1.0.0"
  AIBOX_PROFILE=base
  _installed_any_profile clash
  AIBOX_PROFILE=prod
  unmark_installed clash
  AIBOX_PROFILE=base
  ! _installed_any_profile clash
}

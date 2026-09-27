#!/usr/bin/env bats
# Profiles: a name deterministically maps to a port slot — but derived is not the
# same as free. Profiles are registered in $AIBOX_HOME/ports.conf and a LIVE
# collision with another profile stops the start (exit 4 = precheck failed).

load test_helper

@test "profile_hash/profile_port: stable, documented values" {
  run bash -c "source '$AIBOX_BIN'; printf '%s|%s|%s|%s' \"\$(profile_hash prod)\" \"\$(profile_port pg \"\$(profile_hash prod)\")\" \"\$(profile_port redis \"\$(profile_hash prod)\")\" \"\$(profile_port web \"\$(profile_hash prod)\")\""
  [ "$output" = "1073|35177|36336|37173" ] || { echo "got: $output"; false; }
}

@test "profile_register: idempotent, sorted, one line per profile" {
  run bash -c "
    source '$AIBOX_BIN'
    profile_register stage; profile_register prod; profile_register prod
    wc -l <'$AIBOX_HOME/ports.conf'
    grep -c '^prod ' '$AIBOX_HOME/ports.conf'
  "
  [ "$output" = "2
1" ] || { echo "got: $output"; false; }
  grep -q '^stage pg=35327 redis=36260 web=37155$' "$AIBOX_HOME/ports.conf" || { cat "$AIBOX_HOME/ports.conf"; false; }
}

@test "profile_owner: maps a registered port back to its profile" {
  run bash -c "
    source '$AIBOX_BIN'
    profile_register stage
    printf '%s|%s' \"\$(profile_owner 35327)\" \"\$(profile_owner 36000)\"
  "
  [ "$output" = "stage|" ] || { echo "got: $output"; false; }
}

@test "profile_conflicts: another profile holding MY slot while LIVE; a dead one is not" {
  # A real conflict is a slot collision (two names hashing to the same port) —
  # seed the registry with a second profile claiming prod's own pg port.
  run bash -c "
    source '$AIBOX_BIN'
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_conflicts prod
  "
  [ "$output" = "other 35177" ] || { echo "got: $output"; false; }
  run bash -c "
    source '$AIBOX_BIN'
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { return 1; }
    profile_conflicts prod
  "
  [ -z "$output" ] || { echo "expected clean (owner not live), got: $output"; false; }
  # and a name that hashes elsewhere is not a conflict at all
  run bash -c "
    source '$AIBOX_BIN'
    rm -f '$AIBOX_HOME/ports.conf'
    profile_register stage
    port_listening() { return 0; }
    profile_conflicts prod
  "
  [ -z "$output" ] || { echo "expected clean (disjoint slots), got: $output"; false; }
}

@test "profile_ensure: creates the conf deterministically and registers the ports" {
  run bash -c "
    source '$AIBOX_BIN'
    profile_ensure demo '$AIBOX_HOME/profiles/demo.conf'
    cat '$AIBOX_HOME/profiles/demo.conf'
    grep '^demo ' '$AIBOX_HOME/ports.conf'
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"PROFILE_NAME=demo"* ]] || false
  [[ "$output" == *"PROFILE_HASH=$(bash -c "source '$AIBOX_BIN'; profile_hash demo")"* ]] || false
  [[ "$output" == *"demo pg="* ]] || false
}

@test "profile_ensure: a LIVE collision with another profile dies with exit 4" {
  run bash -c "
    source '$AIBOX_BIN'
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_ensure prod '$AIBOX_HOME/profiles/prod.conf'
  "
  [ "$status" -eq 4 ] || { echo "expected exit 4, got $status: $output"; false; }
  [[ "$output" == *"port collision"* ]] || { echo "$output"; false; }
  # and it REFUSES rather than silently starting into a busy port
  [[ "$output" == *"pick another name"* ]] || { echo "$output"; false; }
}

@test "the DEFAULT profile is exempt (keeps the module's declared ports)" {
  run bash -c "
    source '$AIBOX_BIN'
    profile_register base; profile_ensure base '$AIBOX_HOME/profiles/base.conf'
    [ -f '$AIBOX_HOME/ports.conf' ] && echo has-file || echo no-file
  "
  [ "$output" = "no-file" ] || { echo "got: $output"; false; }
}

@test "base and pi-web no longer carry their own profile derivation (one source)" {
  for f in "$REPO_ROOT/tools/base/lib.sh" "$REPO_ROOT/tools/pi-web/lib.sh"; do
    ! grep -q '_profile_hash()' "$f" || { echo "$f still defines _profile_hash"; false; }
    ! grep -q '_profile_create()' "$f" || { echo "$f still defines _profile_create"; false; }
    grep -q 'profile_ensure ' "$f" || { echo "$f does not use profile_ensure"; false; }
  done
  [ "$(grep -c '^profile_hash()' "$AIBOX_BIN")" = "1" ] || false
}

@test "the profile ports registry is data (mode 600, parsed never sourced)" {
  bash -c "source '$AIBOX_BIN'; profile_register stage" >/dev/null
  local mode
  mode="$(ls -l "$AIBOX_HOME/ports.conf" | cut -c1-10)"
  [ "$mode" = "-rw-------" ] || { echo "mode: $mode"; false; }
}

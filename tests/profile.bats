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
  # BSD wc pads the count with spaces; compare normalised
  [ "${output// /}" = "2
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

@test "profile_conflicts: registered owner wins; unregistered live port is 'unknown'" {
  # 1. another profile registered MY slot and it is LIVE → conflict, owner named
  run bash -c "
    source '$AIBOX_BIN'
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_conflicts prod
  "
  [ "$output" = "other 35177" ] || { echo "got: $output"; false; }
  # 2. the same registration but the port is NOT live → no conflict
  run bash -c "
    source '$AIBOX_BIN'
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { return 1; }
    profile_conflicts prod
  "
  [ -z "$output" ] || { echo "expected clean (owner not live), got: $output"; false; }
  # 3. OUR OWN registration + live → clean (idempotent re-start must not refuse)
  run bash -c "
    source '$AIBOX_BIN'
    rm -f '$AIBOX_HOME/ports.conf'
    profile_register prod
    port_listening() { return 0; }
    profile_conflicts prod
  "
  [ -z "$output" ] || { echo "expected clean (our own slots), got: $output"; false; }
  # 4. a LIVE port nobody registered → reported as unknown (the case that used to
  #    surface as docker's raw 'port is already allocated')
  run bash -c "
    source '$AIBOX_BIN'
    rm -f '$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_conflicts prod
  "
  [ "$output" = "unknown 35177" ] || { echo "got: $output"; false; }
}

@test "profile_conflicts: only aibox knowledge is used (no docker query)" {
  # a docker CLI that would answer nonsense must not be consulted at all
  run bash -c "
    source '$AIBOX_BIN'
    docker() { printf 'aibox-base-prod-postgres\n'; }
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_conflicts prod
  "
  [ "$output" = "other 35177" ] || { echo "got: $output"; false; }
  ! grep -q '_port_owner_container' "$AIBOX_BIN" || { echo "the docker-query helper is back"; false; }
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

@test "profile_ensure: a LIVE port it cannot attribute dies with exit 4" {
  # the live-caught case: a real deployment holds the slot a fresh profile hashes
  # to, and no aibox profile registered it → refuse, name the port, exit 4
  run bash -c "
    source '$AIBOX_BIN'
    rm -f '$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_ensure prod '$AIBOX_HOME/profiles/prod.conf'
  "
  [ "$status" -eq 4 ] || { echo "expected exit 4, got $status: $output"; false; }
  [[ "$output" == *"port collision"* ]] || { echo "$output"; false; }
  [[ "$output" == *"no aibox profile registered it"* ]] || { echo "$output"; false; }
}

@test "profile_ensure: a LIVE port owned by ANOTHER profile dies with exit 4" {
  run bash -c "
    source '$AIBOX_BIN'
    printf 'other pg=35177 redis=36336 web=37173\n' >'$AIBOX_HOME/ports.conf'
    port_listening() { [ \"\$1\" = 35177 ]; }
    profile_ensure prod '$AIBOX_HOME/profiles/prod.conf'
  "
  [ "$status" -eq 4 ] || { echo "expected exit 4, got $status: $output"; false; }
  [[ "$output" == *"belongs to profile 'other'"* ]] || { echo "$output"; false; }
}

@test "profile_ensure: our own registered, live slot is NOT a conflict (re-start)" {
  run bash -c "
    source '$AIBOX_BIN'
    rm -f '$AIBOX_HOME/ports.conf'
    profile_register prod
    port_listening() { return 0; }
    profile_ensure prod '$AIBOX_HOME/profiles/prod.conf'
  "
  [ "$status" -eq 0 ] || { echo "re-start must be clean, got $status: $output"; false; }
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

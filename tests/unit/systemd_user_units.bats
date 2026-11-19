#!/usr/bin/env bats
# .config/systemd/user: the user manager does not load network.target or network-online.target
# (LoadState=not-found), so After= or Wants= on either in a user unit is a no-op that reads like a
# network wait. A unit whose boot run would leave a wrong result standing waits with
# ExecStartPre=-/usr/bin/nm-online, as session-snapshot-up.service does; one its timer or Restart=
# retries within minutes needs no wait.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DEAD='^[[:space:]]*(After|Wants|Requires|BindsTo)=.*network(-online)?\.target'
}

@test "no user unit orders on a system network target" {
  run grep -rnE "$DEAD" "$ROOT/.config/systemd/user"
  assert_output ""
}

@test "the check catches a user unit that orders on a system network target" {
  d="$BATS_TEST_TMPDIR/user"; mkdir -p "$d"
  printf '[Unit]\n  After=pipewire-pulse.service network-online.target\nWants=network.target\n' > "$d/x.service"
  run grep -rnE "$DEAD" "$d"
  assert_line --partial "x.service:2:"
  assert_line --partial "x.service:3:"
}

@test "the fleet-pulse enroller writes no system network target into its unit" {
  run grep -nE "$DEAD" "$ROOT/.local/src/fleet-pulse/enroll.sh"
  assert_output ""
}

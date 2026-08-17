#!/usr/bin/env bats
# fleet_pulse.sh: the waybar module that renders "is my whole fleet alive".
#
# This file had NO coverage at all, which is how the bug below shipped and then sat
# on the bar in plain sight.
#
# THE BUG: FLEET_DISPLAY is a FOURTH copy of the fleet roster (the others are the gatus
# `external-endpoints` config, apps/fleet-exporter's FLEET_ROSTER, and FLEET_ROSTER in
# ~/.config/fleet-pulse/env - two of them in home-config, one in the private overlay,
# this one in the public repo). On 2026-08-17 `lazer-machine` was retired from the
# other three when that contract ended, and stayed here. The bar kept drawing
# `lzr○` in red - byte-for-byte the same dot a machine that is genuinely DOWN gets -
# so a decommissioned host was indistinguishable from an outage, forever.
#
# The fix is not "remember to edit four files". It is that a token naming a host in
# NEITHER the roster NOR the API renders `?`, not `○`, and names itself in the tooltip.
# Absence-of-machine and absence-of-config are different facts and must not share a glyph.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  MODULE="$REPO_ROOT/.config/waybar/fleet_pulse.sh"

  # A gatus statuses API frozen in time. `date -u` so the fixture is fresh on every run
  # and "up" does not decay into "stale" the moment the clock moves - the alternative
  # (a hardcoded timestamp) makes the suite pass today and fail silently next week.
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OLD="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  export NOW OLD

  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
[
  {"name":"linux-cachyos","group":"homelab","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"gp-mac","group":"workplace","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"pi5-master","group":"k3s","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"pi4-worker4","group":"k3s","results":[{"success":false,"timestamp":"$OLD"}]}
]
JSON
EOF
  chmod +x "$SANDBOX/bin/curl"

  export GATUS_BASE="http://stub"
  export FLEET_ROSTER="linux-cachyos gp-mac pi5-master pi4-worker4"
}

# --- the regression this file exists for -------------------------------------

@test "a display token naming a retired host renders ? rather than a down dot" {
  FLEET_DISPLAY="linux-cachyos=main lazer-machine=lzr" run "$MODULE"
  assert_success
  # The ghost marker, and specifically NOT the hollow red dot a dead machine gets.
  assert_output --partial "lzr<span color='#ffcc2f'>?</span>"
  refute_output --partial "lzr<span color='#ef5734'>○</span>"
}

@test "the tooltip names the offending token, so the fix is findable" {
  FLEET_DISPLAY="linux-cachyos=main lazer-machine=lzr" run "$MODULE"
  assert_success
  assert_output --partial "FLEET_DISPLAY names hosts that no longer exist"
  assert_output --partial "lazer-machine: not on the roster, unknown to gatus"
}

# THE NEGATIVE CONTROL. If a real machine going down also rendered `?`, the test above
# would pass for the wrong reason and the ghost marker would mean nothing. A host that
# IS on the roster and IS failing must still be a plain red dot.
@test "...and a genuinely down machine is still a down dot, not a ghost" {
  FLEET_DISPLAY="pi4-worker4=w4" run "$MODULE"
  assert_success
  assert_output --partial "w4<span color='#ef5734'>○</span>"
  refute_output --partial "w4<span color='#ffcc2f'>?</span>"
  refute_output --partial "FLEET_DISPLAY names hosts"
}

@test "a host rostered but never enrolled is a down dot, not a ghost" {
  # Declared-but-never-reported is a REAL fleet fact (the machine owes a heartbeat),
  # unlike a ghost, which is a config fact. Conflating them would hide enrolment bugs.
  FLEET_ROSTER="linux-cachyos cachy-laptop" FLEET_DISPLAY="cachy-laptop=lap" run "$MODULE"
  assert_success
  assert_output --partial "lap<span color='#ef5734'>○</span>"
  assert_output --partial "cachy-laptop: NEVER REPORTED"
  refute_output --partial "FLEET_DISPLAY names hosts"
}

@test "a group token naming a group gatus does not have renders as a ghost" {
  FLEET_DISPLAY="@nosuchgroup=xx" run "$MODULE"
  assert_success
  assert_output --partial "xx<span color='#ffcc2f'>?</span>"
  assert_output --partial "@nosuchgroup: not on the roster, unknown to gatus"
}

@test "a real group still collapses to its worst member" {
  FLEET_DISPLAY="@k3s=k3s" run "$MODULE"
  assert_success
  # pi4-worker4 is failing, so the group dot is red even though pi5-master is up.
  assert_output --partial "k3s<span color='#ef5734'>○</span>"
  refute_output --partial "FLEET_DISPLAY names hosts"
}

# --- the shape the bar contract depends on -----------------------------------

@test "the default FLEET_DISPLAY names no host that is absent from the roster" {
  # Pins the fourth-copy problem itself: whatever ships as the default must be a
  # SUBSET of the shipped roster, or the bar lies out of the box. This is the
  # assertion that would have failed the day lazer-machine was retired elsewhere.
  local display roster tok key
  display="$(sed -n 's/^: "${FLEET_DISPLAY:=\(.*\)}"$/\1/p' "$MODULE")"
  [[ -n "$display" ]] || fail "could not read the default FLEET_DISPLAY out of $MODULE"
  # The roster lives in the PRIVATE overlay, so this assertion can only run where both
  # repos are checked out. $HOME is the sandbox by now, hence the real home from passwd.
  local real_home priv
  real_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  priv="${FLEET_PRIVATE_ENV:-$real_home/.dotfiles-private/.config/fleet-pulse/env}"
  roster="$(sed -n 's/^: "${FLEET_ROSTER:=\(.*\)}"$/\1/p' "$priv" 2>/dev/null || true)"
  # A public clone (or CI) has no overlay; skip rather than fail, but NEVER pass
  # silently - a skip is visible in the bats output and says which file was missing.
  [[ -n "$roster" ]] || skip "no roster at $priv (private overlay not checked out)"
  for tok in $display; do
    key="${tok%%=*}"
    [[ "$key" == @* ]] && continue          # groups are gatus-side, not roster-side
    [[ " $roster " == *" $key "* ]] || fail "FLEET_DISPLAY names '$key', absent from FLEET_ROSTER"
  done
}

@test "an unreachable API says so instead of drawing a fleet that is not there" {
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$SANDBOX/bin/curl"
  run "$MODULE"
  assert_success
  assert_output --partial "status API unreachable"
  assert_output --partial '"class": "unreachable"'
}

#!/usr/bin/env bats
# fleet_pulse.sh: the waybar module that renders "is my whole fleet alive".
#
# This file had NO coverage at all, which is how the bug below shipped and then sat
# on the bar in plain sight.
#
# The roster and the display tokens come from one document, $GATUS_BASE/roster, which
# home-config renders from its inventory, so a retired host cannot linger in a copy.
# A token naming a host in NEITHER the roster NOR the API still renders `?`, not the
# hollow red dot a down machine gets, and names itself in the tooltip: absence of a
# machine and absence of config are different facts and must not share a glyph.
#
# The curl stub serves the statuses API from $STATUSES and /roster from STUB_ROSTER
# and STUB_DISPLAY (STUB_ROSTER_MODE=down fails the fetch, =html returns a non-JSON
# 200), and logs every URL it is asked for to $CURL_LOG.

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

  export STATUSES="$SANDBOX/statuses.json" CURL_LOG="$SANDBOX/curl.log"
  cat > "$STATUSES" <<JSON
[
  {"name":"linux-cachyos","group":"homelab","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"gp-mac","group":"workplace","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"pi5-master","group":"k3s","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"pi4-worker4","group":"k3s","results":[{"success":false,"timestamp":"$OLD"}]}
]
JSON

  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
for url; do :; done
printf '%s\n' "$url" >> "$CURL_LOG"
case "$url" in
  */roster)
    case "${STUB_ROSTER_MODE:-ok}" in
      down) exit 22 ;;
      html) echo '<html>login</html>'; exit 0 ;;
    esac
    jq -n --arg r "$STUB_ROSTER" --arg d "${STUB_DISPLAY:-}" \
      '{roster: ($r | split(" ") | map(select(. != ""))), display: ($d | split(" ") | map(select(. != "")))}' ;;
  *) cat "$STATUSES" ;;
esac
EOF
  chmod +x "$SANDBOX/bin/curl"

  export GATUS_BASE="http://stub"
  export STUB_ROSTER="linux-cachyos gp-mac pi5-master pi4-worker4"
  export FLEET_ROSTER_TTL_MIN=0   # every run fetches the roster its test sets; the cache tests raise it
}

# --- the regression this file exists for -------------------------------------

@test "a display token naming a retired host renders ? rather than a down dot" {
  STUB_DISPLAY="linux-cachyos=main lazer-machine=lzr" run "$MODULE"
  assert_success
  # The ghost marker, and specifically NOT the hollow red dot a dead machine gets.
  assert_output --partial "lzr<span color='#ffcc2f'>?</span>"
  refute_output --partial "lzr<span color='#ef5734'>○</span>"
}

@test "the tooltip names the offending token, so the fix is findable" {
  STUB_DISPLAY="linux-cachyos=main lazer-machine=lzr" run "$MODULE"
  assert_success
  assert_output --partial "Display tokens that name nothing"
  assert_output --partial "lazer-machine: not on the roster, unknown to gatus"
}

# THE NEGATIVE CONTROL. If a real machine going down also rendered `?`, the test above
# would pass for the wrong reason and the ghost marker would mean nothing. A host that
# IS on the roster and IS failing must still be a plain red dot.
@test "...and a genuinely down machine is still a down dot, not a ghost" {
  STUB_DISPLAY="pi4-worker4=w4" run "$MODULE"
  assert_success
  assert_output --partial "w4<span color='#ef5734'>○</span>"
  refute_output --partial "w4<span color='#ffcc2f'>?</span>"
  refute_output --partial "Display tokens that name nothing"
}

@test "a host rostered but never enrolled is a down dot, not a ghost" {
  # Declared-but-never-reported is a REAL fleet fact (the machine owes a heartbeat),
  # unlike a ghost, which is a config fact. Conflating them would hide enrolment bugs.
  STUB_ROSTER="linux-cachyos cachy-laptop" STUB_DISPLAY="cachy-laptop=lap" run "$MODULE"
  assert_success
  assert_output --partial "lap<span color='#ef5734'>○</span>"
  assert_output --partial "cachy-laptop: NEVER REPORTED"
  refute_output --partial "Display tokens that name nothing"
}

@test "a group token naming a group gatus does not have renders as a ghost" {
  STUB_DISPLAY="@nosuchgroup=xx" run "$MODULE"
  assert_success
  assert_output --partial "xx<span color='#ffcc2f'>?</span>"
  assert_output --partial "@nosuchgroup: not on the roster, unknown to gatus"
}

@test "a real group is never a ghost, however unhealthy its members are" {
  # The ghost check must key on "does this group exist", not "is it happy" - or an
  # entirely-down group would be reported as a config typo and nobody would go look.
  STUB_DISPLAY="@k3s=k3s" run "$MODULE"
  assert_success
  refute_output --partial "Display tokens that name nothing"
}

# --- a group is not one machine -----------------------------------------------
#
# `k3s○` claimed the cluster was down while 8 of 9 nodes were healthy and the ninth
# was a workstation somebody had switched off. worst_of() scored a GROUP the way it
# scores a MACHINE, so one unhappy member painted the whole group red - which made
# red mean "at least one of these is imperfect", i.e. red nearly always, i.e. nothing.

@test "a group with one member down is amber, not red" {
  # pi4-worker4 is failing; pi5-master is up. That is DEGRADED, not down.
  STUB_DISPLAY="@k3s=k3s" run "$MODULE"
  assert_success
  assert_output --partial "k3s<span color='#ffcc2f'>●</span>"
  refute_output --partial "k3s<span color='#ef5734'>○</span>"
}

@test "a group with every member up draws no dot" {
  STUB_DISPLAY="@homelab=hl" run "$MODULE"
  assert_success
  refute_output --partial "hl<span"
}

# THE NEGATIVE CONTROL for the above: if amber were returned whenever ANYTHING was
# wrong, a group that is entirely gone would also be amber and the bar could never
# say "this whole thing is down". Red has to still be reachable.
@test "...and a group with NO member up is still red" {
  STUB_ROSTER="pi4-worker4" STUB_DISPLAY="@k3s=k3s" run "$MODULE"
  assert_success
  assert_output --partial "k3s<span color='#ef5734'>○</span>"
  refute_output --partial "k3s<span color='#ffcc2f'>●</span>"
}

# --- the bar is the icon alone until something is wrong -----------------------
#
# Four green dots cost 180px, and with them the clock fell off a 1920 screen. All four
# coming back when one goes amber would push it off exactly when the bar matters, so
# only the unhappy token draws.

# custom/health already says "all is well", so a healthy fleet prints empty text and
# hide-empty-text drops the chip; it comes back beside the heart only when something is off.
@test "a fully healthy fleet prints no chip at all" {
  STUB_ROSTER="linux-cachyos gp-mac pi5-master" STUB_DISPLAY="linux-cachyos=main gp-mac=gp" run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" ""
  assert_equal "$(jq -r .class <<< "$output")" healthy
  assert_output --partial "linux-cachyos: up"
}

@test "a healthy roster with a ghost token still shows the chip" {
  STUB_ROSTER="linux-cachyos gp-mac pi5-master" STUB_DISPLAY="linux-cachyos=main retired-box=rb" run "$MODULE"
  assert_success
  assert_output --partial "rb<span color='#ffcc2f'>?</span>"
}

@test "one host down draws that token and not its healthy sibling" {
  STUB_DISPLAY="linux-cachyos=main pi4-worker4=w4" run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" \
    "<span color='#ffcc2f'>"$'\U000F0430'"</span> w4<span color='#ef5734'>○</span>"
}

@test "a rostered host with no token is an amber icon, no dots, named on hover" {
  STUB_DISPLAY="linux-cachyos=main" run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ffcc2f'>"$'\U000F0430'"</span>"
  assert_equal "$(jq -r .class <<< "$output")" degraded
  assert_output --partial "pi4-worker4: DOWN"
}

# --- transient (~) tokens: a laptop only ever draws a ghost marker ------------

@test "a ~ token for a host that is up draws nothing" {
  STUB_DISPLAY="linux-cachyos=main ~gp-mac=gp" run "$MODULE"
  assert_success
  refute_output --partial " gp<"
}

@test "a ~ token for a host that is not up draws nothing at all" {
  # pi4-worker4's last result is a failure 2h old: a normal token draws it red.
  STUB_DISPLAY="linux-cachyos=main pi4-worker4=w4" run "$MODULE"
  assert_output --partial "w4<span color='#ef5734'>○</span>"
  # The same host as ~ leaves no label and no dot behind.
  STUB_DISPLAY="linux-cachyos=main ~pi4-worker4=w4" run "$MODULE"
  assert_success
  refute_output --partial " w4<"
}

@test "a ~ host off the roster does not turn the fleet icon amber" {
  # cachy-laptop: reported once, 2h ago, now closed. Not on the roster.
  cat > "$STATUSES" <<JSON
[
  {"name":"linux-cachyos","group":"homelab","results":[{"success":true,"timestamp":"$NOW"}]},
  {"name":"cachy-laptop","group":"homelab","results":[{"success":true,"timestamp":"$OLD"}]}
]
JSON
  STUB_ROSTER="linux-cachyos" STUB_DISPLAY="linux-cachyos=main ~cachy-laptop=lap" run "$MODULE"
  assert_success
  assert_output --partial '"class": "healthy"'
  refute_output --partial " lap<"
  # ...but the tooltip still says where it is.
  assert_output --partial "cachy-laptop (only shown when online): STALE"
}

@test "a ~ token naming a host gatus has never heard of is still a ghost" {
  STUB_DISPLAY="linux-cachyos=main ~typo-laptop=lap" run "$MODULE"
  assert_success
  assert_output --partial "lap<span color='#ffcc2f'>?</span>"
}

# --- where the roster comes from ----------------------------------------------

@test "a roster or display left in the env is not read" {
  # The env copies are gone; a stale one on some machine must not come back to life.
  export FLEET_ROSTER="retired-box" FLEET_DISPLAY="retired-box=rb"
  STUB_DISPLAY="linux-cachyos=main" run "$MODULE"
  assert_success
  refute_output --partial "retired-box"
  refute_output --partial " rb<"
}

@test "no roster ever fetched falls back to reporting hosts and says so" {
  STUB_ROSTER_MODE=down run "$MODULE"
  assert_success
  assert_output --partial "no roster from http://stub/roster: reporting hosts only"
  assert_output --partial "pi4-worker4: DOWN"
}

@test "a failed, non-JSON or empty roster fetch keeps the last good roster" {
  # gp-mac is on the roster fetched first; the later roster would drop it.
  STUB_DISPLAY="gp-mac=gp" run "$MODULE"
  assert_success
  for mode in down html empty; do
    roster="linux-cachyos"; [ "$mode" = empty ] && roster=""
    STUB_ROSTER="$roster" STUB_DISPLAY="" STUB_ROSTER_MODE=$mode run "$MODULE"
    assert_success
    refute_output --partial "reporting hosts only"
    assert_output --partial "gp-mac: up"
    assert_output --partial "pi4-worker4: DOWN"
  done
  # Negative control: a good fetch does replace it.
  STUB_ROSTER="linux-cachyos" STUB_DISPLAY="" run "$MODULE"
  refute_output --partial "pi4-worker4: DOWN"
}

@test "a cached roster younger than FLEET_ROSTER_TTL_MIN is not fetched again" {
  FLEET_ROSTER_TTL_MIN=10 run "$MODULE"
  FLEET_ROSTER_TTL_MIN=10 run "$MODULE"
  assert_success
  assert_equal "$(grep -c '/roster$' "$CURL_LOG")" 1
  # TTL 0 always fetches, so the count above is the cache at work, not a dead fetch.
  run "$MODULE"
  assert_equal "$(grep -c '/roster$' "$CURL_LOG")" 2
}

@test "a failed fetch waits a TTL before trying again, on the last good roster" {
  run "$MODULE"
  touch -d '-20 minutes' "$XDG_CACHE_HOME/fleet-pulse/roster.json"
  STUB_ROSTER_MODE=down FLEET_ROSTER_TTL_MIN=10 run "$MODULE"
  STUB_ROSTER_MODE=down FLEET_ROSTER_TTL_MIN=10 run "$MODULE"
  assert_success
  assert_output --partial "pi4-worker4: DOWN"
  # The first run fetched, the stale cache made the second fetch, and the failure held off the third.
  assert_equal "$(grep -c '/roster$' "$CURL_LOG")" 2
}

@test "a failed first fetch waits a TTL too, with no roster cached yet" {
  STUB_ROSTER_MODE=down FLEET_ROSTER_TTL_MIN=10 run "$MODULE"
  STUB_ROSTER_MODE=down FLEET_ROSTER_TTL_MIN=10 run "$MODULE"
  assert_success
  assert_output --partial "reporting hosts only"
  assert_equal "$(grep -c '/roster$' "$CURL_LOG")" 1
}

@test "a GATUS_BASE with a trailing slash still fetches /roster" {
  GATUS_BASE="http://stub/" run "$MODULE"
  refute_output --partial "reporting hosts only"
  assert_equal "$(grep -c '^http://stub/roster$' "$CURL_LOG")" 1
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

# --- the stale window ----------------------------------------------------------
@test "a heartbeat 5 minutes old is stale by the shared 180 s default, fresh when the env raises it" {
  FIVE="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$STATUSES" <<JSON
[
  {"name":"linux-cachyos","group":"homelab","results":[{"success":true,"timestamp":"$FIVE"}]}
]
JSON
  STUB_ROSTER="linux-cachyos" STUB_DISPLAY="linux-cachyos=main" run "$MODULE"
  assert_success
  assert_output --partial "linux-cachyos: STALE"
  FLEET_STALE_AFTER=600 STUB_ROSTER="linux-cachyos" STUB_DISPLAY="linux-cachyos=main" run "$MODULE"
  assert_output --partial "linux-cachyos: up"
}

@test "the stale window has one default, in fleet-pulse-roster.sh, not one per bar" {
  run grep -n 'FLEET_STALE_AFTER:-' "$MODULE" "$REPO_ROOT/.config/sketchybar/plugins/fleet.sh"
  assert_failure
  run grep -c 'FLEET_STALE_AFTER:=' "$REPO_ROOT/.local/lib/fleet-pulse-roster.sh"
  assert_output 1
}

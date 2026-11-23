#!/usr/bin/env bats
# needs.sh: the waybar Needs you chip, Home's one count of what only the human can do, read from the
# `needs` card that rides the retained agents/<host>/summary/overview (`hub phone --json`). What these
# pin: the bar is "!:N" coloured by the card's level, the hover its kind split and oldest rows; the
# newest as_of wins over a host whose state stopped; a count of 0 is a green 0 that still shows; no
# card, or one older than STALE_SECS, reads "!:?" in amber, never a 0; a card that could not read
# every source is amber and says what.
setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/needs.sh"
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css" AGENT_MQTT_CONF=/nonexistent AGENT_MQTT_HOST=broker.test
  G="#a6e34a" Y="#ffcc2f"
  export FX="$BATS_TEST_TMPDIR" NEEDS_NOW=100000 TZ=UTC
  : > "$FX/msgs"
  # The broker: each line of $FX/msgs is one retained message, printed in the -F format asked for.
  cat > "$SANDBOX/bin/mosquitto_sub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/sub.args"
while IFS=$'\t' read -r topic doc; do printf '{"topic":"%s","doc":%s}\n' "$topic" "$doc"; done < "$FX/msgs"
exit 27
STUB
  chmod +x "$SANDBOX/bin/mosquitto_sub"
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }

# send <host> <as_of> <count> <level> [error]: one host's overview with its needs card.
send() {
  local err=null; [ -n "${5:-}" ] && err="\"$5\""
  printf 'agents/%s/summary/overview\t{"state":"warn","rows":[],"as_of":%s,"needs":{"big":"%s","level":"%s","error":%s,"parts":[{"label":"Question","value":"%s","level":"%s"}],"lists":[{"head":"Oldest","rows":[{"text":"Answer the <deploy> ask","sub":"2h dotfiles","level":"warn"}]}]}}\n' \
    "$1" "$2" "$3" "$4" "$err" "$3" "$4" >> "$FX/msgs"
}

@test "the bar is the card's count in its level's colour, and the hover its split and oldest rows" {
  send main 99940 55 warn
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "<span color='$Y'>!:55</span>"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 0 "<b>Needs you</b>  55 waiting on you"
  assert_line --index 1 "Question 55"
  assert_line --index 2 "<b>Oldest</b>"
  assert_line --index 3 "Answer the &lt;deploy&gt; ask  <span color='#7f7f7f'>2h dotfiles</span>"
  assert_output --partial "on main; click for the hub"
  grep -q -- "-t agents/+/summary/overview --retained-only" "$FX/sub.args"
}

@test "the newest count wins over a host whose fleet state stopped" {
  send razer_laptop 50000 3 warn "fleet state stopped reporting"
  send main 99940 55 warn
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>!:55</span>"
  assert_output --partial "on main"
}

@test "nothing waiting is a green 0 that still shows" {
  send main 99940 0 ok
  run "$MODULE"
  assert_equal "$(text)" "<span color='$G'>!:0</span>"
  assert_equal "$(class)" ok
}

@test "no card on the broker reads ? in amber, never 0" {
  printf 'agents/main/summary/overview\t{"state":"ok","rows":[]}\n' > "$FX/msgs"
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "<span color='$Y'>!:?</span>"
  assert_equal "$(class)" warn
  assert_output --partial "not read: no host sent a Needs you card"
}

@test "a count older than STALE_SECS reads ? in amber with its age" {
  send main 90000 55 warn
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>!:?</span>"
  assert_output --partial "166m old (from main)"
}

@test "a card that could not read every source says what, in amber" {
  send main 99940 4 warn "agent-ask could not be read"
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>!:4</span>"
  assert_output --partial "not all read: agent-ask could not be read"
}

@test "no broker named reads ? in amber and never subscribes" {
  send main 99940 55 warn
  AGENT_MQTT_HOST= run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>!:?</span>"
  assert_output --partial "AGENT_MQTT_HOST is unset"
  [ ! -e "$FX/sub.args" ]
}

@test "nothing waiting with a source unread still says what, in amber" {
  printf 'agents/main/summary/overview\t{"as_of":99940,"needs":{"big":"0","level":"warn","error":"agent-ask could not be read","parts":[],"lists":[]}}\n' > "$FX/msgs"
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>!:0</span>"
  run tip
  assert_line --index 0 "<b>Needs you</b>  0 waiting on you"
  assert_line --index 1 "<span color='$Y'>not all read: agent-ask could not be read</span>"
}

@test "one host's unreadable payload does not hide another host's card" {
  printf 'agents/razer_laptop/summary/overview\tnot json\n' > "$FX/msgs"
  send main 99940 55 warn
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>!:55</span>"
}

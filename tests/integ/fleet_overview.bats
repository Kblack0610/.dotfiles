#!/usr/bin/env bats
# fleet-overview: the waybar chips as one document for the phone widget. What these pin: the html
# is each chip's phone lines in bar order, so the widget and the bar share a source; Pango spans
# become the <font> the Template widget renders, in the phone palette; state is the worst chip;
# a chip with no phone lines gives its hover; a chip that prints nothing is named and red, never
# a quiet gap.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CMD="$REPO_ROOT/.local/bin/fleet-overview"
  export FLEET_OVERVIEW_CHIPS="$BATS_TEST_TMPDIR/chips"
  mkdir -p "$FLEET_OVERVIEW_CHIPS"
  cp "$REPO_ROOT/.config/waybar/pango.sh" "$FLEET_OVERVIEW_CHIPS/"
  for c in ai_agents dispatch ci_runners day; do chip "$c" "{\"class\": \"ok\", \"phone\": \"$c line\"}"; done
}

# chip <name> <output>: a stub chip that prints <output>.
chip() {
  printf '#!/usr/bin/env bash\ncat <<'\''OUT'\''\n%s\nOUT\n' "$2" > "$FLEET_OVERVIEW_CHIPS/$1.sh"
  chmod +x "$FLEET_OVERVIEW_CHIPS/$1.sh"
}

html() { jq -r .html <<< "$output"; }
state() { jq -r .state <<< "$output"; }

@test "the html is each chip's phone lines in bar order, then the time" {
  run "$CMD"
  assert_success
  assert_equal "$(html)" "ai_agents line<br>dispatch line<br>ci_runners line<br>day line<br>as of $(date +%H:%M)"
  assert_equal "$(state)" ok
}

@test "a chip's lines become <br>, its spans <font> in the phone palette" {
  chip day '{"class": "warn", "phone": "a <span color='\''#ef5734'\''>red</span>\nb <span color='\''#ffcc2f'\''>amber</span> <span color='\''#a6e34a'\''>ok</span>"}'
  run "$CMD"
  run html
  assert_output --partial "a <font color='#e53935'>red</font><br>b <font color='#f9a825'>amber</font> <font color='#43a047'>ok</font>"
  refute_output --partial "<span"
}

@test "a colour outside the level palette passes through" {
  chip day '{"class": "ok", "phone": "<span color='\''#123456'\''>x</span>"}'
  run "$CMD"
  run html
  assert_output --partial "<font color='#123456'>x</font>"
}

@test "state is the worst chip: critical over warn, inactive counts as ok" {
  chip ai_agents '{"class": "inactive", "phone": "a"}'
  run "$CMD"
  assert_equal "$(state)" ok
  chip dispatch '{"class": "warn", "phone": "b"}'
  run "$CMD"
  assert_equal "$(state)" warn
  chip day '{"class": "critical", "phone": "c"}'
  run "$CMD"
  assert_equal "$(state)" critical
}

@test "a chip with no phone lines gives its hover, which says why" {
  chip dispatch '{"class": "warn", "tooltip": "cannot read prom"}'
  run "$CMD"
  run html
  assert_output --partial "ai_agents line<br>cannot read prom<br>ci_runners line"
}

# Negative control: a dead chip must not read as a shorter, healthy overview.
@test "a chip that prints nothing or junk is named, and the overview is red" {
  chip dispatch ''
  chip day 'not json'
  run "$CMD"
  assert_success
  assert_equal "$(state)" critical
  run html
  assert_output --partial "dispatch: the chip printed nothing"
  assert_output --partial "day: the chip printed nothing"
}

@test "the real chips with Prometheus down still make a document that says so" {
  export FLEET_OVERVIEW_CHIPS="$REPO_ROOT/.config/waybar" CC_PROM_URL=http://prom.test
  export DAYLOG_DIR="$BATS_TEST_TMPDIR/daylog"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$SANDBOX/bin/curl"
  chmod +x "$SANDBOX/bin/curl"
  run "$CMD"
  assert_success
  assert_equal "$(state)" critical
  run html
  assert_output --partial "cannot read http://prom.test"
  refute_output --partial "the chip printed nothing"
}

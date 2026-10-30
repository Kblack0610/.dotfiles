#!/usr/bin/env bats
# ai_agents.sh: the waybar agents chip. What these pin: one count per state per project, so
# the chip's width follows the projects and not the agents (a glyph per agent pushed the
# clock off the bar); one agent is the bare glyph; attention comes first; the hover still
# lists every agent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ai_agents.sh"
  export FX="$BATS_TEST_TMPDIR" AGENT_PANEL="$BATS_TEST_TMPDIR/agent-panel"
  : > "$FX/rows"
  cat > "$AGENT_PANEL" <<'STUB'
#!/usr/bin/env bash
cat "$FX/rows"
STUB
  chmod +x "$AGENT_PANEL"
}

# agents project glyph... -> one panel row per glyph.
agents() {
  local project="$1" glyph i=0
  shift
  for glyph in "$@"; do
    i=$((i + 1))
    printf 'hub/%s:%s\t%s\t%s\tjob %s\n' "$project" "$i" "$glyph" "$project" "$i" >> "$FX/rows"
  done
}

# Colours gone, so a test reads what the bar says. The leading icon and space go with them.
bar() { jq -r .text <<< "$output" | sed -E "s/<[^>]*>//g; s/^[^a-z]*//"; }

@test "agents fold into one count per state, per project" {
  agents dotfiles '~' '✓' '~' '~' '~' '✓' '~'
  agents unity-core '~' '~' '~'
  run "$MODULE"
  assert_success
  assert_equal "$(bar)" "dot ~5 ✓2 · uni ~3"
}

@test "one agent in a state is the bare glyph" {
  agents dotfiles '~'
  agents shack '✓' '~'
  run "$MODULE"
  assert_success
  assert_equal "$(bar)" "dot ~ · shk ~ ✓"
}

@test "attention comes first, whatever order the panel lists agents in" {
  agents dotfiles '✓' '~' '!' '✓' '!' '~' '~'
  run "$MODULE"
  assert_success
  assert_equal "$(bar)" "dot !2 ~3 ✓2"
  assert_equal "$(jq -r .class <<< "$output")" urgent
}

@test "the width stays put as agents are added to a state" {
  agents dotfiles '~' '~'
  run "$MODULE"
  local two="$(bar)"
  agents dotfiles '~' '~' '~' '~' '~' '~' '~'
  run "$MODULE"
  assert_equal "${#two}" "$(bar | tr -d '\n' | wc -m)"
}

@test "the hover still lists every agent" {
  agents dotfiles '~' '~' '✓'
  run "$MODULE"
  assert_success
  local tip
  tip="$(jq -r .tooltip <<< "$output")"
  assert_equal "$(grep -c 'hub/dotfiles:' <<< "$tip")" 3
}

@test "no agents reads inactive" {
  run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" inactive
}

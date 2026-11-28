#!/usr/bin/env bats
# machine_mode.sh: the waybar chip. What these pin: the mode's initial in every mode, open included,
# neutral because a mode is a choice and not a health state (dashboards.md rule 5); the hover is the
# command's own output, escaped; the module is wired for the toggle.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/hypr'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/machine_mode.sh"
  ICON=$'\uf1de' # nf-fa-sliders, as an escape so no editor can strip it
  export FX="$BATS_TEST_TMPDIR" AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  ln -s "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  mkdir -p "$HOME/.agent"
}

mode() { printf 'MACHINE_MODE=%s\n' "$1" > "$HOME/.agent/machine-mode.env"; }

@test "the bar is the mode's initial and neutral in every mode, open included" {
  for m in reserved:R shared:S open:O full:F; do
    mode "${m%:*}"
    run "$MODULE"
    assert_success
    assert_equal "$(jq -r .text <<< "$output")" "$ICON ${m#*:}"
    assert_equal "$(jq -r .class <<< "$output")" ok
  done
}

@test "the hover is the command's own lines and the click hint" {
  mode shared
  run "$MODULE"
  tip="$(jq -r .tooltip <<< "$output")"
  [[ "$tip" == "mode: shared"* ]]
  [[ "$tip" == *"new agent sessions: as today"* ]]
  [[ "$tip" != *"local Unity runs"* ]]
  [[ "$tip" == *"click: next mode" ]]
}

@test "the module is gated, signalled and in the registry" {
  run grep -c 'modules.sh gate custom/machine-mode' "$REPO_ROOT/.config/waybar/config.base"
  assert_output 1
  run grep -c '^mode|.*|custom/machine-mode$' "$REPO_ROOT/.config/waybar/modules.registry"
  assert_output 1
  run grep -c '"custom/machine-mode",\?$' "$REPO_ROOT/.config/waybar/config.desktop"
  assert_output 1
}

@test "the chip sits right after the disk chip on the desktop bar, and not in the status group" {
  run grep -A1 '"custom/storage",' "$REPO_ROOT/.config/waybar/config.desktop"
  assert_line --partial '"custom/machine-mode",'
  run awk '/"group\/status": \{/,/\]/' "$REPO_ROOT/.config/waybar/config.base"
  refute_output --partial machine-mode
}

@test "each pinbar-mode leaf sets the mode of its own key" {
  run hypr_dump registry
  assert_success
  local reg=$output
  run jq -r '.[] | select(.submap == "pinbar-mode") | "\(.key) \(.description)|\(.dispatcher) \(.arg)"' <<<"$reg"
  for m in r:reserved s:shared o:open f:full; do
    assert_line "${m%:*} ${m#*:}|exec \$HOME/.local/bin/machine-mode ${m#*:}"
  done
  assert_line 'escape back|submap pinbar'
  assert_line 'q exit|submap reset'
  run jq -r '.[] | select(.submap == "pinbar" and .key == "m") | "\(.description)|\(.dispatcher) \(.arg)"' <<<"$reg"
  assert_output 'machine mode >|submap pinbar-mode'
}

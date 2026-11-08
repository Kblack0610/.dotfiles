#!/usr/bin/env bats
# machine_mode.sh: the waybar chip. What these pin: the mode's initial in every mode, open included,
# neutral because a mode is a choice and not a health state (dashboards.md rule 5); amber in any
# mode when the runner part never reached the cluster; the hover is the command's own output, escaped; the
# chip has no text on a machine with no pool runners; the module is wired for the toggle.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/machine_mode.sh"
  ICON=$'\uf1de' # nf-fa-sliders, as an escape so no editor can strip it
  export FX="$BATS_TEST_TMPDIR" AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds" CC_PROM_URL=http://prom.test
  touch "$FX/actions.runner.host-unity-pool-1.service"
  export MACHINE_MODE_RUNNER_UNITS="$FX/actions.runner.*-unity-pool-*.service"
  ln -s "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$SANDBOX/bin/curl"
  chmod +x "$SANDBOX/bin/curl"
  mkdir -p "$HOME/.agent"
}

mode() { printf 'MACHINE_MODE=%s\nRUNNERS_PINNED=%s\n' "$1" "${2:-yes}" > "$HOME/.agent/machine-mode.env"; }

@test "the bar is the mode's initial and neutral in every mode" {
  for m in reserved:R shared:S open:O full:F; do
    mode "${m%:*}"
    run "$MODULE"
    assert_success
    assert_equal "$(jq -r .text <<< "$output")" "$ICON ${m#*:}"
    assert_equal "$(jq -r .class <<< "$output")" ok
  done
}

@test "a switch that never reached the cluster paints the initial amber" {
  mode reserved no
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "$ICON <span color='#ffcc2f'>R</span>"
  assert_equal "$(jq -r .class <<< "$output")" warn
  assert_equal "$(jq -r '.tooltip | contains("was not applied")' <<< "$output")" true
}

@test "open still warns when the switch to it never reached the cluster" {
  mode open no
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "$ICON <span color='#ffcc2f'>O</span>"
  assert_equal "$(jq -r .class <<< "$output")" warn
}

@test "the hover is the command's own lines and the click hint" {
  mode shared
  run "$MODULE"
  tip="$(jq -r .tooltip <<< "$output")"
  [[ "$tip" == "mode: shared"* ]]
  [[ "$tip" == *"local Unity runs: 2, plus 0 when there is room"* ]]
  [[ "$tip" == *"click: next mode" ]]
}

@test "no pool runners here: empty text, so the chip hides" {
  export MACHINE_MODE_RUNNER_UNITS="$FX/none-*.service"
  run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" ""
}

@test "the module is gated, signalled and in the registry" {
  run grep -c 'modules.sh gate custom/machine-mode' "$REPO_ROOT/.config/waybar/config.base"
  assert_output 1
  run grep -c '^mode|.*|custom/machine-mode$' "$REPO_ROOT/.config/waybar/modules.registry"
  assert_output 1
  # Right of the disk chip on the desktop bar, and out of the status group (so off the pin).
  run grep -A1 '"custom/storage",$' "$REPO_ROOT/.config/waybar/config.desktop"
  assert_line --index 1 --regexp '^ *"custom/machine-mode",$'
  run grep -c '"custom/machine-mode",\?$' "$REPO_ROOT/.config/waybar/config.base"
  assert_output 0
}

@test "Super+A m has a leaf per mode, keyed by its initial, plus auto" {
  run awk '/^submap = pinbar-mode$/,/^submap = pinbar-utils$/' "$REPO_ROOT/.config/hypr/conf.d/leader.conf"
  local block="$output" m
  for m in $(grep -v '^#' "$REPO_ROOT/.config/machine-mode/modes" | grep . | cut -d'|' -f1) auto; do
    grep -qE "^bindpd = ,${m:0:1}, [^,]+, exec, \\\$HOME/\.local/bin/machine-mode $m$" <<<"$block" || fail "no leaf for $m"
  done
  run grep -c 'bindpd = ,m, machine mode >, submap, pinbar-mode' "$REPO_ROOT/.config/hypr/conf.d/leader.conf"
  assert_output 1
}
